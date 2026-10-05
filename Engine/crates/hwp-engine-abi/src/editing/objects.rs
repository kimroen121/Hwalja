//! Pictures, equations and tables as objects: where they are laid out, their properties,
//! and the equation preview.
use super::*;
use rhwp::model::{control::Control, shape::ShapeObject};
use serde::Serialize;
use serde_json::{Map, Value};

/// Table property names that differ from the object names `ObjectProps` uses.
const TABLE_NAMES: [(&str, &str); 4] = [
    ("outerMarginLeft", "outerLeft"),
    ("outerMarginRight", "outerRight"),
    ("outerMarginTop", "outerTop"),
    ("outerMarginBottom", "outerBottom"),
];
/// Caption sides and, beside the object, their alignment, in the order rhwp numbers them
/// for tables.
const CAPTION_SIDES: [&str; 4] = ["Left", "Right", "Top", "Bottom"];
const CAPTION_ALIGNS: [&str; 3] = ["Top", "Center", "Bottom"];
/// The positions of 캡션 넣기: above, below, or beside at the top, middle or bottom.
pub(super) const CAPTIONS: [&str; 9] = [
    "None",
    "Top",
    "Bottom",
    "LeftTop",
    "LeftCenter",
    "LeftBottom",
    "RightTop",
    "RightCenter",
    "RightBottom",
];
/// Longest equation script accepted, in characters.
const SCRIPT_LIMIT: usize = 4096;

fn number(json: &Value, key: &str) -> Option<f64> {
    json.get(key).and_then(Value::as_f64)
}
fn index(json: &Value, key: &str) -> Option<u32> {
    json.get(key).and_then(Value::as_u64).map(|v| v as u32)
}
fn object_json(props: &impl Serialize) -> Map<String, Value> {
    match serde_json::to_value(props) {
        Ok(Value::Object(map)) => map.into_iter().filter(|(_, v)| !v.is_null()).collect(),
        _ => Map::new(),
    }
}
/// Reads rhwp's caption fields as one `caption` position.
fn read_caption(map: &mut Map<String, Value>) {
    let name = |key: &str, names: &[&'static str]| match map.get(key) {
        Some(Value::Number(n)) => n.as_u64().and_then(|n| names.get(n as usize).copied()),
        Some(Value::String(s)) => names.iter().find(|n| **n == s.as_str()).copied(),
        _ => None,
    };
    let side = name("captionDirection", &CAPTION_SIDES).unwrap_or("Bottom");
    let align = name("captionVertAlign", &CAPTION_ALIGNS).unwrap_or("Top");
    let position = match (map.get("hasCaption") == Some(&Value::Bool(true)), side) {
        (false, _) => "None".to_string(),
        (true, "Left" | "Right") => format!("{side}{align}"),
        (true, _) => side.to_string(),
    };
    map.insert("caption".into(), Value::String(position));
}
/// Writes `caption` as rhwp's caption fields; tables number them.
fn write_caption(map: &mut Map<String, Value>, table: bool) {
    let Some(Value::String(position)) = map.remove("caption") else {
        return;
    };
    map.insert("hasCaption".into(), Value::Bool(position != "None"));
    if position == "None" {
        return;
    }
    let (side, align) = ["Left", "Right"]
        .iter()
        .find_map(|side| position.strip_prefix(side).map(|align| (*side, align)))
        .unwrap_or((position.as_str(), "Top"));
    let value = |name: &str, names: &[&str]| match names.iter().position(|n| *n == name) {
        Some(n) if table => Value::from(n),
        _ => Value::String(name.to_string()),
    };
    map.insert("captionDirection".into(), value(side, &CAPTION_SIDES));
    map.insert("captionVertAlign".into(), value(align, &CAPTION_ALIGNS));
}
fn rename(mut map: Map<String, Value>, to_table: bool) -> Map<String, Value> {
    for (object, table) in TABLE_NAMES {
        let (from, to) = if to_table {
            (object, table)
        } else {
            (table, object)
        };
        if let Some(value) = map.remove(from) {
            map.insert(to.into(), value);
        }
    }
    map
}
fn parse<T: serde::de::DeserializeOwned>(
    text: Result<String, rhwp::error::HwpError>,
) -> Result<T, EditError> {
    serde_json::from_str(&text.map_err(|_| EditError::UnsupportedTarget)?)
        .map_err(|_| EditError::RenderFailed)
}
pub(super) fn is_script(script: &str) -> bool {
    !script.trim().is_empty()
        && script.chars().count() <= SCRIPT_LIMIT
        && script
            .chars()
            .all(|c| matches!(c, '\n' | '\t') || !c.is_control())
}

impl EditSession {
    /// The control `o` names, checked to be of its kind.
    fn control(&self, o: &ObjectRef) -> Result<&Control, EditError> {
        let control = commands::get(
            self.core.document(),
            &EditTarget {
                section: o.section,
                paragraph: o.paragraph,
                cell: None,
                note: None,
            },
        )?
        .controls
        .get(o.control as usize)
        .ok_or(EditError::InvalidInput)?;
        let matches = match (o.kind, control) {
            (ObjectKind::Picture, Control::Picture(_)) => true,
            (ObjectKind::Picture, Control::Shape(s)) => matches!(**s, ShapeObject::Picture(_)),
            (ObjectKind::Equation, Control::Equation(_)) => true,
            (ObjectKind::Table, Control::Table(_)) => true,
            _ => false,
        };
        if matches {
            Ok(control)
        } else {
            Err(EditError::UnsupportedTarget)
        }
    }
    /// Pictures and equations of the body laid out on `page`, bottom first.
    pub(super) fn placed(&self, page: u32) -> Result<Vec<PlacedObject>, EditError> {
        let layout: Value = parse(self.core.get_page_control_layout_native(page))?;
        let controls = layout["controls"]
            .as_array()
            .ok_or(EditError::RenderFailed)?;
        Ok(controls
            .iter()
            .filter_map(|c| {
                let kind = match c["type"].as_str()? {
                    "image" => ObjectKind::Picture,
                    "equation" => ObjectKind::Equation,
                    _ => return None,
                };
                // Objects in cells, notes, headers and text boxes are not selectable yet.
                if ["cellIdx", "cellPath", "noteRef", "headerFooter"]
                    .iter()
                    .any(|k| c.get(k).is_some())
                {
                    return None;
                }
                let object = ObjectRef {
                    kind,
                    section: index(c, "secIdx")?,
                    paragraph: index(c, "paraIdx")?,
                    control: index(c, "controlIdx")?,
                };
                self.control(&object).ok()?;
                Some(PlacedObject {
                    object,
                    rect: PageRect {
                        page,
                        x: number(c, "x")?,
                        y: number(c, "y")?,
                        width: number(c, "w")?,
                        height: number(c, "h")?,
                    },
                })
            })
            .collect())
    }
    /// The topmost picture or equation under a page point (96 dpi, top-left origin).
    pub fn object_at(
        &self,
        revision: u64,
        page: u32,
        x: f64,
        y: f64,
    ) -> Result<Option<PlacedObject>, EditError> {
        self.check_revision(revision)?;
        if page >= self.core.page_count() {
            return Err(EditError::InvalidInput);
        }
        Ok(self.placed(page)?.into_iter().rev().find(|o| {
            let r = &o.rect;
            (r.x..=r.x + r.width).contains(&x) && (r.y..=r.y + r.height).contains(&y)
        }))
    }
    /// Where `object` is laid out, looking from `page` outward.
    pub fn place(
        &self,
        revision: u64,
        object: &ObjectRef,
        page: u32,
    ) -> Result<PlacedObject, EditError> {
        self.check_revision(revision)?;
        let count = self.core.page_count();
        let near = page.min(count.saturating_sub(1));
        (0..count)
            .flat_map(|d| [near.checked_sub(d), near.checked_add(d + 1)])
            .flatten()
            .filter(|&p| p < count)
            .find_map(|p| {
                self.placed(p)
                    .ok()?
                    .into_iter()
                    .find(|o| &o.object == object)
            })
            .ok_or(EditError::UnsupportedTarget)
    }
    pub fn object_props(&self, o: &ObjectRef) -> Result<ObjectProps, EditError> {
        self.control(o)?;
        let (s, p, c) = (o.section as usize, o.paragraph as usize, o.control as usize);
        let json: Value = match o.kind {
            ObjectKind::Picture => parse(self.core.get_picture_properties_native(s, p, c))?,
            ObjectKind::Equation => parse(
                self.core
                    .get_equation_properties_native(s, p, c, None, None),
            )?,
            ObjectKind::Table => parse(self.core.get_table_properties_native(s, p, c))?,
        };
        let Value::Object(mut map) = json else {
            return Err(EditError::RenderFailed);
        };
        if o.kind != ObjectKind::Equation {
            read_caption(&mut map);
        }
        serde_json::from_value(Value::Object(rename(map, false)))
            .map_err(|_| EditError::RenderFailed)
    }
    pub fn cell_props(&self, t: &EditTarget) -> Result<CellProps, EditError> {
        commands::get(self.core.document(), t)?;
        let c = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        parse(self.core.get_cell_properties_native(
            t.section as usize,
            t.paragraph as usize,
            c.control as usize,
            c.cell as usize,
        ))
    }
    pub(super) fn validate_object(
        &self,
        o: &ObjectRef,
        props: &ObjectProps,
    ) -> Result<(), EditError> {
        self.control(o)?;
        let length = |v: Option<i32>| v.is_none_or(|v| v.abs() <= 1_000_000);
        let percent = |v: Option<i32>| v.is_none_or(|v| (-100..=100).contains(&v));
        let one_of =
            |v: &Option<String>, names: &[&str]| v.as_deref().is_none_or(|v| names.contains(&v));
        let valid = props.width.is_none_or(|v| (1..=1_000_000).contains(&v))
            && props.height.is_none_or(|v| (1..=1_000_000).contains(&v))
            && [
                props.horz_offset,
                props.vert_offset,
                props.outer_margin_left,
                props.outer_margin_right,
                props.outer_margin_top,
                props.outer_margin_bottom,
                props.padding_left,
                props.padding_right,
                props.padding_top,
                props.padding_bottom,
                props.crop_left,
                props.crop_right,
                props.crop_top,
                props.crop_bottom,
                props.cell_spacing,
            ]
            .into_iter()
            .all(length)
            && percent(props.brightness)
            && percent(props.contrast)
            && props
                .rotation_angle
                .is_none_or(|v| (-360..=360).contains(&v))
            && props.page_break.is_none_or(|v| v <= 2)
            && one_of(
                &props.text_wrap,
                &["Square", "TopAndBottom", "BehindText", "InFrontOfText"],
            )
            && one_of(&props.horz_rel_to, &["Paper", "Page", "Column", "Para"])
            && one_of(&props.horz_align, &["Left", "Center", "Right"])
            && one_of(&props.vert_rel_to, &["Paper", "Page", "Para"])
            && one_of(&props.vert_align, &["Top", "Center", "Bottom"])
            && one_of(&props.effect, &["RealPic", "GrayScale", "BlackWhite"])
            && one_of(&props.caption, &CAPTIONS)
            && (o.kind != ObjectKind::Equation || props.caption.is_none())
            && props.script.as_deref().is_none_or(is_script)
            && props.font_size.is_none_or(|v| (100..=12_700).contains(&v))
            && props.color.is_none_or(|v| v <= 0x00ff_ffff)
            && props.baseline.is_none_or(|v| i16::try_from(v).is_ok())
            && props.original_width.is_none()
            && props.original_height.is_none();
        if valid {
            Ok(())
        } else {
            Err(EditError::InvalidInput)
        }
    }
    pub(super) fn validate_cell(&self, t: &EditTarget, props: &CellProps) -> Result<(), EditError> {
        commands::get(self.core.document(), t)?;
        t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let length = |v: Option<i32>| v.is_none_or(|v| (0..=100_000).contains(&v));
        if props.width.is_none_or(|v| (1..=1_000_000).contains(&v))
            && props.height.is_none_or(|v| (1..=1_000_000).contains(&v))
            && [
                props.padding_left,
                props.padding_right,
                props.padding_top,
                props.padding_bottom,
            ]
            .into_iter()
            .all(length)
            && props.vertical_align.is_none_or(|v| v <= 2)
        {
            Ok(())
        } else {
            Err(EditError::InvalidInput)
        }
    }
    pub(super) fn set_object(
        &mut self,
        o: &ObjectRef,
        props: &ObjectProps,
    ) -> Result<(), EditError> {
        let (s, p, c) = (o.section as usize, o.paragraph as usize, o.control as usize);
        let mut json = object_json(props);
        write_caption(&mut json, o.kind == ObjectKind::Table);
        let core = &mut self.core;
        match o.kind {
            ObjectKind::Picture => {
                core.set_picture_properties_native(s, p, c, &Value::Object(json).to_string())
            }
            ObjectKind::Equation => core.set_equation_properties_native(
                s,
                p,
                c,
                None,
                None,
                &Value::Object(json).to_string(),
            ),
            ObjectKind::Table => core.set_table_properties_native(
                s,
                p,
                c,
                &Value::Object(rename(json, true)).to_string(),
            ),
        }?;
        Ok(())
    }
    pub(super) fn set_cell(&mut self, t: &EditTarget, props: &CellProps) -> Result<(), EditError> {
        let c = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        self.core.set_cell_properties_native(
            t.section as usize,
            t.paragraph as usize,
            c.control as usize,
            c.cell as usize,
            &Value::Object(object_json(props)).to_string(),
        )?;
        Ok(())
    }
    pub(super) fn delete_object(&mut self, o: &ObjectRef) -> Result<(), EditError> {
        let (s, p, c) = (o.section as usize, o.paragraph as usize, o.control as usize);
        match o.kind {
            ObjectKind::Picture => self.core.delete_picture_control_native(s, p, c),
            ObjectKind::Equation => self.core.delete_equation_control_native(s, p, c),
            ObjectKind::Table => self.core.delete_table_control_native(s, p, c),
        }?;
        Ok(())
    }
    /// An equation script laid out as a display list, for previews.
    pub fn equation_preview(
        &self,
        script: &str,
        font_size: u32,
        color: u32,
    ) -> Result<display::Display, EditError> {
        if script.chars().count() > SCRIPT_LIMIT
            || !(100..=12_700).contains(&font_size)
            || color > 0x00ff_ffff
        {
            return Err(EditError::InvalidInput);
        }
        let svg = self
            .core
            .render_equation_preview_native(script, font_size, color)
            .map_err(|_| EditError::RenderFailed)?;
        display::build(&svg).ok_or(EditError::RenderFailed)
    }
}
