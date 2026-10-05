use super::*;
use rhwp::model::{control::Control, document::Document, paragraph::Paragraph};

// Only derived line layout is excluded. Table dimensions, merges, controls,
// character styles, source streams and binary payloads remain in the comparison.
fn normalize(paragraphs: &mut [Paragraph]) {
    for p in paragraphs {
        p.line_segs.clear();
        // IR-only axis of the stored line segments, rebuilt with them.
        p.hwpx_axis_shift = 0;
        p.source_line_seg_vertical_pos = None;
        p.single_line_overflow_memo = Default::default();
        p.layout_only_fill_lines = 0;
        for c in &mut p.controls {
            if let Control::Table(t) = c {
                for cell in &mut t.cells {
                    normalize(&mut cell.paragraphs);
                }
            }
        }
    }
}
/// Takes the raw byte payloads out of `doc`. They are compared with `==`: formatting
/// them for the `Debug` comparison would cost more than the edit itself.
fn take_bytes(doc: &mut Document) -> Vec<Option<Vec<u8>>> {
    let mut bytes = vec![doc.doc_info.raw_stream.take()];
    if let Some(image) = doc.preview.as_mut().and_then(|p| p.image.as_mut()) {
        bytes.push(Some(std::mem::take(&mut image.data)));
    }
    bytes.extend(doc.sections.iter_mut().map(|s| s.raw_stream.take()));
    for (_, data) in doc
        .extra_streams
        .iter_mut()
        .chain(&mut doc.hwpx_aux_entries)
    {
        bytes.push(Some(std::mem::take(data)));
    }
    bytes
}
/// Whether two documents are the same, byte payloads included.
fn same(a: &mut Document, b: &mut Document) -> bool {
    take_bytes(a) == take_bytes(b) && format!("{a:?}") == format!("{b:?}")
}
/// Controls and their parallel CTRL_DATA records.
type HeldControls = (Vec<Control>, Vec<Option<Vec<u8>>>);

/// Removes the edited paragraph range and returns the controls (with their CTRL_DATA) it held.
fn remove(
    doc: &mut Document,
    t: &EditTarget,
    start: usize,
    count: usize,
) -> Result<HeldControls, EditError> {
    let ps = edited_paragraphs(doc, t)?;
    if start + count > ps.len() {
        return Err(EditError::PreservationFailed);
    }
    let mut held = (Vec::new(), Vec::new());
    for mut p in ps.drain(start..start + count) {
        p.ctrl_data_records.resize(p.controls.len(), None);
        held.0.append(&mut p.controls);
        held.1.append(&mut p.ctrl_data_records);
    }
    Ok(held)
}
/// The paragraph list (body or cell) that `t` addresses.
fn edited_paragraphs<'a>(
    doc: &'a mut Document,
    t: &EditTarget,
) -> Result<&'a mut Vec<Paragraph>, EditError> {
    let section = doc
        .sections
        .get_mut(t.section as usize)
        .ok_or(EditError::PreservationFailed)?;
    Ok(if let Some(c) = &t.cell {
        let Some(Control::Table(table)) = section
            .paragraphs
            .get_mut(t.paragraph as usize)
            .and_then(|p| p.controls.get_mut(c.control as usize))
        else {
            return Err(EditError::PreservationFailed);
        };
        table.text_reflowed_after_edit = false;
        &mut table
            .cells
            .get_mut(c.cell as usize)
            .ok_or(EditError::PreservationFailed)?
            .paragraphs
    } else if let Some(n) = &t.note {
        match section
            .paragraphs
            .get_mut(t.paragraph as usize)
            .and_then(|p| p.controls.get_mut(n.control as usize))
        {
            Some(Control::Footnote(note)) => &mut note.paragraphs,
            Some(Control::Endnote(note)) => &mut note.paragraphs,
            _ => return Err(EditError::PreservationFailed),
        }
    } else {
        &mut section.paragraphs
    })
}
pub(super) fn check(
    before: &Document,
    after: &Document,
    command: &EditCommand,
) -> Result<(), EditError> {
    let (target, start, old_count, new_count) = match command {
        EditCommand::Replace { selection, text } => {
            let (start, end) = commands::ordered(selection);
            let (s, e) = (commands::index(&start.target), commands::index(&end.target));
            (
                &start.target,
                s,
                e - s + 1,
                1 + text
                    .replace("\r\n", "\n")
                    .replace('\r', "\n")
                    .matches('\n')
                    .count(),
            )
        }
        EditCommand::FormatText { selection, .. }
        | EditCommand::FormatParagraphs { selection, .. }
        | EditCommand::ApplyStyle { selection, .. } => {
            return check_format(before, after, selection)
        }
        EditCommand::Split { position } | EditCommand::Break { position, .. } => {
            (&position.target, commands::index(&position.target), 1, 2)
        }
        EditCommand::InsertTable { position, .. } => {
            let section = position.target.section as usize;
            let grown = after.sections[section].paragraphs.len()
                - before.sections[section].paragraphs.len();
            return check_inserted_table(
                before,
                after,
                &position.target,
                commands::index(&position.target),
                grown,
            );
        }
        EditCommand::InsertPicture { position, .. } => {
            return check_inserted_picture(before, after, &position.target)
        }
        EditCommand::InsertEquation { position, .. } => {
            return check_inserted_equation(before, after, &position.target)
        }
        EditCommand::EditTable { cell, .. } => return check_table(before, after, cell),
        EditCommand::MergeCells { selection }
        | EditCommand::SplitCells { selection, .. }
        | EditCommand::EqualizeCells { selection, .. } => {
            return check_table(before, after, &selection.anchor.target)
        }
        EditCommand::InsertNote { position, .. } => {
            return check_inserted_note(before, after, &position.target)
        }
        EditCommand::SetPage { section, .. } => return check_page(before, after, *section),
        EditCommand::InsertShape { position, .. } => {
            return check_host(
                before,
                after,
                position.target.section,
                position.target.paragraph,
            )
        }
        EditCommand::SetObject { object, .. } | EditCommand::DeleteObject { object } => {
            return check_host(before, after, object.section, object.paragraph)
        }
        EditCommand::SetCell { cell, .. } => {
            return check_host(before, after, cell.section, cell.paragraph)
        }
        EditCommand::HeaderFooter {
            section, footer, ..
        } => return check_header_footer(before, after, *section, *footer),
        EditCommand::MergePrevious { position } => (
            &position.target,
            commands::index(&position.target) - 1,
            2,
            1,
        ),
        _ => return Err(EditError::UnsupportedTarget),
    };
    let mut a = before.clone();
    let mut b = after.clone();
    let old_controls = remove(&mut a, target, start, old_count)?;
    let new_controls = remove(&mut b, target, start, new_count)?;
    if format!("{old_controls:?}") != format!("{new_controls:?}") {
        return Err(EditError::PreservationFailed);
    }
    // Editing deliberately invalidates this section's cached serialized stream.
    // The immutable source bytes and all semantic model fields are still checked.
    a.sections[target.section as usize].raw_stream = None;
    b.sections[target.section as usize].raw_stream = None;
    for doc in [&mut a, &mut b] {
        doc.doc_properties.caret_list_id = 0;
        doc.doc_properties.caret_para_id = 0;
        doc.doc_properties.caret_char_pos = 0;
        if let Some(raw) = &mut doc.doc_info.raw_stream {
            let _ = rhwp::serializer::doc_info::surgical_update_caret(raw, 0, 0, 0);
        }
    }
    for s in &mut a.sections {
        normalize(&mut s.paragraphs);
    }
    for s in &mut b.sections {
        normalize(&mut s.paragraphs);
    }
    if same(&mut a, &mut b) {
        Ok(())
    } else {
        Err(EditError::PreservationFailed)
    }
}

/// A picture insertion may add one picture and its one binary-data record; the rest of
/// the document, including every previous binary payload, must remain unchanged.
fn check_inserted_picture(
    before: &Document,
    after: &Document,
    target: &EditTarget,
) -> Result<(), EditError> {
    if after.bin_data_content.len() != before.bin_data_content.len() + 1
        || after.doc_info.bin_data_list.len() != before.doc_info.bin_data_list.len() + 1
        || format!("{:?}", before.bin_data_content)
            != format!(
                "{:?}",
                &after.bin_data_content[..before.bin_data_content.len()]
            )
        || format!("{:?}", before.doc_info.bin_data_list)
            != format!(
                "{:?}",
                &after.doc_info.bin_data_list[..before.doc_info.bin_data_list.len()]
            )
    {
        return Err(EditError::PreservationFailed);
    }
    let mut a = before.clone();
    let mut b = after.clone();
    let old = remove(&mut a, target, commands::index(target), 1)?;
    let new = remove(&mut b, target, commands::index(target), 1)?;
    let pictures = new
        .0
        .iter()
        .filter(|c| matches!(c, Control::Picture(_)))
        .count();
    let old_pictures = old
        .0
        .iter()
        .filter(|c| matches!(c, Control::Picture(_)))
        .count();
    if pictures != old_pictures + 1 {
        return Err(EditError::PreservationFailed);
    }
    b.bin_data_content.truncate(a.bin_data_content.len());
    b.doc_info
        .bin_data_list
        .truncate(a.doc_info.bin_data_list.len());
    for doc in [&mut a, &mut b] {
        doc.doc_info.raw_stream = None;
    }
    same_rest(&mut a, &mut b, target.section)
}

/// A formula insertion may add exactly one equation control to its host paragraph.
fn check_inserted_equation(
    before: &Document,
    after: &Document,
    target: &EditTarget,
) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    let old = remove(&mut a, target, commands::index(target), 1)?;
    let new = remove(&mut b, target, commands::index(target), 1)?;
    let equations = new
        .0
        .iter()
        .filter(|control| matches!(control, Control::Equation(_)))
        .count();
    let old_equations = old
        .0
        .iter()
        .filter(|control| matches!(control, Control::Equation(_)))
        .count();
    if equations != old_equations + 1 {
        return Err(EditError::PreservationFailed);
    }
    same_rest(&mut a, &mut b, target.section)
}

/// DocInfo may only gain entries (shapes, fonts, border fills) at the end of its lists;
/// trims them off `b` and drops both cached streams.
fn trim_appended(a: &mut Document, b: &mut Document) -> bool {
    fn prefix<T: std::fmt::Debug>(old: &[T], new: &mut Vec<T>) -> bool {
        let same =
            new.len() >= old.len() && format!("{old:?}") == format!("{:?}", &new[..old.len()]);
        new.truncate(old.len());
        same
    }
    let (x, y) = (&mut a.doc_info, &mut b.doc_info);
    let appended = prefix(&x.char_shapes, &mut y.char_shapes)
        && prefix(&x.para_shapes, &mut y.para_shapes)
        && prefix(&x.border_fills, &mut y.border_fills)
        && prefix(&x.numberings, &mut y.numberings)
        && prefix(&x.bullets, &mut y.bullets)
        && x.font_faces.len() <= y.font_faces.len()
        && {
            y.font_faces.truncate(x.font_faces.len());
            x.font_faces
                .iter()
                .zip(y.font_faces.iter_mut())
                .all(|(old, new)| prefix(old, new))
        };
    for info in [x, y] {
        info.raw_stream = None;
        info.raw_stream_dirty = false;
    }
    appended
}
/// Compares what is left after a structural edit took out its own changes: line layout
/// and the edited section's cached stream are ignored.
fn same_rest(a: &mut Document, b: &mut Document, section: u32) -> Result<(), EditError> {
    for doc in [&mut *a, &mut *b] {
        doc.sections[section as usize].raw_stream = None;
        for s in &mut doc.sections {
            normalize(&mut s.paragraphs);
        }
    }
    if same(a, b) {
        Ok(())
    } else {
        Err(EditError::PreservationFailed)
    }
}
/// A new table may only replace the paragraph at `start` with `grown + 1` paragraphs that
/// hold its controls plus one table, and append DocInfo entries.
fn check_inserted_table(
    before: &Document,
    after: &Document,
    target: &EditTarget,
    start: usize,
    grown: usize,
) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    let old = remove(&mut a, target, start, 1)?;
    let (mut controls, mut data) = remove(&mut b, target, start, grown + 1)?;
    let tables: Vec<usize> = (0..controls.len())
        .filter(|&i| matches!(controls[i], Control::Table(_)))
        .collect();
    let [table] = tables[..] else {
        return Err(EditError::PreservationFailed);
    };
    controls.remove(table);
    data.remove(table);
    if format!("{old:?}") != format!("{:?}", (controls, data)) || !trim_appended(&mut a, &mut b) {
        return Err(EditError::PreservationFailed);
    }
    same_rest(&mut a, &mut b, target.section)
}
/// Note numbers, which a new note renumbers in document order.
fn unnumber(paragraphs: &mut [Paragraph]) {
    for p in paragraphs {
        for c in &mut p.controls {
            match c {
                Control::Footnote(n) => n.number = 0,
                Control::Endnote(n) => n.number = 0,
                Control::Table(t) => t.cells.iter_mut().for_each(|c| unnumber(&mut c.paragraphs)),
                _ => {}
            }
        }
    }
}
/// A new note may only add one note control to the paragraph at `target`, leaving its
/// text and other controls, and renumber the notes.
fn check_inserted_note(
    before: &Document,
    after: &Document,
    target: &EditTarget,
) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    let (x, y) = (
        &mut a.sections[target.section as usize].paragraphs[target.paragraph as usize],
        &mut b.sections[target.section as usize].paragraphs[target.paragraph as usize],
    );
    let added: Vec<usize> = (0..y.controls.len())
        .filter(|&i| matches!(y.controls[i], Control::Footnote(_) | Control::Endnote(_)))
        .filter(|&i| {
            let shown = format!("{:?}", y.controls[i]);
            !x.controls.iter().any(|c| format!("{c:?}") == shown)
        })
        .collect();
    let [added] = added[..] else {
        return Err(EditError::PreservationFailed);
    };
    y.ctrl_data_records.resize(y.controls.len(), None);
    x.ctrl_data_records.resize(x.controls.len(), None);
    y.controls.remove(added);
    y.ctrl_data_records.remove(added);
    if x.text != y.text {
        return Err(EditError::PreservationFailed);
    }
    // The control's room in the text stream.
    for p in [&mut *x, &mut *y] {
        p.char_offsets.clear();
        p.char_count = 0;
        p.control_mask = 0;
        p.has_para_text = true;
        p.char_shapes.iter_mut().for_each(|c| c.start_pos = 0);
    }
    for doc in [&mut a, &mut b] {
        unnumber(&mut doc.sections[target.section as usize].paragraphs);
    }
    same_rest(&mut a, &mut b, target.section)
}
/// Row and column edits may only change the table holding `cell`.
fn check_table(before: &Document, after: &Document, cell: &EditTarget) -> Result<(), EditError> {
    let control = cell
        .cell
        .as_ref()
        .ok_or(EditError::PreservationFailed)?
        .control as usize;
    let mut a = before.clone();
    let mut b = after.clone();
    for doc in [&mut a, &mut b] {
        let host = doc.sections[cell.section as usize]
            .paragraphs
            .get_mut(cell.paragraph as usize)
            .ok_or(EditError::PreservationFailed)?;
        if !matches!(host.controls.get(control), Some(Control::Table(_))) {
            return Err(EditError::PreservationFailed);
        }
        host.controls.remove(control);
        if control < host.ctrl_data_records.len() {
            host.ctrl_data_records.remove(control);
        }
    }
    if !trim_appended(&mut a, &mut b) {
        return Err(EditError::PreservationFailed);
    }
    same_rest(&mut a, &mut b, cell.section)
}
/// An object edit may only change the body paragraph holding the object, and append
/// DocInfo entries.
fn check_host(
    before: &Document,
    after: &Document,
    section: u32,
    paragraph: u32,
) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    for doc in [&mut a, &mut b] {
        let paragraphs = &mut doc.sections[section as usize].paragraphs;
        if paragraph as usize >= paragraphs.len() {
            return Err(EditError::PreservationFailed);
        }
        paragraphs.remove(paragraph as usize);
    }
    if !trim_appended(&mut a, &mut b) {
        return Err(EditError::PreservationFailed);
    }
    same_rest(&mut a, &mut b, section)
}
/// Page setup may only change the section's paper and margins.
fn check_page(before: &Document, after: &Document, section: u32) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    let (x, y) = (
        &mut a.sections[section as usize],
        &b.sections[section as usize],
    );
    x.section_def.page_def = y.section_def.page_def.clone();
    // The section's first paragraph carries its own copy of the definition.
    for (p, q) in x.paragraphs.iter_mut().zip(&y.paragraphs) {
        for (c, d) in p.controls.iter_mut().zip(&q.controls) {
            if let (Control::SectionDef(c), Control::SectionDef(d)) = (c, d) {
                c.page_def = d.page_def.clone();
            }
        }
    }
    same_rest(&mut a, &mut b, section)
}
/// A header or footer command may only add or replace that one control and append
/// paragraph shapes.
fn check_header_footer(
    before: &Document,
    after: &Document,
    section: u32,
    footer: bool,
) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    let mut kinds = vec![];
    for doc in [&mut a, &mut b] {
        let found = commands::header_footer_at(doc, section as usize, footer);
        kinds.push(found);
        if let Some((p, c)) = found {
            let p = &mut doc.sections[section as usize].paragraphs[p];
            p.ctrl_data_records.resize(p.controls.len(), None);
            p.controls.remove(c);
            p.ctrl_data_records.remove(c);
            p.char_count -= 8;
        }
    }
    // An existing one is replaced where it was.
    if kinds[1].is_none() || kinds[0].is_some_and(|k| Some(k) != kinds[1]) {
        return Err(EditError::PreservationFailed);
    }
    for doc in [&mut a, &mut b] {
        for p in &mut doc.sections[section as usize].paragraphs {
            p.ctrl_data_records.resize(p.controls.len(), None);
        }
    }
    if !trim_appended(&mut a, &mut b) {
        return Err(EditError::PreservationFailed);
    }
    same_rest(&mut a, &mut b, section)
}

/// Formatting may only restyle the selected paragraphs and append shapes and fonts to
/// DocInfo; existing DocInfo entries and everything else must be unchanged.
fn check_format(
    before: &Document,
    after: &Document,
    selection: &EditSelection,
) -> Result<(), EditError> {
    let (start, end) = commands::ordered(selection);
    let target = &start.target;
    let range = commands::index(target)..=commands::index(&end.target);
    let mut a = before.clone();
    let mut b = after.clone();
    if !trim_appended(&mut a, &mut b) {
        return Err(EditError::PreservationFailed);
    }
    for doc in [&mut a, &mut b] {
        doc.sections[target.section as usize].raw_stream = None;
        let paragraphs = edited_paragraphs(doc, target)?;
        for p in paragraphs
            .get_mut(range.clone())
            .ok_or(EditError::PreservationFailed)?
        {
            p.char_shapes.clear();
            p.para_shape_id = 0;
            p.style_id = 0;
        }
        for s in &mut doc.sections {
            normalize(&mut s.paragraphs);
        }
    }
    if same(&mut a, &mut b) {
        Ok(())
    } else {
        Err(EditError::PreservationFailed)
    }
}
