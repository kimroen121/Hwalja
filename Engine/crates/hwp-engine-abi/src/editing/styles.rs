//! The document's styles (스타일): listed, applied to paragraphs, added, edited, deleted
//! and moved.
use super::commands::get;
use super::*;
use serde::Serialize;
use serde_json::Value;

/// One style, by the name the document gives it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StyleInfo {
    pub id: u32,
    pub name: String,
    pub english_name: String,
    /// 문단 스타일, else 글자 스타일.
    pub paragraph_style: bool,
    /// 다음 문단에 적용할 스타일.
    pub next: u32,
}
/// The most styles a document holds.
const MAX_STYLES: usize = 160;

impl EditSession {
    pub fn styles(&self) -> Vec<StyleInfo> {
        self.core
            .document()
            .doc_info
            .styles
            .iter()
            .enumerate()
            .map(|(id, s)| StyleInfo {
                id: id as u32,
                name: if s.local_name.is_empty() {
                    s.english_name.clone()
                } else {
                    s.local_name.clone()
                },
                english_name: s.english_name.clone(),
                paragraph_style: s.style_type == 0,
                next: s.next_style_id as u32,
            })
            .collect()
    }
    pub(super) fn validate_style(
        &self,
        selection: &EditSelection,
        style: u32,
    ) -> Result<(), EditError> {
        self.validate_range(selection)?;
        commands::body_or_cell(&selection.anchor.target)?;
        if (style as usize) < self.core.document().doc_info.styles.len() {
            Ok(())
        } else {
            Err(EditError::InvalidInput)
        }
    }
    /// Applies `style` to every paragraph the selection touches.
    pub(super) fn apply_style(
        &mut self,
        selection: &EditSelection,
        style: u32,
    ) -> Result<EditSelection, EditError> {
        let (start, end) = commands::ordered(selection);
        let t = start.target.clone();
        for i in commands::index(&t)..=commands::index(&end.target) {
            match &t.cell {
                Some(c) => self.core.apply_cell_style_native(
                    t.section as usize,
                    t.paragraph as usize,
                    c.control as usize,
                    c.cell as usize,
                    i,
                    style as usize,
                ),
                None => self
                    .core
                    .apply_style_native(t.section as usize, i, style as usize),
            }?;
        }
        Ok(selection.clone())
    }
    /// A style's character and paragraph shapes.
    pub fn style_format(&self, style: u32) -> Result<Format, EditError> {
        let id = style as usize;
        let parse = |json: Option<String>| -> Result<Value, EditError> {
            serde_json::from_str(&json.ok_or(EditError::InvalidInput)?)
                .map_err(|_| EditError::RenderFailed)
        };
        let text = parse(self.core.style_char_properties_native(id))?;
        let para = parse(self.core.style_para_properties_native(id))?;
        let info = &self.core.document().doc_info;
        let shape = info
            .para_shapes
            .get(info.styles[id].para_shape_id as usize)
            .ok_or(EditError::InvalidInput)?;
        Ok(self.format_of(&text, &para, shape, style, false))
    }
    fn style_exists(&self, style: u32) -> Result<(), EditError> {
        if (style as usize) < self.core.document().doc_info.styles.len() {
            Ok(())
        } else {
            Err(EditError::InvalidInput)
        }
    }
    /// `next` may name the style being added, the one after the last.
    pub(super) fn validate_spec(&self, spec: &StyleSpec, adding: bool) -> Result<(), EditError> {
        let styles = self.core.document().doc_info.styles.len() as u32;
        if spec.next > styles || (spec.next == styles && !adding) {
            return Err(EditError::InvalidInput);
        }
        for text in &spec.text {
            format::validate_char(text).or_else(|_| {
                (*text == CharStyle::default())
                    .then_some(())
                    .ok_or(EditError::InvalidInput)
            })?;
        }
        if spec.paragraph != ParaStyle::default() {
            format::validate_para(&spec.paragraph)?;
        }
        if spec.name.trim().is_empty() {
            return Err(EditError::InvalidInput);
        }
        Ok(())
    }
    pub(super) fn validate_style_command(&self, command: &EditCommand) -> Result<(), EditError> {
        let styles = self.core.document().doc_info.styles.len();
        match command {
            EditCommand::AddStyle { position, style } => {
                commands::body_or_cell(&position.target)?;
                self.validate_position(position)?;
                if styles >= MAX_STYLES {
                    return Err(EditError::InvalidInput);
                }
                self.validate_spec(style, true)
            }
            EditCommand::EditStyle { style, spec } => {
                self.style_exists(*style)?;
                self.validate_spec(spec, false)
            }
            EditCommand::DeleteStyle { style, replacement } => {
                self.style_exists(*style)?;
                self.style_exists(*replacement)?;
                let s = &self.core.document().doc_info.styles;
                if *style == 0 || style == replacement || s[*replacement as usize].style_type != 0 {
                    return Err(EditError::InvalidInput);
                }
                Ok(())
            }
            EditCommand::MoveStyle { style, up } => {
                let other = if *up {
                    style.checked_sub(1)
                } else {
                    Some(style + 1)
                };
                match other {
                    Some(o) if *style >= 1 && o >= 1 && (o as usize) < styles => Ok(()),
                    _ => Err(EditError::InvalidInput),
                }
            }
            EditCommand::RestyleFromCaret { style, position } => {
                self.style_exists(*style)?;
                commands::body_or_cell(&position.target)?;
                self.validate_position(position)
            }
            _ => Ok(()),
        }
    }
    /// The character and paragraph shapes at `position`.
    fn shapes_at(&self, position: &EditPosition) -> Result<(u16, u16), EditError> {
        let para = get(self.core.document(), &position.target)?;
        let offset = logical::spot(para, position.scalar).text as u32;
        // The run holding the character before the caret, or the first one.
        let char_shape = para
            .char_shapes
            .iter()
            .take_while(|r| r.start_pos <= offset.saturating_sub(1))
            .last()
            .or(para.char_shapes.first())
            .map(|r| r.char_shape_id as u16)
            .unwrap_or(0);
        Ok((char_shape, para.para_shape_id))
    }
    /// Lays `spec`'s names, next style and shape changes over style `id`.
    fn set_spec(&mut self, id: usize, spec: &StyleSpec) -> Result<(), EditError> {
        let meta = serde_json::json!({
            "name": spec.name.trim(),
            "englishName": spec.english_name.trim(),
            "nextStyleId": spec.next,
        });
        if !self.core.update_style_native(id, &meta.to_string()) {
            return Err(EditError::InvalidInput);
        }
        let paragraph = if spec.paragraph_style && spec.paragraph != ParaStyle::default() {
            self.para_props(&spec.paragraph)
        } else {
            String::new()
        };
        let mut texts = spec.text.iter().filter(|t| **t != CharStyle::default());
        let first = texts.next();
        let text = |session: &mut Self, t: &CharStyle| {
            let (props, languages) = session.char_props(t);
            if languages.is_empty() {
                props
            } else {
                let info = &session.core.document().doc_info;
                let own = &info.char_shapes[info.styles[id].char_shape_id as usize];
                languages.over(own, &props)
            }
        };
        let char_props = first.map(|t| text(self, t)).unwrap_or_default();
        if !(char_props.is_empty() && paragraph.is_empty())
            && !self
                .core
                .update_style_shapes_native(id, &char_props, &paragraph)
        {
            return Err(EditError::InvalidInput);
        }
        for t in texts {
            let props = text(self, t);
            if !self.core.update_style_shapes_native(id, &props, "") {
                return Err(EditError::InvalidInput);
            }
        }
        Ok(())
    }
    pub(super) fn run_style_command(&mut self, command: &EditCommand) -> Result<(), EditError> {
        let ok = |done: bool| {
            if done {
                Ok(())
            } else {
                Err(EditError::InvalidInput)
            }
        };
        match command {
            EditCommand::AddStyle { position, style } => {
                let (char_shape, para_shape) = self.shapes_at(position)?;
                let json = serde_json::json!({
                    "name": style.name.trim(),
                    "type": if style.paragraph_style { 0 } else { 1 },
                    "baseCharShapeId": char_shape,
                    "baseParaShapeId": para_shape,
                });
                let id = self.core.create_style_native(&json.to_string());
                if id < 0 {
                    return Err(EditError::InvalidInput);
                }
                self.set_spec(id as usize, style)
            }
            EditCommand::EditStyle { style, spec } => self.set_spec(*style as usize, spec),
            EditCommand::DeleteStyle { style, replacement } => ok(self
                .core
                .delete_style_native(*style as usize, *replacement as usize)),
            EditCommand::MoveStyle { style, up } => {
                ok(self.core.move_style_native(*style as usize, *up))
            }
            EditCommand::RestyleFromCaret { style, position } => {
                let (char_shape, para_shape) = self.shapes_at(position)?;
                ok(self
                    .core
                    .relink_style_native(*style as usize, char_shape, para_shape))
            }
            _ => Ok(()),
        }
    }
}
