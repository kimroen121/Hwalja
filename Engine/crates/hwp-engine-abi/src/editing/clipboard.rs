//! 서식 있는 복사하기 and 붙이기: rhwp's own clipboard within a document, HTML between
//! documents and with other apps. In body text and table cells.
use super::commands::{at_index, get, index, ordered, table};
use super::*;
use serde::Serialize;
use serde_json::Value;

/// What 복사하기 puts on the pasteboard besides the plain text: the selection as HTML, and
/// the copy's number, which pastes it again from the engine's clipboard while it holds it.
#[derive(Debug, Serialize)]
pub struct Copied {
    pub html: String,
    pub copy: u64,
}

/// The table cell `t` is in, as rhwp's cell functions take it: host paragraph, table and cell.
/// None in the body; an error in a note, 머리말, 꼬리말, 글상자 or caption.
fn cell(
    doc: &rhwp::model::document::Document,
    t: &EditTarget,
) -> Result<Option<(usize, usize, usize)>, EditError> {
    if t.note.is_some() || t.header_footer.is_some() {
        return Err(EditError::UnsupportedTarget);
    }
    let Some(c) = &t.cell else { return Ok(None) };
    match table(doc, t) {
        Some(table) if (c.cell as usize) < table.cells.len() => Ok(Some((
            t.paragraph as usize,
            c.control as usize,
            c.cell as usize,
        ))),
        _ => Err(EditError::UnsupportedTarget),
    }
}

impl EditSession {
    /// Copies the selection to the engine's clipboard and returns it as HTML.
    pub fn copy(&mut self, revision: u64, selection: &EditSelection) -> Result<Copied, EditError> {
        self.check_revision(revision)?;
        self.validate_range(selection)?;
        let (start, end) = ordered(selection);
        let doc = self.core.document();
        let place = cell(doc, &start.target)?;
        let offset = |p: &EditPosition| -> Result<usize, EditError> {
            Ok(logical::spot(get(doc, &p.target)?, p.scalar).text)
        };
        let (s, from, to) = (start.target.section as usize, offset(start)?, offset(end)?);
        let (first, last) = (index(&start.target), index(&end.target));
        let html = match place {
            None => {
                self.core.copy_selection_native(s, first, from, last, to)?;
                self.core
                    .export_selection_html_native(s, first, from, last, to)?
            }
            Some((p, control, cell)) => {
                self.core
                    .copy_selection_in_cell_native(s, p, control, cell, first, from, last, to)?;
                self.core.export_selection_in_cell_html_native(
                    s, p, control, cell, first, from, last, to,
                )?
            }
        };
        Ok(Copied {
            // Other apps read HTML without a charset as Latin-1.
            html: format!("<meta charset=\"utf-8\">{html}"),
            ..self.copied()
        })
    }
    /// Counts a new copy in the engine's clipboard.
    pub(super) fn copied(&mut self) -> Copied {
        self.copies += 1;
        self.copied = self.copies;
        Copied {
            html: String::new(),
            copy: self.copied,
        }
    }
    pub(super) fn validate_paste(
        &self,
        selection: &EditSelection,
        copy: Option<u64>,
        html: Option<&String>,
    ) -> Result<(), EditError> {
        self.validate_span(selection, true)?;
        cell(self.core.document(), &selection.anchor.target)?;
        match (copy, html) {
            (Some(copy), None) if copy != 0 && copy == self.copied => Ok(()),
            (None, Some(html)) if !html.is_empty() => Ok(()),
            _ => Err(EditError::InvalidInput),
        }
    }
    /// Replaces the selection with copy `copy` from the engine's clipboard, or with `html`.
    /// The caret ends after what came in.
    pub(super) fn paste(
        &mut self,
        selection: &EditSelection,
        html: Option<&str>,
    ) -> Result<EditSelection, EditError> {
        let (start, end) = ordered(selection);
        let (start, end) = (start.clone(), end.clone());
        self.delete_range(&start, &end)?;
        let t = &start.target;
        let para = get(self.core.document(), t)?;
        // What follows the caret keeps its length; the caret ends that far from the end.
        let rest = logical::length(para) - start.scalar;
        let at = logical::spot(para, start.scalar).split(para);
        let (s, i) = (t.section as usize, index(t));
        let reply = match (cell(self.core.document(), t)?, html) {
            (None, None) => self.core.paste_internal_native(s, i, at),
            (None, Some(html)) => self.core.paste_html_native(s, i, at, html),
            (Some((p, control, cell)), None) => self
                .core
                .paste_internal_in_cell_native(s, p, control, cell, i, at),
            (Some((p, control, cell)), Some(html)) => self
                .core
                .paste_html_in_cell_native(s, p, control, cell, i, at, html),
        }?;
        let reply: Value = serde_json::from_str(&reply).map_err(|_| EditError::RenderFailed)?;
        if reply.get("ok") != Some(&Value::Bool(true)) {
            return Err(EditError::InvalidInput);
        }
        let last = ["paraIdx", "cellParaIdx"]
            .iter()
            .find_map(|key| reply.get(*key).and_then(Value::as_u64))
            .ok_or(EditError::RenderFailed)?;
        let target = at_index(t, last as usize);
        let scalar = logical::length(get(self.core.document(), &target)?)
            .checked_sub(rest)
            .ok_or(EditError::RenderFailed)?;
        Ok(EditSelection::caret(EditPosition {
            target,
            scalar,
            upstream: false,
        }))
    }
}
