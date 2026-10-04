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
/// The selection's ends in document order.
pub(super) fn ordered(s: &EditSelection) -> (&EditPosition, &EditPosition) {
    let key = |p: &EditPosition| (index(&p.target), p.scalar);
    if key(&s.anchor) <= key(&s.focus) {
        (&s.anchor, &s.focus)
    } else {
        (&s.focus, &s.anchor)
    }
}
/// Whether two targets address paragraphs of the same container.
fn same_container(a: &EditTarget, b: &EditTarget) -> bool {
    a.section == b.section
        && match (&a.cell, &b.cell) {
            (None, None) => true,
            (Some(x), Some(y)) => {
                a.paragraph == b.paragraph && x.control == y.control && x.cell == y.cell
            }
            _ => false,
        }
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
            count: paragraphs(self.core.document(), target)?.len() as u32,
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
    /// Both ends valid, in one container, with only editable paragraphs between them.
    /// With `joinable`, paragraphs after the first must hold no controls, since a
    /// multi-paragraph replace merges them into the first.
    fn validate_range(&self, selection: &EditSelection, joinable: bool) -> Result<(), EditError> {
        let (start, end) = ordered(selection);
        if !same_container(&start.target, &end.target) {
            return Err(EditError::UnsupportedTarget);
        }
        self.validate_position(start)?;
        self.validate_position(end)?;
        let all = paragraphs(self.core.document(), &start.target)?;
        let (s, e) = (index(&start.target), index(&end.target));
        if all[s..=e].iter().any(|p| !editable(p))
            || (joinable && all[s + 1..=e].iter().any(|p| !p.controls.is_empty()))
        {
            return Err(EditError::UnsupportedTarget);
        }
        Ok(())
    }
    pub(super) fn validate_command(&self, command: &EditCommand) -> Result<(), EditError> {
        match command {
            EditCommand::Replace { selection, text } => {
                self.validate_range(selection, true)?;
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
            EditCommand::FormatText { selection, style } => {
                self.validate_range(selection, false)?;
                let (start, end) = ordered(selection);
                if start == end {
                    return Err(EditError::InvalidInput);
                }
                super::format::validate_char(style)
            }
            EditCommand::FormatParagraphs { selection, style } => {
                self.validate_range(selection, false)?;
                super::format::validate_para(style)
            }
            EditCommand::Undo | EditCommand::Redo => Err(EditError::UnsupportedTarget),
        }
    }
    fn length(&self, t: &EditTarget) -> Result<u32, EditError> {
        Ok(get(self.core.document(), t)?.text.chars().count() as u32)
    }
    /// Joins the paragraph at `t` onto the previous one.
    fn merge(&mut self, t: &EditTarget) -> Result<(), EditError> {
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
        Ok(())
    }
    /// Deletes from `start` to `end` (ordered, same container), joining the paragraphs.
    fn delete_range(&mut self, start: &EditPosition, end: &EditPosition) -> Result<(), EditError> {
        let (s, e) = (index(&start.target), index(&end.target));
        if s == e {
            return match end.scalar - start.scalar {
                0 => Ok(()),
                count => self.delete(start, count),
            };
        }
        let tail = self.length(&start.target)? - start.scalar;
        if tail > 0 {
            self.delete(start, tail)?;
        }
        let next = at_index(&start.target, s + 1);
        for remaining in (s + 1..=e).rev() {
            let count = if remaining == s + 1 {
                end.scalar
            } else {
                self.length(&next)?
            };
            if count > 0 {
                self.delete(
                    &EditPosition {
                        target: next.clone(),
                        scalar: 0,
                    },
                    count,
                )?;
            }
            self.merge(&next)?;
        }
        Ok(())
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
    /// Runs a validated command and returns the selection that follows it.
    pub(super) fn execute(&mut self, command: &EditCommand) -> Result<EditSelection, EditError> {
        match command {
            EditCommand::Replace { selection, text } => {
                let (start, end) = ordered(selection);
                self.delete_range(start, end)?;
                let mut p = start.clone();
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
                Ok(EditSelection::caret(p))
            }
            EditCommand::Split { position } => Ok(EditSelection::caret(self.split(position)?)),
            EditCommand::MergePrevious { position } => {
                let t = &position.target;
                let previous = at_index(t, index(t) - 1);
                let scalar = self.length(&previous)?;
                self.merge(t)?;
                Ok(EditSelection::caret(EditPosition {
                    target: previous,
                    scalar,
                }))
            }
            EditCommand::FormatText { selection, style } => {
                let (start, end) = ordered(selection);
                let props = self.char_props(style);
                for i in index(&start.target)..=index(&end.target) {
                    let target = at_index(&start.target, i);
                    let from = if i == index(&start.target) {
                        start.scalar
                    } else {
                        0
                    };
                    let to = if i == index(&end.target) {
                        end.scalar
                    } else {
                        self.length(&target)?
                    };
                    if to > from {
                        self.format_text(&target, from, to, &props)?;
                    }
                }
                Ok(selection.clone())
            }
            EditCommand::FormatParagraphs { selection, style } => {
                let (start, end) = ordered(selection);
                let props = super::format::para_props(style);
                for i in index(&start.target)..=index(&end.target) {
                    self.format_paragraph(&at_index(&start.target, i), &props)?;
                }
                Ok(selection.clone())
            }
            EditCommand::Undo | EditCommand::Redo => Err(EditError::UnsupportedTarget),
        }
    }
}
