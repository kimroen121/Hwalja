//! The document's styles (스타일), listed and applied to paragraphs.
use super::*;
use serde::Serialize;

/// One style, by the name the document gives it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StyleInfo {
    pub id: u32,
    pub name: String,
}

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
            })
            .collect()
    }
    pub(super) fn validate_style(
        &self,
        selection: &EditSelection,
        style: u32,
    ) -> Result<(), EditError> {
        self.validate_range(selection)?;
        commands::not_in_note(&selection.anchor.target)?;
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
}
