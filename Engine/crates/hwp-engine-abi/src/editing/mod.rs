mod commands;
pub mod ffi;
mod geometry;
mod preservation;
mod protocol;
pub use protocol::*;
use rhwp::DocumentCore;
use std::panic::{catch_unwind, AssertUnwindSafe};

/// Undo + redo states kept in memory; the original bytes are kept separately.
const HISTORY_LIMIT: usize = 20;

/// A restorable document state. `id` 0 is the opened original.
struct State {
    snapshot: u32,
    selection: Option<EditSelection>,
    id: u64,
}

pub struct EditSession {
    core: DocumentCore,
    original: Vec<u8>,
    revision: u64,
    pdf: Vec<u8>,
    warnings: String,
    selection: Option<EditSelection>,
    locked: bool,
    undo: Vec<State>,
    redo: Vec<State>,
    state: u64,
    next_state: u64,
    #[cfg(test)]
    fail_render: bool,
}
impl EditSession {
    pub fn open(bytes: &[u8]) -> Result<Self, EditError> {
        if bytes.is_empty() {
            return Err(EditError::InvalidInput);
        }
        if bytes.len() > 64 * 1024 * 1024 {
            return Err(EditError::ResourceLimit);
        }
        let core = DocumentCore::from_bytes(bytes)?;
        let mut session = Self {
            core,
            original: bytes.to_vec(),
            revision: 0,
            pdf: Vec::new(),
            warnings: String::new(),
            selection: None,
            locked: false,
            undo: Vec::new(),
            redo: Vec::new(),
            state: 0,
            next_state: 1,
            #[cfg(test)]
            fail_render: false,
        };
        (session.pdf, session.warnings) = session.render()?;
        Ok(session)
    }
    pub fn pdf(&self) -> &[u8] {
        &self.pdf
    }
    pub fn original(&self) -> &[u8] {
        &self.original
    }
    pub fn reply(&self) -> EditReply {
        EditReply {
            version: 1,
            revision: self.revision,
            selection: self.selection.clone(),
            page_count: self.core.page_count(),
            warnings: self.warnings.clone(),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.state != 0,
            locked: self.locked,
        }
    }
    fn render(&self) -> Result<(Vec<u8>, String), EditError> {
        #[cfg(test)]
        if self.fail_render {
            return Err(EditError::RenderFailed);
        }
        if self.core.page_count() > 1000 {
            return Err(EditError::ResourceLimit);
        }
        let warnings =
            crate::layout_audit::warnings(&self.core).map_err(|_| EditError::RenderFailed)?;
        let pdf = self
            .core
            .render_document_pdf_native()
            .map_err(|_| EditError::RenderFailed)?;
        Ok((pdf, warnings))
    }
    pub fn apply(&mut self, request: EditRequest) -> Result<EditReply, EditError> {
        if self.locked {
            return Err(EditError::Locked);
        }
        if request.version != 1 {
            return Err(EditError::InvalidInput);
        }
        if request.revision != self.revision {
            return Err(EditError::StaleRevision);
        }
        match &request.command {
            EditCommand::Undo => return self.travel(true),
            EditCommand::Redo => return self.travel(false),
            _ => {}
        }
        self.validate_command(&request.command)?;
        let before = self.core.document().clone();
        let snapshot = self.core.save_snapshot_native();
        let result = catch_unwind(AssertUnwindSafe(|| {
            let position = self.execute(&request.command)?;
            preservation::check(&before, self.core.document(), &request.command)?;
            Ok((position, self.render()?))
        }))
        .unwrap_or(Err(EditError::RenderFailed));
        match result {
            Ok((position, output)) => {
                self.undo.push(State {
                    snapshot,
                    selection: self.selection.take(),
                    id: self.state,
                });
                for state in std::mem::take(&mut self.redo) {
                    self.core.discard_snapshot_native(state.snapshot);
                }
                while self.undo.len() > HISTORY_LIMIT {
                    let oldest = self.undo.remove(0);
                    self.core.discard_snapshot_native(oldest.snapshot);
                }
                self.state = self.next_state;
                self.next_state += 1;
                self.publish(output, Some(EditSelection::caret(position)));
                Ok(self.reply())
            }
            Err(error) => Err(self.roll_back(snapshot, error)),
        }
    }
    /// Moves one state back (undo) or forward (redo), keeping the current state on the other stack.
    fn travel(&mut self, back: bool) -> Result<EditReply, EditError> {
        let target = if back {
            self.undo.pop()
        } else {
            self.redo.pop()
        }
        .ok_or(EditError::InvalidInput)?;
        let current = self.core.save_snapshot_native();
        let result = catch_unwind(AssertUnwindSafe(|| {
            self.core
                .restore_snapshot_native(target.snapshot)
                .map_err(|_| EditError::RenderFailed)?;
            self.render()
        }))
        .unwrap_or(Err(EditError::RenderFailed));
        match result {
            Ok(output) => {
                self.core.discard_snapshot_native(target.snapshot);
                let leaving = State {
                    snapshot: current,
                    selection: self.selection.take(),
                    id: self.state,
                };
                if back {
                    self.redo.push(leaving)
                } else {
                    self.undo.push(leaving)
                }
                self.state = target.id;
                self.publish(output, target.selection);
                Ok(self.reply())
            }
            Err(error) => {
                if back {
                    self.undo.push(target)
                } else {
                    self.redo.push(target)
                }
                Err(self.roll_back(current, error))
            }
        }
    }
    fn publish(&mut self, (pdf, warnings): (Vec<u8>, String), selection: Option<EditSelection>) {
        self.pdf = pdf;
        self.warnings = warnings;
        self.selection = selection;
        self.revision += 1;
    }
    /// Restores `snapshot` after a failed command; locks the session if even that fails.
    fn roll_back(&mut self, snapshot: u32, error: EditError) -> EditError {
        if catch_unwind(AssertUnwindSafe(|| {
            self.core.restore_snapshot_native(snapshot)
        }))
        .ok()
        .and_then(Result::ok)
        .is_none()
        {
            self.locked = true;
        }
        self.core.discard_snapshot_native(snapshot);
        if self.locked {
            EditError::Locked
        } else {
            error
        }
    }
}
#[cfg(test)]
mod tests;
