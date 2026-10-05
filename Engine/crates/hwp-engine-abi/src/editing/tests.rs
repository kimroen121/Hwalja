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
        amend: false,
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
        amend: false,
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
        amend: false,
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
        amend: false,
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
fn edits_text_around_controls() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let host = EditTarget {
            paragraph: 2,
            ..body()
        };
        let table = format!("{:?}", s.core.document().sections[0].paragraphs[2].controls);
        replace(&mut s, host.clone(), 0, 0, "앞").unwrap();
        let end = s.paragraph(&host).unwrap().text.chars().count() as u32;
        replace(&mut s, host.clone(), end, end, "뒤 글").unwrap();
        replace(&mut s, host.clone(), 1, 2, "").unwrap();
        run(
            &mut s,
            EditCommand::Split {
                position: point(host.clone(), 1),
            },
        )
        .unwrap();
        let next = EditTarget {
            paragraph: 3,
            ..body()
        };
        run(
            &mut s,
            EditCommand::MergePrevious {
                position: point(next, 0),
            },
        )
        .unwrap();
        assert_eq!(s.paragraph(&host).unwrap().text, "앞 글", "{format}");
        let controls = &s.core.document().sections[0].paragraphs[2].controls;
        assert_eq!(format!("{controls:?}"), table, "{format}");
        // The controls follow their paragraph when it joins the previous one.
        let previous = s.paragraph(&body()).unwrap().text;
        run(
            &mut s,
            EditCommand::MergePrevious {
                position: point(host, 0),
            },
        )
        .unwrap();
        assert_eq!(s.paragraph(&body()).unwrap().text, previous + "앞 글");
        let controls = &s.core.document().sections[0].paragraphs[1].controls;
        assert!(
            format!("{controls:?}").contains(&table[1..table.len() - 1]),
            "{format}"
        );
    }
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
        amend: false,
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
    let (text, rendering) = (s.paragraph(&body()).unwrap().text, s.rendering());
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
        (
            s.paragraph(&body()).unwrap().text,
            s.rendering(),
            s.revision
        ),
        (text, rendering, 1)
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
        let data = std::slice::from_raw_parts(
            hwp_edit_result_data(opened),
            hwp_edit_result_length(opened),
        );
        assert_eq!(data[0], 1);
        assert!(!data.windows(5).any(|w| w == b"%PDF-"));
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
        amend: false,
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
        amend: false,
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
fn generated_fixtures_open_as_display_lists() {
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
        let display = session.displays[0].as_ref().unwrap();
        assert!(session.pdf.is_empty() && !display.fonts.is_empty());
        assert!(display
            .ops
            .iter()
            .any(|op| matches!(op, display::Op::Text { runs, .. } if runs[0].1 == "한")));
        assert!(session.reply().page_count > 0);
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

#[test]
fn replace_spans_paragraphs() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        let last = EditTarget {
            paragraph: 2,
            ..body()
        };
        let selection = EditSelection {
            anchor: point(last.clone(), 2),
            focus: point(body(), 1),
        };
        let reply = s
            .apply(EditRequest {
                version: 1,
                amend: false,
                revision: 0,
                command: EditCommand::Replace {
                    selection,
                    text: "X".into(),
                },
            })
            .unwrap();
        assert_eq!(s.paragraph(&body()).unwrap().text, "가X 문단");
        assert_eq!(s.paragraph(&body()).unwrap().count, 2);
        assert_eq!(
            reply.selection,
            Some(EditSelection::caret(point(body(), 2)))
        );
        let undo = EditRequest {
            version: 1,
            amend: false,
            revision: 1,
            command: EditCommand::Undo,
        };
        s.apply(undo).unwrap();
        assert_eq!(s.paragraph(&last).unwrap().text, "보존 문단");
    }
}
#[test]
fn replace_joins_a_table_paragraph_keeping_the_table() {
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let last = EditTarget {
        paragraph: 2,
        ..body()
    };
    let selection = EditSelection {
        anchor: point(body(), 1),
        focus: point(last, 0),
    };
    let result = s.apply(EditRequest {
        version: 1,
        amend: false,
        revision: 0,
        command: EditCommand::Replace {
            selection,
            text: String::new(),
        },
    });
    result.unwrap();
    assert_eq!(s.paragraph(&body()).unwrap().text, "가");
    let controls = &s.core.document().sections[0].paragraphs[1].controls;
    assert!(controls.iter().any(|c| matches!(c, Control::Table(_))));
}
#[test]
fn formats_text_and_paragraphs_and_saves() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let selection = EditSelection {
            anchor: point(body(), 0),
            focus: point(body(), 1),
        };
        let style = CharStyle {
            font: Some("Apple SD Gothic Neo".into()),
            size: Some(20.0),
            bold: Some(true),
            color: Some("#FF0000".into()),
            ..Default::default()
        };
        let reply = s
            .apply(EditRequest {
                version: 1,
                amend: false,
                revision: 0,
                command: EditCommand::FormatText {
                    selection: selection.clone(),
                    style,
                },
            })
            .unwrap();
        assert_eq!(reply.selection, Some(selection.clone()));
        let at = s.format(1, &point(body(), 1)).unwrap();
        assert_eq!(at.text.font.as_deref(), Some("Apple SD Gothic Neo"));
        assert_eq!((at.text.size, at.text.bold), (Some(20.0), Some(true)));
        assert_eq!(at.text.color.as_deref(), Some("#ff0000"));
        assert!(!at.fonts.is_empty());
        let after = s.format(1, &point(body(), 3)).unwrap();
        assert_eq!(after.text.bold, Some(false));

        let style = ParaStyle {
            alignment: Some(Alignment::Center),
            line_spacing: Some(200.0),
            line_spacing_kind: Some(LineSpacingKind::Percent),
            ..Default::default()
        };
        s.apply(EditRequest {
            version: 1,
            amend: false,
            revision: 1,
            command: EditCommand::FormatParagraphs { selection, style },
        })
        .unwrap();
        let at = s.format(2, &point(body(), 0)).unwrap();
        assert_eq!(at.paragraph.alignment, Some(Alignment::Center));
        assert_eq!(at.paragraph.line_spacing, Some(200.0));

        let saved = s
            .export(if format == "hwp" {
                SaveFormat::Hwp
            } else {
                SaveFormat::Hwpx
            })
            .unwrap();
        let reopened = EditSession::open(&saved).unwrap();
        let at = reopened.format(0, &point(body(), 1)).unwrap();
        assert_eq!((at.text.size, at.text.bold), (Some(20.0), Some(true)));
        assert_eq!(at.paragraph.alignment, Some(Alignment::Center));
    }
}
#[test]
fn format_rejects_empty_changes() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let selection = EditSelection {
        anchor: point(body(), 0),
        focus: point(body(), 1),
    };
    for style in [
        CharStyle::default(),
        CharStyle {
            color: Some("red".into()),
            ..Default::default()
        },
    ] {
        let result = s.apply(EditRequest {
            version: 1,
            amend: false,
            revision: 0,
            command: EditCommand::FormatText {
                selection: selection.clone(),
                style,
            },
        });
        assert!(matches!(result, Err(EditError::InvalidInput)));
    }
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
        amend: false,
        revision: s.revision,
        command: EditCommand::Undo,
    })
    .unwrap();
    eprintln!("undo {:?}, pages {:?}", t.elapsed(), s.changed);
}
#[cfg(feature = "skia")]
#[test]
#[ignore]
fn bench_skia_pdf() {
    use std::time::Instant;
    let bytes = std::fs::read(std::env::var("HWP_BENCH").unwrap()).unwrap();
    let s = EditSession::open(&bytes).unwrap();
    for p in 0..s.core.page_count().min(4) {
        let t = Instant::now();
        let pdf = s.core.render_page_pdf_direct_native(p).unwrap();
        eprintln!(
            "page {p} direct pdf {:?} {} KB",
            t.elapsed(),
            pdf.len() / 1024
        );
        let t = Instant::now();
        let svgpdf = s.core.render_page_pdf_native(p).unwrap();
        eprintln!(
            "page {p} svg pdf {:?} {} KB",
            t.elapsed(),
            svgpdf.len() / 1024
        );
        if let Ok(dir) = std::env::var("HWP_PDF_OUT") {
            std::fs::write(format!("{dir}/direct{p}.pdf"), pdf).unwrap();
            std::fs::write(format!("{dir}/svg{p}.pdf"), svgpdf).unwrap();
        }
    }
}
#[test]
fn amended_edits_share_one_undo_step() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let original = s.paragraph(&body()).unwrap().text;
    for (revision, text, amend) in [(0, "ㅎ", false), (1, "하", true), (2, "한", true)] {
        let start = point(body(), 0);
        let end = point(body(), if revision == 0 { 0 } else { 1 });
        s.apply(EditRequest {
            version: 1,
            amend,
            revision,
            command: EditCommand::Replace {
                selection: EditSelection {
                    anchor: start,
                    focus: end,
                },
                text: text.into(),
            },
        })
        .unwrap();
    }
    assert_eq!(s.paragraph(&body()).unwrap().text, format!("한{original}"));
    let undo = EditRequest {
        version: 1,
        amend: false,
        revision: 3,
        command: EditCommand::Undo,
    };
    let reply = s.apply(undo).unwrap();
    assert_eq!(s.paragraph(&body()).unwrap().text, original);
    assert!(!reply.can_undo && !reply.dirty);
}
#[test]
fn later_formats_keep_earlier_ones() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let selection = EditSelection {
        anchor: point(body(), 0),
        focus: point(body(), 1),
    };
    for (revision, style) in [
        (
            0,
            CharStyle {
                color: Some("#ff0000".into()),
                ..Default::default()
            },
        ),
        (
            1,
            CharStyle {
                size: Some(20.0),
                ..Default::default()
            },
        ),
        (
            2,
            CharStyle {
                bold: Some(true),
                ..Default::default()
            },
        ),
    ] {
        s.apply(EditRequest {
            version: 1,
            amend: false,
            revision,
            command: EditCommand::FormatText {
                selection: selection.clone(),
                style,
            },
        })
        .unwrap();
    }
    let at = s.format(3, &point(body(), 1)).unwrap();
    assert_eq!(at.text.color.as_deref(), Some("#ff0000"));
    assert_eq!((at.text.size, at.text.bold), (Some(20.0), Some(true)));
}
#[test]
fn formatting_a_span_keeps_each_runs_other_attributes() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let request = |revision, focus, style| EditRequest {
        version: 1,
        amend: false,
        revision,
        command: EditCommand::FormatText {
            selection: EditSelection {
                anchor: point(body(), 0),
                focus: point(body(), focus),
            },
            style,
        },
    };
    let red = CharStyle {
        color: Some("#ff0000".into()),
        ..Default::default()
    };
    s.apply(request(0, 1, red)).unwrap();
    let big = CharStyle {
        size: Some(20.0),
        ..Default::default()
    };
    s.apply(request(1, 12, big)).unwrap();
    let first = s.format(2, &point(body(), 1)).unwrap();
    let later = s.format(2, &point(body(), 12)).unwrap();
    assert_eq!(
        (first.text.color.as_deref(), first.text.size),
        (Some("#ff0000"), Some(20.0))
    );
    assert_eq!(
        (later.text.color.as_deref(), later.text.size),
        (Some("#000000"), Some(20.0))
    );
}
fn wrapped_document() -> EditSession {
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    let long = "가나다 라마바 사아자 차카타 파하 ".repeat(12);
    core.insert_text_native(0, 0, 0, &long).unwrap();
    core.split_paragraph_native(0, 0, long.chars().count(), None)
        .unwrap();
    core.insert_text_native(0, 1, 0, "둘째 문단").unwrap();
    EditSession::open(&core.export_hwpx_native().unwrap()).unwrap()
}
fn go(s: &EditSession, from: EditPosition, motion: Motion, goal: Option<f64>) -> Navigation {
    s.navigate(0, &from, motion, goal).unwrap()
}
#[test]
fn horizontal_and_word_motions() {
    let s = wrapped_document();
    let first = EditTarget {
        section: 0,
        paragraph: 0,
        cell: None,
    };
    let second = EditTarget {
        paragraph: 1,
        ..first.clone()
    };
    assert_eq!(
        go(&s, point(first.clone(), 0), Motion::Right, None).position,
        point(first.clone(), 1)
    );
    assert_eq!(
        go(&s, point(second.clone(), 0), Motion::Left, None)
            .position
            .target,
        first
    );
    assert_eq!(
        go(&s, point(second.clone(), 5), Motion::WordLeft, None).position,
        point(second.clone(), 3)
    );
    assert_eq!(
        go(&s, point(second.clone(), 0), Motion::WordRight, None).position,
        point(second.clone(), 2)
    );
    assert_eq!(
        go(&s, point(second.clone(), 1), Motion::WordStart, None).position,
        point(second.clone(), 0)
    );
    assert_eq!(
        go(&s, point(second.clone(), 1), Motion::WordEnd, None).position,
        point(second.clone(), 2)
    );
    assert_eq!(
        go(&s, point(second.clone(), 3), Motion::DocumentStart, None).position,
        point(first, 0)
    );
}
#[test]
fn vertical_motion_keeps_its_column_and_lines_have_edges() {
    let s = wrapped_document();
    let first = EditTarget {
        section: 0,
        paragraph: 0,
        cell: None,
    };
    let start = point(first.clone(), 5);
    let down = go(&s, start.clone(), Motion::Down, None);
    assert_eq!(down.position.target, first);
    assert!(down.position.scalar > 5 && down.caret.y > s.caret(0, &start).unwrap().y);
    let up = go(&s, down.position.clone(), Motion::Up, Some(down.goal_x));
    assert_eq!(up.position, start);

    let end = go(&s, start.clone(), Motion::LineEnd, None);
    let line_start = go(&s, down.position.clone(), Motion::LineStart, None);
    assert!(end.position.scalar < line_start.position.scalar);
    assert_eq!(end.caret.y, s.caret(0, &start).unwrap().y);
    assert_eq!(go(&s, start, Motion::LineStart, None).position.scalar, 0);
}
#[test]
fn replies_carry_the_caret() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let reply = replace(&mut s, body(), 0, 0, "가").unwrap();
    assert_eq!(reply.caret, Some(s.caret(1, &point(body(), 1)).unwrap()));
}

/// `HWP_BENCH=<file>`: how many pages draw natively, and the cost per page.
#[test]
#[ignore]
fn bench_display() {
    use std::time::Instant;
    let bytes = std::fs::read(std::env::var("HWP_BENCH").unwrap()).unwrap();
    let s = EditSession::open(&bytes).unwrap();
    for page in 0..s.core.page_count() {
        let svg = s.core.render_page_svg_native(page).unwrap();
        let t = Instant::now();
        let display = display::build(&svg);
        let mut bytes = Vec::new();
        if let Some(display) = &display {
            display.encode(&mut bytes);
        }
        eprintln!(
            "page {page}: {} in {:?}, {} KB",
            if display.is_some() { "native" } else { "PDF" },
            t.elapsed(),
            bytes.len() / 1024
        );
    }
}
#[test]
fn find_reports_body_and_cell_matches() {
    let s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let cell = EditTarget {
        section: 0,
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: 0,
            paragraph: 0,
        }),
    };
    let hits = s.find("내용", true).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(
        (&hits[0].anchor, &hits[0].focus),
        (&point(cell.clone(), 2), &point(cell, 4))
    );
    let hits = s.find("끝", true).unwrap();
    assert_eq!(hits[0].anchor, point(body(), 11));
    assert!(s.find("없는 말", true).unwrap().is_empty());
    assert!(s.find("", true).unwrap().is_empty());
}
fn run(s: &mut EditSession, command: EditCommand) -> Result<EditReply, EditError> {
    s.apply(EditRequest {
        version: 1,
        amend: false,
        revision: s.revision,
        command,
    })
}
fn table_shape(s: &EditSession, paragraph: usize) -> (u16, u16, usize) {
    let Control::Table(t) = s.core.document().sections[0].paragraphs[paragraph]
        .controls
        .iter()
        .find(|c| matches!(c, Control::Table(_)))
        .unwrap()
    else {
        unreachable!()
    };
    (t.row_count, t.col_count, t.cells.len())
}
#[test]
fn page_break_starts_a_page_and_undoes() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let text = s.paragraph(&body()).unwrap().text;
        let pages = s.core.page_count();
        let reply = run(
            &mut s,
            EditCommand::Break {
                position: point(body(), 1),
                column: false,
            },
        )
        .unwrap();
        assert_eq!(reply.page_count, pages + 1);
        let next = commands::at_index(&body(), 2);
        assert_eq!(reply.selection.unwrap().focus, point(next, 0));
        run(&mut s, EditCommand::Undo).unwrap();
        assert_eq!(s.core.page_count(), pages);
        assert_eq!(s.paragraph(&body()).unwrap().text, text);
    }
}
#[test]
fn inserts_tables_where_the_caret_is() {
    for format in ["hwp", "hwpx"] {
        // Middle of a paragraph, its start, and the section's structure-only first line.
        for (paragraph, scalar) in [(1, 1), (1, 0), (0, 0)] {
            let mut s = EditSession::open(&plain_document(format, false)).unwrap();
            let target = commands::at_index(&body(), paragraph);
            let reply = run(
                &mut s,
                EditCommand::InsertTable {
                    position: point(target, scalar),
                    rows: 2,
                    columns: 3,
                },
            )
            .unwrap_or_else(|e| panic!("{format} {paragraph}:{scalar} {e:?}"));
            let caret = reply.selection.unwrap().focus;
            let cell = caret.target.cell.clone().unwrap();
            assert_eq!((cell.cell, caret.scalar), (0, 0));
            assert_eq!(table_shape(&s, caret.target.paragraph as usize), (2, 3, 6));
            replace(&mut s, caret.target.clone(), 0, 0, "칸").unwrap();
            assert_eq!(s.paragraph(&caret.target).unwrap().text, "칸");
            assert!(s.find("보존 문단", true).unwrap().len() == 1);
        }
    }
}
#[test]
fn edits_table_rows_and_columns() {
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let cell = |index| EditTarget {
        section: 0,
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: index,
            paragraph: 0,
        }),
    };
    for (change, shape) in [
        (TableChange::InsertRowBelow, (2, 2, 4)),
        (TableChange::InsertColumnRight, (2, 3, 6)),
        (TableChange::InsertRowAbove, (3, 3, 9)),
        (TableChange::InsertColumnLeft, (3, 4, 12)),
        // Removes the row and column holding the caret, which hold no text by now.
        (TableChange::DeleteRow, (2, 4, 8)),
        (TableChange::DeleteColumn, (2, 3, 6)),
    ] {
        let caret = s.selection.clone().map_or(cell(0), |s| s.focus.target);
        let reply = run(
            &mut s,
            EditCommand::EditTable {
                cell: caret,
                change,
            },
        )
        .unwrap_or_else(|e| panic!("{change:?} {e:?}"));
        assert_eq!(table_shape(&s, 2), shape, "{change:?}");
        assert!(reply.selection.unwrap().focus.target.cell.is_some());
    }
    let one = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let mut one = one;
    assert!(run(
        &mut one,
        EditCommand::EditTable {
            cell: cell(0),
            change: TableChange::DeleteRow,
        },
    )
    .is_err());
}
#[test]
fn sets_paper_and_margins() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let mut page = s.page_setup(0).unwrap();
        let width = s.core.get_page_info_native(0).unwrap();
        page.landscape = !page.landscape;
        page.margin_left += 2835;
        run(
            &mut s,
            EditCommand::SetPage {
                section: 0,
                page: page.clone(),
            },
        )
        .unwrap();
        assert_eq!(s.page_setup(0).unwrap(), page);
        assert_ne!(s.core.get_page_info_native(0).unwrap(), width);
        page.margin_left = page.width.max(page.height);
        assert!(run(&mut s, EditCommand::SetPage { section: 0, page }).is_err());
    }
}
/// Opt-in: `HWP_CORPUS=<folder> cargo test --release structure_edits_on_corpus -- --ignored --nocapture`.
/// Runs each structure command once on every document and reports refusals.
#[test]
#[ignore]
fn structure_edits_on_corpus() {
    let folder = std::env::var("HWP_CORPUS").unwrap();
    let (mut runs, mut failures) = (0, 0);
    for entry in std::fs::read_dir(folder).unwrap() {
        let path = entry.unwrap().path();
        let Ok(bytes) = std::fs::read(&path) else {
            continue;
        };
        let Ok(opened) = EditSession::open(&bytes) else {
            continue;
        };
        let doc = opened.core.document().clone();
        let body = doc.sections[0]
            .paragraphs
            .iter()
            .position(|p| commands::editable(p) && !p.text.is_empty());
        let host = doc.sections[0].paragraphs.iter().position(|p| {
            commands::editable(p)
                && p.controls
                    .iter()
                    .any(|c| !matches!(c, Control::SectionDef(_) | Control::ColumnDef(_)))
        });
        let cell = doc.sections[0]
            .paragraphs
            .iter()
            .enumerate()
            .find_map(|(i, p)| {
                p.controls.iter().enumerate().find_map(|(j, c)| {
                    let Control::Table(t) = c else { return None };
                    (t.cells.first()?.text_direction == 0).then_some(EditTarget {
                        section: 0,
                        paragraph: i as u32,
                        cell: Some(CellTarget {
                            control: j as u32,
                            cell: 0,
                            paragraph: 0,
                        }),
                    })
                })
            });
        let mut commands = vec![];
        if let Some(p) = body {
            let position = point(commands::at_index(&self::body(), p), 1);
            commands.push(EditCommand::Break {
                position: position.clone(),
                column: false,
            });
            commands.push(EditCommand::InsertTable {
                position,
                rows: 2,
                columns: 2,
            });
        }
        if let Some(cell) = cell {
            commands.push(EditCommand::EditTable {
                cell,
                change: TableChange::InsertRowBelow,
            });
        }
        if let Some(p) = host {
            let target = commands::at_index(&self::body(), p);
            let end = doc.sections[0].paragraphs[p].text.chars().count() as u32;
            for at in [0, end] {
                commands.push(EditCommand::Replace {
                    selection: EditSelection::caret(point(target.clone(), at)),
                    text: "글".into(),
                });
                commands.push(EditCommand::Split {
                    position: point(target.clone(), at),
                });
            }
            if end > 0 {
                commands.push(EditCommand::Replace {
                    selection: EditSelection {
                        anchor: point(target.clone(), 0),
                        focus: point(target.clone(), end),
                    },
                    text: String::new(),
                });
            }
        }
        for footer in [false, true] {
            commands.push(EditCommand::HeaderFooter {
                section: 0,
                footer,
                page_number: Some(Placement::Center),
            });
        }
        let mut page = opened.page_setup(0).unwrap();
        page.margin_left += 283;
        commands.push(EditCommand::SetPage { section: 0, page });
        for command in commands {
            let mut s = EditSession::open(&bytes).unwrap();
            runs += 1;
            let label = format!("{command:?}").chars().take(24).collect::<String>();
            if let Err(e) = run(&mut s, command) {
                failures += 1;
                println!("{}: {label} {e:?}", path.display());
            }
        }
    }
    println!("{failures} of {runs} refused");
}
#[test]
fn full_char_and_para_formats_round_trip() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        let selection = EditSelection {
            anchor: point(body(), 0),
            focus: point(body(), 1),
        };
        let text = CharStyle {
            underline: Some(true),
            underline_shape: Some(2),
            strikethrough: Some(true),
            strike_shape: Some(1),
            shade: Some("#ffff00".into()),
            ratio: Some(80.0),
            spacing: Some(-10.0),
            superscript: Some(true),
            outline: Some(true),
            shadow: Some(true),
            emboss: Some(true),
            ..Default::default()
        };
        run(
            &mut s,
            EditCommand::FormatText {
                selection: selection.clone(),
                style: text.clone(),
            },
        )
        .unwrap();
        let paragraph = ParaStyle {
            line_spacing: Some(18.0),
            line_spacing_kind: Some(LineSpacingKind::Fixed),
            margin_left: Some(10.0),
            margin_right: Some(5.0),
            indent: Some(-8.0),
            spacing_before: Some(6.0),
            spacing_after: Some(3.0),
            keep_with_next: Some(true),
            ..Default::default()
        };
        run(
            &mut s,
            EditCommand::FormatParagraphs {
                selection,
                style: paragraph.clone(),
            },
        )
        .unwrap();
        let at = s.format(s.revision, &point(body(), 1)).unwrap();
        let t = at.text;
        assert_eq!(
            (t.underline_shape, t.strike_shape, t.shade.as_deref()),
            (Some(2), Some(1), Some("#ffff00"))
        );
        assert_eq!((t.ratio, t.spacing), (Some(80.0), Some(-10.0)));
        assert_eq!(
            (t.superscript, t.subscript, t.outline, t.shadow, t.emboss),
            (Some(true), Some(false), Some(true), Some(true), Some(true))
        );
        let p = at.paragraph;
        assert_eq!(
            (p.line_spacing_kind, p.line_spacing),
            (Some(LineSpacingKind::Fixed), Some(18.0))
        );
        assert_eq!(
            (p.margin_left, p.margin_right, p.indent),
            (Some(10.0), Some(5.0), Some(-8.0))
        );
        assert_eq!((p.spacing_before, p.spacing_after), (Some(6.0), Some(3.0)));
        assert_eq!(p.keep_with_next, Some(true));
    }
}
#[test]
fn header_and_footer_number_pages_and_save() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        let count = |s: &EditSession| {
            s.core.document().sections[0].paragraphs[0]
                .controls
                .iter()
                .filter(|c| matches!(c, Control::Header(_) | Control::Footer(_)))
                .count()
        };
        let place = |footer, page_number| EditCommand::HeaderFooter {
            section: 0,
            footer,
            page_number,
        };
        run(&mut s, place(false, None)).unwrap();
        run(&mut s, place(false, Some(Placement::Center))).unwrap();
        run(&mut s, place(true, Some(Placement::Right))).unwrap();
        assert_eq!(count(&s), 2, "{format}");
        let svg = s.core.render_page_svg_native(0).unwrap();
        assert_eq!(svg.matches(">1<").count(), 2, "{format}");
        let saved = s
            .export(if format == "hwp" {
                SaveFormat::Hwp
            } else {
                SaveFormat::Hwpx
            })
            .unwrap();
        let reopened = EditSession::open(&saved).unwrap();
        assert_eq!(count(&reopened), 2, "{format}");
        let svg = reopened.core.render_page_svg_native(0).unwrap();
        assert_eq!(svg.matches(">1<").count(), 2, "{format}");
        run(&mut s, EditCommand::Undo).unwrap();
        run(&mut s, EditCommand::Undo).unwrap();
        run(&mut s, EditCommand::Undo).unwrap();
        assert_eq!(count(&s), 0, "{format}");
    }
}
