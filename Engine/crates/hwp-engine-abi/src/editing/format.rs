//! Character and paragraph formats: the caret query and the rhwp property JSON for changes.
use super::commands::{get, index};
use super::*;
use serde_json::{json, Map, Value};

pub(super) fn validate_char(style: &CharStyle) -> Result<(), EditError> {
    let font_ok = style.font.as_ref().is_none_or(|f| {
        !f.trim().is_empty() && f.chars().count() <= 64 && !f.chars().any(char::is_control)
    });
    let size_ok = style.size.is_none_or(|s| (1.0..=4096.0).contains(&s));
    let color_ok = style.color.as_ref().is_none_or(|c| color(c).is_some());
    if font_ok && size_ok && color_ok && *style != CharStyle::default() {
        Ok(())
    } else {
        Err(EditError::InvalidInput)
    }
}
pub(super) fn validate_para(style: &ParaStyle) -> Result<(), EditError> {
    if style
        .line_spacing
        .is_none_or(|s| (50.0..=500.0).contains(&s))
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
pub(super) fn para_props(style: &ParaStyle) -> String {
    let mut props = Map::new();
    if let Some(alignment) = style.alignment {
        props.insert("alignment".into(), serde_json::to_value(alignment).unwrap());
    }
    if let Some(spacing) = style.line_spacing {
        props.insert("lineSpacing".into(), json!(spacing.round() as i32));
        props.insert("lineSpacingType".into(), json!("Percent"));
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

    /// Format of the text before the caret (what typing continues with) and its paragraph.
    pub fn format(&self, revision: u64, p: &EditPosition) -> Result<Format, EditError> {
        if self.locked {
            return Err(EditError::Locked);
        }
        if revision != self.revision {
            return Err(EditError::StaleRevision);
        }
        get(self.core.document(), &p.target)?;
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
        let percent = para.get("lineSpacingType").and_then(Value::as_str) == Some("Percent");
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
            },
            paragraph: ParaStyle {
                alignment: para
                    .get("alignment")
                    .and_then(|a| serde_json::from_value(a.clone()).ok()),
                line_spacing: percent
                    .then(|| para.get("lineSpacing").and_then(Value::as_f64))
                    .flatten(),
            },
            fonts,
        })
    }
}
