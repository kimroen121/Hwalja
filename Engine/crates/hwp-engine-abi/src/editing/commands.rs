use super::*;
use base64::Engine;
use rhwp::model::{
    control::{AutoNumber, AutoNumberType, Control},
    document::Document,
    header_footer::HeaderFooterApply,
    paragraph::Paragraph,
    shape::{Caption, ShapeObject, TextBox},
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
    if t.header_footer.is_some() {
        return header_footer::paragraphs(doc, t);
    }
    if let Some(c) = &t.cell {
        let host = section
            .paragraphs
            .get(t.paragraph as usize)
            .ok_or(EditError::InvalidInput)?;
        let table = match host.controls.get(c.control as usize) {
            // Captions are cell 0 of their picture and cell `CAPTION` of their table, as
            // rhwp addresses them.
            Some(Control::Table(table)) if c.cell == CAPTION => {
                return caption(table.caption.as_ref())
            }
            Some(Control::Picture(picture)) if c.cell == 0 => {
                return caption(picture.caption.as_ref())
            }
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
/// The cell number rhwp gives a table's caption.
pub(super) const CAPTION: u32 = 65_534;
fn caption(c: Option<&Caption>) -> Result<&[Paragraph], EditError> {
    c.map(|c| c.paragraphs.as_slice())
        .ok_or(EditError::UnsupportedTarget)
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
pub(super) fn same_container(a: &EditTarget, b: &EditTarget) -> bool {
    a.section == b.section
        && a.header_footer == b.header_footer
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
    if usize::from(t.cell.is_some())
        + usize::from(t.note.is_some())
        + usize::from(t.header_footer.is_some())
        > 1
    {
        return Err(EditError::UnsupportedTarget);
    }
    paragraphs(doc, t)?
        .get(index(t))
        .ok_or(EditError::InvalidInput)
}
/// Paragraphs whose text can change around their controls (tables, pictures, notes…),
/// which stay in place, and inside or around their fields (rhwp moves a field's range
/// with the text). Title marks, range tags and fields across paragraphs index the text
/// and stay read-only.
pub(super) fn editable(p: &Paragraph) -> bool {
    editable_with(p, &[])
}
/// Like `editable`, letting the control characters in `allowed` stand in the text.
pub(super) fn editable_with(p: &Paragraph, allowed: &[char]) -> bool {
    p.title_marks.is_empty()
        && p.range_tags.is_empty()
        && p.orphan_field_ends.is_empty()
        && p.ctrl_data_records.len() <= p.controls.len()
        && !p
            .text
            .chars()
            .any(|c| c.is_control() && c != '\t' && !allowed.contains(&c))
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
/// A picture's image as `InsertPicture` and `ReplacePicture` take it: base64 PNG or JPEG
/// of up to 5 MiB, at most 20,000 pixels a side and 100 million in all.
fn validate_image(data: &str, width: u32, height: u32, extension: &str) -> Result<(), EditError> {
    if data.len() > 7 * 1024 * 1024 {
        return Err(EditError::ResourceLimit);
    }
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|_| EditError::InvalidInput)?;
    if decoded.is_empty()
        || decoded.len() > 5 * 1024 * 1024
        || !matches!(extension, "png" | "jpg" | "jpeg")
        || !(1..=20_000).contains(&width)
        || !(1..=20_000).contains(&height)
        || width as u64 * height as u64 > 100_000_000
    {
        Err(EditError::InvalidInput)
    } else {
        Ok(())
    }
}
/// The table holding `t`'s cell, in the body. rhwp's table functions reach only the
/// body's, so a cell in a note, 머리말 or 꼬리말 has none here.
pub(super) fn table<'a>(doc: &'a Document, t: &EditTarget) -> Option<&'a Table> {
    body_or_cell(t).ok()?;
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
/// Formatting inside notes is not supported yet.
/// Not a note, 머리말 or 꼬리말.
pub(super) fn body_or_cell(t: &EditTarget) -> Result<(), EditError> {
    if t.note.is_some() || t.header_footer.is_some() {
        Err(EditError::UnsupportedTarget)
    } else {
        Ok(())
    }
}
pub(super) fn body_only(t: &EditTarget) -> Result<(), EditError> {
    if t.cell.is_some() {
        return Err(EditError::UnsupportedTarget);
    }
    body_or_cell(t)
}
/// The sections `SetPage` changes.
pub(super) fn page_sections(doc: &Document, section: u32, whole: bool) -> std::ops::Range<usize> {
    if whole {
        0..doc.sections.len()
    } else {
        section as usize..section as usize + 1
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
    if page.binding <= 2
        && sides
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
            text: logical::text(get(self.core.document(), target)?),
        })
    }
    pub(super) fn validate_position(&self, p: &EditPosition) -> Result<(), EditError> {
        let para = get(self.core.document(), &p.target)?;
        let editable = match p.target.header_footer {
            Some(_) => header_footer::editable(para, p.scalar, p.scalar),
            None => editable(para),
        };
        if !editable {
            return Err(EditError::UnsupportedTarget);
        }
        boundary(&logical::text(para), p.scalar)
    }
    /// Both ends valid, in one container, with only editable paragraphs between them.
    pub(super) fn validate_range(&self, selection: &EditSelection) -> Result<(), EditError> {
        self.validate_span(selection, false)
    }
    /// Like `validate_range`; `whole` lets paragraphs that are read-only (fields, title
    /// marks) lie between the ends, as when a replacement removes them entirely.
    pub(super) fn validate_span(
        &self,
        selection: &EditSelection,
        whole: bool,
    ) -> Result<(), EditError> {
        let (start, end) = ordered(selection);
        if !same_container(&start.target, &end.target) {
            return Err(EditError::UnsupportedTarget);
        }
        self.validate_position(start)?;
        self.validate_position(end)?;
        let all = paragraphs(self.core.document(), &start.target)?;
        let (s, e) = (index(&start.target), index(&end.target));
        // In a 머리말 the fields in each paragraph must stay whole.
        let ok = |(i, p): (usize, &Paragraph)| match start.target.header_footer {
            Some(_) => header_footer::editable(
                p,
                if i == s { start.scalar } else { 0 },
                if i == e {
                    end.scalar
                } else {
                    logical::length(p)
                },
            ),
            None => whole || editable(p),
        };
        if !all[s..=e]
            .iter()
            .enumerate()
            .map(|(i, p)| (s + i, p))
            .all(ok)
        {
            return Err(EditError::UnsupportedTarget);
        }
        Ok(())
    }
    pub(super) fn validate_command(&self, command: &EditCommand) -> Result<(), EditError> {
        match command {
            EditCommand::Replace { selection, text } => {
                self.validate_span(selection, true)?;
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
            EditCommand::Paste {
                selection,
                copy,
                html,
            } => self.validate_paste(selection, *copy, html.as_ref()),
            EditCommand::ReplaceAll { selections, text } => {
                let replace = |selection: &EditSelection| EditCommand::Replace {
                    selection: selection.clone(),
                    text: text.clone(),
                };
                if selections.len() <= 100_000
                    && selections
                        .iter()
                        .any(|s| self.validate_command(&replace(s)).is_ok())
                {
                    Ok(())
                } else {
                    Err(EditError::InvalidInput)
                }
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
                    upstream: false,
                })
            }
            EditCommand::FormatText { selection, style } => {
                self.validate_range(selection)?;
                let (start, end) = ordered(selection);
                if start == end {
                    return Err(EditError::InvalidInput);
                }
                super::format::validate_char(style)
            }
            EditCommand::ApplyStyle { selection, style } => self.validate_style(selection, *style),
            EditCommand::AddStyle { .. }
            | EditCommand::EditStyle { .. }
            | EditCommand::DeleteStyle { .. }
            | EditCommand::MoveStyle { .. }
            | EditCommand::RestyleFromCaret { .. } => self.validate_style_command(command),
            EditCommand::InsertShape { .. } => self.validate_shape(command),
            EditCommand::FormatParagraphs { selection, style } => {
                self.validate_range(selection)?;
                // rhwp restarts numbering in body paragraphs only.
                if style.restart.is_some() {
                    body_only(&ordered(selection).0.target)?;
                }
                super::format::validate_para(style)
            }
            EditCommand::InsertNote { position, .. } => {
                body_only(&position.target)?;
                self.validate_position(position)
            }
            EditCommand::SetForm { form, value, text } => {
                self.validate_form(form, *value, text.as_deref())
            }
            EditCommand::SetChartData { chart, data } => self.validate_chart_data(*chart, data),
            EditCommand::EditClickHere {
                position,
                guide,
                memo,
                name,
                ..
            } => {
                self.click_here_at(position)?
                    .ok_or(EditError::UnsupportedTarget)?;
                let fits = |s: &String, n: usize| {
                    s.chars().count() <= n && !s.chars().any(char::is_control)
                };
                if guide.trim().is_empty()
                    || !fits(guide, 1_000)
                    || !fits(memo, 1_000)
                    || !fits(name, 255)
                {
                    return Err(EditError::InvalidInput);
                }
                Ok(())
            }
            EditCommand::InsertClickHere {
                position,
                guide,
                memo,
                name,
                ..
            } => {
                let t = &position.target;
                if t.note.is_some() || t.header_footer.is_some() {
                    return Err(EditError::UnsupportedTarget);
                }
                self.validate_position(position)?;
                let fits = |s: &String, n: usize| {
                    s.chars().count() <= n && !s.chars().any(char::is_control)
                };
                if guide.trim().is_empty()
                    || !fits(guide, 1_000)
                    || !fits(memo, 1_000)
                    || !fits(name, 255)
                {
                    return Err(EditError::InvalidInput);
                }
                Ok(())
            }
            EditCommand::Break { position, .. } => {
                body_only(&position.target)?;
                self.validate_position(position)
            }
            EditCommand::InsertTable {
                position,
                rows,
                columns,
                width,
                height,
                ..
            } => {
                body_only(&position.target)?;
                self.validate_position(position)?;
                let size = |v: &Option<u32>, n: u16| {
                    v.is_none_or(|v| (n as u32 * 200..=1_000_000).contains(&v))
                };
                if size(width, *columns)
                    && size(height, *rows)
                    && (1..=1000).contains(rows)
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
                body_or_cell(&position.target)?;
                self.validate_position(position)?;
                validate_image(data, *natural_width, *natural_height, extension)?;
                if !(1..=1_000_000).contains(width)
                    || !(1..=1_000_000).contains(height)
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
                body_or_cell(&position.target)?;
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
            EditCommand::FlipTable { cell, .. } => {
                let doc = self.core.document();
                paragraphs(doc, cell)?;
                table(doc, cell)
                    .map(|_| ())
                    .ok_or(EditError::UnsupportedTarget)
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
            EditCommand::SetPage { section, page, .. } => {
                self.section_exists(*section)?;
                validate_page(page)
            }
            EditCommand::SetNoteShape {
                section,
                footnote,
                shape,
                ..
            } => {
                self.section_exists(*section)?;
                if super::sections::valid_note(shape, *footnote) {
                    Ok(())
                } else {
                    Err(EditError::InvalidInput)
                }
            }
            EditCommand::SetSection { section, setup, .. } => {
                self.section_exists(*section)?;
                if super::sections::valid_setup(setup) {
                    Ok(())
                } else {
                    Err(EditError::InvalidInput)
                }
            }
            EditCommand::SetPageBorder {
                section, border, ..
            } => {
                self.section_exists(*section)?;
                if super::sections::valid(border) {
                    Ok(())
                } else {
                    Err(EditError::InvalidInput)
                }
            }
            EditCommand::HeaderFooter { section, .. } => self.section_exists(*section),
            EditCommand::NewNumber { position, .. } => {
                codes::body(&position.target)?;
                self.validate_position(position)
            }
            EditCommand::SetPageHide { target, .. } => {
                codes::body(target)?;
                get(self.core.document(), target).map(|_| ())
            }
            EditCommand::AddBookmark { position, name } => {
                codes::body(&position.target)?;
                self.validate_position(position)?;
                if name.trim().is_empty() || self.bookmarks().iter().any(|b| &b.name == name) {
                    return Err(EditError::InvalidInput);
                }
                Ok(())
            }
            EditCommand::ReplaceFont { language, from, to } => {
                self.validate_replace_font(*language, from, to)
            }
            EditCommand::ChangeBookmark {
                target,
                control,
                name,
            } => {
                codes::body(target)?;
                if !matches!(
                    get(self.core.document(), target)?
                        .controls
                        .get(*control as usize),
                    Some(Control::Bookmark(_))
                ) || name.as_ref().is_some_and(|n| n.trim().is_empty())
                {
                    return Err(EditError::InvalidInput);
                }
                Ok(())
            }
            EditCommand::EraseCodes { selection, kinds } => {
                if kinds.is_empty() {
                    return Err(EditError::InvalidInput);
                }
                if let Some(selection) = selection {
                    codes::body(&selection.anchor.target)?;
                    codes::body(&selection.focus.target)?;
                    self.validate_position(&selection.anchor)?;
                    self.validate_position(&selection.focus)?;
                }
                Ok(())
            }
            EditCommand::DeleteHeaderFooter { target } => {
                if target.header_footer.is_none() {
                    return Err(EditError::UnsupportedTarget);
                }
                paragraphs(self.core.document(), target).map(|_| ())
            }
            EditCommand::SetColumns { section, count } => {
                self.section_exists(*section)?;
                // rhwp lays every line of a section out at its first definition's width.
                if (1..=3).contains(count) && self.column_defs(*section).len() == 1 {
                    Ok(())
                } else {
                    Err(EditError::UnsupportedTarget)
                }
            }
            EditCommand::SetObject { object, props } => self.validate_object(object, props),
            EditCommand::MergeCells { .. }
            | EditCommand::SplitCells { .. }
            | EditCommand::EqualizeCells { .. }
            | EditCommand::CalculateBlock { .. } => self.validate_cells(command),
            EditCommand::SetCell { cell, props } => self.validate_cell(cell, props),
            EditCommand::SetCellBorder {
                selection, border, ..
            } => self.validate_cell_border(selection, border),
            EditCommand::DeleteObject { object } => {
                if (object.cell.is_some() && object.kind == ObjectKind::Table)
                    || object.note.is_some()
                {
                    return Err(EditError::UnsupportedTarget);
                }
                self.validate_object(object, &ObjectProps::default())
            }
            EditCommand::MoveObject { object, to } => self.validate_move(object, to),
            EditCommand::Order { object, .. } => self.validate_drawing(object, |_| true),
            EditCommand::MoveLineEnd { .. } => self.line_ends(command).map(|_| ()),
            EditCommand::Ungroup { object } => {
                self.validate_drawing(object, |s| matches!(s, ShapeObject::Group(_)))
            }
            EditCommand::Group { objects } => self.validate_group(objects),
            EditCommand::SetPictureLink { object, path } => {
                self.linked_bin(object)?;
                if path.trim().is_empty() || path.chars().count() > 1_000 {
                    return Err(EditError::InvalidInput);
                }
                Ok(())
            }
            EditCommand::ReplacePicture {
                object,
                data,
                natural_width,
                natural_height,
                extension,
            } => {
                if object.kind != ObjectKind::Picture || object.note.is_some() {
                    return Err(EditError::UnsupportedTarget);
                }
                self.validate_object(object, &ObjectProps::default())?;
                validate_image(data, *natural_width, *natural_height, extension)
            }
            EditCommand::SetTextBox { object, attach } => self.validate_drawing(object, |s| {
                s.drawing().is_some_and(|d| d.text_box.is_some() != *attach)
            }),
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
    /// The 단 정의 of a section, in order.
    pub(super) fn column_defs(&self, section: u32) -> Vec<&rhwp::model::page::ColumnDef> {
        self.core.document().sections[section as usize]
            .paragraphs
            .iter()
            .flat_map(|p| &p.controls)
            .filter_map(|c| match c {
                Control::ColumnDef(d) => Some(d),
                _ => None,
            })
            .collect()
    }
    /// The selection, unchanged by an edit that only touched the section's page layout.
    /// The selection, or the start of the section when it no longer exists.
    fn kept(&self, section: u32) -> EditSelection {
        let doc = self.core.document();
        let exists = |s: &EditSelection| {
            get(doc, &s.anchor.target).is_ok() && get(doc, &s.focus.target).is_ok()
        };
        self.selection.clone().filter(exists).unwrap_or_else(|| {
            EditSelection::caret(EditPosition {
                target: EditTarget {
                    section,
                    paragraph: 0,
                    cell: None,
                    note: None,
                    header_footer: None,
                },
                scalar: 0,
                upstream: false,
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
            TableChange::Split => {
                self.core.split_table_native(s, host, control, row)?;
                // The caret's row heads the new table, two paragraphs on.
                let back = EditTarget {
                    paragraph: target.paragraph + 2,
                    cell: Some(CellTarget {
                        control: 0,
                        ..c.clone()
                    }),
                    ..target.clone()
                };
                return self.caret_in_cell(&back, 0, col);
            }
            TableChange::Attach => {
                self.core.merge_table_with_next_native(s, host, control)?;
            }
        }
        self.caret_in_cell(target, row, col)
    }
    /// 표 뒤집기, the caret staying in its cell.
    fn flip_table(
        &mut self,
        target: &EditTarget,
        turn: TableTurn,
        margins: bool,
    ) -> Result<EditSelection, EditError> {
        let c = target.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let t = table(self.core.document(), target).ok_or(EditError::InvalidInput)?;
        let cell = t
            .cells
            .get(c.cell as usize)
            .ok_or(EditError::InvalidInput)?;
        let (row, col) = turn.place(
            (cell.row, cell.col),
            (cell.row_span, cell.col_span),
            (t.row_count, t.col_count),
        );
        // rhwp numbers them in the order they are declared.
        self.core.flip_table_native(
            target.section as usize,
            target.paragraph as usize,
            c.control as usize,
            turn as u8,
            margins,
        )?;
        self.caret_in_cell(target, row, col)
    }
    fn length(&self, t: &EditTarget) -> Result<u32, EditError> {
        Ok(logical::length(get(self.core.document(), t)?))
    }
    /// Where `p` falls in rhwp's text.
    fn spot(&self, p: &EditPosition) -> Result<logical::Spot, EditError> {
        Ok(logical::spot(
            get(self.core.document(), &p.target)?,
            p.scalar,
        ))
    }
    pub(super) fn control_index_of(reply: &str) -> Result<usize, EditError> {
        serde_json::from_str::<Value>(reply)
            .ok()
            .and_then(|v| v["controlIdx"].as_u64())
            .map(|v| v as usize)
            .ok_or(EditError::RenderFailed)
    }
    /// Puts a new object in the line at `p` and returns the position after it. `insert`
    /// makes it in a body paragraph (section, paragraph, character offset) and returns its
    /// control index: `p` itself in the body; for a cell, 글상자 or caption, the end of the
    /// body paragraph holding it, from where it moves in. That paragraph is left as it was.
    fn place_object(
        &mut self,
        p: &EditPosition,
        insert: impl FnOnce(&mut DocumentCore, usize, usize, usize) -> Result<usize, EditError>,
    ) -> Result<EditPosition, EditError> {
        let host = EditTarget {
            cell: None,
            ..p.target.clone()
        };
        let para = get(self.core.document(), &host)?;
        let at = match p.target.cell {
            None => self.spot(p)?.text,
            Some(_) => para.text.chars().count(),
        };
        // What rhwp's insertion leaves behind in the holding paragraph.
        let kept = (
            para.control_mask,
            para.ctrl_data_records.clone(),
            para.raw_header_extra.clone(),
        );
        let control = insert(
            &mut self.core,
            host.section as usize,
            host.paragraph as usize,
            at,
        )?;
        let placed = logical::object_position(get(self.core.document(), &host)?, control);
        if host == p.target && placed == Some(p.scalar) {
            return Ok(EditPosition {
                target: p.target.clone(),
                scalar: p.scalar + 1,
                upstream: false,
            });
        }
        let after = self.transplant(&host, control, p)?;
        if host != p.target {
            let para = &mut self.core.document_mut().sections[host.section as usize].paragraphs
                [host.paragraph as usize];
            (
                para.control_mask,
                para.ctrl_data_records,
                para.raw_header_extra,
            ) = kept;
        }
        Ok(after)
    }
    /// Joins the paragraph at `t` onto the previous one.
    fn merge(&mut self, t: &EditTarget) -> Result<(), EditError> {
        if let Some(hf) = &t.header_footer {
            self.core.merge_paragraph_in_header_footer_native(
                t.section as usize,
                !hf.footer,
                hf.apply_to,
                t.paragraph as usize,
            )?;
        } else if let Some(n) = &t.note {
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
    pub(super) fn delete_range(
        &mut self,
        start: &EditPosition,
        end: &EditPosition,
    ) -> Result<(), EditError> {
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
        // The last paragraph counts as whole when the range reaches the end of its text; an
        // empty one ends where it starts, before its objects.
        let last = self.length(&at_index(&start.target, e))?;
        let whole_last = last > 0 && end.scalar >= last;
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
                        upstream: false,
                    },
                    count,
                )?;
            }
            // Each pass takes the paragraph after the start, the last one on the last pass.
            // A whole paragraph's objects go with it, those not in its lines too (a table or
            // picture laid out on its own); they have no place in the text to delete.
            if next.header_footer.is_none()
                && next.note.is_none()
                && (remaining > s + 1 || whole_last)
            {
                let objects: Vec<usize> = get(self.core.document(), &next)?
                    .controls
                    .iter()
                    .enumerate()
                    .filter(|(_, c)| {
                        matches!(
                            c,
                            Control::Table(_)
                                | Control::Picture(_)
                                | Control::Shape(_)
                                | Control::Equation(_)
                        )
                    })
                    .map(|(i, _)| i)
                    .collect();
                for control in objects.into_iter().rev() {
                    self.delete_control(&next, control)?;
                }
            }
            self.merge(&next)?;
        }
        Ok(())
    }
    fn insert(&mut self, p: &EditPosition, text: &str) -> Result<(), EditError> {
        let t = &p.target;
        let spot = self.spot(p)?;
        let at = spot.text;
        let skip = spot.skip(get(self.core.document(), t)?);
        self.core.set_insert_skip(skip);
        if let Some(n) = &t.note {
            self.core.insert_text_in_footnote_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
                at,
                text,
            )?;
        } else if let Some(c) = &t.cell {
            self.core.insert_text_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                at,
                text,
            )?;
        } else {
            self.core
                .insert_text_native(t.section as usize, t.paragraph as usize, at, text)?;
        }
        Ok(())
    }
    /// Deletes `count` positions from `p`: the objects among them, then the characters.
    fn delete(&mut self, p: &EditPosition, count: u32) -> Result<(), EditError> {
        let t = &p.target;
        let objects = logical::objects(get(self.core.document(), t)?, p.scalar, p.scalar + count);
        for &control in objects.iter().rev() {
            self.delete_control(t, control)?;
        }
        let count = (count as usize - objects.len()) as u32;
        if count == 0 {
            return Ok(());
        }
        let at = self.spot(p)?.text;
        if let Some(n) = &t.note {
            self.core.delete_text_in_footnote_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
                at,
                count as usize,
            )?;
        } else if let Some(c) = &t.cell {
            self.core.delete_text_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                at,
                count as usize,
            )?;
        } else {
            self.core.delete_text_native(
                t.section as usize,
                t.paragraph as usize,
                at,
                count as usize,
            )?;
        }
        Ok(())
    }
    fn split(&mut self, p: &EditPosition) -> Result<EditPosition, EditError> {
        let t = &p.target;
        let at = self.spot(p)?.split(get(self.core.document(), t)?);
        if let Some(hf) = &t.header_footer {
            self.core.split_paragraph_in_header_footer_native(
                t.section as usize,
                !hf.footer,
                hf.apply_to,
                t.paragraph as usize,
                at,
                None,
            )?;
        } else if let Some(n) = &t.note {
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
            upstream: false,
        })
    }
    /// Runs a validated command and returns the selection that follows it.
    pub(super) fn execute(&mut self, command: &EditCommand) -> Result<EditSelection, EditError> {
        match command {
            EditCommand::Paste {
                selection, html, ..
            } => self.paste(selection, html.as_deref()),
            EditCommand::ReplaceAll { selections, text } => {
                // Last first, so the matches before keep their places.
                let mut caret = None;
                for selection in selections.iter().rev() {
                    let replace = EditCommand::Replace {
                        selection: selection.clone(),
                        text: text.clone(),
                    };
                    if self.validate_command(&replace).is_err() {
                        continue;
                    }
                    #[cfg(test)]
                    let before = self.core.document().clone();
                    caret = Some(self.execute(&replace)?);
                    #[cfg(test)]
                    super::preservation::check(&before, self.core.document(), &replace)?;
                }
                caret.ok_or(EditError::InvalidInput)
            }
            EditCommand::Replace { selection, text } => {
                let (start, end) = ordered(selection);
                let normalized = text
                    .replace("\r\n", "\n")
                    .replace('\r', "\n")
                    .replace(logical::OBJECT, "");
                if let Some(hf) = &start.target.header_footer {
                    let start_at = self.spot(start)?.text;
                    let end_at = self.spot(end)?.text;
                    let json = self.core.replace_range_in_header_footer_native(
                        start.target.section as usize,
                        !hf.footer,
                        hf.apply_to,
                        index(&start.target),
                        start_at,
                        index(&end.target),
                        end_at,
                        &normalized,
                    )?;
                    let result: Value =
                        serde_json::from_str(&json).map_err(|_| EditError::RenderFailed)?;
                    let field = |key| result.get(key).and_then(Value::as_u64).map(|v| v as u32);
                    let paragraph = field("hfParaIndex").ok_or(EditError::RenderFailed)?;
                    let scalar = field("charOffset").ok_or(EditError::RenderFailed)?;
                    return Ok(EditSelection::caret(EditPosition {
                        target: at_index(&start.target, paragraph as usize),
                        scalar,
                        upstream: false,
                    }));
                }
                self.delete_range(start, end)?;
                let mut p = start.clone();
                // Objects come only from the document.
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
                    upstream: false,
                }))
            }
            EditCommand::FormatText { selection, style } => {
                let (start, end) = ordered(selection);
                let (props, languages) = self.char_props(style);
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
                        self.format_text(&target, from, to, &props, &languages)?;
                    }
                }
                Ok(selection.clone())
            }
            EditCommand::ApplyStyle { selection, style } => self.apply_style(selection, *style),
            EditCommand::AddStyle { .. }
            | EditCommand::EditStyle { .. }
            | EditCommand::DeleteStyle { .. }
            | EditCommand::MoveStyle { .. }
            | EditCommand::RestyleFromCaret { .. } => {
                self.run_style_command(command)?;
                Ok(self.kept(0))
            }
            EditCommand::InsertShape { .. } => self.insert_shape(command),
            EditCommand::FormatParagraphs { selection, style } => {
                let (start, end) = ordered(selection);
                let props = self.para_props(style);
                for i in index(&start.target)..=index(&end.target) {
                    self.format_paragraph(&at_index(&start.target, i), &props)?;
                }
                if let Some(mode) = style.restart {
                    let t = &start.target;
                    self.core.set_numbering_restart_native(
                        t.section as usize,
                        t.paragraph as usize,
                        mode,
                        style.start_number.unwrap_or(1),
                    )?;
                }
                Ok(selection.clone())
            }
            EditCommand::Break { position, column } => {
                let t = &position.target;
                let (s, p, o) = (
                    t.section as usize,
                    t.paragraph as usize,
                    self.spot(position)?.split(get(self.core.document(), t)?),
                );
                if *column {
                    self.core.insert_column_break_native(s, p, o)?;
                } else {
                    self.core.insert_page_break_native(s, p, o)?;
                }
                Ok(EditSelection::caret(EditPosition {
                    target: at_index(t, index(t) + 1),
                    scalar: 0,
                    upstream: false,
                }))
            }
            EditCommand::InsertTable {
                position,
                rows,
                columns,
                width,
                height,
                treat_as_char,
            } => {
                let t = &position.target;
                // rhwp splits the paragraph there, counting objects as it moves them.
                let at = self.spot(position)?.split(get(self.core.document(), t)?);
                let json = self.core.create_table_native(
                    t.section as usize,
                    t.paragraph as usize,
                    at,
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
                let (s, p, c) = (t.section, field("paraIdx")?, field("controlIdx")?);
                if width.is_some() || height.is_some() {
                    let cells: Vec<(u16, u16)> = self.core.document().sections[s as usize]
                        .paragraphs[p as usize]
                        .controls
                        .get(c as usize)
                        .and_then(|control| match control {
                            Control::Table(table) => Some(
                                table
                                    .cells
                                    .iter()
                                    .map(|cell| (cell.col_span.max(1), cell.row_span.max(1)))
                                    .collect(),
                            ),
                            _ => None,
                        })
                        .ok_or(EditError::RenderFailed)?;
                    // ponytail: one reflow per cell; a single table resize if large tables lag.
                    for (index, (across, down)) in cells.into_iter().enumerate() {
                        let mut props = serde_json::Map::new();
                        if let Some(w) = width {
                            props.insert(
                                "width".into(),
                                (w / *columns as u32 * across as u32).into(),
                            );
                        }
                        if let Some(h) = height {
                            props.insert("height".into(), (h / *rows as u32 * down as u32).into());
                        }
                        self.core.set_cell_properties_native(
                            s as usize,
                            p as usize,
                            c as usize,
                            index,
                            &Value::Object(props).to_string(),
                        )?;
                    }
                }
                if *treat_as_char {
                    let table = ObjectRef {
                        kind: ObjectKind::Table,
                        section: s,
                        paragraph: p,
                        control: c,
                        cell: None,
                        note: None,
                    };
                    let props = ObjectProps {
                        treat_as_char: Some(true),
                        ..Default::default()
                    };
                    self.set_object(&table, &props)?;
                }
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
                        header_footer: None,
                    },
                    scalar: 0,
                    upstream: false,
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
                let after = self.place_object(position, |core, s, p, at| {
                    let control = Self::control_index_of(&core.insert_picture_native(
                        s,
                        p,
                        at,
                        &[],
                        &bytes,
                        *width,
                        *height,
                        *natural_width,
                        *natural_height,
                        extension,
                        description,
                        None,
                        None,
                    )?)?;
                    // rhwp floats a new picture at the paper's corner; Hancom places it
                    // in the line, like a character.
                    core.set_picture_properties_native(s, p, control, r#"{"treatAsChar":true}"#)?;
                    Ok(control)
                })?;
                Ok(EditSelection::caret(after))
            }
            EditCommand::InsertEquation {
                position,
                script,
                font_size,
                color,
            } => {
                let after = self.place_object(position, |core, s, p, at| {
                    Self::control_index_of(
                        &core.insert_equation_native(s, p, at, script, *font_size, *color)?,
                    )
                })?;
                Ok(EditSelection::caret(after))
            }
            EditCommand::InsertClickHere {
                position,
                guide,
                memo,
                name,
                form_editable,
            } => {
                let t = &position.target;
                let at = self.spot(position)?.text;
                let (s, p) = (t.section as usize, t.paragraph as usize);
                match &t.cell {
                    Some(c) => self.core.insert_click_here_field_at_in_cell(
                        s,
                        p,
                        c.control as usize,
                        c.cell as usize,
                        c.paragraph as usize,
                        at,
                        false,
                        guide,
                        memo,
                        name,
                        *form_editable,
                    )?,
                    None => self.core.insert_click_here_field_at(
                        s,
                        p,
                        at,
                        guide,
                        memo,
                        name,
                        *form_editable,
                    )?,
                };
                Ok(EditSelection::caret(position.clone()))
            }
            EditCommand::SetForm { form, value, text } => {
                self.set_form(form, *value, text.as_deref())?;
                Ok(self.kept(form.section))
            }
            EditCommand::SetChartData { chart, data } => {
                self.set_chart_data(*chart, data)?;
                Ok(self.kept(0))
            }
            EditCommand::EditClickHere {
                position,
                guide,
                memo,
                name,
                form_editable,
            } => {
                let (id, _) = self
                    .click_here_at(position)?
                    .ok_or(EditError::UnsupportedTarget)?;
                if !self
                    .core
                    .update_click_here_native(id, guide, memo, name, *form_editable)
                {
                    return Err(EditError::UnsupportedTarget);
                }
                Ok(EditSelection::caret(position.clone()))
            }
            EditCommand::InsertNote { position, endnote } => {
                let t = &position.target;
                let (s, p, o) = (
                    t.section as usize,
                    t.paragraph as usize,
                    self.spot(position)?.text,
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
                    header_footer: None,
                    ..t.clone()
                };
                // After the number and the space that follows it.
                let scalar = self.length(&target)?;
                Ok(EditSelection::caret(EditPosition {
                    target,
                    scalar,
                    upstream: false,
                }))
            }
            EditCommand::EditTable { cell, change } => self.edit_table(cell, *change),
            EditCommand::FlipTable {
                cell,
                turn,
                margins,
            } => self.flip_table(cell, *turn, *margins),
            EditCommand::SetPage {
                section,
                page,
                whole,
            } => {
                let json = serde_json::to_string(page).map_err(|_| EditError::InvalidInput)?;
                for s in page_sections(self.core.document(), *section, *whole) {
                    self.core.set_page_def_native(s, &json)?;
                }
                Ok(self.kept(*section))
            }
            EditCommand::SetNoteShape {
                section,
                footnote,
                shape,
                whole,
            } => {
                self.set_note_shape(*section, *footnote, shape, *whole)?;
                Ok(self.kept(*section))
            }
            EditCommand::SetSection {
                section,
                setup,
                whole,
            } => {
                self.set_section(*section, setup, *whole)?;
                Ok(self.kept(*section))
            }
            EditCommand::SetPageBorder {
                section,
                border,
                whole,
            } => {
                self.set_page_border(*section, border, *whole)?;
                Ok(self.kept(*section))
            }
            EditCommand::DeleteHeaderFooter { target } => {
                let hf = target
                    .header_footer
                    .as_ref()
                    .ok_or(EditError::UnsupportedTarget)?;
                let s = target.section as usize;
                let (p, c) = header_footer::place(self.core.document(), target)?;
                self.core
                    .delete_header_footer_native(s, !hf.footer, hf.apply_to)?;
                // rhwp leaves the control's data record behind, where the next control
                // would take it.
                let records =
                    &mut self.core.document_mut().sections[s].paragraphs[p].ctrl_data_records;
                if c < records.len() {
                    records.remove(c);
                }
                Ok(self.kept(target.section))
            }
            EditCommand::NewNumber {
                position,
                numbering,
                number,
            } => {
                self.new_number(position, *numbering, *number)?;
                Ok(self.kept(position.target.section))
            }
            EditCommand::SetPageHide { target, hide } => {
                self.set_page_hide(target, hide)?;
                Ok(self.kept(target.section))
            }
            EditCommand::AddBookmark { position, name } => {
                self.add_bookmark(position, name)?;
                Ok(self.kept(position.target.section))
            }
            EditCommand::ChangeBookmark {
                target,
                control,
                name,
            } => {
                self.change_bookmark(target, *control, name.as_deref())?;
                Ok(self.kept(target.section))
            }
            EditCommand::EraseCodes { selection, kinds } => {
                self.erase_codes(selection.as_ref(), kinds)?;
                Ok(self.kept(0))
            }
            EditCommand::ReplaceFont { language, from, to } => {
                if !self
                    .core
                    .replace_font_native(language.map(usize::from), from, to)
                {
                    return Err(EditError::InvalidInput);
                }
                Ok(self.kept(0))
            }
            EditCommand::SetColumns { section, count } => {
                let current = self.column_defs(*section)[0];
                let (kind, spacing) = (current.column_type as u8, current.spacing);
                self.core
                    .set_column_def_native(*section as usize, *count, kind, true, spacing)?;
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
            | EditCommand::EqualizeCells { .. }
            | EditCommand::CalculateBlock { .. } => self.edit_cells(command),
            EditCommand::SetObject { object, props } => {
                self.set_object(object, props)?;
                Ok(self.kept(object.section))
            }
            EditCommand::SetCell { cell, props } => {
                self.set_cell(cell, props)?;
                Ok(self.kept(cell.section))
            }
            EditCommand::SetCellBorder {
                selection,
                all,
                one,
                border,
            } => {
                self.set_cell_border(selection, *all, *one, border)?;
                Ok(selection.clone())
            }
            EditCommand::MoveObject { object, to } => {
                Ok(EditSelection::caret(self.move_object(object, to)?))
            }
            EditCommand::DeleteObject { object } => {
                self.delete_object(object)?;
                Ok(self.kept(object.section))
            }
            EditCommand::MoveLineEnd { object, .. } => {
                let [x1, y1, x2, y2] = self.line_ends(command)?;
                self.core.move_line_endpoint_native(
                    object.section as usize,
                    object.paragraph as usize,
                    object.control as usize,
                    x1,
                    y1,
                    x2,
                    y2,
                )?;
                Ok(self.kept(object.section))
            }
            EditCommand::Ungroup { object } => {
                self.core.ungroup_shape_native(
                    object.section as usize,
                    object.paragraph as usize,
                    object.control as usize,
                )?;
                Ok(self.kept(object.section))
            }
            EditCommand::ReplacePicture {
                object,
                data,
                natural_width,
                natural_height,
                extension,
            } => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(data)
                    .map_err(|_| EditError::InvalidInput)?;
                self.core.assign_picture_image_native(
                    object.section as usize,
                    object.paragraph as usize,
                    &objects::path(&Self::host(object)),
                    object.control as usize,
                    &bytes,
                    *natural_width,
                    *natural_height,
                    extension,
                )?;
                Ok(self.kept(object.section))
            }
            EditCommand::SetPictureLink { object, path } => {
                let index = self.linked_bin(object)?;
                let info = &mut self.core.document_mut().doc_info;
                let bin = &mut info.bin_data_list[index];
                (bin.abs_path, bin.rel_path, bin.raw_data) =
                    (Some(path.clone()), Some(path.clone()), None);
                info.raw_stream_dirty = true;
                Ok(self.kept(object.section))
            }
            EditCommand::Group { objects } => {
                let section = objects[0].section;
                let targets: Vec<(usize, usize)> = objects
                    .iter()
                    .map(|o| (o.paragraph as usize, o.control as usize))
                    .collect();
                self.core.group_shapes_native(section as usize, &targets)?;
                Ok(self.kept(section))
            }
            EditCommand::SetTextBox { object, attach } => {
                let doc = self.core.document();
                // rhwp counts the body's paragraphs across sections.
                let before: usize = doc.sections[..object.section as usize]
                    .iter()
                    .map(|s| s.paragraphs.len())
                    .sum();
                self.core.set_text_box_at(
                    before + object.paragraph as usize,
                    object.control as usize,
                    *attach,
                )?;
                if !attach {
                    return Ok(self.kept(object.section));
                }
                Ok(EditSelection::caret(EditPosition {
                    target: EditTarget {
                        section: object.section,
                        paragraph: object.paragraph,
                        cell: Some(CellTarget {
                            control: object.control,
                            cell: 0,
                            paragraph: 0,
                        }),
                        note: None,
                        header_footer: None,
                    },
                    scalar: 0,
                    upstream: false,
                }))
            }
            EditCommand::Order { object, order } => {
                let operation = match order {
                    Order::Front => "front",
                    Order::Forward => "forward",
                    Order::Back => "back",
                    Order::Backward => "backward",
                };
                self.core.change_shape_z_order_native(
                    object.section as usize,
                    object.paragraph as usize,
                    object.control as usize,
                    operation,
                )?;
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
