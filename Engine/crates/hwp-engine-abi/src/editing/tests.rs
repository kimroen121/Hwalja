use super::*;
use rhwp::{
    model::{
        control::Control,
        header_footer::{Footer, Header, HeaderFooterApply},
        paragraph::Paragraph,
    },
    DocumentCore,
};

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
        note: None,
        header_footer: None,
    }
}

fn header_footer_target(footer: bool, apply_to: u8, paragraph: u32) -> EditTarget {
    EditTarget {
        section: 0,
        paragraph,
        cell: None,
        note: None,
        header_footer: Some(HeaderFooterTarget {
            footer,
            apply_to,
            page: 0,
        }),
    }
}

fn text_paragraph(text: &str) -> Paragraph {
    Paragraph {
        text: text.into(),
        ..Default::default()
    }
}

#[test]
fn header_footer_target_resolves_each_apply_kind_and_rejects_mixed_containers() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let host = &mut s.core.document_mut().sections[0].paragraphs[0];
    host.controls.extend([
        Control::Header(Box::new(Header {
            apply_to: HeaderFooterApply::Both,
            paragraphs: vec![text_paragraph("양쪽 머리말")],
            ..Default::default()
        })),
        Control::Header(Box::new(Header {
            apply_to: HeaderFooterApply::Even,
            paragraphs: vec![text_paragraph("짝수 머리말")],
            ..Default::default()
        })),
        Control::Footer(Box::new(Footer {
            apply_to: HeaderFooterApply::Odd,
            paragraphs: vec![text_paragraph("홀수 꼬리말")],
            ..Default::default()
        })),
    ]);

    assert_eq!(
        s.paragraph(&header_footer_target(false, 0, 0))
            .unwrap()
            .text,
        "양쪽 머리말"
    );
    assert_eq!(
        s.paragraph(&header_footer_target(false, 1, 0))
            .unwrap()
            .text,
        "짝수 머리말"
    );
    assert_eq!(
        s.paragraph(&header_footer_target(true, 2, 0)).unwrap().text,
        "홀수 꼬리말"
    );

    let mut mixed = header_footer_target(false, 0, 0);
    mixed.cell = Some(CellTarget {
        control: 0,
        cell: 0,
        paragraph: 0,
    });
    assert_eq!(
        s.paragraph(&mixed).unwrap_err(),
        EditError::UnsupportedTarget
    );
}

#[test]
fn header_footer_ranges_preserve_field_markers() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    s.core.document_mut().sections[0].paragraphs[0]
        .controls
        .push(Control::Footer(Box::new(Footer {
            apply_to: HeaderFooterApply::Both,
            paragraphs: vec![text_paragraph("앞\u{0015}중\u{0016}뒤\u{0017}")],
            ..Default::default()
        })));
    let target = header_footer_target(true, 0, 0);
    let selection = |start, end| EditSelection {
        anchor: point(target.clone(), start),
        focus: point(target.clone(), end),
    };

    assert!(s.validate_range(&selection(1, 1)).is_ok());
    assert!(s.validate_range(&selection(2, 2)).is_ok());
    for range in [1..2, 3..4, 5..6] {
        assert_eq!(
            s.validate_range(&selection(range.start, range.end))
                .unwrap_err(),
            EditError::UnsupportedTarget
        );
    }
}

#[test]
fn header_footer_hit_testing_requires_opt_in_and_geometry_round_trips() {
    let mut s = EditSession::blank().unwrap();
    s.core.create_header_footer_native(0, true, 0).unwrap();
    s.core
        .insert_text_in_header_footer_native(0, true, 0, 0, 0, "학교 머리말")
        .unwrap();
    let cursor: serde_json::Value = serde_json::from_str(
        &s.core
            .get_cursor_rect_in_header_footer_native(0, true, 0, 0, 2, 0)
            .unwrap(),
    )
    .unwrap();
    let x = cursor["x"].as_f64().unwrap();
    let y = cursor["y"].as_f64().unwrap() + cursor["height"].as_f64().unwrap() / 2.0;

    let ordinary = s.hit_test(0, 0, x, y, false).unwrap();
    assert!(ordinary.target.header_footer.is_none());
    let hit = s.hit_test(0, 0, x, y, true).unwrap();
    assert_eq!(
        hit.target.header_footer,
        Some(HeaderFooterTarget {
            footer: false,
            apply_to: 0,
            page: 0,
        })
    );
    assert_eq!(hit.target.section, 0);
    assert_eq!(hit.target.paragraph, 0);

    let caret = s.caret(0, &hit).unwrap();
    assert_eq!(caret.page, 0);
    assert!(caret.height > 0.0 && caret.x.is_finite() && caret.y.is_finite());
    let round_trip = s
        .hit_test(
            0,
            caret.page,
            caret.x + 0.2,
            caret.y + caret.height / 2.0,
            true,
        )
        .unwrap();
    assert_eq!(round_trip.target, hit.target);
    assert!(round_trip.scalar.abs_diff(hit.scalar) <= 1);
    let selection = EditSelection {
        anchor: point(hit.target.clone(), 0),
        focus: point(hit.target.clone(), 2),
    };
    assert!(!s.selection_rects(0, &selection).unwrap().is_empty());
    let word_end = s.navigate(0, &hit, Motion::WordEnd, None).unwrap();
    assert_eq!(word_end.position.target, hit.target);
    assert!(word_end.position.scalar >= hit.scalar);
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
    run(
        s,
        EditCommand::Replace {
            selection: EditSelection {
                anchor: point(target.clone(), start),
                focus: point(target, end),
            },
            text: text.into(),
        },
    )
}
#[test]
fn protocol_version_accepts_current_and_rejects_previous() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let command = |text: &str| EditCommand::Replace {
        selection: EditSelection::caret(point(body(), 0)),
        text: text.into(),
    };
    assert!(s
        .apply(EditRequest {
            version: 3,
            revision: 0,
            command: command("새"),
            amend: false,
        })
        .is_ok());
    assert!(matches!(
        s.apply(EditRequest {
            version: 2,
            revision: 1,
            command: command("옛"),
            amend: false,
        }),
        Err(EditError::InvalidInput)
    ));
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
            note: None,
            header_footer: None,
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
        note: None,
        header_footer: None,
    };
    let request = EditRequest {
        version: PROTOCOL_VERSION,
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
        note: None,
        header_footer: None,
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
        version: PROTOCOL_VERSION,
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
        .hit_test(
            0,
            caret.page,
            caret.x + 0.5,
            caret.y + caret.height / 2.0,
            false,
        )
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
        let opened = hwp_edit_open_v2(PROTOCOL_VERSION, bytes.as_ptr(), bytes.len(), &mut session);
        assert_eq!(hwp_edit_result_status(opened), 0, "{}", json(opened));
        let data = std::slice::from_raw_parts(
            hwp_edit_result_data(opened),
            hwp_edit_result_length(opened),
        );
        assert_eq!(data[0], 1);
        assert!(!data.windows(5).any(|w| w == b"%PDF-"));
        hwp_edit_result_free(opened);
        let request = br#"{"op":"apply","request":{"version":3,"revision":0,"command":{"kind":"replace","selection":{"anchor":{"target":{"section":0,"paragraph":1,"cell":null},"scalar":0},"focus":{"target":{"section":0,"paragraph":1,"cell":null},"scalar":0}},"text":"x"}}}"#;
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
        let failed = hwp_edit_open_v2(PROTOCOL_VERSION, b"junk".as_ptr(), 4, &mut session);
        assert!(session.is_null() && hwp_edit_result_status(failed) == 1);
        hwp_edit_result_free(failed);
    }
}

#[test]
fn legacy_open_rejects_before_returning_rendering() {
    use super::ffi::*;
    let bytes = plain_document("hwpx", false);
    let mut session = std::ptr::null_mut();
    let result = unsafe { hwp_edit_open(bytes.as_ptr(), bytes.len(), &mut session) };
    assert_eq!(unsafe { hwp_edit_result_status(result) }, 1);
    assert!(session.is_null());
    assert_eq!(unsafe { hwp_edit_result_length(result) }, 0);
    let json = unsafe { std::ffi::CStr::from_ptr(hwp_edit_result_json(result)) };
    assert!(json.to_str().unwrap().contains("IncompatibleEngine"));
    unsafe { hwp_edit_result_free(result) };
}

#[test]
fn versioned_open_negotiates_before_returning_rendering() {
    use super::ffi::*;
    let bytes = plain_document("hwpx", false);
    let mut session = std::ptr::null_mut();
    let current =
        unsafe { hwp_edit_open_v2(PROTOCOL_VERSION, bytes.as_ptr(), bytes.len(), &mut session) };
    assert_eq!(unsafe { hwp_edit_result_status(current) }, 0);
    assert!(!session.is_null());
    unsafe {
        hwp_edit_result_free(current);
        hwp_edit_close(session);
    }

    session = std::ptr::null_mut();
    let old = unsafe {
        hwp_edit_open_v2(
            PROTOCOL_VERSION - 1,
            bytes.as_ptr(),
            bytes.len(),
            &mut session,
        )
    };
    assert_eq!(unsafe { hwp_edit_result_status(old) }, 1);
    assert!(session.is_null());
    assert_eq!(unsafe { hwp_edit_result_length(old) }, 0);
    unsafe { hwp_edit_result_free(old) };
}
#[test]
fn first_paragraph_with_section_definition_is_editable() {
    let mut s = EditSession::open(&plain_document("hwp", false)).unwrap();
    let first = EditTarget {
        section: 0,
        paragraph: 0,
        cell: None,
        note: None,
        header_footer: None,
    };
    let controls = format!("{:?}", s.core.document().sections[0].paragraphs[0].controls);
    assert!(controls.contains("SectionDef"));
    replace(&mut s, first.clone(), 0, 0, "첫 줄").unwrap();
    run(
        &mut s,
        EditCommand::Split {
            position: point(first.clone(), 1),
        },
    )
    .unwrap();
    let second = EditTarget {
        paragraph: 1,
        ..first.clone()
    };
    run(
        &mut s,
        EditCommand::MergePrevious {
            position: point(second, 0),
        },
    )
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
fn picture_insert_undo_and_save_round_trip() {
    use base64::Engine;
    let png = base64::engine::general_purpose::STANDARD
        .decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        .unwrap();
    for (format, save) in [("hwp", SaveFormat::Hwp), ("hwpx", SaveFormat::Hwpx)] {
        let mut session = EditSession::open(&plain_document(format, false)).unwrap();
        let before_bins = session.core.document().bin_data_content.len();
        let command = EditCommand::InsertPicture {
            position: point(body(), 1),
            data: base64::engine::general_purpose::STANDARD.encode(&png),
            width: 7_500,
            height: 7_500,
            natural_width: 1,
            natural_height: 1,
            extension: "png".into(),
            description: "test.png".into(),
        };
        run(&mut session, command).unwrap();
        assert_eq!(
            session.core.document().bin_data_content.len(),
            before_bins + 1
        );
        assert!(session.core.document().sections[0].paragraphs[1]
            .controls
            .iter()
            .any(|c| matches!(c, Control::Picture(_))));
        let reopened = EditSession::open(&session.export(save).unwrap()).unwrap();
        assert!(reopened.core.document().sections[0].paragraphs[1]
            .controls
            .iter()
            .any(|c| matches!(c, Control::Picture(_))));
        run(&mut session, EditCommand::Undo).unwrap();
        assert_eq!(session.core.document().bin_data_content.len(), before_bins);
    }
}

#[test]
fn equation_insert_undo_and_save_round_trip() {
    for (format, save) in [("hwp", SaveFormat::Hwp), ("hwpx", SaveFormat::Hwpx)] {
        let mut session = EditSession::open(&plain_document(format, false)).unwrap();
        let command: EditCommand = serde_json::from_value(serde_json::json!({
            "kind": "insertEquation",
            "position": {
                "target": { "section": 0, "paragraph": 1, "cell": null },
                "scalar": 1
            },
            "script": "x^2 + y^2 = z^2",
            "fontSize": 1000,
            "color": 0
        }))
        .unwrap();
        run(&mut session, command).unwrap();
        let equation = session.core.document().sections[0].paragraphs[1]
            .controls
            .iter()
            .find_map(|control| match control {
                Control::Equation(equation) => Some(equation),
                _ => None,
            })
            .unwrap();
        assert_eq!(equation.script, "x^2 + y^2 = z^2");
        assert_eq!((equation.font_size, equation.color), (1000, 0));
        let reopened = EditSession::open(&session.export(save).unwrap()).unwrap();
        assert!(reopened.core.document().sections[0].paragraphs[1]
            .controls
            .iter()
            .any(|control| matches!(control, Control::Equation(_))));
        run(&mut session, EditCommand::Undo).unwrap();
        assert!(!session.core.document().sections[0].paragraphs[1]
            .controls
            .iter()
            .any(|control| matches!(control, Control::Equation(_))));
    }
}

#[test]
fn objects_are_found_changed_and_deleted() {
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let picture = EditCommand::InsertPicture {
        position: point(body(), 1),
        data: png.into(),
        width: 7_500,
        height: 7_500,
        natural_width: 1,
        natural_height: 1,
        extension: "png".into(),
        description: "".into(),
    };
    run(&mut s, picture).unwrap();
    let equation = EditCommand::InsertEquation {
        position: point(body(), 0),
        script: "x^2".into(),
        font_size: 1000,
        color: 0,
    };
    run(&mut s, equation).unwrap();

    let placed = s.placed(0).unwrap();
    let kinds: Vec<_> = placed.iter().map(|o| o.object.kind).collect();
    assert_eq!(kinds, [ObjectKind::Equation, ObjectKind::Picture]);
    for o in &placed {
        let r = &o.rect;
        let hit = s
            .object_at(s.revision, 0, r.x + r.width / 2.0, r.y + r.height / 2.0)
            .unwrap();
        assert_eq!(hit.as_ref(), Some(o));
        assert_eq!(s.place(s.revision, &o.object, 0).unwrap(), *o);
    }
    assert_eq!(s.object_at(s.revision, 0, 1.0, 1.0).unwrap(), None);

    let (equation, picture) = (placed[0].object.clone(), placed[1].object.clone());
    let change = ObjectProps {
        width: Some(15_000),
        height: Some(15_000),
        effect: Some("GrayScale".into()),
        brightness: Some(20),
        outer_margin_left: Some(283),
        caption: Some("LeftBottom".into()),
        ..Default::default()
    };
    run(
        &mut s,
        EditCommand::SetObject {
            object: picture.clone(),
            props: change,
        },
    )
    .unwrap();
    let props = s.object_props(&picture).unwrap();
    assert_eq!((props.width, props.height), (Some(15_000), Some(15_000)));
    assert_eq!(props.effect.as_deref(), Some("GrayScale"));
    assert_eq!(props.caption.as_deref(), Some("LeftBottom"));
    assert_eq!(
        (props.brightness, props.outer_margin_left),
        (Some(20), Some(283))
    );
    let script = ObjectProps {
        script: Some("a over b".into()),
        font_size: Some(1_200),
        ..Default::default()
    };
    run(
        &mut s,
        EditCommand::SetObject {
            object: equation.clone(),
            props: script,
        },
    )
    .unwrap();
    let props = s.object_props(&equation).unwrap();
    assert_eq!(props.script.as_deref(), Some("a over b"));
    assert_eq!(props.font_size, Some(1_200));
    let wrong = ObjectProps {
        text_wrap: Some("Sideways".into()),
        ..Default::default()
    };
    let refused = EditCommand::SetObject {
        object: picture.clone(),
        props: wrong,
    };
    assert_eq!(run(&mut s, refused).unwrap_err(), EditError::InvalidInput);

    let table = ObjectRef {
        kind: ObjectKind::Table,
        section: 0,
        paragraph: 2,
        control: 0,
        cell: None,
    };
    let change = ObjectProps {
        repeat_header: Some(true),
        outer_margin_top: Some(567),
        page_break: Some(2),
        caption: Some("RightCenter".into()),
        ..Default::default()
    };
    run(
        &mut s,
        EditCommand::SetObject {
            object: table.clone(),
            props: change,
        },
    )
    .unwrap();
    let props = s.object_props(&table).unwrap();
    assert_eq!(props.repeat_header, Some(true));
    assert_eq!(props.caption.as_deref(), Some("RightCenter"));
    assert_eq!(
        (props.outer_margin_top, props.page_break),
        (Some(567), Some(2))
    );
    let cell = EditTarget {
        section: 0,
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: 0,
            paragraph: 0,
        }),
        note: None,
        header_footer: None,
    };
    let change = CellProps {
        vertical_align: Some(1),
        is_header: Some(true),
        ..Default::default()
    };
    run(
        &mut s,
        EditCommand::SetCell {
            cell: cell.clone(),
            props: change,
        },
    )
    .unwrap();
    let props = s.cell_props(&cell).unwrap();
    assert_eq!(
        (props.vertical_align, props.is_header),
        (Some(1), Some(true))
    );

    let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
    assert_eq!(
        reopened.object_props(&equation).unwrap().script.as_deref(),
        Some("a over b")
    );
    assert_eq!(
        reopened.object_props(&table).unwrap().repeat_header,
        Some(true)
    );

    run(
        &mut s,
        EditCommand::DeleteObject {
            object: equation.clone(),
        },
    )
    .unwrap();
    assert_eq!(s.placed(0).unwrap().len(), 1);
    run(&mut s, EditCommand::Undo).unwrap();
    assert_eq!(s.placed(0).unwrap().len(), 2);

    let preview = s.equation_preview("sqrt {x over 2}", 1_000, 0xff).unwrap();
    assert!(preview.width > 0.0 && preview.height > 0.0 && !preview.ops.is_empty());
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
        let reply = run(
            &mut s,
            EditCommand::Replace {
                selection,
                text: "X".into(),
            },
        )
        .unwrap();
        assert_eq!(s.paragraph(&body()).unwrap().text, "가X 문단");
        assert_eq!(s.paragraph(&body()).unwrap().count, 2);
        assert_eq!(
            reply.selection,
            Some(EditSelection::caret(point(body(), 2)))
        );
        run(&mut s, EditCommand::Undo).unwrap();
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
    let result = run(
        &mut s,
        EditCommand::Replace {
            selection,
            text: String::new(),
        },
    );
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
        let reply = run(
            &mut s,
            EditCommand::FormatText {
                selection: selection.clone(),
                style,
            },
        )
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
        run(&mut s, EditCommand::FormatParagraphs { selection, style }).unwrap();
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
fn borders_and_backgrounds_are_set_read_and_saved() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let selection = EditSelection {
            anchor: point(body(), 0),
            focus: point(body(), 1),
        };
        let text = CharStyle {
            border_line: Some(1),
            border_width: Some(3),
            border_color: Some("#0000FF".into()),
            fill_color: Some("#FFFF00".into()),
            pattern_color: Some("#000000".into()),
            pattern: Some(0),
            underline: Some(true),
            underline_top: Some(true),
            relative_size: Some(80.0),
            offset: Some(-10.0),
            ..Default::default()
        };
        let command = EditCommand::FormatText {
            selection: selection.clone(),
            style: text,
        };
        run(&mut s, command).unwrap();
        let paragraph = ParaStyle {
            border_line: Some(2),
            border_width: Some(1),
            border_color: Some("#ff0000".into()),
            fill_color: Some("none".into()),
            pattern_color: Some("#00ff00".into()),
            pattern: Some(3),
            border_connect: Some(true),
            ..Default::default()
        };
        let command = EditCommand::FormatParagraphs {
            selection: selection.clone(),
            style: paragraph,
        };
        run(&mut s, command).unwrap();
        let check = |s: &EditSession| {
            let at = s.format(s.revision, &point(body(), 1)).unwrap();
            let t = &at.text;
            assert_eq!(
                (t.border_line, t.border_width, t.border_color.as_deref()),
                (Some(1), Some(3), Some("#0000ff"))
            );
            assert_eq!(
                (t.fill_color.as_deref(), t.pattern),
                (Some("#ffff00"), Some(0))
            );
            assert_eq!(
                (t.underline_top, t.relative_size, t.offset),
                (Some(true), Some(80.0), Some(-10.0))
            );
            let p = &at.paragraph;
            assert_eq!((p.border_line, p.border_width), (Some(2), Some(1)));
            assert_eq!(
                (p.pattern, p.pattern_color.as_deref()),
                (Some(3), Some("#00ff00"))
            );
            assert_eq!(p.border_connect, Some(true));
        };
        check(&s);
        let saved = s
            .export(if format == "hwp" {
                SaveFormat::Hwp
            } else {
                SaveFormat::Hwpx
            })
            .unwrap();
        check(&EditSession::open(&saved).unwrap());
        // Half a set is refused.
        let half = CharStyle {
            border_line: Some(1),
            ..Default::default()
        };
        let command = EditCommand::FormatText {
            selection,
            style: half,
        };
        assert_eq!(run(&mut s, command).unwrap_err(), EditError::InvalidInput);
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
        let result = run(
            &mut s,
            EditCommand::FormatText {
                selection: selection.clone(),
                style,
            },
        );
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
            note: None,
            header_footer: None,
        })
        .find(|t| commands::get(s.core.document(), t).is_ok_and(commands::editable))
        .unwrap();
    for i in 0..5 {
        let t = Instant::now();
        replace(&mut s, target.clone(), i, i, "가").unwrap();
        eprintln!("keystroke {:?}, pages {:?}", t.elapsed(), s.changed);
    }
    let t = Instant::now();
    run(&mut s, EditCommand::Undo).unwrap();
    eprintln!("undo {:?}, pages {:?}", t.elapsed(), s.changed);
}
#[test]
fn amended_edits_share_one_undo_step() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let original = s.paragraph(&body()).unwrap().text;
    for (revision, text, amend) in [(0, "ㅎ", false), (1, "하", true), (2, "한", true)] {
        let start = point(body(), 0);
        let end = point(body(), if revision == 0 { 0 } else { 1 });
        s.apply(EditRequest {
            version: PROTOCOL_VERSION,
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
    let reply = run(&mut s, EditCommand::Undo).unwrap();
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
            version: PROTOCOL_VERSION,
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
        version: PROTOCOL_VERSION,
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
        note: None,
        header_footer: None,
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
        note: None,
        header_footer: None,
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
        note: None,
        header_footer: None,
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
        version: PROTOCOL_VERSION,
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
        note: None,
        header_footer: None,
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
                        note: None,
                        header_footer: None,
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
                position: position.clone(),
                rows: 2,
                columns: 2,
            });
            for endnote in [false, true] {
                commands.push(EditCommand::InsertNote {
                    position: position.clone(),
                    endnote,
                });
            }
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
            underline_color: Some("#ff0000".into()),
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
            (
                t.underline_shape,
                t.strike_shape,
                t.shade.as_deref(),
                t.underline_color.as_deref()
            ),
            (Some(2), Some(1), Some("#ffff00"), Some("#ff0000"))
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
#[test]
fn notes_are_inserted_and_edited() {
    for format in ["hwp", "hwpx"] {
        for endnote in [false, true] {
            let mut s = EditSession::open(&plain_document(format, false)).unwrap();
            let label = format!("{format} endnote={endnote}");
            let reply = run(
                &mut s,
                EditCommand::InsertNote {
                    position: point(body(), 1),
                    endnote,
                },
            )
            .unwrap();
            let caret = reply.selection.unwrap().focus;
            let note = caret.target.clone();
            assert!(note.note.is_some(), "{label}");
            assert_eq!(caret.scalar, 2, "{label}");
            replace(&mut s, note.clone(), 2, 2, "주석 글").unwrap();
            run(
                &mut s,
                EditCommand::Split {
                    position: point(note.clone(), 5),
                },
            )
            .unwrap();
            let second = commands::at_index(&note, 1);
            assert_eq!(s.paragraph(&second).unwrap().text, "글", "{label}");
            run(
                &mut s,
                EditCommand::MergePrevious {
                    position: point(second, 0),
                },
            )
            .unwrap();
            replace(&mut s, note.clone(), 4, 5, "").unwrap();
            assert_eq!(s.paragraph(&note).unwrap().text, "  주석글", "{label}");
            // The body keeps its text; the caret and a click find the note again.
            assert_eq!(
                s.paragraph(&body()).unwrap().text,
                "가\u{FFFC}👨‍👩‍👧‍👦e\u{301} 끝",
                "{label}"
            );
            let rect = s.caret(s.revision, &point(note.clone(), 3)).unwrap();
            if !endnote {
                let hit = s
                    .hit_test(
                        s.revision,
                        rect.page,
                        rect.x + 1.0,
                        rect.y + rect.height / 2.0,
                        false,
                    )
                    .unwrap();
                assert_eq!(hit.target, note, "{label}");
                let rects = s
                    .selection_rects(
                        s.revision,
                        &EditSelection {
                            anchor: point(note.clone(), 2),
                            focus: point(note.clone(), 4),
                        },
                    )
                    .unwrap();
                assert!(!rects.is_empty(), "{label}");
            }
            let saved = s
                .export(if format == "hwp" {
                    SaveFormat::Hwp
                } else {
                    SaveFormat::Hwpx
                })
                .unwrap();
            let reopened = EditSession::open(&saved).unwrap();
            assert!(
                reopened.paragraph(&note).unwrap().text.contains("주석"),
                "{label}"
            );
            for _ in 0..5 {
                run(&mut s, EditCommand::Undo).unwrap();
            }
            assert!(commands::get(s.core.document(), &note).is_err(), "{label}");
        }
    }
}

#[test]
fn marks_show_on_pages_but_not_in_the_pdf() {
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let plain = s.core.render_page_svg_native(0).unwrap();
    let pdf = s.export(SaveFormat::Pdf).unwrap();
    let reply = s.show_marks(true, true).unwrap();
    assert_eq!(reply.changed_pages, [0]);
    assert!(!reply.dirty && !reply.can_undo);
    let marked = s.core.render_page_svg_native(0).unwrap();
    assert_ne!(marked, plain);
    assert!(display::build(&marked).is_some(), "{marked}");
    assert_eq!(s.export(SaveFormat::Pdf).unwrap().len(), pdf.len());
    assert!(s.core.show_paragraph_marks);
    s.show_marks(false, false).unwrap();
    assert_eq!(s.core.render_page_svg_native(0).unwrap(), plain);
}
#[test]
fn cell_blocks_merge_split_and_equalize() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        let insert = EditCommand::InsertTable {
            position: point(body(), 0),
            rows: 3,
            columns: 3,
        };
        let caret = run(&mut s, insert).unwrap().selection.unwrap().focus;
        let host = caret.target.paragraph as usize;
        let at = |s: &EditSession, row: u16, col: u16| {
            let t = commands::table(s.core.document(), &caret.target).unwrap();
            let cell = t
                .cells
                .iter()
                .position(|c| (c.row, c.col) == (row, col))
                .unwrap();
            let mut target = caret.target.clone();
            target.cell.as_mut().unwrap().cell = cell as u32;
            point(target, 0)
        };
        let block = |s: &EditSession, from: (u16, u16), to: (u16, u16)| EditSelection {
            anchor: at(s, from.0, from.1),
            focus: at(s, to.0, to.1),
        };

        let square = block(&s, (1, 1), (0, 0));
        assert_eq!(s.selection_rects(s.revision, &square).unwrap().len(), 4);
        let merge = EditCommand::MergeCells { selection: square };
        run(&mut s, merge).unwrap();
        assert_eq!(table_shape(&s, host), (3, 3, 6));
        // A block cutting the merged cell grows to cover it.
        let cut = block(&s, (0, 0), (2, 0));
        assert_eq!(s.block(&cut).unwrap().cols, (0, 1));
        let split = EditCommand::SplitCells {
            selection: EditSelection::caret(at(&s, 0, 0)),
            rows: 2,
            columns: 2,
            equal_height: true,
            merge_first: false,
        };
        run(&mut s, split).unwrap();
        assert_eq!(table_shape(&s, host), (3, 3, 9));

        let widen = CellProps {
            width: Some(20_000),
            ..Default::default()
        };
        let first = at(&s, 0, 0).target;
        for row in 0..3 {
            let cell = at(&s, row, 0).target;
            run(
                &mut s,
                EditCommand::SetCell {
                    cell,
                    props: widen.clone(),
                },
            )
            .unwrap();
        }
        let widths = |s: &EditSession| {
            let t = commands::table(s.core.document(), &first).unwrap();
            (0..3)
                .map(|col| {
                    t.cells
                        .iter()
                        .find(|c| (c.row, c.col) == (0, col))
                        .unwrap()
                        .width
                })
                .collect::<Vec<_>>()
        };
        assert_ne!(widths(&s)[0], widths(&s)[1]);
        let even = EditCommand::EqualizeCells {
            selection: block(&s, (0, 0), (2, 2)),
            height: false,
        };
        run(&mut s, even).unwrap();
        let w = widths(&s);
        assert!(w.iter().all(|x| x.abs_diff(w[0]) <= 1), "{w:?}");
        let pages = s.export(if format == "hwp" {
            SaveFormat::Hwp
        } else {
            SaveFormat::Hwpx
        });
        assert!(pages.is_ok());
        run(&mut s, EditCommand::Undo).unwrap();
        assert_ne!(widths(&s)[0], widths(&s)[1]);
        let one = EditCommand::MergeCells {
            selection: EditSelection::caret(at(&s, 0, 0)),
        };
        assert_eq!(run(&mut s, one).unwrap_err(), EditError::InvalidInput);
    }
}

#[test]
fn table_borders_are_found_and_dragged() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        let insert = EditCommand::InsertTable {
            position: point(body(), 0),
            rows: 2,
            columns: 3,
        };
        let caret = run(&mut s, insert).unwrap().selection.unwrap().focus;
        let lines = s.table_lines(s.revision, 0).unwrap();
        let column = lines.iter().find(|l| !l.row && l.line == 0).unwrap();
        assert!(column.at > column.start && lines.iter().any(|l| l.row && l.line == 1));
        let table = column.table.clone();
        let sizes = |s: &EditSession| {
            let t = commands::table(s.core.document(), &caret.target).unwrap();
            (t.get_column_widths(), t.get_row_heights())
        };
        let (widths, heights) = sizes(&s);
        let wider = EditCommand::ResizeTable {
            table: table.clone(),
            row: false,
            line: 0,
            size: widths[0] + 2_000,
        };
        run(&mut s, wider).unwrap();
        let (w, _) = sizes(&s);
        // An inner border keeps the table's width.
        assert_eq!(
            (w[0], w[1], w[2]),
            (widths[0] + 2_000, widths[1] - 2_000, widths[2])
        );
        let taller = EditCommand::ResizeTable {
            table: table.clone(),
            row: true,
            line: 1,
            size: heights[1] + 3_000,
        };
        run(&mut s, taller).unwrap();
        assert_eq!(sizes(&s).1[1], heights[1] + 3_000);
        let crush = EditCommand::ResizeTable {
            table,
            row: false,
            line: 0,
            size: widths[0] + widths[1],
        };
        assert_eq!(run(&mut s, crush).unwrap_err(), EditError::InvalidInput);
        run(&mut s, EditCommand::Undo).unwrap();
        assert_eq!(sizes(&s).0[0], widths[0] + 2_000);
    }
}

#[test]
fn line_break_units_are_set_and_read() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let style = ParaStyle {
        korean_break_unit: Some(0),
        english_break_unit: Some(2),
        ..Default::default()
    };
    let selection = EditSelection::caret(point(body(), 0));
    run(&mut s, EditCommand::FormatParagraphs { selection, style }).unwrap();
    let format = s.format(s.revision, &point(body(), 0)).unwrap().paragraph;
    assert_eq!(
        (format.korean_break_unit, format.english_break_unit),
        (Some(0), Some(2))
    );
}

#[test]
fn styles_apply_to_paragraphs() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let styles = s.styles();
        assert!(styles.len() > 2 && !styles[0].name.is_empty());
        let selection = EditSelection {
            anchor: point(body(), 0),
            focus: point(commands::at_index(&body(), 2), 0),
        };
        run(
            &mut s,
            EditCommand::ApplyStyle {
                selection,
                style: 2,
            },
        )
        .unwrap();
        for p in [body(), commands::at_index(&body(), 2)] {
            assert_eq!(s.format(s.revision, &point(p, 0)).unwrap().style, 2);
        }
        let cell = EditTarget {
            section: 0,
            paragraph: 2,
            cell: Some(CellTarget {
                control: 0,
                cell: 0,
                paragraph: 0,
            }),
            note: None,
            header_footer: None,
        };
        let selection = EditSelection::caret(point(cell.clone(), 0));
        run(
            &mut s,
            EditCommand::ApplyStyle {
                selection,
                style: 1,
            },
        )
        .unwrap();
        assert_eq!(s.format(s.revision, &point(cell, 0)).unwrap().style, 1);
        let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
        assert_eq!(reopened.format(0, &point(body(), 0)).unwrap().style, 2);
        run(&mut s, EditCommand::Undo).unwrap();
        let wrong = EditCommand::ApplyStyle {
            selection: EditSelection::caret(point(body(), 0)),
            style: 9_999,
        };
        assert_eq!(run(&mut s, wrong).unwrap_err(), EditError::InvalidInput);
    }
}
#[test]
fn numbering_and_bullets_head_paragraphs() {
    // The generated HWP lays its body out past page 0; pages are checked in HWPX.
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let both = EditSelection {
        anchor: point(body(), 0),
        focus: point(commands::at_index(&body(), 2), 0),
    };
    let apply = |s: &mut EditSession, style: ParaStyle| {
        let command = EditCommand::FormatParagraphs {
            selection: both.clone(),
            style,
        };
        run(s, command).unwrap();
        // One `<text>` per character: the page's text in order.
        let svg = s.core.render_page_svg_native(0).unwrap();
        svg.split("</text>")
            .filter_map(|t| t.rsplit('>').next())
            .collect::<String>()
    };
    let number = ParaStyle {
        head: Some("Number".into()),
        numbering: Some(0),
        ..Default::default()
    };
    let text = apply(&mut s, number.clone());
    assert!(
        text.starts_with("1.가") && text.contains("2.보존"),
        "{text}"
    );
    let numberings = s.core.document().doc_info.numberings.len();
    apply(&mut s, number);
    assert_eq!(s.core.document().doc_info.numberings.len(), numberings);
    let deeper = ParaStyle {
        level: Some(1),
        ..Default::default()
    };
    let text = apply(&mut s, deeper);
    assert!(text.starts_with("가.가"), "{text}");
    let now = s.format(s.revision, &point(body(), 0)).unwrap().paragraph;
    assert_eq!((now.head.as_deref(), now.level), (Some("Number"), Some(1)));
    let bullet = ParaStyle {
        head: Some("Bullet".into()),
        bullet: Some("■".into()),
        ..Default::default()
    };
    assert!(apply(&mut s, bullet).contains('■'));
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        let head = reopened
            .format(0, &point(body(), 0))
            .unwrap()
            .paragraph
            .head;
        assert_eq!(head.as_deref(), Some("Bullet"), "{format:?}");
    }
    let none = ParaStyle {
        head: Some("None".into()),
        ..Default::default()
    };
    assert!(!apply(&mut s, none).contains('■'));
    let wrong = EditCommand::FormatParagraphs {
        selection: both.clone(),
        style: ParaStyle {
            head: Some("Number".into()),
            numbering: Some(99),
            ..Default::default()
        },
    };
    assert_eq!(run(&mut s, wrong).unwrap_err(), EditError::InvalidInput);
}
#[test]
fn shapes_are_drawn_selected_changed_and_deleted() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let shapes = ["textbox", "rectangle", "ellipse", "line", "arc"];
    for (i, shape) in shapes.iter().enumerate() {
        let insert = EditCommand::InsertShape {
            position: point(body(), 0),
            shape: shape.to_string(),
            x: 10_000,
            y: 20_000 + i as i32 * 8_000,
            width: 14_000,
            height: if *shape == "line" { 0 } else { 6_000 },
            flip: false,
        };
        run(&mut s, insert).unwrap_or_else(|e| panic!("{shape}: {e:?}"));
    }
    let placed = s.placed(0).unwrap();
    assert_eq!(placed.len(), shapes.len());
    assert!(placed.iter().all(|o| o.object.kind == ObjectKind::Shape));
    // 20 000 HWPUNIT from the paper's top is 266.7 px at 96 dpi.
    let first = placed
        .iter()
        .min_by(|a, b| a.rect.y.total_cmp(&b.rect.y))
        .unwrap();
    assert!(
        (first.rect.y - 266.7).abs() < 2.0 && (first.rect.x - 133.3).abs() < 2.0,
        "{first:?}"
    );
    let r = &first.rect;
    let hit = s
        .object_at(s.revision, 0, r.x + r.width / 2.0, r.y + r.height / 2.0)
        .unwrap();
    assert_eq!(hit.map(|o| o.object), Some(first.object.clone()));

    let wider = ObjectProps {
        width: Some(20_000),
        ..Default::default()
    };
    let shape = first.object.clone();
    run(
        &mut s,
        EditCommand::SetObject {
            object: shape.clone(),
            props: wider,
        },
    )
    .unwrap();
    assert_eq!(s.object_props(&shape).unwrap().width, Some(20_000));
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        assert_eq!(
            reopened.object_props(&shape).unwrap().width,
            Some(20_000),
            "{format:?}"
        );
    }
    run(&mut s, EditCommand::DeleteObject { object: shape }).unwrap();
    assert_eq!(s.placed(0).unwrap().len(), shapes.len() - 1);
    let bad = EditCommand::InsertShape {
        position: point(body(), 0),
        shape: "star".into(),
        x: 0,
        y: 0,
        width: 100,
        height: 100,
        flip: false,
    };
    assert_eq!(run(&mut s, bad).unwrap_err(), EditError::InvalidInput);
}
#[test]
fn text_boxes_take_text() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let insert = EditCommand::InsertShape {
        position: point(body(), 0),
        shape: "textbox".into(),
        x: 10_000,
        y: 30_000,
        width: 20_000,
        height: 8_000,
        flip: false,
    };
    run(&mut s, insert).unwrap();
    let placed = s.placed(0).unwrap().remove(0);
    let inside = EditTarget {
        section: 0,
        paragraph: placed.object.paragraph,
        cell: Some(CellTarget {
            control: placed.object.control,
            cell: 0,
            paragraph: 0,
        }),
        note: None,
        header_footer: None,
    };
    let r = &placed.rect;
    let hit = s
        .hit_test(s.revision, 0, r.x + 10.0, r.y + 10.0, false)
        .unwrap();
    assert_eq!(hit.target, inside);
    replace(&mut s, inside.clone(), 0, 0, "글상자").unwrap();
    run(
        &mut s,
        EditCommand::Split {
            position: point(inside.clone(), 3),
        },
    )
    .unwrap();
    let second = commands::at_index(&inside, 1);
    replace(&mut s, second.clone(), 0, 0, "둘째 줄").unwrap();
    assert_eq!(s.paragraph(&inside).unwrap().text, "글상자");
    assert_eq!(s.paragraph(&second).unwrap().text, "둘째 줄");
    let caret = s.caret(s.revision, &point(second.clone(), 2)).unwrap();
    assert!(
        caret.y > r.y && caret.y < r.y + r.height,
        "{caret:?} in {r:?}"
    );
    let format = s.format(s.revision, &point(second.clone(), 1)).unwrap();
    assert!(format.text_box);
    let rects = s
        .selection_rects(
            s.revision,
            &EditSelection {
                anchor: point(inside.clone(), 0),
                focus: point(inside.clone(), 3),
            },
        )
        .unwrap();
    assert_eq!(rects.len(), 1);
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        assert_eq!(
            reopened.paragraph(&second).unwrap().text,
            "둘째 줄",
            "{format:?}"
        );
    }
}

#[test]
fn pictures_and_equations_go_into_a_table_cell() {
    use base64::Engine;
    let png = base64::engine::general_purpose::STANDARD
        .decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        .unwrap();
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let insert = EditCommand::InsertTable {
        position: point(body(), 0),
        rows: 2,
        columns: 2,
    };
    let caret = run(&mut s, insert).unwrap().selection.unwrap().focus;
    let picture = EditCommand::InsertPicture {
        position: caret.clone(),
        data: base64::engine::general_purpose::STANDARD.encode(&png),
        width: 7_500,
        height: 7_500,
        natural_width: 1,
        natural_height: 1,
        extension: "png".into(),
        description: "cell.png".into(),
    };
    let after = run(&mut s, picture).unwrap().selection.unwrap().focus;
    assert_eq!(after, point(caret.target.clone(), 1));
    let equation = EditCommand::InsertEquation {
        position: after,
        script: "x^2".into(),
        font_size: 1000,
        color: 0,
    };
    let after = run(&mut s, equation).unwrap().selection.unwrap().focus;
    assert_eq!(after, point(caret.target.clone(), 2));
    assert_eq!(s.paragraph(&caret.target).unwrap().text, "\u{FFFC}\u{FFFC}");
    let placed: Vec<_> = s.placed(0).unwrap().into_iter().map(|o| o.object).collect();
    assert_eq!(placed.len(), 2);
    assert!(placed.iter().all(|o| o.cell == caret.target.cell));
    // Typing after both objects stays after them.
    replace(&mut s, caret.target.clone(), 2, 2, "끝").unwrap();
    assert_eq!(
        s.paragraph(&caret.target).unwrap().text,
        "\u{FFFC}\u{FFFC}끝"
    );
    let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
    assert_eq!(
        reopened.paragraph(&caret.target).unwrap().text,
        "\u{FFFC}\u{FFFC}끝"
    );
    for _ in 0..3 {
        run(&mut s, EditCommand::Undo).unwrap();
    }
    assert!(s.placed(0).unwrap().is_empty());
}

#[test]
fn a_table_cell_picture_resizes_deletes_undoes_and_round_trips_both_formats() {
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let extension = match format {
            SaveFormat::Hwp => "hwp",
            SaveFormat::Hwpx => "hwpx",
            SaveFormat::Pdf => unreachable!(),
        };
        let mut s = EditSession::open(&plain_document(extension, false)).unwrap();
        let caret = run(
            &mut s,
            EditCommand::InsertTable {
                position: point(body(), 0),
                rows: 1,
                columns: 1,
            },
        )
        .unwrap()
        .selection
        .unwrap()
        .focus;
        run(&mut s, picture_at(caret.clone())).unwrap();
        let object = s
            .placed(0)
            .unwrap()
            .into_iter()
            .find(|placed| placed.object.kind == ObjectKind::Picture)
            .unwrap()
            .object;
        assert_eq!(object.cell, caret.target.cell);

        run(
            &mut s,
            EditCommand::SetObject {
                object: object.clone(),
                props: ObjectProps {
                    width: Some(12_000),
                    height: Some(9_000),
                    ..Default::default()
                },
            },
        )
        .unwrap();
        run(
            &mut s,
            EditCommand::DeleteObject {
                object: object.clone(),
            },
        )
        .unwrap();
        assert!(s.placed(0).unwrap().is_empty(), "{format:?}");
        run(&mut s, EditCommand::Undo).unwrap();

        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        let reopened_object = reopened
            .placed(0)
            .unwrap()
            .into_iter()
            .find(|placed| placed.object.kind == ObjectKind::Picture)
            .unwrap()
            .object;
        assert_eq!(reopened_object.cell, caret.target.cell, "{format:?}");
        let props = reopened.object_props(&reopened_object).unwrap();
        assert_eq!(
            (props.width, props.height),
            (Some(12_000), Some(9_000)),
            "{format:?}"
        );
    }
}

#[test]
fn an_equation_moves_within_the_text() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        let insert = EditCommand::InsertEquation {
            position: point(body(), 1),
            script: "x^2".into(),
            font_size: 1000,
            color: 0,
        };
        run(&mut s, insert).unwrap();
        let host = 1;
        let find = |s: &EditSession, paragraph: usize| {
            s.core.document().sections[0].paragraphs[paragraph]
                .controls
                .iter()
                .position(|c| matches!(c, Control::Equation(_)))
        };
        let control = find(&s, host).unwrap() as u32;
        let object = ObjectRef {
            kind: ObjectKind::Equation,
            section: 0,
            paragraph: host as u32,
            control,
            cell: None,
        };
        for to in [point(body(), 0), point(commands::at_index(&body(), 0), 0)] {
            let target = to.target.paragraph as usize;
            let command = EditCommand::MoveObject {
                object: ObjectRef {
                    control: find(&s, host).unwrap_or(0) as u32,
                    ..object.clone()
                },
                to,
            };
            run(&mut s, command).unwrap();
            assert!(find(&s, target).is_some());
            let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
            assert!(reopened.core.document().sections[0].paragraphs[target]
                .controls
                .iter()
                .any(|c| matches!(c, Control::Equation(_))));
            run(&mut s, EditCommand::Undo).unwrap();
            assert!(find(&s, host).is_some());
        }
    }
}

#[test]
fn an_equation_in_a_table_cell_is_an_object() {
    // A table whose first cell holds the paragraph an equation was put in.
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    let mut doc = core.document().clone();
    let mut para = doc.sections[0].paragraphs[0].clone();
    para.controls.clear();
    doc.sections[0].paragraphs.push(para);
    core.set_document(doc);
    core.create_table_native(0, 1, 0, 1, 2).unwrap();
    core.insert_equation_native(0, 0, 0, "x^2", 1000, 0)
        .unwrap();
    let mut doc = core.document().clone();
    let paragraphs = &mut doc.sections[0].paragraphs;
    let with_equation = paragraphs[0].clone();
    let Control::Table(t) = paragraphs[1]
        .controls
        .iter_mut()
        .find(|c| matches!(c, Control::Table(_)))
        .unwrap()
    else {
        panic!()
    };
    t.cells[0].paragraphs[0] = with_equation;
    paragraphs.remove(0);
    core.set_document(doc);
    let mut s = EditSession::open(&core.export_hwpx_native().unwrap()).unwrap();
    let placed = s.placed(0).unwrap();
    let object = placed
        .iter()
        .find(|o| o.object.cell.is_some())
        .expect("the equation in the cell")
        .object
        .clone();
    assert_eq!(object.kind, ObjectKind::Equation);
    let props = ObjectProps {
        font_size: Some(2000),
        ..Default::default()
    };
    run(
        &mut s,
        EditCommand::SetObject {
            object: object.clone(),
            props,
        },
    )
    .unwrap();
    assert_eq!(s.object_props(&object).unwrap().font_size, Some(2000));
    let delete = EditCommand::DeleteObject {
        object: object.clone(),
    };
    run(&mut s, delete).unwrap();
    assert!(s.placed(0).unwrap().is_empty());
    run(&mut s, EditCommand::Undo).unwrap();
    run(&mut s, EditCommand::Undo).unwrap();
    assert_eq!(s.object_props(&object).unwrap().font_size, Some(1000));
}

/// A 1×1 PNG put in at `position`, 100 px square.
fn picture_at(position: EditPosition) -> EditCommand {
    EditCommand::InsertPicture {
        position,
        data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            .into(),
        width: 7_500,
        height: 7_500,
        natural_width: 1,
        natural_height: 1,
        extension: "png".into(),
        description: "p.png".into(),
    }
}
fn second() -> EditTarget {
    commands::at_index(&body(), 2)
}

#[test]
fn objects_in_the_line_are_positions_of_their_own() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        // 보존 문단, with 존 문단 bold.
        let bold = EditCommand::FormatText {
            selection: EditSelection {
                anchor: point(second(), 1),
                focus: point(second(), 5),
            },
            style: CharStyle {
                bold: Some(true),
                ..Default::default()
            },
        };
        run(&mut s, bold).unwrap();
        let shape = |s: &EditSession, text: usize| {
            commands::get(s.core.document(), &second())
                .unwrap()
                .char_shape_id_at(text)
        };
        let bold_shape = shape(&s, 1);
        let caret = run(&mut s, picture_at(point(second(), 1)))
            .unwrap()
            .selection
            .unwrap()
            .focus;
        assert_eq!(caret, point(second(), 2), "{format}");
        assert_eq!(s.paragraph(&second()).unwrap().text, "보\u{FFFC}존 문단");
        // The caret before and after the picture are its two sides, and a click on
        // either side finds them.
        // (The generated hwp lays the picture out on a later page.)
        let r = (0..s.core.page_count())
            .find_map(|page| s.placed(page).unwrap().first().map(|o| o.rect.clone()))
            .unwrap();
        let (before, after) = (
            s.caret(s.revision, &point(second(), 1)).unwrap(),
            s.caret(s.revision, &point(second(), 2)).unwrap(),
        );
        assert!((before.x - r.x).abs() < 1.0 && (after.x - (r.x + r.width)).abs() < 1.0);
        let y = r.y + r.height - 2.0;
        let hit = |x| {
            s.hit_test(s.revision, r.page, x, y, false)
                .unwrap()
                .scalar
        };
        assert_eq!(
            (hit(r.x - 2.0), hit(r.x + r.width + 2.0)),
            (1, 2),
            "{format}"
        );
        // Typing on each side stays on that side.
        replace(&mut s, second(), 2, 2, "뒤").unwrap();
        replace(&mut s, second(), 1, 1, "앞").unwrap();
        assert_eq!(
            s.paragraph(&second()).unwrap().text,
            "보앞\u{FFFC}뒤존 문단"
        );
        let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
        assert_eq!(
            reopened.paragraph(&second()).unwrap().text,
            "보앞\u{FFFC}뒤존 문단"
        );
        // Deleting over the picture takes it out; the text after keeps its shape.
        replace(&mut s, second(), 1, 4, "").unwrap();
        assert_eq!(s.paragraph(&second()).unwrap().text, "보존 문단");
        assert!(commands::get(s.core.document(), &second())
            .unwrap()
            .controls
            .is_empty());
        assert_eq!(shape(&s, 1), bold_shape, "{format}");
        for _ in 0..4 {
            run(&mut s, EditCommand::Undo).unwrap();
        }
        assert_eq!(s.paragraph(&second()).unwrap().text, "보존 문단");
    }
}

#[test]
fn a_picture_in_the_line_moves_within_the_text_and_into_a_cell() {
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let pictures = |s: &EditSession| s.core.document().bin_data_content.len();
    run(&mut s, picture_at(point(body(), 1))).unwrap();
    let stored = pictures(&s);
    let object = s.placed(0).unwrap()[0].object.clone();
    // 가[그림]👨‍👩‍👧‍👦é 끝 → before 끝.
    let to = run(
        &mut s,
        EditCommand::MoveObject {
            object,
            to: point(body(), 12),
        },
    )
    .unwrap()
    .selection
    .unwrap()
    .focus;
    assert_eq!(to, point(body(), 12));
    assert_eq!(
        s.paragraph(&body()).unwrap().text,
        "가👨‍👩‍👧‍👦e\u{301} \u{FFFC}끝"
    );
    // Into the table's first cell, after 표.
    let cell = EditTarget {
        section: 0,
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: 0,
            paragraph: 0,
        }),
        note: None,
        header_footer: None,
    };
    let object = s.placed(0).unwrap()[0].object.clone();
    run(
        &mut s,
        EditCommand::MoveObject {
            object,
            to: point(cell.clone(), 1),
        },
    )
    .unwrap();
    assert_eq!(s.paragraph(&cell).unwrap().text, "표\u{FFFC} 내용");
    assert_eq!(s.paragraph(&body()).unwrap().text, "가👨‍👩‍👧‍👦e\u{301} 끝");
    assert_eq!(s.placed(0).unwrap()[0].object.cell, cell.cell);
    // The picture keeps its one copy of the image.
    assert_eq!(pictures(&s), stored);
    let reopened = EditSession::open(&s.export(SaveFormat::Hwp).unwrap()).unwrap();
    assert_eq!(reopened.paragraph(&cell).unwrap().text, "표\u{FFFC} 내용");
    run(&mut s, EditCommand::Undo).unwrap();
    run(&mut s, EditCommand::Undo).unwrap();
    assert_eq!(
        s.paragraph(&body()).unwrap().text,
        "가\u{FFFC}👨‍👩‍👧‍👦e\u{301} 끝"
    );
}

#[test]
fn captions_are_written_and_edited() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    run(&mut s, picture_at(point(second(), 0))).unwrap();
    let object = s.placed(0).unwrap()[0].object.clone();
    let props = ObjectProps {
        caption: Some("Bottom".into()),
        ..Default::default()
    };
    run(
        &mut s,
        EditCommand::SetObject {
            object: object.clone(),
            props,
        },
    )
    .unwrap();
    // The caption is cell 0 of its picture, written 그림 and a number.
    let caption = EditTarget {
        cell: Some(CellTarget {
            control: object.control,
            cell: 0,
            paragraph: 0,
        }),
        ..second()
    };
    assert_eq!(s.paragraph(&caption).unwrap().text, "그림  ");
    replace(&mut s, caption.clone(), 4, 4, "꽃").unwrap();
    assert_eq!(s.paragraph(&caption).unwrap().text, "그림  꽃");
    // A click on it reaches it.
    let r = s.placed(0).unwrap()[0].rect.clone();
    let rect = s.caret(s.revision, &point(caption.clone(), 4)).unwrap();
    assert!(rect.y > r.y + r.height);
    let hit = s
        .hit_test(
            s.revision,
            0,
            rect.x + 1.0,
            rect.y + rect.height / 2.0,
            false,
        )
        .unwrap();
    assert_eq!(hit.target, caption);
    let reopened = EditSession::open(&s.export(SaveFormat::Hwp).unwrap()).unwrap();
    assert_eq!(reopened.paragraph(&caption).unwrap().text, "그림  꽃");

    // A table's caption is its cell `CAPTION`.
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let table = ObjectRef {
        kind: ObjectKind::Table,
        section: 0,
        paragraph: 2,
        control: 0,
        cell: None,
    };
    let props = ObjectProps {
        caption: Some("Top".into()),
        ..Default::default()
    };
    run(
        &mut s,
        EditCommand::SetObject {
            object: table,
            props,
        },
    )
    .unwrap();
    let caption = EditTarget {
        section: 0,
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: commands::CAPTION,
            paragraph: 0,
        }),
        note: None,
        header_footer: None,
    };
    let end = s.paragraph(&caption).unwrap().text.chars().count() as u32;
    replace(&mut s, caption.clone(), end, end, "목록").unwrap();
    assert!(s.paragraph(&caption).unwrap().text.ends_with("목록"));
}

#[test]
fn matches_after_an_object_are_found_where_they_are() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    run(&mut s, picture_at(point(second(), 1))).unwrap();
    let found = s.find("존", true).unwrap();
    assert_eq!(
        found[0],
        EditSelection {
            anchor: point(second(), 2),
            focus: point(second(), 3),
        }
    );
}

#[test]
fn every_line_after_an_object_keeps_its_positions() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let long = "가나다라마바사아자차카타파하 ".repeat(12);
    replace(&mut s, second(), 0, 5, &long).unwrap();
    let equation = EditCommand::InsertEquation {
        position: point(second(), 2),
        script: "x^2".into(),
        font_size: 1000,
        color: 0,
    };
    run(&mut s, equation).unwrap();
    let length = s.paragraph(&second()).unwrap().text.chars().count() as u32;
    let mut lines = std::collections::BTreeSet::new();
    for at in 0..=length {
        let r = s.caret(s.revision, &point(second(), at)).unwrap();
        lines.insert((r.y * 10.0) as i64);
        let hit = s
            .hit_test(
                s.revision,
                r.page,
                r.x + 0.3,
                r.y + r.height / 2.0,
                false,
            )
            .unwrap();
        assert_eq!(hit, point(second(), at));
    }
    assert!(lines.len() >= 3);
    // A selection on a later line is highlighted where its text is.
    let (a, b) = (length - 10, length - 5);
    let rects = s
        .selection_rects(
            s.revision,
            &EditSelection {
                anchor: point(second(), a),
                focus: point(second(), b),
            },
        )
        .unwrap();
    let (ca, cb) = (
        s.caret(s.revision, &point(second(), a)).unwrap(),
        s.caret(s.revision, &point(second(), b)).unwrap(),
    );
    assert_eq!(rects.len(), 1);
    assert!((rects[0].x - ca.x).abs() < 0.5 && (rects[0].x + rects[0].width - cb.x).abs() < 0.5);
    // Line start and end stay on the caret's line.
    let middle = point(second(), length - 7);
    let start = s
        .navigate(s.revision, &middle, Motion::LineStart, None)
        .unwrap();
    let end = s
        .navigate(s.revision, &middle, Motion::LineEnd, None)
        .unwrap();
    let here = s.caret(s.revision, &middle).unwrap();
    assert_eq!((start.caret.y, end.caret.y), (here.y, here.y));
    assert!(start.position.scalar < middle.scalar && middle.scalar < end.position.scalar);
}

#[test]
fn the_caret_passes_an_equation_in_a_cell() {
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let cell = EditTarget {
        section: 0,
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: 0,
            paragraph: 0,
        }),
        note: None,
        header_footer: None,
    };
    let equation = EditCommand::InsertEquation {
        position: point(cell.clone(), 1),
        script: "x^2".into(),
        font_size: 1000,
        color: 0,
    };
    run(&mut s, equation).unwrap();
    let r = s.placed(0).unwrap()[0].rect.clone();
    let before = s.caret(s.revision, &point(cell.clone(), 1)).unwrap();
    let after = s.caret(s.revision, &point(cell.clone(), 2)).unwrap();
    assert!((before.x - r.x).abs() < 1.0 && (after.x - (r.x + r.width)).abs() < 1.0);
    let y = r.y + r.height / 2.0;
    assert_eq!(
        s.hit_test(s.revision, 0, r.x + r.width + 1.0, y, false)
            .unwrap(),
        point(cell, 2)
    );
}
