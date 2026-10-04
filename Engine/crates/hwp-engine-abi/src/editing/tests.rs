use super::*;
use rhwp::{model::control::Control, DocumentCore};

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
        core.insert_text_in_cell_native(0, 2, 0, 0, 0, 0, "표 내용")
            .unwrap();
    } else {
        core.insert_text_native(0, 2, 0, "보존 문단").unwrap();
    }
    if format == "hwp" {
        core.export_hwp_native().unwrap()
    } else {
        core.export_hwpx_native().unwrap()
    }
}
fn body() -> EditTarget {
    EditTarget {
        section: 0,
        paragraph: 1,
        cell: None,
    }
}
fn point(target: EditTarget, scalar: u32) -> EditPosition {
    EditPosition { target, scalar }
}
fn replace(
    s: &mut EditSession,
    target: EditTarget,
    start: u32,
    end: u32,
    text: &str,
) -> Result<EditReply, EditError> {
    s.apply(EditRequest {
        version: 1,
        revision: s.revision,
        command: EditCommand::Replace {
            selection: EditSelection {
                anchor: point(target.clone(), start),
                focus: point(target, end),
            },
            text: text.into(),
        },
    })
}
#[test]
fn replace_preserves_other_content() {
    for format in ["hwp", "hwpx"] {
        let bytes = plain_document(format, true);
        let mut s = EditSession::open(&bytes).unwrap();
        let images = format!("{:?}", s.core.document().bin_data_content);
        replace(&mut s, body(), 0, 1, "수정").unwrap();
        assert!(s.paragraph(&body()).unwrap().text.starts_with("수정👨"));
        let cell = EditTarget {
            section: 0,
            paragraph: 2,
            cell: Some(CellTarget {
                control: 0,
                cell: 0,
                paragraph: 0,
            }),
        };
        replace(&mut s, cell.clone(), 0, 1, "셀").unwrap();
        assert_eq!(s.paragraph(&cell).unwrap().text, "셀 내용");
        assert_eq!(s.original, bytes);
        assert_eq!(format!("{:?}", s.core.document().bin_data_content), images);
        let Control::Table(t) = &s.core.document().sections[0].paragraphs[2].controls[0] else {
            panic!()
        };
        assert_eq!((t.row_count, t.col_count, t.cells.len()), (1, 2, 2));
    }
}
#[test]
fn rejects_unsupported_target() {
    let mut s = EditSession::open(&plain_document("hwp", true)).unwrap();
    let host = EditTarget {
        section: 0,
        paragraph: 2,
        cell: None,
    };
    assert!(replace(&mut s, host, 0, 0, "안됨").is_err());
    let other = EditTarget {
        section: 0,
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: 1,
            paragraph: 0,
        }),
    };
    let request = EditRequest {
        version: 1,
        revision: 0,
        command: EditCommand::Replace {
            selection: EditSelection {
                anchor: point(body(), 0),
                focus: point(other, 0),
            },
            text: "x".into(),
        },
    };
    assert!(s.apply(request).is_err());
    assert_eq!(s.revision, 0);
}
#[test]
fn rejects_invalid_boundary() {
    let mut s = EditSession::open(&plain_document("hwp", false)).unwrap();
    for offset in [2, 3, 9, u32::MAX] {
        assert!(
            replace(&mut s, body(), offset, offset, "x").is_err(),
            "{offset}"
        );
    }
    assert_eq!(s.revision, 0);
}
#[test]
fn split_merge_preserves_following_control() {
    let mut s = EditSession::open(&plain_document("hwp", true)).unwrap();
    let before = s.paragraph(&body()).unwrap().text;
    let table = format!("{:?}", s.core.document().sections[0].paragraphs[2].controls);
    s.apply(EditRequest {
        version: 1,
        revision: 0,
        command: EditCommand::Split {
            position: point(body(), 1),
        },
    })
    .unwrap();
    let second = EditTarget {
        paragraph: 2,
        ..body()
    };
    s.apply(EditRequest {
        version: 1,
        revision: 1,
        command: EditCommand::MergePrevious {
            position: point(second, 0),
        },
    })
    .unwrap();
    assert_eq!(s.paragraph(&body()).unwrap().text, before);
    assert_eq!(
        format!("{:?}", s.core.document().sections[0].paragraphs[2].controls),
        table
    );
}

#[test]
fn inline_metadata_and_vertical_cells_are_read_only() {
    let mut s = EditSession::open(&plain_document("hwp", true)).unwrap();
    s.core.document_mut().sections[0].paragraphs[1]
        .title_marks
        .push(rhwp::model::paragraph::TitleMark {
            ..Default::default()
        });
    assert_eq!(
        replace(&mut s, body(), 0, 0, "x").unwrap_err(),
        EditError::UnsupportedTarget
    );
    let Control::Table(t) = &mut s.core.document_mut().sections[0].paragraphs[2].controls[0] else {
        panic!()
    };
    t.cells[0].text_direction = 1;
    let cell = EditTarget {
        section: 0,
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: 0,
            paragraph: 0,
        }),
    };
    assert_eq!(
        replace(&mut s, cell, 0, 0, "x").unwrap_err(),
        EditError::UnsupportedTarget
    );
    assert_eq!(s.revision, 0);
}

#[test]
fn preservation_rejects_changes_to_unedited_content() {
    let s = EditSession::open(&plain_document("hwp", true)).unwrap();
    let before = s.core.document().clone();
    let mut after = before.clone();
    let Control::Table(t) = &mut after.sections[0].paragraphs[2].controls[0] else {
        panic!()
    };
    t.col_count += 1;
    let command = EditCommand::Split {
        position: point(body(), 1),
    };
    after.sections[0]
        .paragraphs
        .insert(2, before.sections[0].paragraphs[1].clone());
    assert_eq!(
        preservation::check(&before, &after, &command),
        Err(EditError::PreservationFailed)
    );
}

fn command(s: &mut EditSession, command: EditCommand) -> Result<EditReply, EditError> {
    s.apply(EditRequest {
        version: 1,
        revision: s.revision,
        command,
    })
}
#[test]
fn undo_redo_restores_text_and_selection() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let original = s.paragraph(&body()).unwrap().text;
    replace(&mut s, body(), 0, 1, "나").unwrap();
    let edited = s.paragraph(&body()).unwrap().text;
    let undone = command(&mut s, EditCommand::Undo).unwrap();
    assert_eq!(s.paragraph(&body()).unwrap().text, original);
    assert!(!undone.dirty && !undone.can_undo && undone.can_redo);
    let redone = command(&mut s, EditCommand::Redo).unwrap();
    assert_eq!(s.paragraph(&body()).unwrap().text, edited);
    assert_eq!(
        redone.selection,
        Some(EditSelection::caret(point(body(), 1)))
    );
    assert!(redone.dirty && redone.can_undo && !redone.can_redo);
    assert_eq!(redone.revision, 3, "undo/redo advance the revision");
    assert_eq!(
        command(&mut s, EditCommand::Redo).unwrap_err(),
        EditError::InvalidInput
    );
}
#[test]
fn failed_render_rolls_back_edits_and_undo() {
    let mut s = EditSession::open(&plain_document("hwp", false)).unwrap();
    replace(&mut s, body(), 0, 1, "나").unwrap();
    let (text, pdf) = (s.paragraph(&body()).unwrap().text, s.pdf.clone());
    s.fail_render = true;
    assert_eq!(
        replace(&mut s, body(), 0, 0, "x").unwrap_err(),
        EditError::RenderFailed
    );
    assert_eq!(
        command(&mut s, EditCommand::Undo).unwrap_err(),
        EditError::RenderFailed
    );
    assert_eq!(
        (s.paragraph(&body()).unwrap().text, &s.pdf, s.revision),
        (text, &pdf, 1)
    );
    assert!(s.reply().can_undo && !s.locked);
    s.fail_render = false;
    command(&mut s, EditCommand::Undo).unwrap();
    assert!(!s.reply().dirty);
}
#[test]
fn history_is_bounded_and_new_edit_clears_redo() {
    let mut s = EditSession::open(&plain_document("hwp", false)).unwrap();
    for _ in 0..25 {
        replace(&mut s, body(), 0, 0, "x").unwrap();
    }
    assert_eq!(s.undo.len(), HISTORY_LIMIT);
    command(&mut s, EditCommand::Undo).unwrap();
    replace(&mut s, body(), 0, 0, "y").unwrap();
    assert!(!s.reply().can_redo);
    assert!(s.undo.len() + s.redo.len() <= HISTORY_LIMIT);
}
#[test]
fn hit_test_and_caret_round_trip() {
    let mut s = EditSession::open(&plain_document("hwp", true)).unwrap();
    let caret = s.caret(0, &point(body(), 1)).unwrap();
    let hit = s
        .hit_test(0, caret.page, caret.x + 0.5, caret.y + caret.height / 2.0)
        .unwrap();
    assert_eq!(hit, point(body(), 1));
    replace(&mut s, body(), 0, 0, "x").unwrap();
    assert_eq!(
        s.caret(0, &point(body(), 0)).unwrap_err(),
        EditError::StaleRevision
    );
}
#[test]
fn ffi_round_trip_owns_results() {
    use super::ffi::*;
    let bytes = plain_document("hwp", false);
    let mut session = std::ptr::null_mut();
    unsafe {
        let json = |r| {
            std::ffi::CStr::from_ptr(hwp_edit_result_json(r))
                .to_str()
                .unwrap()
                .to_owned()
        };
        let opened = hwp_edit_open(bytes.as_ptr(), bytes.len(), &mut session);
        assert_eq!(hwp_edit_result_status(opened), 0, "{}", json(opened));
        assert!(std::slice::from_raw_parts(
            hwp_edit_result_data(opened),
            hwp_edit_result_length(opened)
        )
        .starts_with(b"%PDF-"));
        hwp_edit_result_free(opened);
        let request = br#"{"op":"apply","request":{"version":1,"revision":0,"command":{"kind":"replace","selection":{"anchor":{"target":{"section":0,"paragraph":1,"cell":null},"scalar":0},"focus":{"target":{"section":0,"paragraph":1,"cell":null},"scalar":0}},"text":"x"}}}"#;
        let applied = hwp_edit_request(session, request.as_ptr(), request.len());
        assert_eq!(hwp_edit_result_status(applied), 0, "{}", json(applied));
        assert!(json(applied).contains("\"revision\":1"));
        hwp_edit_result_free(applied);
        let stale = hwp_edit_request(session, request.as_ptr(), request.len());
        assert_eq!(json(stale), r#"{"error":"StaleRevision"}"#);
        hwp_edit_result_free(stale);
        let bad = hwp_edit_request(session, b"{".as_ptr(), 1);
        assert_eq!(json(bad), r#"{"error":"InvalidInput"}"#);
        hwp_edit_result_free(bad);
        hwp_edit_close(session);
        let failed = hwp_edit_open(b"junk".as_ptr(), 4, &mut session);
        assert!(session.is_null() && hwp_edit_result_status(failed) == 1);
        hwp_edit_result_free(failed);
    }
}
#[test]
fn first_paragraph_with_section_definition_is_editable() {
    let mut s = EditSession::open(&plain_document("hwp", false)).unwrap();
    let first = EditTarget {
        section: 0,
        paragraph: 0,
        cell: None,
    };
    let controls = format!("{:?}", s.core.document().sections[0].paragraphs[0].controls);
    assert!(controls.contains("SectionDef"));
    replace(&mut s, first.clone(), 0, 0, "첫 줄").unwrap();
    s.apply(EditRequest {
        version: 1,
        revision: s.revision,
        command: EditCommand::Split {
            position: point(first.clone(), 1),
        },
    })
    .unwrap();
    let second = EditTarget {
        paragraph: 1,
        ..first.clone()
    };
    s.apply(EditRequest {
        version: 1,
        revision: s.revision,
        command: EditCommand::MergePrevious {
            position: point(second, 0),
        },
    })
    .unwrap();
    assert_eq!(s.paragraph(&first).unwrap().text, "첫 줄");
    assert_eq!(
        format!("{:?}", s.core.document().sections[0].paragraphs[0].controls),
        controls
    );
}
#[test]
fn open_rejects_empty_oversized_and_classifies_failures() {
    assert_eq!(EditSession::open(&[]).err(), Some(EditError::InvalidInput));
    let oversized = vec![0u8; 64 * 1024 * 1024 + 1];
    assert_eq!(
        EditSession::open(&oversized).err(),
        Some(EditError::ResourceLimit)
    );
    let mut source = DocumentCore::new_empty();
    source.create_blank_document_native().unwrap();
    let encrypted = source
        .export_hwpx_native_with_password(b"fixture-password")
        .unwrap();
    for (bytes, expected) in [
        (encrypted.as_slice(), EditError::PasswordRequired),
        (
            b"\x9b DRMONE protected".as_slice(),
            EditError::UnsupportedFormat,
        ),
        (b"PK\x03\x04broken".as_slice(), EditError::UnsupportedFormat),
        (
            b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1".as_slice(),
            EditError::InvalidInput,
        ),
    ] {
        assert_eq!(EditSession::open(bytes).err(), Some(expected));
    }
}
/// `HWP_WRITE_FIXTURES=1` regenerates Tests/Fixtures/generated.{hwp,hwpx}.
#[test]
fn generated_fixtures_open_as_pdf() {
    let mut source = DocumentCore::new_empty();
    source.create_blank_document_native().unwrap();
    source
        .insert_text_native(0, 0, 0, "HwpStudio generated fixture — 한글 읽기 전용")
        .unwrap();
    for (extension, bytes) in [
        ("hwp", source.export_hwp_native().unwrap()),
        ("hwpx", source.export_hwpx_native().unwrap()),
    ] {
        let session = EditSession::open(&bytes).unwrap();
        assert!(session.pdf().starts_with(b"%PDF-"));
        assert!(session.reply().suspect_pages.is_empty() && session.reply().page_count > 0);
        if std::env::var_os("HWP_WRITE_FIXTURES").is_some() {
            let folder =
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Tests/Fixtures");
            std::fs::write(folder.join(format!("generated.{extension}")), bytes).unwrap();
        }
    }
}
#[test]
fn selection_rects_cover_the_selected_text() {
    let s = EditSession::open(&plain_document("hwp", false)).unwrap();
    let selection = EditSelection {
        anchor: point(body(), 5),
        focus: point(body(), 0),
    };
    let rects = s.selection_rects(0, &selection).unwrap();
    assert_eq!(rects.len(), 1);
    let (start, end) = (
        s.caret(0, &point(body(), 0)).unwrap(),
        s.caret(0, &point(body(), 5)).unwrap(),
    );
    assert!(
        (rects[0].x - start.x).abs() < 1.0 && (rects[0].x + rects[0].width - end.x).abs() < 1.0
    );
    let other = EditTarget {
        paragraph: 2,
        ..body()
    };
    let across = EditSelection {
        anchor: point(body(), 0),
        focus: point(other, 2),
    };
    assert_eq!(s.selection_rects(0, &across).unwrap().len(), 2);
}
#[test]
fn export_round_trips_edits() {
    for (format, save) in [("hwp", SaveFormat::Hwp), ("hwpx", SaveFormat::Hwpx)] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        replace(&mut s, body(), 0, 1, "저장").unwrap();
        let reopened = EditSession::open(&s.export(save).unwrap()).unwrap();
        assert_eq!(
            reopened.paragraph(&body()).unwrap().text,
            s.paragraph(&body()).unwrap().text
        );
    }
}
#[test]
fn blank_document_is_editable() {
    let mut s = EditSession::blank().unwrap();
    let first = EditTarget {
        section: 0,
        paragraph: 0,
        cell: None,
    };
    replace(&mut s, first.clone(), 0, 0, "새 문서").unwrap();
    assert_eq!(s.paragraph(&first).unwrap().text, "새 문서");
}

/// Opt-in typing latency on a private document; prints durations only:
/// `HWP_BENCH=<file> cargo test --release bench_typing -- --ignored --nocapture`
#[test]
#[ignore]
fn bench_typing() {
    use std::time::Instant;
    let bytes = std::fs::read(std::env::var("HWP_BENCH").unwrap()).unwrap();
    let t = Instant::now();
    let mut s = EditSession::open(&bytes).unwrap();
    eprintln!("open {:?}, {} pages", t.elapsed(), s.core.page_count());
    let target = (0..s.core.document().sections[0].paragraphs.len() as u32)
        .map(|paragraph| EditTarget {
            section: 0,
            paragraph,
            cell: None,
        })
        .find(|t| commands::get(s.core.document(), t).is_ok_and(commands::editable))
        .unwrap();
    for i in 0..5 {
        let t = Instant::now();
        replace(&mut s, target.clone(), i, i, "가").unwrap();
        eprintln!("keystroke {:?}, pages {:?}", t.elapsed(), s.changed);
    }
    let t = Instant::now();
    s.apply(EditRequest {
        version: 1,
        revision: s.revision,
        command: EditCommand::Undo,
    })
    .unwrap();
    eprintln!("undo {:?}, pages {:?}", t.elapsed(), s.changed);
}
