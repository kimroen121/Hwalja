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
        | EditCommand::FormatParagraphs { selection, .. } => {
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
        EditCommand::EditTable { cell, .. } => return check_table(before, after, cell),
        EditCommand::SetPage { section, .. } => return check_page(before, after, *section),
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
