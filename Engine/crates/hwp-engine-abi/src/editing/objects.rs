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
/// 그리기 개체 rhwp can draw: 가로 글상자, 직사각형, 타원, 직선, 호.
const SHAPES: [&str; 5] = ["textbox", "rectangle", "ellipse", "line", "arc"];
/// Longest equation script accepted, in characters.
const SCRIPT_LIMIT: usize = 4096;

fn number(json: &Value, key: &str) -> Option<f64> {
    json.get(key).and_then(Value::as_f64)
}
fn index(json: &Value, key: &str) -> Option<u32> {
    json.get(key).and_then(Value::as_u64).map(|v| v as u32)
}
/// rhwp's path from a body paragraph to the cell, 글상자 or caption paragraph `t` names;
/// empty in the body.
fn path(t: &EditTarget) -> Vec<(usize, usize, usize)> {
    t.cell
        .iter()
        .map(|c| (c.control as usize, c.cell as usize, c.paragraph as usize))
        .collect()
}
/// rhwp's path to the paragraph of table cell or 글상자 `c`.
fn cell_path(c: &CellTarget) -> String {
    format!(
        "[{{\"controlIdx\":{},\"cellIdx\":{},\"cellParaIdx\":{}}}]",
        c.control, c.cell, c.paragraph
    )
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
                cell: o.cell.clone(),
                note: None,
                header_footer: None,
            },
        )?
        .controls
        .get(o.control as usize)
        .ok_or(EditError::InvalidInput)?;
        // In a cell rhwp reaches only plain pictures, and the one equation of a table cell's paragraph.
        if let Some(c) = &o.cell {
            let reachable = match o.kind {
                ObjectKind::Picture => matches!(control, Control::Picture(_)),
                ObjectKind::Equation => {
                    self.cell_equation(o.section, o.paragraph, c) == Some(o.control)
                }
                _ => false,
            };
            if !reachable {
                return Err(EditError::UnsupportedTarget);
            }
        }
        let matches = match (o.kind, control) {
            (ObjectKind::Picture, Control::Picture(_)) => true,
            (ObjectKind::Picture, Control::Shape(s)) => matches!(**s, ShapeObject::Picture(_)),
            (ObjectKind::Equation, Control::Equation(_)) => true,
            (ObjectKind::Table, Control::Table(_)) => true,
            (ObjectKind::Shape, Control::Shape(s)) => !matches!(**s, ShapeObject::Picture(_)),
            _ => false,
        };
        if matches {
            Ok(control)
        } else {
            Err(EditError::UnsupportedTarget)
        }
    }
    /// The control index of the only equation in a table cell's paragraph.
    fn cell_equation(&self, section: u32, paragraph: u32, c: &CellTarget) -> Option<u32> {
        let host = commands::get(
            self.core.document(),
            &EditTarget {
                section,
                paragraph,
                cell: None,
                note: None,
                header_footer: None,
            },
        )
        .ok()?;
        if !matches!(
            host.controls.get(c.control as usize),
            Some(Control::Table(_))
        ) {
            return None;
        }
        let target = EditTarget {
            section,
            paragraph,
            cell: Some(c.clone()),
            note: None,
            header_footer: None,
        };
        let controls = &commands::get(self.core.document(), &target).ok()?.controls;
        let mut equations = controls
            .iter()
            .enumerate()
            .filter(|(_, c)| matches!(c, Control::Equation(_)));
        match (equations.next(), equations.next()) {
            (Some((i, _)), None) => Some(i as u32),
            _ => None,
        }
    }
    /// Pictures and equations laid out on `page`, bottom first: those of the body, and
    /// those in a table cell or 글상자 of the body.
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
                    "shape" | "line" | "group" => ObjectKind::Shape,
                    _ => return None,
                };
                // Objects in notes, headers and nested cells are not selectable yet.
                if c.get("noteRef").is_some() || c.get("headerFooter").is_some() {
                    return None;
                }
                let (section, paragraph) = (index(c, "secIdx")?, index(c, "paraIdx")?);
                let (cell, control) = match (c.get("cellPath"), c.get("cellIdx"), kind) {
                    (None, None, _) => (None, index(c, "controlIdx")?),
                    (Some(Value::Array(path)), _, ObjectKind::Picture) if path.len() == 1 => (
                        Some(CellTarget {
                            control: index(&path[0], "controlIndex")?,
                            cell: index(&path[0], "cellIndex")?,
                            paragraph: index(&path[0], "cellParaIndex")?,
                        }),
                        index(c, "controlIdx")?,
                    ),
                    (None, Some(_), ObjectKind::Equation) => {
                        let cell = CellTarget {
                            control: index(c, "controlIdx")?,
                            cell: index(c, "cellIdx")?,
                            paragraph: index(c, "cellParaIdx")?,
                        };
                        let control = self.cell_equation(section, paragraph, &cell)?;
                        (Some(cell), control)
                    }
                    _ => return None,
                };
                let object = ObjectRef {
                    kind,
                    section,
                    paragraph,
                    control,
                    cell,
                };
                let shape = match self.control(&object).ok()? {
                    Control::Shape(s) => Some(&**s),
                    _ => None,
                };
                let (x, y, w, h) = (
                    number(c, "x")?,
                    number(c, "y")?,
                    number(c, "w")?,
                    number(c, "h")?,
                );
                // Each end in proportion to the line's box.
                let ends = match shape {
                    Some(ShapeObject::Line(l)) if l.connector.is_none() => {
                        let along = |v: i32, size: u32, start: f64, extent: f64| {
                            start
                                + if size > 0 {
                                    v as f64 / size as f64 * extent
                                } else {
                                    0.0
                                }
                        };
                        let (cw, ch) = (l.common.width, l.common.height);
                        Some([
                            along(l.start.x, cw, x, w),
                            along(l.start.y, ch, y, h),
                            along(l.end.x, cw, x, w),
                            along(l.end.y, ch, y, h),
                        ])
                    }
                    _ => None,
                };
                Some(PlacedObject {
                    ends,
                    group: matches!(shape, Some(ShapeObject::Group(_))),
                    text_box: shape
                        .and_then(ShapeObject::drawing)
                        .map(|d| d.text_box.is_some()),
                    object,
                    rect: PageRect {
                        page,
                        x,
                        y,
                        width: w,
                        height: h,
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
        let json: Value = match (o.kind, &o.cell) {
            (ObjectKind::Picture, Some(cell)) => parse(
                self.core
                    .get_cell_picture_properties_by_path_native(s, p, &cell_path(cell), c),
            )?,
            (ObjectKind::Equation, Some(cell)) => parse(self.core.get_equation_properties_native(
                s,
                p,
                cell.control as usize,
                Some(cell.cell as usize),
                Some(cell.paragraph as usize),
            ))?,
            (ObjectKind::Picture, None) => parse(self.core.get_picture_properties_native(s, p, c))?,
            (ObjectKind::Equation, None) => parse(
                self.core
                    .get_equation_properties_native(s, p, c, None, None),
            )?,
            (ObjectKind::Table, _) => parse(self.core.get_table_properties_native(s, p, c))?,
            (ObjectKind::Shape, _) => parse(self.core.get_shape_properties_native(s, p, c))?,
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
        // A size-protected object keeps its size unless the same change lifts the protection.
        if props.width.is_some() || props.height.is_some() {
            let current = self.object_props(o)?;
            if current.size_protect == Some(true)
                && props.size_protect != Some(false)
                && (props.width.is_some_and(|w| Some(w) != current.width)
                    || props.height.is_some_and(|h| Some(h) != current.height))
            {
                return Err(EditError::InvalidInput);
            }
        }
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
        match (o.kind, &o.cell) {
            (ObjectKind::Picture, Some(cell)) => core.set_cell_picture_properties_by_path_native(
                s,
                p,
                &cell_path(cell),
                c,
                &Value::Object(json).to_string(),
            ),
            (ObjectKind::Equation, Some(cell)) => core.set_equation_properties_native(
                s,
                p,
                cell.control as usize,
                Some(cell.cell as usize),
                Some(cell.paragraph as usize),
                &Value::Object(json).to_string(),
            ),
            (ObjectKind::Picture, None) => {
                core.set_picture_properties_native(s, p, c, &Value::Object(json).to_string())
            }
            (ObjectKind::Equation, None) => core.set_equation_properties_native(
                s,
                p,
                c,
                None,
                None,
                &Value::Object(json).to_string(),
            ),
            (ObjectKind::Shape, _) => {
                core.set_shape_properties_native(s, p, c, &Value::Object(json).to_string())
            }
            (ObjectKind::Table, _) => core.set_table_properties_native(
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
    /// The paragraph that holds `o`.
    fn host(o: &ObjectRef) -> EditTarget {
        EditTarget {
            section: o.section,
            paragraph: o.paragraph,
            cell: o.cell.clone(),
            note: None,
            header_footer: None,
        }
    }
    /// An object in the line (글자처럼 취급) moves to another place in the text.
    pub(super) fn validate_move(&self, o: &ObjectRef, to: &EditPosition) -> Result<(), EditError> {
        if !self.control(o)?.is_treat_as_char_object() || o.kind == ObjectKind::Table {
            return Err(EditError::UnsupportedTarget);
        }
        let t = &to.target;
        // Not into a note, 머리말 or 꼬리말, nor into the object's own caption.
        let inside = o.cell.is_none()
            && t.paragraph == o.paragraph
            && t.cell.as_ref().is_some_and(|c| c.control == o.control);
        if commands::body_or_cell(t).is_err() || inside {
            return Err(EditError::UnsupportedTarget);
        }
        self.validate_position(to)
    }
    pub(super) fn move_object(
        &mut self,
        o: &ObjectRef,
        to: &EditPosition,
    ) -> Result<EditPosition, EditError> {
        self.transplant(&Self::host(o), o.control as usize, to)
    }
    /// Moves control `control` of the paragraph at `from` into the text at `to` by way of
    /// rhwp's clipboard, which keeps its binary data, and returns the position after it.
    pub(super) fn transplant(
        &mut self,
        from: &EditTarget,
        control: usize,
        to: &EditPosition,
    ) -> Result<EditPosition, EditError> {
        let (s, p) = (from.section as usize, from.paragraph as usize);
        self.core.copy_control_native(s, p, &path(from), control)?;
        // The clipboard no longer holds what was copied.
        self.copied = 0;
        // Where `to` is once the control has left its place.
        let mut to = to.clone();
        if *from == to.target {
            let at = logical::object_position(commands::get(self.core.document(), from)?, control);
            if at.is_some_and(|at| at < to.scalar) {
                to.scalar -= 1;
            }
        }
        self.delete_control(from, control)?;
        let t = &to.target;
        let para = commands::get(self.core.document(), t)?;
        let offset = logical::spot(para, to.scalar).split(para);
        let (s, p) = (t.section as usize, t.paragraph as usize);
        match t.cell {
            None => self.core.paste_internal_native(s, p, offset),
            Some(_) => self
                .core
                .paste_internal_in_cell_by_path_native(s, p, &path(t), offset),
        }?;
        to.scalar += 1;
        Ok(to)
    }
    /// Copies object `o` to the engine's clipboard, for 붙이기 in this document.
    pub fn copy_object(&mut self, o: &ObjectRef) -> Result<clipboard::Copied, EditError> {
        self.validate_object(o, &ObjectProps::default())?;
        let t = Self::host(o);
        self.core.copy_control_native(
            t.section as usize,
            t.paragraph as usize,
            &path(&t),
            o.control as usize,
        )?;
        Ok(self.copied())
    }
    /// Deletes control `control` of the paragraph at `t`, closing its place in the text.
    pub(super) fn delete_control(
        &mut self,
        t: &EditTarget,
        control: usize,
    ) -> Result<(), EditError> {
        let (s, p) = (t.section as usize, t.paragraph as usize);
        let held = commands::get(self.core.document(), t)?
            .controls
            .get(control)
            .ok_or(EditError::InvalidInput)?;
        match (&t.cell, &t.note, held) {
            (None, None, Control::Footnote(_) | Control::Endnote(_)) => {
                self.core.delete_footnote_native(s, p, control)
            }
            (None, None, _) => self.core.delete_control_native(s, p, control),
            (Some(c), None, Control::Picture(_) | Control::Equation(_) | Control::Shape(_)) => self
                .core
                .delete_cell_picture_control_by_path_native(s, p, &cell_path(c), control),
            _ => return Err(EditError::UnsupportedTarget),
        }?;
        Ok(())
    }
    pub(super) fn delete_object(&mut self, o: &ObjectRef) -> Result<(), EditError> {
        let (s, p, c) = (o.section as usize, o.paragraph as usize, o.control as usize);
        match (o.kind, &o.cell) {
            (_, Some(_)) => return self.delete_control(&Self::host(o), c),
            (ObjectKind::Picture, None) => self.core.delete_picture_control_native(s, p, c),
            (ObjectKind::Equation, None) => self.core.delete_equation_control_native(s, p, c),
            (ObjectKind::Table, None) => self.core.delete_table_control_native(s, p, c),
            (ObjectKind::Shape, None) => self.core.delete_shape_control_native(s, p, c),
        }?;
        Ok(())
    }
    /// The ends of 직선 `o` where `MoveLineEnd` leaves them, from the corner its offsets
    /// count from (HWPUNIT).
    pub(super) fn line_ends(&self, command: &EditCommand) -> Result<[i32; 4], EditError> {
        let EditCommand::MoveLineEnd {
            object,
            end,
            dx,
            dy,
        } = command
        else {
            return Err(EditError::UnsupportedTarget);
        };
        self.validate_drawing(
            object,
            |s| matches!(s, ShapeObject::Line(l) if l.connector.is_none()),
        )?;
        let Control::Shape(shape) = self.control(object)? else {
            return Err(EditError::UnsupportedTarget);
        };
        let ShapeObject::Line(l) = &**shape else {
            return Err(EditError::UnsupportedTarget);
        };
        let (x, y) = (
            l.common.horizontal_offset as i32,
            l.common.vertical_offset as i32,
        );
        let mut ends = [x + l.start.x, y + l.start.y, x + l.end.x, y + l.end.y];
        let at = if *end { 2 } else { 0 };
        ends[at] = ends[at].saturating_add(*dx);
        ends[at + 1] = ends[at + 1].saturating_add(*dy);
        if ends.iter().all(|v| (0..=1_000_000).contains(v)) {
            Ok(ends)
        } else {
            Err(EditError::InvalidInput)
        }
    }
    /// A drawing object of the body for which `test` holds.
    pub(super) fn validate_drawing(
        &self,
        o: &ObjectRef,
        test: impl Fn(&ShapeObject) -> bool,
    ) -> Result<(), EditError> {
        match self.control(o)? {
            Control::Shape(s) if o.kind == ObjectKind::Shape && o.cell.is_none() && test(s) => {
                Ok(())
            }
            _ => Err(EditError::UnsupportedTarget),
        }
    }
    pub(super) fn validate_shape(&self, command: &EditCommand) -> Result<(), EditError> {
        let EditCommand::InsertShape {
            position,
            shape,
            x,
            y,
            width,
            height,
            ..
        } = command
        else {
            return Err(EditError::UnsupportedTarget);
        };
        commands::body_only(&position.target)?;
        self.validate_position(position)?;
        let lines = shape == "line";
        if SHAPES.contains(&shape.as_str())
            && x.abs() <= 1_000_000
            && y.abs() <= 1_000_000
            && *width <= 1_000_000
            && *height <= 1_000_000
            && (lines && *width + *height > 0 || *width > 0 && *height > 0)
        {
            Ok(())
        } else {
            Err(EditError::InvalidInput)
        }
    }
    pub(super) fn insert_shape(
        &mut self,
        command: &EditCommand,
    ) -> Result<EditSelection, EditError> {
        let EditCommand::InsertShape {
            position,
            shape,
            x,
            y,
            width,
            height,
            flip,
        } = command
        else {
            return Err(EditError::UnsupportedTarget);
        };
        let t = &position.target;
        let at = logical::spot(commands::get(self.core.document(), t)?, position.scalar).text;
        self.core.create_shape_control_native(
            t.section as usize,
            t.paragraph as usize,
            at,
            *width,
            *height,
            *x as u32,
            *y as u32,
            false,
            "InFrontOfText",
            shape,
            false,
            *flip,
            &[],
        )?;
        Ok(EditSelection::caret(position.clone()))
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
