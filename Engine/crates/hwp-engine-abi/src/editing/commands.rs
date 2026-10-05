use super::*;
use base64::Engine;
use rhwp::model::{
    control::{AutoNumber, AutoNumberType, Control},
    document::Document,
    header_footer::HeaderFooterApply,
    paragraph::Paragraph,
    shape::{ShapeObject, TextBox},
    table::Table,
};
use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

/// 1 cm in HWPUNIT, the smallest paper side or body extent `SetPage` accepts.
const CENTIMETER: u32 = 2835;

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
        let table = match host.controls.get(c.control as usize) {
            Some(Control::Table(table)) => table,
            // A 글상자 is addressed as cell 0 of its shape, as rhwp does.
            Some(Control::Shape(shape)) if c.cell == 0 => {
                return text_box(shape)
                    .map(|b| b.paragraphs.as_slice())
                    .ok_or(EditError::UnsupportedTarget)
            }
            _ => return Err(EditError::UnsupportedTarget),
        };
        let cell = table
            .cells
            .get(c.cell as usize)
            .ok_or(EditError::InvalidInput)?;
        if cell.text_direction != 0 {
            return Err(EditError::UnsupportedTarget);
        }
        Ok(&cell.paragraphs)
    } else if let Some(n) = &t.note {
        let host = section
            .paragraphs
            .get(t.paragraph as usize)
            .ok_or(EditError::InvalidInput)?;
        match host.controls.get(n.control as usize) {
            Some(Control::Footnote(note)) => Ok(&note.paragraphs),
            Some(Control::Endnote(note)) => Ok(&note.paragraphs),
            _ => Err(EditError::UnsupportedTarget),
        }
    } else {
        Ok(&section.paragraphs)
    }
}
/// The 글상자 a drawing object holds, if any.
pub(super) fn text_box(shape: &ShapeObject) -> Option<&TextBox> {
    match shape {
        ShapeObject::Rectangle(s) => s.drawing.text_box.as_ref(),
        ShapeObject::Ellipse(s) => s.drawing.text_box.as_ref(),
        ShapeObject::Polygon(s) => s.drawing.text_box.as_ref(),
        ShapeObject::Curve(s) => s.drawing.text_box.as_ref(),
        _ => None,
    }
}
/// Whether `t` is in a 글상자 rather than a table cell.
pub(super) fn in_text_box(doc: &Document, t: &EditTarget) -> bool {
    t.cell.as_ref().is_some_and(|c| {
        matches!(
            doc.sections
                .get(t.section as usize)
                .and_then(|s| s.paragraphs.get(t.paragraph as usize))
                .and_then(|p| p.controls.get(c.control as usize)),
            Some(Control::Shape(_))
        )
    })
}
pub(super) fn index(t: &EditTarget) -> usize {
    (match (&t.cell, &t.note) {
        (Some(c), _) => c.paragraph,
        (_, Some(n)) => n.paragraph,
        _ => t.paragraph,
    }) as usize
}
pub(super) fn at_index(t: &EditTarget, index: usize) -> EditTarget {
    let mut result = t.clone();
    if let Some(c) = &mut result.cell {
        c.paragraph = index as u32;
    } else if let Some(n) = &mut result.note {
        n.paragraph = index as u32;
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
        && match (&a.note, &b.note) {
            (None, None) => true,
            (Some(x), Some(y)) => a.paragraph == b.paragraph && x.control == y.control,
            _ => false,
        }
}
pub(super) fn get<'a>(doc: &'a Document, t: &EditTarget) -> Result<&'a Paragraph, EditError> {
    if t.cell.is_some() && t.note.is_some() {
        return Err(EditError::UnsupportedTarget);
    }
    paragraphs(doc, t)?
        .get(index(t))
        .ok_or(EditError::InvalidInput)
}
/// Paragraphs whose text can change around their controls (tables, pictures, notes…),
/// which stay in place. Fields and title marks index the text and stay read-only.
pub(super) fn editable(p: &Paragraph) -> bool {
    p.title_marks.is_empty()
        && p.field_ranges.is_empty()
        && p.range_tags.is_empty()
        && p.orphan_field_ends.is_empty()
        && p.ctrl_data_records.len() <= p.controls.len()
        && !p.text.chars().any(|c| c.is_control() && c != '\t')
}
/// Where the header (or footer) for every page of section `s` sits: paragraph and control.
pub(super) fn header_footer_at(doc: &Document, s: usize, footer: bool) -> Option<(usize, usize)> {
    doc.sections[s]
        .paragraphs
        .iter()
        .enumerate()
        .find_map(|(p, para)| {
            let c = para.controls.iter().position(|c| match c {
                Control::Header(h) => !footer && h.apply_to == HeaderFooterApply::Both,
                Control::Footer(f) => footer && f.apply_to == HeaderFooterApply::Both,
                _ => false,
            })?;
            Some((p, c))
        })
}
/// The table holding `t`'s cell.
pub(super) fn table<'a>(doc: &'a Document, t: &EditTarget) -> Option<&'a Table> {
    let c = t.cell.as_ref()?;
    match doc
        .sections
        .get(t.section as usize)?
        .paragraphs
        .get(t.paragraph as usize)?
        .controls
        .get(c.control as usize)?
    {
        Control::Table(table) => Some(table),
        _ => None,
    }
}
/// The offset rhwp's paragraph split takes for the text offset `scalar`: it counts each
/// object in the text flow (table, picture, note, number…) as one position.
fn split_offset(p: &Paragraph, scalar: u32) -> usize {
    let scalar = scalar as usize;
    let objects = p
        .controls
        .iter()
        .zip(p.control_text_positions())
        .filter(|(c, at)| {
            *at < scalar
                && matches!(
                    c,
                    Control::Shape(_)
                        | Control::Table(_)
                        | Control::Picture(_)
                        | Control::Equation(_)
                        | Control::Footnote(_)
                        | Control::Endnote(_)
                        | Control::AutoNumber(_)
                        | Control::CharOverlap(_)
                )
        })
        .count();
    scalar + objects
}
/// Formatting inside notes is not supported yet.
pub(super) fn not_in_note(t: &EditTarget) -> Result<(), EditError> {
    if t.note.is_some() {
        Err(EditError::UnsupportedTarget)
    } else {
        Ok(())
    }
}
pub(super) fn body_only(t: &EditTarget) -> Result<(), EditError> {
    if t.cell.is_some() || t.note.is_some() {
        Err(EditError::UnsupportedTarget)
    } else {
        Ok(())
    }
}
fn validate_page(page: &PageSetup) -> Result<(), EditError> {
    let (width, height) = if page.landscape {
        (page.height, page.width)
    } else {
        (page.width, page.height)
    };
    let sides = [width, height];
    let across = page.margin_left as u64 + page.margin_right as u64 + page.margin_gutter as u64;
    let down = page.margin_top as u64
        + page.margin_bottom as u64
        + page.margin_header as u64
        + page.margin_footer as u64;
    if sides
        .iter()
        .all(|&s| (CENTIMETER..=100 * CENTIMETER).contains(&s))
        && across + (CENTIMETER as u64) <= width as u64
        && down + (CENTIMETER as u64) <= height as u64
    {
        Ok(())
    } else {
        Err(EditError::InvalidInput)
    }
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
        Ok(ParagraphInfo {
            target: target.clone(),
            count: paragraphs(self.core.document(), target)?.len() as u32,
            text: get(self.core.document(), target)?.text.clone(),
        })
    }
    pub(super) fn validate_position(&self, p: &EditPosition) -> Result<(), EditError> {
        let para = get(self.core.document(), &p.target)?;
        if !editable(para) {
            return Err(EditError::UnsupportedTarget);
        }
        boundary(&para.text, p.scalar)
    }
    /// Both ends valid, in one container, with only editable paragraphs between them.
    pub(super) fn validate_range(&self, selection: &EditSelection) -> Result<(), EditError> {
        let (start, end) = ordered(selection);
        if !same_container(&start.target, &end.target) {
            return Err(EditError::UnsupportedTarget);
        }
        self.validate_position(start)?;
        self.validate_position(end)?;
        let all = paragraphs(self.core.document(), &start.target)?;
        let (s, e) = (index(&start.target), index(&end.target));
        if all[s..=e].iter().any(|p| !editable(p)) {
            return Err(EditError::UnsupportedTarget);
        }
        Ok(())
    }
    pub(super) fn validate_command(&self, command: &EditCommand) -> Result<(), EditError> {
        match command {
            EditCommand::Replace { selection, text } => {
                self.validate_range(selection)?;
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
                self.validate_range(selection)?;
                not_in_note(&selection.anchor.target)?;
                let (start, end) = ordered(selection);
                if start == end {
                    return Err(EditError::InvalidInput);
                }
                super::format::validate_char(style)
            }
            EditCommand::ApplyStyle { selection, style } => self.validate_style(selection, *style),
            EditCommand::InsertShape { .. } => self.validate_shape(command),
            EditCommand::FormatParagraphs { selection, style } => {
                self.validate_range(selection)?;
                not_in_note(&selection.anchor.target)?;
                super::format::validate_para(style)
            }
            EditCommand::InsertNote { position, .. } => {
                body_only(&position.target)?;
                self.validate_position(position)
            }
            EditCommand::Break { position, .. } => {
                body_only(&position.target)?;
                self.validate_position(position)
            }
            EditCommand::InsertTable {
                position,
                rows,
                columns,
            } => {
                body_only(&position.target)?;
                self.validate_position(position)?;
                if (1..=1000).contains(rows)
                    && (1..=256).contains(columns)
                    && *rows as u32 * *columns as u32 <= 10_000
                {
                    Ok(())
                } else {
                    Err(EditError::InvalidInput)
                }
            }
            EditCommand::InsertPicture {
                position,
                data,
                width,
                height,
                natural_width,
                natural_height,
                extension,
                description,
            } => {
                not_in_note(&position.target)?;
                self.validate_position(position)?;
                if data.len() > 7 * 1024 * 1024 {
                    return Err(EditError::ResourceLimit);
                }
                let decoded = base64::engine::general_purpose::STANDARD
                    .decode(data)
                    .map_err(|_| EditError::InvalidInput)?;
                if decoded.is_empty()
                    || decoded.len() > 5 * 1024 * 1024
                    || !matches!(extension.as_str(), "png" | "jpg" | "jpeg")
                    || !(1..=1_000_000).contains(width)
                    || !(1..=1_000_000).contains(height)
                    || !(1..=20_000).contains(natural_width)
                    || !(1..=20_000).contains(natural_height)
                    || *natural_width as u64 * *natural_height as u64 > 100_000_000
                    || description.len() > 1024
                {
                    Err(EditError::InvalidInput)
                } else {
                    Ok(())
                }
            }
            EditCommand::InsertEquation {
                position,
                script,
                font_size,
                color,
            } => {
                body_only(&position.target)?;
                self.validate_position(position)?;
                if !objects::is_script(script)
                    || !(400..=7_200).contains(font_size)
                    || *color > 0x00ff_ffff
                {
                    Err(EditError::InvalidInput)
                } else {
                    Ok(())
                }
            }
            EditCommand::EditTable { cell, change } => {
                let doc = self.core.document();
                paragraphs(doc, cell)?;
                let t = table(doc, cell).ok_or(EditError::UnsupportedTarget)?;
                match change {
                    TableChange::DeleteRow if t.row_count < 2 => Err(EditError::InvalidInput),
                    TableChange::DeleteColumn if t.col_count < 2 => Err(EditError::InvalidInput),
                    _ => Ok(()),
                }
            }
            EditCommand::SetPage { section, page } => {
                self.section_exists(*section)?;
                validate_page(page)
            }
            EditCommand::HeaderFooter { section, .. } => self.section_exists(*section),
            EditCommand::SetObject { object, props } => self.validate_object(object, props),
            EditCommand::MergeCells { .. }
            | EditCommand::SplitCells { .. }
            | EditCommand::EqualizeCells { .. } => self.validate_cells(command),
            EditCommand::SetCell { cell, props } => self.validate_cell(cell, props),
            EditCommand::DeleteObject { object } => {
                self.validate_object(object, &ObjectProps::default())
            }
            EditCommand::ResizeTable { .. } => self.validate_resize(command),
            EditCommand::Undo | EditCommand::Redo => Err(EditError::UnsupportedTarget),
        }
    }
    fn section_exists(&self, section: u32) -> Result<(), EditError> {
        self.core
            .document()
            .sections
            .get(section as usize)
            .map(|_| ())
            .ok_or(EditError::InvalidInput)
    }
    /// The selection, unchanged by an edit that only touched the section's page layout.
    fn kept(&self, section: u32) -> EditSelection {
        self.selection.clone().unwrap_or_else(|| {
            EditSelection::caret(EditPosition {
                target: EditTarget {
                    section,
                    paragraph: 0,
                    cell: None,
                    note: None,
                },
                scalar: 0,
            })
        })
    }
    /// Replaces the section's header or footer for every page, keeping an existing one's
    /// place among its paragraph's controls.
    fn header_footer(
        &mut self,
        section: u32,
        footer: bool,
        page_number: Option<Placement>,
    ) -> Result<(), EditError> {
        let s = section as usize;
        let mut paragraph = Paragraph::default();
        if page_number.is_some() {
            // The page number is an inline auto number shown in place of a space, as
            // rhwp reads one from a file.
            paragraph.text = " ".into();
            paragraph.char_offsets = vec![0];
            paragraph.controls = vec![Control::AutoNumber(AutoNumber {
                number_type: AutoNumberType::Page,
                ..Default::default()
            })];
            paragraph.ctrl_data_records = vec![None];
            paragraph.char_count = 9;
            paragraph.control_mask = 1 << 0x12;
            paragraph.has_para_text = true;
        }
        if header_footer_at(self.core.document(), s, footer).is_none() {
            self.core.create_header_footer_native(s, !footer, 0)?;
        }
        let (p, c) =
            header_footer_at(self.core.document(), s, footer).ok_or(EditError::RenderFailed)?;
        match &mut self.core.document_mut().sections[s].paragraphs[p].controls[c] {
            Control::Header(h) => h.paragraphs = vec![paragraph],
            Control::Footer(f) => f.paragraphs = vec![paragraph],
            _ => return Err(EditError::RenderFailed),
        }
        let alignment = match page_number {
            Some(Placement::Left) => "left",
            Some(Placement::Center) => "center",
            Some(Placement::Right) => "right",
            None => "justify",
        };
        // Also lays the section out again.
        self.core.apply_para_format_in_hf_native(
            s,
            !footer,
            0,
            0,
            &format!(r#"{{"alignment":"{alignment}"}}"#),
        )?;
        Ok(())
    }
    /// Paper and margins of a section.
    pub fn page_setup(&self, section: u32) -> Result<PageSetup, EditError> {
        let json = self.core.get_page_def_native(section as usize)?;
        serde_json::from_str(&json).map_err(|_| EditError::InvalidInput)
    }
    /// Adds or removes a row or column, keeping the caret in the cell it was in (or the
    /// one that takes its place).
    fn edit_table(
        &mut self,
        target: &EditTarget,
        change: TableChange,
    ) -> Result<EditSelection, EditError> {
        let c = target.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let (s, host, control) = (
            target.section as usize,
            target.paragraph as usize,
            c.control as usize,
        );
        let cell = table(self.core.document(), target)
            .and_then(|t| t.cells.get(c.cell as usize))
            .ok_or(EditError::InvalidInput)?;
        let (mut row, mut col) = (cell.row, cell.col);
        let (last_row, last_col) = (
            row + cell.row_span.max(1) - 1,
            col + cell.col_span.max(1) - 1,
        );
        match change {
            TableChange::InsertRowAbove => {
                self.core
                    .insert_table_row_native(s, host, control, row, false)?;
                row += 1;
            }
            TableChange::InsertRowBelow => {
                self.core
                    .insert_table_row_native(s, host, control, last_row, true)?;
            }
            TableChange::InsertColumnLeft => {
                self.core
                    .insert_table_column_native(s, host, control, col, false)?;
                col += 1;
            }
            TableChange::InsertColumnRight => {
                self.core
                    .insert_table_column_native(s, host, control, last_col, true)?;
            }
            TableChange::DeleteRow => {
                self.core.delete_table_row_native(s, host, control, row)?;
            }
            TableChange::DeleteColumn => {
                self.core
                    .delete_table_column_native(s, host, control, col)?;
            }
        }
        self.caret_in_cell(target, row, col)
    }
    fn length(&self, t: &EditTarget) -> Result<u32, EditError> {
        Ok(get(self.core.document(), t)?.text.chars().count() as u32)
    }
    /// Joins the paragraph at `t` onto the previous one.
    fn merge(&mut self, t: &EditTarget) -> Result<(), EditError> {
        if let Some(n) = &t.note {
            self.core.merge_paragraph_in_footnote_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
            )?;
        } else if let Some(c) = &t.cell {
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
        if let Some(n) = &t.note {
            self.core.insert_text_in_footnote_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
                p.scalar as usize,
                text,
            )?;
        } else if let Some(c) = &t.cell {
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
        if let Some(n) = &t.note {
            self.core.delete_text_in_footnote_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
                p.scalar as usize,
                count as usize,
            )?;
        } else if let Some(c) = &t.cell {
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
        let at = split_offset(get(self.core.document(), t)?, p.scalar);
        if let Some(n) = &t.note {
            self.core.split_paragraph_in_footnote_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
                at,
                None,
            )?;
        } else if let Some(c) = &t.cell {
            self.core.split_paragraph_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                at,
                None,
            )?;
        } else {
            self.core
                .split_paragraph_native(t.section as usize, t.paragraph as usize, at, None)?;
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
            EditCommand::ApplyStyle { selection, style } => self.apply_style(selection, *style),
            EditCommand::InsertShape { .. } => self.insert_shape(command),
            EditCommand::FormatParagraphs { selection, style } => {
                let (start, end) = ordered(selection);
                let props = self.para_props(style);
                for i in index(&start.target)..=index(&end.target) {
                    self.format_paragraph(&at_index(&start.target, i), &props)?;
                }
                Ok(selection.clone())
            }
            EditCommand::Break { position, column } => {
                let t = &position.target;
                let (s, p, o) = (
                    t.section as usize,
                    t.paragraph as usize,
                    split_offset(get(self.core.document(), t)?, position.scalar),
                );
                if *column {
                    self.core.insert_column_break_native(s, p, o)?;
                } else {
                    self.core.insert_page_break_native(s, p, o)?;
                }
                Ok(EditSelection::caret(EditPosition {
                    target: at_index(t, index(t) + 1),
                    scalar: 0,
                }))
            }
            EditCommand::InsertTable {
                position,
                rows,
                columns,
            } => {
                let t = &position.target;
                let json = self.core.create_table_native(
                    t.section as usize,
                    t.paragraph as usize,
                    position.scalar as usize,
                    *rows,
                    *columns,
                )?;
                let made: Value =
                    serde_json::from_str(&json).map_err(|_| EditError::RenderFailed)?;
                let field = |key: &str| {
                    made.get(key)
                        .and_then(Value::as_u64)
                        .map(|v| v as u32)
                        .ok_or(EditError::RenderFailed)
                };
                Ok(EditSelection::caret(EditPosition {
                    target: EditTarget {
                        section: t.section,
                        paragraph: field("paraIdx")?,
                        cell: Some(CellTarget {
                            control: field("controlIdx")?,
                            cell: 0,
                            paragraph: 0,
                        }),
                        note: None,
                    },
                    scalar: 0,
                }))
            }
            EditCommand::InsertPicture {
                position,
                data,
                width,
                height,
                natural_width,
                natural_height,
                extension,
                description,
            } => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(data)
                    .map_err(|_| EditError::InvalidInput)?;
                let t = &position.target;
                // In a cell rhwp floats the picture beside its table, as Hancom does.
                let path: Vec<(usize, usize, usize)> = t
                    .cell
                    .iter()
                    .map(|c| (c.control as usize, c.cell as usize, c.paragraph as usize))
                    .collect();
                let inserted = self.core.insert_picture_native(
                    t.section as usize,
                    t.paragraph as usize,
                    position.scalar as usize,
                    &path,
                    &bytes,
                    *width,
                    *height,
                    *natural_width,
                    *natural_height,
                    extension,
                    description,
                    None,
                    None,
                )?;
                // rhwp floats a new picture at the paper's corner; Hancom places it in
                // the line, like a character.
                let inserted = serde_json::from_str::<Value>(&inserted)
                    .map_err(|_| EditError::RenderFailed)?;
                if path.is_empty() {
                    let control = inserted["controlIdx"]
                        .as_u64()
                        .ok_or(EditError::RenderFailed)?;
                    self.core.set_picture_properties_native(
                        t.section as usize,
                        t.paragraph as usize,
                        control as usize,
                        r#"{"treatAsChar":true}"#,
                    )?;
                }
                Ok(EditSelection::caret(position.clone()))
            }
            EditCommand::InsertEquation {
                position,
                script,
                font_size,
                color,
            } => {
                let target = &position.target;
                self.core.insert_equation_native(
                    target.section as usize,
                    target.paragraph as usize,
                    position.scalar as usize,
                    script,
                    *font_size,
                    *color,
                )?;
                Ok(EditSelection::caret(position.clone()))
            }
            EditCommand::InsertNote { position, endnote } => {
                let t = &position.target;
                let (s, p, o) = (
                    t.section as usize,
                    t.paragraph as usize,
                    position.scalar as usize,
                );
                let json = if *endnote {
                    self.core.insert_endnote_native(s, p, o)?
                } else {
                    self.core.insert_footnote_native(s, p, o)?
                };
                let made: Value =
                    serde_json::from_str(&json).map_err(|_| EditError::RenderFailed)?;
                let control = made
                    .get("controlIdx")
                    .and_then(Value::as_u64)
                    .ok_or(EditError::RenderFailed)? as u32;
                let target = EditTarget {
                    note: Some(NoteTarget {
                        control,
                        paragraph: 0,
                    }),
                    ..t.clone()
                };
                // After the number and the space that follows it.
                let scalar = self.length(&target)?;
                Ok(EditSelection::caret(EditPosition { target, scalar }))
            }
            EditCommand::EditTable { cell, change } => self.edit_table(cell, *change),
            EditCommand::SetPage { section, page } => {
                let json = serde_json::to_string(page).map_err(|_| EditError::InvalidInput)?;
                self.core.set_page_def_native(*section as usize, &json)?;
                Ok(self.kept(*section))
            }
            EditCommand::HeaderFooter {
                section,
                footer,
                page_number,
            } => {
                self.header_footer(*section, *footer, *page_number)?;
                Ok(self.kept(*section))
            }
            EditCommand::MergeCells { .. }
            | EditCommand::SplitCells { .. }
            | EditCommand::EqualizeCells { .. } => self.edit_cells(command),
            EditCommand::SetObject { object, props } => {
                self.set_object(object, props)?;
                Ok(self.kept(object.section))
            }
            EditCommand::SetCell { cell, props } => {
                self.set_cell(cell, props)?;
                Ok(self.kept(cell.section))
            }
            EditCommand::DeleteObject { object } => {
                self.delete_object(object)?;
                Ok(self.kept(object.section))
            }
            EditCommand::ResizeTable { table, .. } => {
                self.resize_table(command)?;
                Ok(self.kept(table.section))
            }
            EditCommand::Undo | EditCommand::Redo => Err(EditError::UnsupportedTarget),
        }
    }
}
