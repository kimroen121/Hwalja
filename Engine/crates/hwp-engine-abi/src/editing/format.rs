//! Character and paragraph formats: the caret query and the rhwp property JSON for changes.
use super::commands::{get, index};
use super::*;
use serde_json::{json, Map, Value};

pub(super) fn validate_char(style: &CharStyle) -> Result<(), EditError> {
    let font_ok = style.font.as_ref().is_none_or(|f| {
        !f.trim().is_empty() && f.chars().count() <= 64 && !f.chars().any(char::is_control)
    });
    let size_ok = style.size.is_none_or(|s| (1.0..=4096.0).contains(&s));
    let color_ok = [
        &style.color,
        &style.shade,
        &style.underline_color,
        &style.strike_color,
    ]
    .iter()
    .all(|c| c.as_ref().is_none_or(|c| color(c).is_some()));
    let shapes_ok = [style.underline_shape, style.strike_shape]
        .iter()
        .all(|s| s.is_none_or(|s| s <= 12));
    let scale_ok = style.ratio.is_none_or(|r| (50.0..=200.0).contains(&r))
        && style.spacing.is_none_or(|s| (-50.0..=50.0).contains(&s));
    if font_ok && size_ok && color_ok && shapes_ok && scale_ok && *style != CharStyle::default() {
        Ok(())
    } else {
        Err(EditError::InvalidInput)
    }
}
pub(super) fn validate_para(style: &ParaStyle) -> Result<(), EditError> {
    let spacing_ok = match style.line_spacing_kind.unwrap_or(LineSpacingKind::Percent) {
        LineSpacingKind::Percent => style
            .line_spacing
            .is_none_or(|s| (50.0..=500.0).contains(&s)),
        _ => style
            .line_spacing
            .is_none_or(|s| (0.0..=1000.0).contains(&s)),
    };
    let lengths_ok = [
        style.margin_left,
        style.margin_right,
        style.spacing_before,
        style.spacing_after,
    ]
    .iter()
    .all(|v| v.is_none_or(|v| (0.0..=1000.0).contains(&v)))
        && style.indent.is_none_or(|v| (-1000.0..=1000.0).contains(&v));
    if spacing_ok
        && lengths_ok
        && style.korean_break_unit.is_none_or(|v| v <= 1)
        && style.english_break_unit.is_none_or(|v| v <= 2)
        && style.line_spacing_kind.is_some() == style.line_spacing.is_some()
        && *style != ParaStyle::default()
    {
        Ok(())
    } else {
        Err(EditError::InvalidInput)
    }
}
/// `#rrggbb` → the same string, normalized to lowercase.
fn color(text: &str) -> Option<String> {
    let hex = text.strip_prefix('#')?;
    (hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit())).then(|| text.to_lowercase())
}
/// Paragraph lengths are stored in 1/200 pt (twice HWPUNIT).
const PARA_UNITS_PER_POINT: f64 = 200.0;

pub(super) fn para_props(style: &ParaStyle) -> String {
    let mut props = Map::new();
    if let Some(alignment) = style.alignment {
        props.insert("alignment".into(), serde_json::to_value(alignment).unwrap());
    }
    let units = |v: f64| json!((v * PARA_UNITS_PER_POINT).round() as i32);
    if let (Some(kind), Some(value)) = (style.line_spacing_kind, style.line_spacing) {
        let (name, value) = match kind {
            LineSpacingKind::Percent => ("Percent", json!(value.round() as i32)),
            LineSpacingKind::Fixed => ("Fixed", units(value)),
            LineSpacingKind::SpaceOnly => ("SpaceOnly", units(value)),
            LineSpacingKind::Minimum => ("Minimum", units(value)),
        };
        props.insert("lineSpacing".into(), value);
        props.insert("lineSpacingType".into(), json!(name));
    }
    for (key, value) in [
        ("marginLeft", style.margin_left),
        ("marginRight", style.margin_right),
        ("indent", style.indent),
        ("spacingBefore", style.spacing_before),
        ("spacingAfter", style.spacing_after),
    ] {
        if let Some(value) = value {
            props.insert(key.into(), units(value));
        }
    }
    for (key, value) in [
        ("keepWithNext", style.keep_with_next),
        ("keepLines", style.keep_lines),
        ("widowOrphan", style.widow_orphan),
        ("pageBreakBefore", style.page_break_before),
    ] {
        if let Some(value) = value {
            props.insert(key.into(), json!(value));
        }
    }
    for (key, value) in [
        ("koreanBreakUnit", style.korean_break_unit),
        ("englishBreakUnit", style.english_break_unit),
    ] {
        if let Some(value) = value {
            props.insert(key.into(), json!(value));
        }
    }
    Value::Object(props).to_string()
}

impl EditSession {
    /// rhwp property JSON for a character change. Registers a new font name if needed.
    pub(super) fn char_props(&mut self, style: &CharStyle) -> String {
        let mut props = Map::new();
        if let Some(font) = &style.font {
            props.insert(
                "fontId".into(),
                json!(self.core.find_or_create_font_id_native(font.trim())),
            );
        }
        if let Some(size) = style.size {
            props.insert("fontSize".into(), json!((size * 100.0).round() as i32));
        }
        for (key, value) in [
            ("bold", style.bold),
            ("italic", style.italic),
            ("underline", style.underline),
            ("strikethrough", style.strikethrough),
        ] {
            if let Some(value) = value {
                props.insert(key.into(), json!(value));
            }
        }
        if style.underline == Some(true) {
            props.insert("underlineType".into(), json!("Bottom"));
        }
        if let Some(c) = style.color.as_deref().and_then(color) {
            props.insert("textColor".into(), json!(c));
        }
        if let Some(c) = style.shade.as_deref().and_then(color) {
            props.insert("shadeColor".into(), json!(c));
        }
        for (key, value) in [
            ("underlineColor", &style.underline_color),
            ("strikeColor", &style.strike_color),
        ] {
            if let Some(c) = value.as_deref().and_then(color) {
                props.insert(key.into(), json!(c));
            }
        }
        if let Some(shape) = style.underline_shape {
            props.insert("underlineShape".into(), json!(shape));
        }
        if let Some(shape) = style.strike_shape {
            props.insert("strikeShape".into(), json!(shape));
        }
        if let Some(ratio) = style.ratio {
            props.insert("ratios".into(), json!(vec![ratio.round() as u8; 7]));
        }
        if let Some(spacing) = style.spacing {
            props.insert("spacings".into(), json!(vec![spacing.round() as i8; 7]));
        }
        // One of superscript and subscript at a time.
        if let Some(on) = style.superscript {
            props.insert("superscript".into(), json!(on));
            if on {
                props.insert("subscript".into(), json!(false));
            }
        }
        if let Some(on) = style.subscript {
            props.insert("subscript".into(), json!(on));
            if on {
                props.insert("superscript".into(), json!(false));
            }
        }
        for (key, value) in [("outlineType", style.outline), ("shadowType", style.shadow)] {
            if let Some(on) = value {
                props.insert(key.into(), json!(on as i32));
            }
        }
        for (key, value) in [("emboss", style.emboss), ("engrave", style.engrave)] {
            if let Some(on) = value {
                props.insert(key.into(), json!(on));
            }
        }
        Value::Object(props).to_string()
    }
    /// Applies `props` to `from..to`, one existing run at a time: rhwp derives the new
    /// shape from the run at the range start, which would copy that run's other
    /// attributes (color, font, …) over the rest of the range.
    pub(super) fn format_text(
        &mut self,
        t: &EditTarget,
        from: u32,
        to: u32,
        props: &str,
    ) -> Result<(), EditError> {
        let para = get(self.core.document(), t)?;
        let mut runs: Vec<(u32, u32)> = Vec::new();
        for offset in from..to {
            let id = para.char_shape_id_at(offset as usize);
            match runs.last_mut() {
                Some((_, end)) if para.char_shape_id_at(*end as usize - 1) == id => {
                    *end = offset + 1
                }
                _ => runs.push((offset, offset + 1)),
            }
        }
        for (start, end) in runs {
            self.format_run(t, start, end, props)?;
        }
        Ok(())
    }
    fn format_run(
        &mut self,
        t: &EditTarget,
        from: u32,
        to: u32,
        props: &str,
    ) -> Result<(), EditError> {
        match &t.cell {
            Some(c) => self.core.apply_char_format_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                from as usize,
                to as usize,
                props,
            ),
            None => self.core.apply_char_format_native(
                t.section as usize,
                t.paragraph as usize,
                from as usize,
                to as usize,
                props,
            ),
        }?;
        Ok(())
    }
    pub(super) fn format_paragraph(
        &mut self,
        t: &EditTarget,
        props: &str,
    ) -> Result<(), EditError> {
        match &t.cell {
            Some(c) => self.core.apply_para_format_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                props,
            ),
            None => {
                self.core
                    .apply_para_format_native(t.section as usize, t.paragraph as usize, props)
            }
        }?;
        Ok(())
    }

    /// The stored shape of the paragraph at `t`, for exact lengths.
    fn paragraph_shape(&self, t: &EditTarget) -> Result<&rhwp::model::style::ParaShape, EditError> {
        let id = get(self.core.document(), t)?.para_shape_id;
        self.core
            .document()
            .doc_info
            .para_shapes
            .get(id as usize)
            .ok_or(EditError::RenderFailed)
    }
    /// Format of the text before the caret (what typing continues with) and its paragraph.
    pub fn format(&self, revision: u64, p: &EditPosition) -> Result<Format, EditError> {
        if self.locked {
            return Err(EditError::Locked);
        }
        if revision != self.revision {
            return Err(EditError::StaleRevision);
        }
        get(self.core.document(), &p.target)?;
        super::commands::not_in_note(&p.target)?;
        let t = &p.target;
        let offset = p.scalar.saturating_sub(1) as usize;
        let parse = |text: Result<String, rhwp::error::HwpError>| -> Result<Value, EditError> {
            serde_json::from_str(&text?).map_err(|_| EditError::RenderFailed)
        };
        let (text, para) = match &t.cell {
            Some(c) => (
                self.core.get_cell_char_properties_at_native(
                    t.section as usize,
                    t.paragraph as usize,
                    c.control as usize,
                    c.cell as usize,
                    index(t),
                    offset,
                ),
                self.core.get_cell_para_properties_at_native(
                    t.section as usize,
                    t.paragraph as usize,
                    c.control as usize,
                    c.cell as usize,
                    index(t),
                ),
            ),
            None => (
                self.core
                    .get_char_properties_at_native(t.section as usize, index(t), offset),
                self.core
                    .get_para_properties_at_native(t.section as usize, index(t)),
            ),
        };
        let (text, para) = (parse(text)?, parse(para)?);
        let flag = |key: &str| text.get(key).and_then(Value::as_bool);
        let font = text
            .get("fontFamily")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let bold = flag("bold");
        let fonts = rhwp::renderer::render_font_family_chain_for_weight(&font, bold == Some(true))
            .split(',')
            .map(|name| name.trim().trim_matches('\'').to_string())
            .filter(|name| !name.is_empty() && !name.ends_with("serif") && name != "monospace")
            .collect();
        let number = |v: &Value, key: &str| v.get(key).and_then(Value::as_f64);
        let first = |key: &str| text.get(key).and_then(|a| a.get(0)).and_then(Value::as_f64);
        let on = |key: &str| text.get(key).and_then(Value::as_i64).map(|v| v != 0);
        let shape = self.paragraph_shape(t)?;
        let points = |v: i32| v as f64 / PARA_UNITS_PER_POINT;
        use rhwp::model::style::LineSpacingType;
        let (kind, spacing) = match shape.line_spacing_type {
            LineSpacingType::Percent => (LineSpacingKind::Percent, shape.line_spacing as f64),
            LineSpacingType::Fixed => (LineSpacingKind::Fixed, points(shape.line_spacing)),
            LineSpacingType::SpaceOnly => (LineSpacingKind::SpaceOnly, points(shape.line_spacing)),
            LineSpacingType::Minimum => (LineSpacingKind::Minimum, points(shape.line_spacing)),
        };
        let para_flag = |key: &str| para.get(key).and_then(Value::as_bool);
        let para_unit = |key: &str| para.get(key).and_then(Value::as_u64).map(|v| v as u8);
        Ok(Format {
            text: CharStyle {
                font: Some(font),
                size: text
                    .get("fontSize")
                    .and_then(Value::as_f64)
                    .map(|s| s / 100.0),
                bold,
                italic: flag("italic"),
                underline: flag("underline"),
                strikethrough: flag("strikethrough"),
                color: text
                    .get("textColor")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                underline_shape: number(&text, "underlineShape").map(|v| v as u8),
                strike_shape: number(&text, "strikeShape").map(|v| v as u8),
                underline_color: text
                    .get("underlineColor")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                strike_color: text
                    .get("strikeColor")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                shade: text
                    .get("shadeColor")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                ratio: first("ratios"),
                spacing: first("spacings"),
                superscript: flag("superscript"),
                subscript: flag("subscript"),
                outline: on("outlineType"),
                shadow: on("shadowType"),
                emboss: flag("emboss"),
                engrave: flag("engrave"),
            },
            paragraph: ParaStyle {
                alignment: para
                    .get("alignment")
                    .and_then(|a| serde_json::from_value(a.clone()).ok()),
                line_spacing: Some(spacing),
                line_spacing_kind: Some(kind),
                margin_left: Some(points(shape.margin_left)),
                margin_right: Some(points(shape.margin_right)),
                indent: Some(points(shape.indent)),
                spacing_before: Some(points(shape.spacing_before)),
                spacing_after: Some(points(shape.spacing_after)),
                keep_with_next: para_flag("keepWithNext"),
                keep_lines: para_flag("keepLines"),
                widow_orphan: para_flag("widowOrphan"),
                page_break_before: para_flag("pageBreakBefore"),
                korean_break_unit: para_unit("koreanBreakUnit"),
                english_break_unit: para_unit("englishBreakUnit"),
            },
            fonts,
        })
    }
}
