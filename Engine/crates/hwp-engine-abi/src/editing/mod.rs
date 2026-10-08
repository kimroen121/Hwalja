mod cells;
mod clipboard;
mod codes;
mod commands;
mod display;
pub mod ffi;
mod format;
mod geometry;
mod header_footer;
mod latex;
mod logical;
mod navigation;
mod objects;
#[cfg(test)]
mod preservation;
mod protocol;
mod save;
mod sections;
mod stops;
mod styles;
pub use protocol::*;
use rhwp::DocumentCore;
use std::panic::{catch_unwind, AssertUnwindSafe};
pub use styles::StyleInfo;

/// Undo + redo states kept in memory; the original bytes are kept separately.
const HISTORY_LIMIT: usize = 20;

/// A restorable document state. `id` 0 is the opened original.
struct State {
    snapshot: u32,
    selection: Option<EditSelection>,
    id: u64,
}

/// Pages after a render (the hash of each page's SVG), and how to draw the ones that
/// changed: a display list each, or, for pages it cannot express, a page in `pdf` (in order).
struct Rendered {
    pages: Vec<u64>,
    changed: Vec<u32>,
    displays: Vec<Option<display::Display>>,
    pdf: Vec<u8>,
}

pub struct EditSession {
    core: DocumentCore,
    original: Vec<u8>,
    revision: u64,
    /// Hash of each page's SVG as last rendered.
    pages: Vec<u64>,
    /// Pages re-rendered by the latest revision, in order, and how to draw them.
    changed: Vec<u32>,
    displays: Vec<Option<display::Display>>,
    pdf: Vec<u8>,
    selection: Option<EditSelection>,
    locked: bool,
    /// The password the document was opened with; saving locks it with the same.
    password: Option<Vec<u8>>,
    undo: Vec<State>,
    redo: Vec<State>,
    state: u64,
    next_state: u64,
    /// Page layouts the caret stops are read from, for the current revision.
    layouts: std::cell::RefCell<stops::Layouts>,
    /// Copies made, and the one rhwp's clipboard holds (0 for none).
    copies: u64,
    copied: u64,
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
        Self::open_with(bytes, None)
    }
    /// Opens a document locked with `password`; a wrong one is `PasswordRequired` again.
    pub fn open_with(bytes: &[u8], password: Option<&[u8]>) -> Result<Self, EditError> {
        if bytes.is_empty() {
            return Err(EditError::InvalidInput);
        }
        if bytes.len() > 64 * 1024 * 1024 {
            return Err(EditError::ResourceLimit);
        }
        let mut core = match password {
            Some(password) => DocumentCore::from_bytes_with_password(bytes, password)
                .map_err(|_| EditError::PasswordRequired)?,
            None => {
                if let Err(error) = rhwp::parser::parse_document(bytes) {
                    return Err(match error {
                        rhwp::parser::ParseError::EncryptedDocument => EditError::PasswordRequired,
                        rhwp::parser::ParseError::UnsupportedFormat { .. } => {
                            EditError::UnsupportedFormat
                        }
                        _ => EditError::InvalidInput,
                    });
                }
                DocumentCore::from_bytes(bytes)?
            }
        };
        // A file another program wrote can leave its lines to the reader, without line
        // records; 한글 lays those paragraphs out on opening, objects in the line included.
        let unlaid = core.document().sections.iter().any(|s| {
            s.paragraphs
                .iter()
                .any(|p| p.line_segs.is_empty() && (!p.text.is_empty() || !p.controls.is_empty()))
        });
        if unlaid {
            core.reflow_linesegs_on_demand();
        }
        let mut session = Self {
            core,
            original: bytes.to_vec(),
            revision: 0,
            pages: Vec::new(),
            changed: Vec::new(),
            displays: Vec::new(),
            pdf: Vec::new(),
            selection: None,
            locked: false,
            password: password.map(<[u8]>::to_vec),
            undo: Vec::new(),
            redo: Vec::new(),
            state: 0,
            next_state: 1,
            layouts: Default::default(),
            copies: 0,
            copied: 0,
            #[cfg(test)]
            fail_render: false,
        };
        let Rendered {
            pages,
            changed,
            displays,
            pdf,
        } = session.render(0, u32::MAX)?;
        (session.pages, session.changed) = (pages, changed);
        (session.displays, session.pdf) = (displays, pdf);
        Ok(session)
    }
    /// The re-rendered pages: per changed page a byte, 1 and its encoded display list or 0
    /// for a page in the PDF that follows them.
    pub fn rendering(&self) -> Vec<u8> {
        let mut data = Vec::new();
        for display in &self.displays {
            data.push(display.is_some() as u8);
            if let Some(display) = display {
                display.encode(&mut data);
            }
        }
        data.extend(&self.pdf);
        data
    }
    pub fn original(&self) -> &[u8] {
        &self.original
    }
    pub fn reply(&self) -> EditReply {
        EditReply {
            version: PROTOCOL_VERSION,
            revision: self.revision,
            selection: self.selection.clone(),
            caret: self
                .selection
                .as_ref()
                .and_then(|s| self.caret(self.revision, &s.focus).ok()),
            page_count: self.core.page_count(),
            changed_pages: self.changed.clone(),
            bodies: self.changed.iter().map(|&page| self.body(page)).collect(),
            can_undo: !self.undo.is_empty(),
            can_redo: !self.redo.is_empty(),
            dirty: self.state != 0,
            locked: self.locked,
        }
    }
    /// 쪽 윤곽 off shows only this rectangle of the page.
    fn body(&self, page: u32) -> PageRect {
        let info: serde_json::Value = self
            .core
            .get_page_info_native(page)
            .ok()
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default();
        let f = |key: &str| info[key].as_f64().unwrap_or(0.0);
        let top = f("marginTop") + f("marginHeader");
        PageRect {
            page,
            x: f("bodyLeft"),
            y: top,
            width: f("bodyRight") - f("bodyLeft"),
            height: f("height") - top - f("marginBottom") - f("marginFooter"),
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
        pages.resize(count as usize, 0);
        let (mut changed, mut displays, mut svgs) = (Vec::new(), Vec::new(), Vec::new());
        for page in if same_count { from } else { 0 }..count {
            let failed = |_| EditError::RenderFailed;
            let svg = self.core.render_page_svg_native(page).map_err(failed)?;
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            svg.hash(&mut hasher);
            let hash = hasher.finish();
            if self.pages.get(page as usize) == Some(&hash) {
                if same_count && page > settle {
                    break;
                }
                continue;
            }
            pages[page as usize] = hash;
            changed.push(page);
            let display = display::build(&svg);
            if display.is_none() {
                svgs.push(svg);
            }
            displays.push(display);
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
            displays,
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
        if request.version != PROTOCOL_VERSION {
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
        // Tests check that every command changes only what it should; the editor skips it,
        // as it costs a document copy per keystroke.
        #[cfg(test)]
        let before = self.core.document().clone();
        let start = match &request.command {
            EditCommand::ReplaceAll { selections, .. } => {
                selections.first().map(|s| commands::ordered(s).0.clone())
            }
            EditCommand::Replace { selection, .. }
            | EditCommand::Paste { selection, .. }
            | EditCommand::FormatText { selection, .. }
            | EditCommand::FormatParagraphs { selection, .. }
            | EditCommand::ApplyStyle { selection, .. } => {
                Some(commands::ordered(selection).0.clone())
            }
            EditCommand::MergeCells { selection }
            | EditCommand::SplitCells { selection, .. }
            | EditCommand::EqualizeCells { selection, .. }
            | EditCommand::CalculateBlock { selection, .. } => Some(selection.anchor.clone()),
            EditCommand::Split { position }
            | EditCommand::MergePrevious { position }
            | EditCommand::Break { position, .. }
            | EditCommand::InsertTable { position, .. }
            | EditCommand::InsertPicture { position, .. }
            | EditCommand::InsertEquation { position, .. }
            | EditCommand::InsertShape { position, .. }
            | EditCommand::InsertNote { position, .. } => Some(position.clone()),
            EditCommand::EditTable { cell, .. }
            | EditCommand::FlipTable { cell, .. }
            | EditCommand::SetCell { cell, .. } => Some(EditPosition {
                target: cell.clone(),
                scalar: 0,
                upstream: false,
            }),
            EditCommand::SetObject { object, .. }
            | EditCommand::MoveObject { object, .. }
            | EditCommand::DeleteObject { object }
            | EditCommand::Order { object, .. }
            | EditCommand::Ungroup { object }
            | EditCommand::ReplacePicture { object, .. }
            | EditCommand::MoveLineEnd { object, .. }
            | EditCommand::SetTextBox { object, .. }
            | EditCommand::ResizeTable { table: object, .. } => Some(EditPosition {
                target: EditTarget {
                    section: object.section,
                    paragraph: object.paragraph,
                    cell: None,
                    note: None,
                    header_footer: None,
                },
                scalar: 0,
                upstream: false,
            }),
            EditCommand::Group { objects } => objects.first().map(|object| EditPosition {
                target: EditTarget {
                    section: object.section,
                    paragraph: object.paragraph,
                    cell: None,
                    note: None,
                    header_footer: None,
                },
                scalar: 0,
                upstream: false,
            }),
            EditCommand::NewNumber { position, .. } | EditCommand::AddBookmark { position, .. } => {
                Some(position.clone())
            }
            EditCommand::SetPageHide { target, .. }
            | EditCommand::ChangeBookmark { target, .. } => Some(EditPosition {
                target: target.clone(),
                scalar: 0,
                upstream: false,
            }),
            EditCommand::SetPage { .. }
            | EditCommand::SetPageBorder { .. }
            | EditCommand::SetSection { .. }
            | EditCommand::SetNoteShape { .. }
            | EditCommand::AddStyle { .. }
            | EditCommand::EditStyle { .. }
            | EditCommand::DeleteStyle { .. }
            | EditCommand::MoveStyle { .. }
            | EditCommand::RestyleFromCaret { .. }
            | EditCommand::EraseCodes { .. }
            | EditCommand::SetColumns { .. }
            | EditCommand::DeleteHeaderFooter { .. }
            | EditCommand::HeaderFooter { .. }
            | EditCommand::Undo
            | EditCommand::Redo => None,
        };
        // A page earlier: joined or shortened text can move back onto the previous page.
        let from = start
            .and_then(|p| self.page_of(&p))
            .map_or(0, |p| p.saturating_sub(1));
        let snapshot = self.core.save_snapshot_native();
        let result = catch_unwind(AssertUnwindSafe(|| {
            let selection = self.execute(&request.command)?;
            #[cfg(test)]
            preservation::check(&before, self.core.document(), &request.command)?;
            let (_, end) = commands::ordered(&selection);
            let settle = self.page_of(end).unwrap_or(u32::MAX);
            Ok((selection, self.render(from, settle)?))
        }))
        .unwrap_or(Err(EditError::RenderFailed));
        match result {
            Ok((selection, output)) => {
                if request.amend && !self.undo.is_empty() {
                    self.core.discard_snapshot_native(snapshot);
                } else {
                    self.undo.push(State {
                        snapshot,
                        selection: self.selection.take(),
                        id: self.state,
                    });
                }
                for state in std::mem::take(&mut self.redo) {
                    self.core.discard_snapshot_native(state.snapshot);
                }
                while self.undo.len() > HISTORY_LIMIT {
                    let oldest = self.undo.remove(0);
                    self.core.discard_snapshot_native(oldest.snapshot);
                }
                self.state = self.next_state;
                self.next_state += 1;
                self.publish(output, Some(selection));
                Ok(self.reply())
            }
            Err(error) => Err(self.roll_back(snapshot, error)),
        }
    }
    /// Shows or hides 문단 부호 and 조판 부호 on the pages. Neither is printed or
    /// exported, saved, or undone.
    pub fn show_marks(
        &mut self,
        paragraph: bool,
        control: bool,
        borders: bool,
    ) -> Result<EditReply, EditError> {
        if self.locked {
            return Err(EditError::Locked);
        }
        self.core.show_paragraph_marks = paragraph;
        self.core.show_control_codes = control;
        self.core.show_transparent_borders = borders;
        let rendered = self.render(0, u32::MAX)?;
        self.publish(rendered, self.selection.clone());
        Ok(self.reply())
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
    /// Takes the app's selection, which may have moved since the last edit.
    pub fn keep_selection(&mut self, selection: Option<EditSelection>) {
        if selection.is_some() {
            self.selection = selection;
        }
    }
    fn publish(&mut self, rendered: Rendered, selection: Option<EditSelection>) {
        self.pages = rendered.pages;
        self.changed = rendered.changed;
        self.displays = rendered.displays;
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
