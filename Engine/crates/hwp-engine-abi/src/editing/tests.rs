use super::*;
use rhwp::{DocumentCore, model::control::Control};

fn plain_document(format: &str, table: bool) -> Vec<u8> {
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    let mut doc = core.document().clone();
    let mut para = doc.sections[0].paragraphs[0].clone();
    para.controls.clear();
    doc.sections[0].paragraphs.extend([para.clone(), para]);
    core.set_document(doc);
    core.insert_text_native(0, 1, 0, "가👨‍👩‍👧‍👦e\u{301} 끝").unwrap();
    if table {
        core.create_table_native(0, 2, 0, 1, 2).unwrap();
        core.insert_text_in_cell_native(0, 2, 0, 0, 0, 0, "표 내용").unwrap();
    } else {
        core.insert_text_native(0, 2, 0, "보존 문단").unwrap();
    }
    if format == "hwp" { core.export_hwp_native().unwrap() }
    else { core.export_hwpx_native().unwrap() }
}
fn body() -> EditTarget { EditTarget { section: 0, paragraph: 1, cell: None } }
fn point(target: EditTarget, scalar: u32) -> EditPosition { EditPosition { target, scalar } }
fn replace(s: &mut EditSession, target: EditTarget, start: u32, end: u32, text: &str) -> Result<EditReply, EditError> {
    s.apply(EditRequest { version: 1, revision: s.revision, command: EditCommand::Replace {
        selection: EditSelection { anchor: point(target.clone(), start), focus: point(target, end) }, text: text.into()
    }})
}
#[test]
fn replace_preserves_other_content() {
    for format in ["hwp", "hwpx"] {
        let bytes = plain_document(format, true);
        let mut s = EditSession::open(&bytes).unwrap();
        let images = format!("{:?}", s.core.document().bin_data_content);
        replace(&mut s, body(), 0, 1, "수정").unwrap();
        assert!(s.paragraph(&body()).unwrap().text.starts_with("수정👨"));
        let cell = EditTarget { section: 0, paragraph: 2, cell: Some(CellTarget { control: 0, cell: 0, paragraph: 0 }) };
        replace(&mut s, cell.clone(), 0, 1, "셀").unwrap();
        assert_eq!(s.paragraph(&cell).unwrap().text, "셀 내용");
        assert_eq!(s.original, bytes);
        assert_eq!(format!("{:?}", s.core.document().bin_data_content), images);
        let Control::Table(t) = &s.core.document().sections[0].paragraphs[2].controls[0] else { panic!() };
        assert_eq!((t.row_count, t.col_count, t.cells.len()), (1, 2, 2));
    }
}
#[test]
fn rejects_unsupported_target() {
    let mut s = EditSession::open(&plain_document("hwp", true)).unwrap();
    let host = EditTarget { section: 0, paragraph: 2, cell: None };
    assert!(replace(&mut s, host, 0, 0, "안됨").is_err());
    let other = EditTarget { section: 0, paragraph: 2, cell: Some(CellTarget { control: 0, cell: 1, paragraph: 0 }) };
    let request = EditRequest { version: 1, revision: 0, command: EditCommand::Replace {
        selection: EditSelection { anchor: point(body(), 0), focus: point(other, 0) }, text: "x".into() } };
    assert!(s.apply(request).is_err());
    assert_eq!(s.revision, 0);
}
#[test]
fn rejects_invalid_boundary() {
    let mut s = EditSession::open(&plain_document("hwp", false)).unwrap();
    for offset in [2, 3, 9, u32::MAX] {
        assert!(replace(&mut s, body(), offset, offset, "x").is_err(), "{offset}");
    }
    assert_eq!(s.revision, 0);
}
#[test]
fn split_merge_preserves_following_control() {
    let mut s = EditSession::open(&plain_document("hwp", true)).unwrap();
    let before = s.paragraph(&body()).unwrap().text;
    let table = format!("{:?}", s.core.document().sections[0].paragraphs[2].controls);
    s.apply(EditRequest { version: 1, revision: 0, command: EditCommand::Split { position: point(body(), 1) } }).unwrap();
    let second = EditTarget { paragraph: 2, ..body() };
    s.apply(EditRequest { version: 1, revision: 1, command: EditCommand::MergePrevious { position: point(second, 0) } }).unwrap();
    assert_eq!(s.paragraph(&body()).unwrap().text, before);
    assert_eq!(format!("{:?}", s.core.document().sections[0].paragraphs[2].controls), table);
}

#[test]
fn inline_metadata_and_vertical_cells_are_read_only() {
    let mut s = EditSession::open(&plain_document("hwp", true)).unwrap();
    s.core.document_mut().sections[0].paragraphs[1].title_marks.push(
        rhwp::model::paragraph::TitleMark { ..Default::default() });
    assert_eq!(replace(&mut s, body(), 0, 0, "x").unwrap_err(), EditError::UnsupportedTarget);
    let Control::Table(t) = &mut s.core.document_mut().sections[0].paragraphs[2].controls[0] else { panic!() };
    t.cells[0].text_direction = 1;
    let cell = EditTarget { section: 0, paragraph: 2, cell: Some(CellTarget { control: 0, cell: 0, paragraph: 0 }) };
    assert_eq!(replace(&mut s, cell, 0, 0, "x").unwrap_err(), EditError::UnsupportedTarget);
    assert_eq!(s.revision, 0);
}

#[test]
fn preservation_rejects_changes_to_unedited_content() {
    let s = EditSession::open(&plain_document("hwp", true)).unwrap();
    let before = s.core.document().clone();
    let mut after = before.clone();
    let Control::Table(t) = &mut after.sections[0].paragraphs[2].controls[0] else { panic!() };
    t.col_count += 1;
    let command = EditCommand::Split { position: point(body(), 1) };
    after.sections[0].paragraphs.insert(2, before.sections[0].paragraphs[1].clone());
    assert_eq!(preservation::check(&before, &after, &command), Err(EditError::PreservationFailed));
}
