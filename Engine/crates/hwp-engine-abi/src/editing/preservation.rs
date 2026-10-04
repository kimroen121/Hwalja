use super::*;
use rhwp::model::{control::Control, document::Document, paragraph::Paragraph};

// Only derived line layout is excluded. Table dimensions, merges, controls,
// character styles, source streams and binary payloads remain in the comparison.
fn normalize(paragraphs: &mut [Paragraph]) {
    for p in paragraphs {
        p.line_segs.clear();
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
        EditCommand::Split { position } => {
            (&position.target, commands::index(&position.target), 1, 2)
        }
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
    let left = format!("{a:?}");
    let right = format!("{b:?}");
    if left == right {
        Ok(())
    } else {
        Err(EditError::PreservationFailed)
    }
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
    fn prefix<T: std::fmt::Debug>(old: &[T], new: &mut Vec<T>) -> bool {
        let same =
            new.len() >= old.len() && format!("{old:?}") == format!("{:?}", &new[..old.len()]);
        new.truncate(old.len());
        same
    }
    let (x, y) = (&a.doc_info, &mut b.doc_info);
    let appended = prefix(&x.char_shapes, &mut y.char_shapes)
        && prefix(&x.para_shapes, &mut y.para_shapes)
        && x.font_faces.len() <= y.font_faces.len()
        && {
            y.font_faces.truncate(x.font_faces.len());
            x.font_faces
                .iter()
                .zip(y.font_faces.iter_mut())
                .all(|(old, new)| prefix(old, new))
        };
    if !appended {
        return Err(EditError::PreservationFailed);
    }
    for doc in [&mut a, &mut b] {
        doc.doc_info.raw_stream = None;
        doc.doc_info.raw_stream_dirty = false;
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
    if format!("{a:?}") == format!("{b:?}") {
        Ok(())
    } else {
        Err(EditError::PreservationFailed)
    }
}
