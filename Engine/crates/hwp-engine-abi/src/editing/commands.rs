use super::*;
use rhwp::model::{control::Control, document::Document, paragraph::Paragraph};
use unicode_segmentation::UnicodeSegmentation;

pub(super) fn paragraphs<'a>(
    doc: &'a Document,
    t: &EditTarget,
) -> Result<&'a [Paragraph], EditError> {
    let section = doc
        .sections
        .get(t.section as usize)
        .ok_or(EditError::InvalidInput)?;
    if let Some(c) = &t.cell {
        let host = section
            .paragraphs
            .get(t.paragraph as usize)
            .ok_or(EditError::InvalidInput)?;
        let Some(Control::Table(table)) = host.controls.get(c.control as usize) else {
            return Err(EditError::UnsupportedTarget);
        };
        let cell = table
            .cells
            .get(c.cell as usize)
            .ok_or(EditError::InvalidInput)?;
        if cell.text_direction != 0 {
            return Err(EditError::UnsupportedTarget);
        }
        Ok(&cell.paragraphs)
    } else {
        Ok(&section.paragraphs)
    }
}
pub(super) fn index(t: &EditTarget) -> usize {
    t.cell.as_ref().map_or(t.paragraph, |c| c.paragraph) as usize
}
pub(super) fn at_index(t: &EditTarget, index: usize) -> EditTarget {
    let mut result = t.clone();
    if let Some(c) = &mut result.cell {
        c.paragraph = index as u32;
    } else {
        result.paragraph = index as u32;
    }
    result
}
pub(super) fn get<'a>(doc: &'a Document, t: &EditTarget) -> Result<&'a Paragraph, EditError> {
    paragraphs(doc, t)?
        .get(index(t))
        .ok_or(EditError::InvalidInput)
}
/// Plain text paragraphs, optionally carrying the invisible section/column definitions
/// that every section's first paragraph holds. Preservation checks those stay intact.
pub(super) fn editable(p: &Paragraph) -> bool {
    p.controls
        .iter()
        .all(|c| matches!(c, Control::SectionDef(_) | Control::ColumnDef(_)))
        && p.title_marks.is_empty()
        && p.field_ranges.is_empty()
        && p.range_tags.is_empty()
        && p.orphan_field_ends.is_empty()
        && p.ctrl_data_records.len() <= p.controls.len()
        && !p.text.chars().any(|c| c.is_control() && c != '\t')
}
pub(super) fn boundary(text: &str, scalar: u32) -> Result<(), EditError> {
    let mut offset = 0;
    for g in text.graphemes(true) {
        if offset == scalar {
            return Ok(());
        }
        offset += g.chars().count() as u32;
    }
    if offset == scalar {
        Ok(())
    } else {
        Err(EditError::InvalidBoundary)
    }
}
impl EditSession {
    pub fn paragraph(&self, target: &EditTarget) -> Result<ParagraphInfo, EditError> {
        let p = get(self.core.document(), target)?;
        let allowed = editable(p);
        Ok(ParagraphInfo {
            target: target.clone(),
            text: p.text.clone(),
            editable: allowed,
            reason: if allowed {
                String::new()
            } else {
                "그림·수식·필드가 포함된 문단은 아직 편집할 수 없습니다.".into()
            },
        })
    }
    fn validate_position(&self, p: &EditPosition) -> Result<(), EditError> {
        let para = get(self.core.document(), &p.target)?;
        if !editable(para) {
            return Err(EditError::UnsupportedTarget);
        }
        boundary(&para.text, p.scalar)
    }
    pub(super) fn validate_command(&self, command: &EditCommand) -> Result<(), EditError> {
        match command {
            EditCommand::Replace { selection, text } => {
                if selection.anchor.target != selection.focus.target {
                    return Err(EditError::UnsupportedTarget);
                }
                self.validate_position(&selection.anchor)?;
                self.validate_position(&selection.focus)?;
                if text.len() > 1024 * 1024 {
                    return Err(EditError::ResourceLimit);
                }
                if text
                    .chars()
                    .any(|c| c.is_control() && !matches!(c, '\t' | '\n' | '\r'))
                {
                    return Err(EditError::InvalidInput);
                }
                Ok(())
            }
            EditCommand::Split { position } => self.validate_position(position),
            EditCommand::MergePrevious { position } => {
                self.validate_position(position)?;
                if position.scalar != 0 || index(&position.target) == 0 {
                    return Err(EditError::InvalidBoundary);
                }
                self.validate_position(&EditPosition {
                    target: at_index(&position.target, index(&position.target) - 1),
                    scalar: 0,
                })
            }
            _ => Err(EditError::UnsupportedTarget),
        }
    }
    fn insert(&mut self, p: &EditPosition, text: &str) -> Result<(), EditError> {
        let t = &p.target;
        if let Some(c) = &t.cell {
            self.core.insert_text_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                p.scalar as usize,
                text,
            )?;
        } else {
            self.core.insert_text_native(
                t.section as usize,
                t.paragraph as usize,
                p.scalar as usize,
                text,
            )?;
        }
        Ok(())
    }
    fn delete(&mut self, p: &EditPosition, count: u32) -> Result<(), EditError> {
        let t = &p.target;
        if let Some(c) = &t.cell {
            self.core.delete_text_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                p.scalar as usize,
                count as usize,
            )?;
        } else {
            self.core.delete_text_native(
                t.section as usize,
                t.paragraph as usize,
                p.scalar as usize,
                count as usize,
            )?;
        }
        Ok(())
    }
    fn split(&mut self, p: &EditPosition) -> Result<EditPosition, EditError> {
        let t = &p.target;
        if let Some(c) = &t.cell {
            self.core.split_paragraph_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                p.scalar as usize,
                None,
            )?;
        } else {
            self.core.split_paragraph_native(
                t.section as usize,
                t.paragraph as usize,
                p.scalar as usize,
                None,
            )?;
        }
        Ok(EditPosition {
            target: at_index(t, index(t) + 1),
            scalar: 0,
        })
    }
    pub(super) fn execute(&mut self, command: &EditCommand) -> Result<EditPosition, EditError> {
        match command {
            EditCommand::Replace { selection, text } => {
                let start = selection.anchor.scalar.min(selection.focus.scalar);
                let count = selection.anchor.scalar.max(selection.focus.scalar) - start;
                let mut p = EditPosition {
                    target: selection.anchor.target.clone(),
                    scalar: start,
                };
                if count > 0 {
                    self.delete(&p, count)?;
                }
                let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
                for (i, part) in normalized.split('\n').enumerate() {
                    if i > 0 {
                        p = self.split(&p)?;
                    }
                    if !part.is_empty() {
                        self.insert(&p, part)?;
                    }
                    p.scalar += part.chars().count() as u32;
                }
                Ok(p)
            }
            EditCommand::Split { position } => self.split(position),
            EditCommand::MergePrevious { position } => {
                let t = &position.target;
                let previous = at_index(t, index(t) - 1);
                let scalar = get(self.core.document(), &previous)?.text.chars().count() as u32;
                if let Some(c) = &t.cell {
                    self.core.merge_paragraph_in_cell_native(
                        t.section as usize,
                        t.paragraph as usize,
                        c.control as usize,
                        c.cell as usize,
                        c.paragraph as usize,
                    )?;
                } else {
                    self.core
                        .merge_paragraph_native(t.section as usize, t.paragraph as usize)?;
                }
                Ok(EditPosition {
                    target: previous,
                    scalar,
                })
            }
            _ => Err(EditError::UnsupportedTarget),
        }
    }
}
