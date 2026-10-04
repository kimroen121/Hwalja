use super::*;
use rhwp::model::{document::Document, paragraph::Paragraph, control::Control};

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
                for cell in &mut t.cells { normalize(&mut cell.paragraphs); }
            }
        }
    }
}
fn remove(doc: &mut Document, t: &EditTarget, start: usize, count: usize) -> Result<(), EditError> {
    let section = doc.sections.get_mut(t.section as usize).ok_or(EditError::PreservationFailed)?;
    let ps = if let Some(c) = &t.cell {
        let Some(Control::Table(table)) = section.paragraphs.get_mut(t.paragraph as usize)
            .and_then(|p| p.controls.get_mut(c.control as usize)) else { return Err(EditError::PreservationFailed) };
        table.text_reflowed_after_edit = false;
        &mut table.cells.get_mut(c.cell as usize).ok_or(EditError::PreservationFailed)?.paragraphs
    } else { &mut section.paragraphs };
    if start + count > ps.len() { return Err(EditError::PreservationFailed) }
    ps.drain(start..start + count);
    Ok(())
}
pub(super) fn check(before: &Document, after: &Document, command: &EditCommand) -> Result<(), EditError> {
    let (target, start, old_count, new_count) = match command {
        EditCommand::Replace { selection, text } => (&selection.anchor.target, commands::index(&selection.anchor.target), 1,
            1 + text.replace("\r\n", "\n").replace('\r', "\n").matches('\n').count()),
        EditCommand::Split { position } => (&position.target, commands::index(&position.target), 1, 2),
        EditCommand::MergePrevious { position } => (&position.target, commands::index(&position.target) - 1, 2, 1),
        _ => return Err(EditError::UnsupportedTarget),
    };
    let mut a = before.clone();
    let mut b = after.clone();
    remove(&mut a, target, start, old_count)?;
    remove(&mut b, target, start, new_count)?;
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
    for s in &mut a.sections { normalize(&mut s.paragraphs); }
    for s in &mut b.sections { normalize(&mut s.paragraphs); }
    let left = format!("{a:?}");
    let right = format!("{b:?}");
    if left == right { Ok(()) } else { Err(EditError::PreservationFailed) }
}
