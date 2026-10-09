use super::*;
use rhwp::model::{
    control::Control,
    document::{Document, SectionDef},
    paragraph::Paragraph,
};

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
fn text_box_mut(
    shape: &mut rhwp::model::shape::ShapeObject,
) -> Option<&mut rhwp::model::shape::TextBox> {
    use rhwp::model::shape::ShapeObject;
    match shape {
        ShapeObject::Rectangle(s) => s.drawing.text_box.as_mut(),
        ShapeObject::Ellipse(s) => s.drawing.text_box.as_mut(),
        ShapeObject::Polygon(s) => s.drawing.text_box.as_mut(),
        ShapeObject::Curve(s) => s.drawing.text_box.as_mut(),
        _ => None,
    }
}
/// The paragraph list (body, cell or 글상자) that `t` addresses.
fn edited_paragraphs<'a>(
    doc: &'a mut Document,
    t: &EditTarget,
) -> Result<&'a mut Vec<Paragraph>, EditError> {
    let place = t
        .header_footer
        .is_some()
        .then(|| super::header_footer::place(doc, t))
        .transpose()
        .map_err(|_| EditError::PreservationFailed)?;
    let section = doc
        .sections
        .get_mut(t.section as usize)
        .ok_or(EditError::PreservationFailed)?;
    Ok(if let Some((p, c)) = place {
        match &mut section.paragraphs[p].controls[c] {
            Control::Header(h) => &mut h.paragraphs,
            Control::Footer(f) => &mut f.paragraphs,
            _ => return Err(EditError::PreservationFailed),
        }
    } else if let Some(c) = &t.cell {
        match section
            .paragraphs
            .get_mut(t.paragraph as usize)
            .and_then(|p| p.controls.get_mut(c.control as usize))
        {
            Some(Control::Picture(picture)) => {
                &mut picture
                    .caption
                    .as_mut()
                    .ok_or(EditError::PreservationFailed)?
                    .paragraphs
            }
            Some(Control::Table(table)) => {
                table.text_reflowed_after_edit = false;
                if c.cell == commands::CAPTION {
                    &mut table
                        .caption
                        .as_mut()
                        .ok_or(EditError::PreservationFailed)?
                        .paragraphs
                } else {
                    &mut table
                        .cells
                        .get_mut(c.cell as usize)
                        .ok_or(EditError::PreservationFailed)?
                        .paragraphs
                }
            }
            Some(Control::Shape(shape)) => {
                &mut text_box_mut(shape)
                    .ok_or(EditError::PreservationFailed)?
                    .paragraphs
            }
            _ => return Err(EditError::PreservationFailed),
        }
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
        EditCommand::Paste { selection, .. } => return check_pasted(before, after, selection),
        // Each replacement is checked as it is made.
        EditCommand::ReplaceAll { .. } => return Ok(()),
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
        EditCommand::SetChartData { .. } => {
            // Only the chart's stored copies change.
            let mut b = after.clone();
            b.bin_data_content = before.bin_data_content.clone();
            for (x, y) in b.sections.iter_mut().zip(&before.sections) {
                x.raw_stream = y.raw_stream.clone();
            }
            let mut a = before.clone();
            return if same(&mut a, &mut b) {
                Ok(())
            } else {
                Err(EditError::PreservationFailed)
            };
        }
        EditCommand::SetForm { .. } => {
            // Only forms' values and text change.
            let (mut a, mut b) = (before.clone(), after.clone());
            for doc in [&mut a, &mut b] {
                for s in &mut doc.sections {
                    s.raw_stream = None;
                    super::forms::without_values(&mut s.paragraphs);
                    normalize(&mut s.paragraphs);
                }
            }
            return if same(&mut a, &mut b) {
                Ok(())
            } else {
                Err(EditError::PreservationFailed)
            };
        }
        EditCommand::SetPictureLink { .. } => {
            // Only one 연결 entry's path changes.
            let mut b = after.clone();
            let changed: Vec<_> = (0..b.doc_info.bin_data_list.len())
                .filter(|&i| {
                    before.doc_info.bin_data_list.get(i).map(|x| &x.abs_path)
                        != Some(&b.doc_info.bin_data_list[i].abs_path)
                })
                .collect();
            if changed.len() != 1
                || before.doc_info.bin_data_list.len() != b.doc_info.bin_data_list.len()
            {
                return Err(EditError::PreservationFailed);
            }
            b.doc_info.bin_data_list[changed[0]] =
                before.doc_info.bin_data_list[changed[0]].clone();
            b.doc_info.raw_stream_dirty = before.doc_info.raw_stream_dirty;
            let mut a = before.clone();
            return if same(&mut a, &mut b) {
                Ok(())
            } else {
                Err(EditError::PreservationFailed)
            };
        }
        EditCommand::ReplacePicture { object, .. } => {
            // One image is added; the old one stays, as other pictures may share it.
            if !one_image_added(before, after) {
                return Err(EditError::PreservationFailed);
            }
            let mut b = after.clone();
            b.bin_data_content.truncate(before.bin_data_content.len());
            b.doc_info
                .bin_data_list
                .truncate(before.doc_info.bin_data_list.len());
            return check_host(before, &b, object.section, object.paragraph);
        }
        EditCommand::InsertEquation { position, .. } => {
            return check_inserted_equation(before, after, &position.target)
        }
        EditCommand::EditTable { cell, change } => {
            return check_table(before, after, cell, Some(*change))
        }
        EditCommand::FlipTable { cell, .. } => return check_table(before, after, cell, None),
        EditCommand::MergeCells { selection }
        | EditCommand::SplitCells { selection, .. }
        | EditCommand::EqualizeCells { selection, .. }
        | EditCommand::CalculateBlock { selection, .. } => {
            return check_table(before, after, &selection.anchor.target, None)
        }
        EditCommand::InsertNote { position, .. } => {
            return check_inserted_note(before, after, &position.target)
        }
        EditCommand::InsertClickHere { position, .. }
        | EditCommand::EditClickHere { position, .. } => {
            return check_host(
                before,
                after,
                position.target.section,
                position.target.paragraph,
            )
        }
        EditCommand::SetPage { section, whole, .. } => {
            return check_page(before, after, *section, *whole)
        }
        EditCommand::SetPageBorder { section, whole, .. } => {
            return check_page_border(before, after, *section, *whole)
        }
        EditCommand::SetSection { section, whole, .. } => {
            return check_section(before, after, *section, *whole)
        }
        EditCommand::SetNoteShape { section, whole, .. } => {
            return check_note_shape(before, after, *section, *whole)
        }
        EditCommand::AddStyle { .. }
        | EditCommand::EditStyle { .. }
        | EditCommand::DeleteStyle { .. }
        | EditCommand::MoveStyle { .. }
        | EditCommand::RestyleFromCaret { .. } => return check_styles(before, after),
        EditCommand::ReplaceFont { .. } => return check_fonts(before, after),
        EditCommand::SetColumns { section, .. } => return check_columns(before, after, *section),
        EditCommand::NewNumber {
            position: EditPosition { target, .. },
            ..
        }
        | EditCommand::AddBookmark {
            position: EditPosition { target, .. },
            ..
        }
        | EditCommand::SetPageHide { target, .. }
        | EditCommand::ChangeBookmark { target, .. } => {
            return check_host(before, after, target.section, target.paragraph)
        }
        EditCommand::EraseCodes { selection, kinds } => {
            return check_erased(before, after, selection.as_ref(), kinds)
        }
        EditCommand::DeleteHeaderFooter { target } => {
            return check_deleted_header_footer(before, after, target)
        }
        EditCommand::InsertShape { position, .. } => {
            return check_host(
                before,
                after,
                position.target.section,
                position.target.paragraph,
            )
        }
        EditCommand::MoveObject { object, to } => {
            return check_hosts(
                before,
                after,
                object.section,
                vec![object.paragraph, to.target.paragraph],
            )
        }
        EditCommand::Group { objects } => {
            let section = objects
                .first()
                .ok_or(EditError::PreservationFailed)?
                .section;
            return check_hosts(
                before,
                after,
                section,
                objects.iter().map(|o| o.paragraph).collect(),
            );
        }
        EditCommand::SetObject { object, .. }
        | EditCommand::DeleteObject { object }
        | EditCommand::Ungroup { object }
        | EditCommand::MoveLineEnd { object, .. }
        | EditCommand::SetTextBox { object, .. }
        | EditCommand::ResizeTable { table: object, .. } => {
            // A table's new 그림 배경 adds its image.
            let after = &with_images_of(before, after);
            return check_host(before, after, object.section, object.paragraph);
        }
        EditCommand::SetCell { cell, .. }
        | EditCommand::SetCellBorder {
            selection:
                EditSelection {
                    anchor: EditPosition { target: cell, .. },
                    ..
                },
            ..
        } => {
            // A cell's new 그림 배경 adds its image.
            let after = &with_images_of(before, after);
            return check_host(before, after, cell.section, cell.paragraph);
        }
        EditCommand::Order { object, .. } => return check_order(before, after, object.section),
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
    // A replacement removes the objects it covers, and with a note the numbers of the
    // notes after it.
    let deleted = match command {
        EditCommand::Replace { selection, .. } => covered(before, selection)?,
        _ => Vec::new(),
    };
    if !deleted.is_empty() {
        for doc in [&mut a, &mut b] {
            clear_note_numbers(doc);
        }
    }
    let mut old_controls = remove(&mut a, target, start, old_count)?;
    for &i in deleted.iter().rev() {
        old_controls.0.remove(i);
        old_controls.1.remove(i);
    }
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

/// The controls a replacement removes, as indexes into the controls of the paragraphs it
/// spans, taken in order.
fn covered(doc: &Document, selection: &EditSelection) -> Result<Vec<usize>, EditError> {
    let (start, end) = commands::ordered(selection);
    let (s, e) = (commands::index(&start.target), commands::index(&end.target));
    let mut taken = Vec::new();
    let mut before = 0;
    for i in s..=e {
        let p = commands::get(doc, &commands::at_index(&start.target, i))?;
        let from = if i == s { start.scalar } else { 0 };
        let to = if i == e {
            end.scalar
        } else {
            logical::length(p)
        };
        let mut objects = logical::objects(p, from, to);
        // A whole paragraph takes the objects laid out on their own too.
        let target = commands::at_index(&start.target, i);
        let whole =
            i > s && (i < e || (logical::length(p) > 0 && end.scalar >= logical::length(p)));
        if whole && target.header_footer.is_none() && target.note.is_none() {
            objects.extend(p.controls.iter().enumerate().filter_map(|(i, c)| {
                matches!(
                    c,
                    Control::Table(_)
                        | Control::Picture(_)
                        | Control::Shape(_)
                        | Control::Equation(_)
                )
                .then_some(i)
            }));
            objects.sort_unstable();
            objects.dedup();
        }
        taken.extend(objects.into_iter().map(|c| before + c));
        before += p.controls.len();
    }
    Ok(taken)
}
/// Clears the numbers of every 각주 and 미주, which rhwp renumbers when one goes.
fn clear_note_numbers(doc: &mut Document) {
    fn clear(paragraphs: &mut [Paragraph]) {
        for p in paragraphs {
            for c in &mut p.controls {
                match c {
                    Control::Footnote(n) => n.number = 0,
                    Control::Endnote(n) => n.number = 0,
                    _ => {}
                }
            }
        }
    }
    for s in &mut doc.sections {
        clear(&mut s.paragraphs);
    }
}
/// One binary-data record and its payload were appended, the earlier ones unchanged.
/// `after` without the one image a 그림 배경 added, when it added one.
fn with_images_of(before: &Document, after: &Document) -> Document {
    let mut b = after.clone();
    if one_image_added(before, after) {
        b.bin_data_content.truncate(before.bin_data_content.len());
        b.doc_info
            .bin_data_list
            .truncate(before.doc_info.bin_data_list.len());
    }
    b
}
fn one_image_added(before: &Document, after: &Document) -> bool {
    after.bin_data_content.len() == before.bin_data_content.len() + 1
        && after.doc_info.bin_data_list.len() == before.doc_info.bin_data_list.len() + 1
        && format!("{:?}", before.bin_data_content)
            == format!(
                "{:?}",
                &after.bin_data_content[..before.bin_data_content.len()]
            )
        && format!("{:?}", before.doc_info.bin_data_list)
            == format!(
                "{:?}",
                &after.doc_info.bin_data_list[..before.doc_info.bin_data_list.len()]
            )
}
/// A picture insertion may add one picture and its one binary-data record; the rest of
/// the document, including every previous binary payload, must remain unchanged.
fn check_inserted_picture(
    before: &Document,
    after: &Document,
    target: &EditTarget,
) -> Result<(), EditError> {
    if !one_image_added(before, after) {
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
fn check_table(
    before: &Document,
    after: &Document,
    cell: &EditTarget,
    change: Option<TableChange>,
) -> Result<(), EditError> {
    let control = cell
        .cell
        .as_ref()
        .ok_or(EditError::PreservationFailed)?
        .control as usize;
    let mut a = before.clone();
    let mut b = after.clone();
    // 표 나누기 adds an empty paragraph and the new table's; 표 붙이기 takes the next
    // table's paragraph and the blank ones before it.
    let (s, host) = (cell.section as usize, cell.paragraph as usize);
    match change {
        Some(TableChange::Split) => drop_next_table(&mut b, s, host, 2)?,
        Some(TableChange::Attach) => {
            let n = before.sections[s].paragraphs.len()
                - after.sections[s]
                    .paragraphs
                    .len()
                    .min(before.sections[s].paragraphs.len());
            drop_next_table(&mut a, s, host, n)?
        }
        _ => {}
    }
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
/// Removes the `n` paragraphs after `host`: blank ones, then one holding only a table.
fn drop_next_table(
    doc: &mut Document,
    section: usize,
    host: usize,
    n: usize,
) -> Result<(), EditError> {
    let paragraphs = &mut doc.sections[section].paragraphs;
    if n == 0 || host + n >= paragraphs.len() {
        return Err(EditError::PreservationFailed);
    }
    let gone: Vec<Paragraph> = paragraphs.drain(host + 1..=host + n).collect();
    let (table, blanks) = gone.split_last().ok_or(EditError::PreservationFailed)?;
    let blank = |p: &Paragraph| p.text.trim().is_empty() && p.controls.is_empty();
    if blanks.iter().all(blank)
        && table.text.trim().is_empty()
        && matches!(&table.controls[..], [Control::Table(_)])
    {
        Ok(())
    } else {
        Err(EditError::PreservationFailed)
    }
}
/// An object edit may only change the body paragraph holding the object, and append
/// DocInfo entries.
/// Only the order of the section's drawing objects changed.
fn check_order(before: &Document, after: &Document, section: u32) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    for doc in [&mut a, &mut b] {
        let paragraphs = &mut doc.sections[section as usize].paragraphs;
        for c in paragraphs.iter_mut().flat_map(|p| &mut p.controls) {
            if let Control::Shape(shape) = c {
                shape.common_mut().z_order = 0;
            }
        }
    }
    same_rest(&mut a, &mut b, section)
}
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
/// Like `check_host`, for a change that touches two paragraphs.
fn check_hosts(
    before: &Document,
    after: &Document,
    section: u32,
    mut paragraphs: Vec<u32>,
) -> Result<(), EditError> {
    paragraphs.sort_unstable_by(|a, b| b.cmp(a));
    paragraphs.dedup();
    let mut a = before.clone();
    let mut b = after.clone();
    for doc in [&mut a, &mut b] {
        let list = &mut doc.sections[section as usize].paragraphs;
        for &p in &paragraphs {
            if p as usize >= list.len() {
                return Err(EditError::PreservationFailed);
            }
            list.remove(p as usize);
        }
    }
    if !trim_appended(&mut a, &mut b) {
        return Err(EditError::PreservationFailed);
    }
    same_rest(&mut a, &mut b, section)
}
/// Page setup may only change the section's paper and margins.
fn check_page(
    before: &Document,
    after: &Document,
    section: u32,
    whole: bool,
) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    for s in commands::page_sections(before, section, whole) {
        let (x, y) = (&mut a.sections[s], &mut b.sections[s]);
        x.section_def.page_def = y.section_def.page_def.clone();
        // The section's first paragraph carries its own copy of the definition.
        for (p, q) in x.paragraphs.iter_mut().zip(&y.paragraphs) {
            for (c, d) in p.controls.iter_mut().zip(&q.controls) {
                if let (Control::SectionDef(c), Control::SectionDef(d)) = (c, d) {
                    c.page_def = d.page_def.clone();
                }
            }
        }
        (x.raw_stream, y.raw_stream) = (None, None);
    }
    same_rest(&mut a, &mut b, section)
}
/// 쪽 테두리/배경 changed only the sections' border, its flags and DocInfo's appended
/// border fills.
fn check_page_border(
    before: &Document,
    after: &Document,
    section: u32,
    whole: bool,
) -> Result<(), EditError> {
    fn take(x: &mut SectionDef, y: &SectionDef) {
        x.page_border_fill = y.page_border_fill.clone();
        (x.hide_border, x.hide_fill) = (y.hide_border, y.hide_fill);
        (x.first_page_border, x.first_page_fill) = (y.first_page_border, y.first_page_fill);
        x.flags = y.flags;
    }
    let mut a = before.clone();
    let mut b = after.clone();
    if !trim_appended(&mut a, &mut b) {
        return Err(EditError::PreservationFailed);
    }
    for s in commands::page_sections(before, section, whole) {
        let (x, y) = (&mut a.sections[s], &mut b.sections[s]);
        take(&mut x.section_def, &y.section_def);
        for (p, q) in x.paragraphs.iter_mut().zip(&y.paragraphs) {
            for (c, d) in p.controls.iter_mut().zip(&q.controls) {
                if let (Control::SectionDef(c), Control::SectionDef(d)) = (c, d) {
                    take(c, d);
                }
            }
        }
        (x.raw_stream, y.raw_stream) = (None, None);
    }
    same_rest(&mut a, &mut b, section)
}
/// A style command changed only the styles, the shapes in DocInfo and which style and
/// shapes paragraphs refer to; no text or control.
fn check_styles(before: &Document, after: &Document) -> Result<(), EditError> {
    fn unstyle(paragraphs: &mut [Paragraph]) {
        for p in paragraphs {
            p.style_id = 0;
            p.para_shape_id = 0;
            p.char_shapes.clear();
            for c in &mut p.controls {
                match c {
                    Control::Table(t) => {
                        for cell in &mut t.cells {
                            unstyle(&mut cell.paragraphs);
                        }
                        if let Some(c) = &mut t.caption {
                            unstyle(&mut c.paragraphs);
                        }
                    }
                    Control::Shape(s) => {
                        if let Some(d) = s.drawing_mut() {
                            if let Some(b) = &mut d.text_box {
                                unstyle(&mut b.paragraphs);
                            }
                            if let Some(c) = &mut d.caption {
                                unstyle(&mut c.paragraphs);
                            }
                        }
                    }
                    Control::Picture(p) => {
                        if let Some(c) = &mut p.caption {
                            unstyle(&mut c.paragraphs);
                        }
                    }
                    Control::Footnote(n) => unstyle(&mut n.paragraphs),
                    Control::Endnote(n) => unstyle(&mut n.paragraphs),
                    Control::Header(h) => unstyle(&mut h.paragraphs),
                    Control::Footer(h) => unstyle(&mut h.paragraphs),
                    _ => {}
                }
            }
        }
    }
    let mut a = before.clone();
    let mut b = after.clone();
    for doc in [&mut a, &mut b] {
        let info = &mut doc.doc_info;
        info.styles.clear();
        info.char_shapes.clear();
        info.para_shapes.clear();
        info.numberings.clear();
        info.bullets.clear();
        info.font_faces.clear();
        info.raw_stream = None;
        info.raw_stream_dirty = false;
        for s in &mut doc.sections {
            unstyle(&mut s.paragraphs);
            s.raw_stream = None;
            normalize(&mut s.paragraphs);
        }
    }
    if same(&mut a, &mut b) {
        Ok(())
    } else {
        Err(EditError::PreservationFailed)
    }
}
/// 글꼴 바꾸기 changed only the fonts the 글자 모양 use.
fn check_fonts(before: &Document, after: &Document) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    for doc in [&mut a, &mut b] {
        let info = &mut doc.doc_info;
        for shape in &mut info.char_shapes {
            shape.font_ids = [0; 7];
            shape.raw_data = None;
        }
        info.font_faces.clear();
        info.raw_stream = None;
        info.raw_stream_dirty = false;
        for s in &mut doc.sections {
            s.raw_stream = None;
            normalize(&mut s.paragraphs);
        }
    }
    if same(&mut a, &mut b) {
        Ok(())
    } else {
        Err(EditError::PreservationFailed)
    }
}
/// 각주/미주 모양 changed only the sections' definitions and the notes' numbers and
/// number shapes.
fn check_note_shape(
    before: &Document,
    after: &Document,
    section: u32,
    whole: bool,
) -> Result<(), EditError> {
    /// Takes out what a note shows of its number.
    fn unnumber(paragraphs: &mut [Paragraph]) {
        for p in paragraphs {
            for c in &mut p.controls {
                let notes = match c {
                    Control::Footnote(n) => {
                        (n.number, n.number_shape) = (0, 0);
                        (n.before_decoration_letter, n.after_decoration_letter) = (0, 0);
                        &mut n.paragraphs
                    }
                    Control::Endnote(n) => {
                        (n.number, n.number_shape) = (0, 0);
                        (n.before_decoration_letter, n.after_decoration_letter) = (0, 0);
                        &mut n.paragraphs
                    }
                    Control::AutoNumber(n) => {
                        (n.format, n.number, n.assigned_number) = (0, 0, 0);
                        (n.prefix_char, n.suffix_char) = ('\0', '\0');
                        continue;
                    }
                    Control::Table(t) => {
                        for cell in &mut t.cells {
                            unnumber(&mut cell.paragraphs);
                        }
                        continue;
                    }
                    Control::Shape(s) => {
                        if let Some(b) = s.drawing_mut().and_then(|d| d.text_box.as_mut()) {
                            unnumber(&mut b.paragraphs);
                        }
                        continue;
                    }
                    _ => continue,
                };
                unnumber(notes);
            }
        }
    }
    let mut a = before.clone();
    let mut b = after.clone();
    for doc in [&mut a, &mut b] {
        for s in &mut doc.sections {
            unnumber(&mut s.paragraphs);
            s.raw_stream = None;
        }
    }
    for s in commands::page_sections(before, section, whole) {
        let (x, y) = (&mut a.sections[s], &mut b.sections[s]);
        x.section_def = y.section_def.clone();
        for (p, q) in x.paragraphs.iter_mut().zip(&y.paragraphs) {
            for (c, d) in p.controls.iter_mut().zip(&q.controls) {
                if let (Control::SectionDef(c), Control::SectionDef(d)) = (c, d) {
                    *c = d.clone();
                }
            }
        }
    }
    same_rest(&mut a, &mut b, section)
}
/// 구역 설정 changed only the sections' definitions and, through the 개체 시작 번호,
/// the numbers of 그림, 표 and 수식.
fn check_section(
    before: &Document,
    after: &Document,
    section: u32,
    whole: bool,
) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    for s in commands::page_sections(before, section, whole) {
        let (x, y) = (&mut a.sections[s], &mut b.sections[s]);
        x.section_def = y.section_def.clone();
        for (p, q) in x.paragraphs.iter_mut().zip(&y.paragraphs) {
            for (c, d) in p.controls.iter_mut().zip(&q.controls) {
                if let (Control::SectionDef(c), Control::SectionDef(d)) = (c, d) {
                    *c = d.clone();
                }
            }
        }
        (x.raw_stream, y.raw_stream) = (None, None);
    }
    rhwp::parser::assign_auto_numbers(&mut a);
    same_rest(&mut a, &mut b, section)
}
/// A paste replaced the paragraphs the selection spanned with others, and may have
/// added to DocInfo (shapes, pictures); nothing else changed.
fn check_pasted(
    before: &Document,
    after: &Document,
    selection: &EditSelection,
) -> Result<(), EditError> {
    let (start, end) = commands::ordered(selection);
    let t = &start.target;
    let s = commands::index(t);
    let old = commands::index(&end.target) - s + 1;
    let mut a = before.clone();
    let mut b = after.clone();
    let grown =
        edited_paragraphs(&mut b, t)?.len() as isize - edited_paragraphs(&mut a, t)?.len() as isize;
    let new = usize::try_from(old as isize + grown).map_err(|_| EditError::PreservationFailed)?;
    remove(&mut a, t, s, old)?;
    remove(&mut b, t, s, new)?;
    if !trim_appended(&mut a, &mut b) {
        return Err(EditError::PreservationFailed);
    }
    same_rest(&mut a, &mut b, t.section)
}
/// Only the section's 단 정의 changed.
fn check_columns(before: &Document, after: &Document, section: u32) -> Result<(), EditError> {
    let mut a = before.clone();
    let mut b = after.clone();
    let x = &mut a.sections[section as usize].paragraphs;
    let y = &b.sections[section as usize].paragraphs;
    for (p, q) in x.iter_mut().zip(y) {
        for (c, d) in p.controls.iter_mut().zip(&q.controls) {
            if let (Control::ColumnDef(c), Control::ColumnDef(d)) = (c, d) {
                *c = d.clone();
            }
        }
    }
    same_rest(&mut a, &mut b, section)
}
/// Every paragraph keeps its text, and its controls but the codes erased.
fn check_erased(
    before: &Document,
    after: &Document,
    selection: Option<&EditSelection>,
    kinds: &[CodeKind],
) -> Result<(), EditError> {
    let erased = super::codes::codes(before, selection, kinds);
    if super::codes::codes(after, selection, kinds).len() == erased.len() && !erased.is_empty() {
        return Err(EditError::PreservationFailed);
    }
    for (s, (x, y)) in before.sections.iter().zip(&after.sections).enumerate() {
        if x.paragraphs.len() != y.paragraphs.len() {
            return Err(EditError::PreservationFailed);
        }
        for (p, (a, b)) in x.paragraphs.iter().zip(&y.paragraphs).enumerate() {
            let kept: Vec<String> = a
                .controls
                .iter()
                .enumerate()
                .filter(|(c, _)| !erased.contains(&(s, p, *c)))
                .map(|(_, c)| format!("{:?}", std::mem::discriminant(c)))
                .collect();
            let now: Vec<String> = b
                .controls
                .iter()
                .map(|c| format!("{:?}", std::mem::discriminant(c)))
                .collect();
            if a.text != b.text || kept != now {
                return Err(EditError::PreservationFailed);
            }
        }
    }
    Ok(())
}
/// Only the definition `target` is in is gone, with its data record.
fn check_deleted_header_footer(
    before: &Document,
    after: &Document,
    target: &EditTarget,
) -> Result<(), EditError> {
    let (p, c) =
        super::header_footer::place(before, target).map_err(|_| EditError::PreservationFailed)?;
    let mut a = before.clone();
    let mut b = after.clone();
    let p = &mut a.sections[target.section as usize].paragraphs[p];
    p.controls.remove(c);
    if c < p.ctrl_data_records.len() {
        p.ctrl_data_records.remove(c);
    }
    p.char_count -= 8;
    same_rest(&mut a, &mut b, target.section)
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
            p.numbering_restart = None;
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
