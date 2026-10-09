//! 하이퍼링크: links to web addresses in the text of the body, table cells and 글상자.
use super::commands::get;
use super::*;
use rhwp::document_core::hyperlink::HyperlinkTarget;

/// The paragraph rhwp's link functions take for `t`.
fn link_target(t: &EditTarget) -> Result<HyperlinkTarget, EditError> {
    if t.note.is_some() || t.header_footer.is_some() {
        return Err(EditError::UnsupportedTarget);
    }
    Ok(HyperlinkTarget {
        section: t.section as usize,
        para: t.paragraph as usize,
        cell_path: t
            .cell
            .iter()
            .map(|c| (c.control as usize, c.cell as usize, c.paragraph as usize))
            .collect(),
    })
}

/// 표시할 문자열: one line, not empty.
fn valid_text(text: &str) -> bool {
    !text.trim().is_empty() && !text.chars().any(char::is_control)
}

impl EditSession {
    /// The link whose text holds the caret at `p`, its ends included, with its field id.
    pub fn hyperlink_at(&self, p: &EditPosition) -> Result<Option<(u32, Hyperlink)>, EditError> {
        let Ok(target) = link_target(&p.target) else {
            return Ok(None);
        };
        let at = logical::spot(get(self.core.document(), &p.target)?, p.scalar).text;
        Ok(self
            .core
            .hyperlinks_native(&target)?
            .into_iter()
            .find(|l| (l.start..=l.end).contains(&at))
            .map(|l| {
                (
                    l.field_id,
                    Hyperlink {
                        text: l.text,
                        uri: l.uri,
                    },
                )
            }))
    }
    pub(super) fn validate_hyperlink(&self, command: &EditCommand) -> Result<(), EditError> {
        match command {
            EditCommand::InsertHyperlink {
                selection,
                text,
                uri,
            } => {
                let (start, end) = commands::ordered(selection);
                link_target(&start.target)?;
                self.validate_range(selection)?;
                if start.target != end.target
                    || !valid_text(text)
                    || rhwp::model::hyperlink::web_command(uri).is_err()
                {
                    return Err(EditError::InvalidInput);
                }
                // Inside a link already.
                if self.hyperlink_at(start)?.is_some() || self.hyperlink_at(end)?.is_some() {
                    return Err(EditError::UnsupportedTarget);
                }
                Ok(())
            }
            EditCommand::EditHyperlink {
                position,
                text,
                uri,
            } => {
                let (_, link) = self
                    .hyperlink_at(position)?
                    .ok_or(EditError::UnsupportedTarget)?;
                // rhwp keeps 전자 우편, file and 한/글 문서 links as they are.
                if rhwp::model::hyperlink::web_command(&link.uri).is_err() {
                    return Err(EditError::UnsupportedTarget);
                }
                if !valid_text(text) || rhwp::model::hyperlink::web_command(uri).is_err() {
                    return Err(EditError::InvalidInput);
                }
                Ok(())
            }
            EditCommand::RemoveHyperlink { position } => self
                .hyperlink_at(position)?
                .map(|_| ())
                .ok_or(EditError::UnsupportedTarget),
            _ => Ok(()),
        }
    }
    /// Links `selection` (or `text` put in at its caret) to `uri`, in blue and underlined
    /// as 한/글 shows links; the caret goes after the link.
    pub(super) fn insert_hyperlink(
        &mut self,
        selection: &EditSelection,
        text: &str,
        uri: &str,
    ) -> Result<EditSelection, EditError> {
        let (start, end) = commands::ordered(selection);
        let (start, mut end) = (start.clone(), end.clone());
        if start == end {
            self.insert(&start, text)?;
            end.scalar += text.chars().count() as u32;
        }
        let target = link_target(&start.target)?;
        let (from, to) = {
            let para = get(self.core.document(), &start.target)?;
            (
                logical::spot(para, start.scalar).text,
                logical::spot(para, end.scalar).text,
            )
        };
        let id = self.core.insert_hyperlink_native(&target, from, to, uri)?;
        let selected: String = get(self.core.document(), &start.target)?
            .text
            .chars()
            .skip(from)
            .take(to - from)
            .collect();
        if selected != text {
            self.core.replace_hyperlink_text_native(&target, id, text)?;
        }
        let to = from + text.chars().count();
        let (from, to) = {
            let para = get(self.core.document(), &start.target)?;
            (
                logical::position(para, from, true),
                logical::position(para, to, false),
            )
        };
        let (props, languages) = self.char_props(&CharStyle {
            color: Some("#0000ff".into()),
            underline: Some(true),
            ..Default::default()
        });
        self.format_text(&start.target, from, to, &props, &languages)?;
        Ok(EditSelection::caret(EditPosition {
            target: start.target,
            scalar: to,
            upstream: false,
        }))
    }
    pub(super) fn edit_hyperlink(
        &mut self,
        position: &EditPosition,
        text: &str,
        uri: &str,
    ) -> Result<(), EditError> {
        let target = link_target(&position.target)?;
        let (id, link) = self
            .hyperlink_at(position)?
            .ok_or(EditError::UnsupportedTarget)?;
        self.core.update_hyperlink_native(&target, id, uri)?;
        if link.text != text {
            self.core.replace_hyperlink_text_native(&target, id, text)?;
        }
        Ok(())
    }
    pub(super) fn remove_hyperlink(&mut self, position: &EditPosition) -> Result<(), EditError> {
        let target = link_target(&position.target)?;
        let (id, _) = self
            .hyperlink_at(position)?
            .ok_or(EditError::UnsupportedTarget)?;
        self.core
            .remove_hyperlink_with_format_native(&target, id, true)?;
        Ok(())
    }
}
