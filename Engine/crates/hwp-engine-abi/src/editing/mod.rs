mod protocol;
mod commands;
mod preservation;
pub use protocol::*;
use rhwp::DocumentCore;
use std::panic::{catch_unwind, AssertUnwindSafe};

pub struct EditSession {
    core: DocumentCore,
    original: Vec<u8>,
    revision: u64,
    pdf: Vec<u8>,
    selection: Option<EditSelection>,
    locked: bool,
}
impl EditSession {
    pub fn open(bytes: &[u8]) -> Result<Self, EditError> {
        if bytes.is_empty() { return Err(EditError::InvalidInput) }
        if bytes.len() > 64 * 1024 * 1024 { return Err(EditError::ResourceLimit) }
        let core = DocumentCore::from_bytes(bytes)?;
        if core.page_count() > 1000 { return Err(EditError::ResourceLimit) }
        let pdf = core.render_document_pdf_native().map_err(|_| EditError::RenderFailed)?;
        Ok(Self { core, original: bytes.to_vec(), revision: 0, pdf, selection: None, locked: false })
    }
    pub fn pdf(&self) -> &[u8] { &self.pdf }
    pub fn original(&self) -> &[u8] { &self.original }
    pub fn reply(&self) -> EditReply {
        EditReply { version: 1, revision: self.revision, selection: self.selection.clone(),
            page_count: self.core.page_count(), warnings: String::new(), can_undo: false,
            can_redo: false, dirty: self.revision != 0, locked: self.locked }
    }
    pub fn apply(&mut self, request: EditRequest) -> Result<EditReply, EditError> {
        if self.locked { return Err(EditError::Locked) }
        if request.version != 1 { return Err(EditError::InvalidInput) }
        if request.revision != self.revision { return Err(EditError::StaleRevision) }
        self.validate_command(&request.command)?;
        let before = self.core.document().clone();
        let snapshot = self.core.save_snapshot_native();
        let result = catch_unwind(AssertUnwindSafe(|| {
            let position = self.execute(&request.command)?;
            preservation::check(&before, self.core.document(), &request.command)?;
            if self.core.page_count() > 1000 { return Err(EditError::ResourceLimit) }
            let pdf = self.core.render_document_pdf_native().map_err(|_| EditError::RenderFailed)?;
            Ok((position, pdf))
        })).unwrap_or(Err(EditError::RenderFailed));
        match result {
            Ok((position, pdf)) => {
                self.pdf = pdf;
                self.selection = Some(EditSelection::caret(position));
                self.revision += 1;
                self.core.discard_snapshot_native(snapshot);
                Ok(self.reply())
            }
            Err(error) => {
                if catch_unwind(AssertUnwindSafe(|| self.core.restore_snapshot_native(snapshot))).ok().and_then(Result::ok).is_none() {
                    self.locked = true;
                }
                self.core.discard_snapshot_native(snapshot);
                Err(if self.locked { EditError::Locked } else { error })
            }
        }
    }
}
#[cfg(test)]
mod tests;
