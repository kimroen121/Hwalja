mod commands;
pub mod ffi;
mod geometry;
mod preservation;
mod protocol;
mod save;
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

/// What the session remembers about one rendered page.
#[derive(Clone, Copy, PartialEq)]
struct Page {
    hash: u64,
    suspect: bool,
}
/// Pages after a render, and the PDF of the ones that changed.
struct Rendered {
    pages: Vec<Page>,
    changed: Vec<u32>,
    pdf: Vec<u8>,
}

pub struct EditSession {
    core: DocumentCore,
    original: Vec<u8>,
    revision: u64,
    pages: Vec<Page>,
    /// Pages re-rendered by the latest revision, in order, and their PDF.
    changed: Vec<u32>,
    pdf: Vec<u8>,
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
    /// A new blank document, opened through the same path as a file saved as HWPX.
    pub fn blank() -> Result<Self, EditError> {
        let mut core = DocumentCore::new_empty();
        core.create_blank_document_native()?;
        Self::open(&core.export_hwpx_native()?)
    }
    pub fn open(bytes: &[u8]) -> Result<Self, EditError> {
        if bytes.is_empty() {
            return Err(EditError::InvalidInput);
        }
        if bytes.len() > 64 * 1024 * 1024 {
            return Err(EditError::ResourceLimit);
        }
        if let Err(error) = rhwp::parser::parse_document(bytes) {
            return Err(match error {
                rhwp::parser::ParseError::EncryptedDocument => EditError::PasswordRequired,
                rhwp::parser::ParseError::UnsupportedFormat { .. } => EditError::UnsupportedFormat,
                _ => EditError::InvalidInput,
            });
        }
        let core = DocumentCore::from_bytes(bytes)?;
        let mut session = Self {
            core,
            original: bytes.to_vec(),
            revision: 0,
            pages: Vec::new(),
            changed: Vec::new(),
            pdf: Vec::new(),
            selection: None,
            locked: false,
            undo: Vec::new(),
            redo: Vec::new(),
            state: 0,
            next_state: 1,
            #[cfg(test)]
            fail_render: false,
        };
        let Rendered {
            pages,
            changed,
            pdf,
        } = session.render(0, u32::MAX)?;
        (session.pages, session.changed, session.pdf) = (pages, changed, pdf);
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
            changed_pages: self.changed.clone(),
            suspect_pages: (0..self.pages.len() as u32)
                .filter(|&p| self.pages[p as usize].suspect)
                .collect(),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.state != 0,
            locked: self.locked,
        }
    }
    /// Renders pages from `from` on and keeps the PDF of those that changed. With an unchanged
    /// page count, the first unchanged page after `settle` ends the scan: layout only flows
    /// forward, so the pages after it are unchanged too. A new page count rescans every page
    /// (page totals may appear anywhere).
    fn render(&self, from: u32, settle: u32) -> Result<Rendered, EditError> {
        use std::hash::{Hash, Hasher};
        #[cfg(test)]
        if self.fail_render {
            return Err(EditError::RenderFailed);
        }
        let count = self.core.page_count();
        if count > 1000 {
            return Err(EditError::ResourceLimit);
        }
        let same_count = count as usize == self.pages.len();
        let mut pages = self.pages.clone();
        pages.resize(
            count as usize,
            Page {
                hash: 0,
                suspect: false,
            },
        );
        let (mut changed, mut svgs) = (Vec::new(), Vec::new());
        for page in if same_count { from } else { 0 }..count {
            let failed = |_| EditError::RenderFailed;
            let svg = self.core.render_page_svg_native(page).map_err(failed)?;
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            svg.hash(&mut hasher);
            let hash = hasher.finish();
            if self
                .pages
                .get(page as usize)
                .is_some_and(|p| p.hash == hash)
            {
                if same_count && page > settle {
                    break;
                }
                continue;
            }
            let suspect = crate::layout_audit::is_suspect_page(&self.core, page).map_err(failed)?;
            pages[page as usize] = Page { hash, suspect };
            changed.push(page);
            svgs.push(svg);
        }
        let pdf = if svgs.is_empty() {
            Vec::new()
        } else {
            rhwp::renderer::pdf::svgs_to_pdf_with_options(&svgs, &Default::default())
                .map_err(|_| EditError::RenderFailed)?
        };
        Ok(Rendered {
            pages,
            changed,
            pdf,
        })
    }
    /// Page showing `position`, if the engine can place it.
    fn page_of(&self, position: &EditPosition) -> Option<u32> {
        self.caret(self.revision, position)
            .ok()
            .map(|rect| rect.page)
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
        let start = match &request.command {
            EditCommand::Replace { selection, .. } => {
                let key = |p: &EditPosition| (commands::index(&p.target), p.scalar);
                Some(std::cmp::min_by_key(
                    &selection.anchor,
                    &selection.focus,
                    |p| key(p),
                ))
            }
            EditCommand::Split { position } | EditCommand::MergePrevious { position } => {
                Some(position)
            }
            EditCommand::Undo | EditCommand::Redo => None,
        };
        // A page earlier: joined or shortened text can move back onto the previous page.
        let from = start
            .and_then(|p| self.page_of(p))
            .map_or(0, |p| p.saturating_sub(1));
        let snapshot = self.core.save_snapshot_native();
        let result = catch_unwind(AssertUnwindSafe(|| {
            let position = self.execute(&request.command)?;
            preservation::check(&before, self.core.document(), &request.command)?;
            let settle = self.page_of(&position).unwrap_or(u32::MAX);
            Ok((position, self.render(from, settle)?))
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
            self.render(0, u32::MAX)
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
    fn publish(&mut self, rendered: Rendered, selection: Option<EditSelection>) {
        self.pages = rendered.pages;
        self.changed = rendered.changed;
        self.pdf = rendered.pdf;
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
