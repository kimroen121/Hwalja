use super::*;
use rhwp::{
    model::{
        control::Control,
        header_footer::{Footer, Header, HeaderFooterApply},
        paragraph::{LineSeg, Paragraph},
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
    // Inserts that only reach the body never land in it from a 꼬리말 position.
    for command in [
        EditCommand::InsertTable {
            position: point(target.clone(), 0),
            rows: 1,
            columns: 1,
            width: None,
            height: None,
            treat_as_char: false,
        },
        EditCommand::InsertEquation {
            position: point(target.clone(), 0),
            script: "x".into(),
            font_size: 1000,
            color: 0,
        },
    ] {
        assert_eq!(
            s.validate_command(&command).unwrap_err(),
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

#[test]
fn header_footer_navigation_stays_in_its_definition() {
    let mut s = EditSession::blank().unwrap();
    s.core.create_header_footer_native(0, true, 0).unwrap();
    s.core
        .insert_text_in_header_footer_native(0, true, 0, 0, 0, "가👨‍👩‍👧‍👦e\u{301} 끝")
        .unwrap();
    s.core
        .split_paragraph_in_header_footer_native(0, true, 0, 0, 12, None)
        .unwrap();
    s.core
        .insert_text_in_header_footer_native(0, true, 0, 1, 0, "둘째 줄")
        .unwrap();
    let first = header_footer_target(false, 0, 0);
    let second = header_footer_target(false, 0, 1);

    let right = s
        .navigate(0, &point(first.clone(), 1), Motion::Right, None)
        .unwrap();
    assert_eq!(
        right.position.scalar, 8,
        "가족 emoji must remain one grapheme"
    );
    assert_eq!(right.position.target, first);

    let line_end = s
        .navigate(0, &point(first.clone(), 0), Motion::LineEnd, None)
        .unwrap();
    assert_eq!(line_end.position, point(first.clone(), 12));
    let down = s
        .navigate(0, &point(first.clone(), 0), Motion::Down, None)
        .unwrap();
    assert_eq!(down.position.target, second);
    let up = s
        .navigate(0, &down.position, Motion::Up, Some(down.goal_x))
        .unwrap();
    assert_eq!(up.position.target, first);

    let end = s
        .navigate(0, &point(first, 0), Motion::DocumentEnd, None)
        .unwrap();
    assert_eq!(end.position, point(second, 4));
}

#[test]
fn header_footer_selection_rejects_different_definitions() {
    let mut s = EditSession::blank().unwrap();
    s.core.create_header_footer_native(0, true, 0).unwrap();
    s.core.create_header_footer_native(0, false, 0).unwrap();
    let selection = EditSelection {
        anchor: point(header_footer_target(false, 0, 0), 0),
        focus: point(header_footer_target(true, 0, 0), 0),
    };
    assert_eq!(
        s.selection_rects(0, &selection).unwrap_err(),
        EditError::UnsupportedTarget
    );
}

#[test]
fn header_footer_replaces_splits_merges_formats_and_undoes_atomically() {
    let mut s = EditSession::blank().unwrap();
    s.core.create_header_footer_native(0, true, 0).unwrap();
    s.core
        .insert_text_in_header_footer_native(0, true, 0, 0, 0, "학교 머리말")
        .unwrap();
    let target = header_footer_target(false, 0, 0);
    let replaced = run(
        &mut s,
        EditCommand::Replace {
            selection: EditSelection {
                anchor: point(target.clone(), 0),
                focus: point(target.clone(), 2),
            },
            text: "우리👋".into(),
        },
    )
    .unwrap();
    assert_eq!(s.paragraph(&target).unwrap().text, "우리👋 머리말");
    assert_eq!(
        replaced.selection,
        Some(EditSelection::caret(point(target.clone(), 3)))
    );

    let split = run(
        &mut s,
        EditCommand::Split {
            position: point(target.clone(), 3),
        },
    )
    .unwrap();
    let second = header_footer_target(false, 0, 1);
    assert_eq!(
        split.selection,
        Some(EditSelection::caret(point(second.clone(), 0)))
    );
    assert_eq!(s.paragraph(&second).unwrap().text, " 머리말");
    run(
        &mut s,
        EditCommand::MergePrevious {
            position: point(second, 0),
        },
    )
    .unwrap();
    assert_eq!(s.paragraph(&target).unwrap().text, "우리👋 머리말");

    let selection = EditSelection {
        anchor: point(target.clone(), 0),
        focus: point(target.clone(), 2),
    };
    run(
        &mut s,
        EditCommand::FormatText {
            selection: selection.clone(),
            style: CharStyle {
                bold: Some(true),
                ..Default::default()
            },
        },
    )
    .unwrap();
    run(
        &mut s,
        EditCommand::FormatParagraphs {
            selection,
            style: ParaStyle {
                alignment: Some(Alignment::Center),
                ..Default::default()
            },
        },
    )
    .unwrap();
    let format = s
        .format(s.revision, &point(target.clone(), 1), None)
        .unwrap();
    assert_eq!(format.text.bold, Some(true));
    assert_eq!(format.paragraph.alignment, Some(Alignment::Center));

    command(&mut s, EditCommand::Undo).unwrap();
    assert_eq!(
        s.format(s.revision, &point(target, 1), None)
            .unwrap()
            .paragraph
            .alignment,
        Some(Alignment::Justify)
    );
}

#[test]
fn header_footer_find_returns_each_definition_once() {
    let mut s = EditSession::blank().unwrap();
    s.core.create_header_footer_native(0, true, 0).unwrap();
    s.core
        .insert_text_in_header_footer_native(0, true, 0, 0, 0, "과제 이름 과제")
        .unwrap();
    let hits = s.find("과제", true).unwrap();
    let header_hits: Vec<_> = hits
        .iter()
        .filter(|hit| hit.anchor.target.header_footer.is_some())
        .collect();
    assert_eq!(header_hits.len(), 2);
    assert_eq!(
        header_hits[0].anchor,
        point(header_footer_target(false, 0, 0), 0)
    );
    assert_eq!(header_hits[0].focus.scalar, 2);
    assert_eq!(header_hits[1].anchor.scalar, 6);
    assert_eq!(header_hits[1].focus.scalar, 8);
}

#[test]
fn header_footer_replace_spans_paragraphs_and_failed_edits_roll_back() {
    let mut s = EditSession::blank().unwrap();
    s.core.create_header_footer_native(0, false, 0).unwrap();
    s.core
        .insert_text_in_header_footer_native(0, false, 0, 0, 0, "첫 문단")
        .unwrap();
    s.core
        .split_paragraph_in_header_footer_native(0, false, 0, 0, 2, None)
        .unwrap();
    let first = header_footer_target(true, 0, 0);
    let second = header_footer_target(true, 0, 1);
    run(
        &mut s,
        EditCommand::Replace {
            selection: EditSelection {
                anchor: point(first.clone(), 1),
                focus: point(second.clone(), 1),
            },
            text: "새\n꼬리".into(),
        },
    )
    .unwrap();
    assert_eq!(s.paragraph(&first).unwrap().text, "첫새");
    assert_eq!(s.paragraph(&second).unwrap().text, "꼬리단");

    s.core.document_mut().sections[0].paragraphs[0]
        .controls
        .iter_mut()
        .find_map(|control| match control {
            Control::Footer(footer) => Some(&mut footer.paragraphs[0].text),
            _ => None,
        })
        .unwrap()
        .insert(3, '\u{0015}');
    let before = s.paragraph(&first).unwrap().text;
    let revision = s.revision;
    assert_eq!(
        replace(&mut s, first.clone(), 0, 2, "금지").unwrap_err(),
        EditError::UnsupportedTarget
    );
    assert_eq!(
        (s.paragraph(&first).unwrap().text, s.revision),
        (before, revision)
    );
}

#[test]
fn header_footer_text_and_format_round_trip_hwp_and_hwpx() {
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let mut prepared = EditSession::blank().unwrap();
        run(
            &mut prepared,
            EditCommand::HeaderFooter {
                section: 0,
                footer: false,
                page_number: Some(Placement::Center),
            },
        )
        .unwrap();
        prepared
            .core
            .create_header_footer_native(0, true, 1)
            .unwrap();
        prepared
            .core
            .insert_text_in_header_footer_native(0, true, 1, 0, 0, "짝수 e\u{301}")
            .unwrap();
        prepared
            .core
            .create_header_footer_native(0, false, 2)
            .unwrap();
        prepared
            .core
            .insert_text_in_header_footer_native(0, false, 2, 0, 0, "홀수 👋")
            .unwrap();
        let source = prepared.export(format).unwrap();
        let mut s = EditSession::open(&source).unwrap();
        let even = header_footer_target(false, 1, 0);
        replace(&mut s, even.clone(), 0, 2, "교정").unwrap();
        run(
            &mut s,
            EditCommand::FormatParagraphs {
                selection: EditSelection::caret(point(even.clone(), 0)),
                style: ParaStyle {
                    alignment: Some(Alignment::Center),
                    ..Default::default()
                },
            },
        )
        .unwrap();
        let bytes = s.export(format).unwrap();
        let reopened = EditSession::open(&bytes).unwrap();
        assert_eq!(reopened.paragraph(&even).unwrap().text, "교정 e\u{301}");
        assert_eq!(
            reopened
                .format(0, &point(even, 1), None)
                .unwrap()
                .paragraph
                .alignment,
            Some(Alignment::Center)
        );
        assert!(reopened
            .core
            .render_page_svg_native(0)
            .unwrap()
            .contains(">1<"));
        assert_eq!(
            reopened
                .paragraph(&header_footer_target(true, 2, 0))
                .unwrap()
                .text,
            "홀수 👋"
        );
    }
}

#[test]
fn editing_imported_header_marks_reflowed_lines_as_synthetic() {
    let mut s = EditSession::blank().unwrap();
    s.core.create_header_footer_native(0, true, 0).unwrap();
    s.core
        .insert_text_in_header_footer_native(0, true, 0, 0, 0, "학교 ")
        .unwrap();

    // Reproduce an imported header whose LINE_SEG rows are stored evidence.
    // Once its text changes, those rows no longer describe the file and the
    // reflow must publish synthetic provenance.
    let mut document = s.core.document().clone();
    let imported_header = document.sections[0].paragraphs[0]
        .controls
        .iter_mut()
        .find_map(|control| match control {
            Control::Header(header) if header.apply_to == HeaderFooterApply::Both => {
                header.paragraphs.first_mut()
            }
            _ => None,
        })
        .unwrap();
    for line in &mut imported_header.line_segs {
        line.tag &= !LineSeg::TAG_IMPLEMENTATION_PROPERTY;
    }
    s.core.set_document(document);
    s.core
        .insert_text_in_header_footer_native(0, true, 0, 0, 3, "머리말")
        .unwrap();

    let para = s.core.document().sections[0].paragraphs[0]
        .controls
        .iter()
        .find_map(|control| match control {
            Control::Header(header) if header.apply_to == HeaderFooterApply::Both => {
                header.paragraphs.first()
            }
            _ => None,
        })
        .unwrap();
    assert!(
        para.line_segs
            .iter()
            .all(|line| line.tag & LineSeg::TAG_IMPLEMENTATION_PROPERTY != 0),
        "edited header/footer rows must not retain imported LINE_SEG provenance"
    );
}
fn point(target: EditTarget, scalar: u32) -> EditPosition {
    EditPosition {
        target,
        scalar,
        upstream: false,
    }
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
            version: PROTOCOL_VERSION,
            revision: 0,
            command: command("새"),
            amend: false,
        })
        .is_ok());
    assert!(matches!(
        s.apply(EditRequest {
            version: PROTOCOL_VERSION - 1,
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
/// A click just right of a 머리말 caret position lands on that position, as in the body.
#[test]
fn header_hit_test_and_caret_round_trip() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    run(
        &mut s,
        EditCommand::HeaderFooter {
            section: 0,
            footer: false,
            page_number: None,
        },
    )
    .unwrap();
    let header = header_footer_target(false, 0, 0);
    replace(&mut s, header.clone(), 0, 0, "학교 머리말").unwrap();
    for scalar in 0..=6 {
        let caret = s.caret(s.revision, &point(header.clone(), scalar)).unwrap();
        let hit = s
            .hit_test(
                s.revision,
                caret.page,
                caret.x + 1.0,
                caret.y + caret.height / 2.0,
                true,
            )
            .unwrap();
        assert_eq!(hit.scalar, scalar);
    }
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
        let request = format!(
            r#"{{"op":"apply","request":{{"version":{PROTOCOL_VERSION},"revision":0,"command":{{"kind":"replace","selection":{{"anchor":{{"target":{{"section":0,"paragraph":1,"cell":null}},"scalar":0}},"focus":{{"target":{{"section":0,"paragraph":1,"cell":null}},"scalar":0}}}},"text":"x"}}}}}}"#
        );
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
fn inserting_a_small_inline_picture_does_not_add_a_page() {
    for format in ["hwp", "hwpx"] {
        let mut session = EditSession::open(&plain_document(format, false)).unwrap();
        let pages_before = session.core.page_count();
        run(&mut session, picture_at(point(body(), 1))).unwrap();
        assert_eq!(
            session.core.page_count(),
            pages_before,
            "a 100 px inline picture fits the existing page ({format})"
        );
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
        note: None,
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
fn equation_shorthands_and_underover_draw_as_hancom_does() {
    let core = DocumentCore::new_empty();
    let svg = |script: &str| {
        core.render_equation_preview_native(script, 1_000, 0)
            .unwrap()
    };
    for (script, symbol) in [
        ("p=+-T_n", "±"),
        ("a-+b", "∓"),
        ("x<=1", "≤"),
        ("x>=1", "≥"),
        ("a!=b", "≠"),
    ] {
        assert!(svg(script).contains(symbol), "{script}");
    }
    // 한글's limits: `from` and `to`, not words; LaTeX's `\to` stays an arrow.
    for script in [
        "sum from {i=1} to {n} i",
        "int from a to b x",
        "lim from {x -> 0} f",
    ] {
        let drawn = svg(script);
        assert!(
            !drawn.contains(">from<") && !drawn.contains(">to<"),
            "{script}"
        );
        assert!(!drawn.contains(">→<") || script.contains("->"), "{script}");
    }
    assert!(svg("x \\to y").contains("→"));
    // The limits go under and over the base, not after it as text.
    let under = svg("UNDEROVER {max}_{[-1,1]}^{} q");
    assert!(!under.contains(">UNDEROVER<"));
    let y = |text: &str| {
        let at = under.find(&format!(">{text}<")).unwrap();
        let tag = &under[under[..at].rfind("<text").unwrap()..at];
        let y = &tag[tag.find(" y=\"").unwrap() + 4..];
        y[..y.find('"').unwrap()].parse::<f64>().unwrap()
    };
    assert!(y("1") > y("max"));
}

#[test]
fn integral_path_is_tall_slender_and_light() {
    let core = DocumentCore::new_empty();
    let svg = core
        .render_equation_preview_native("int from 0 to 1 x", 1_000, 0)
        .unwrap();
    // The ∫ is one filled outline: STIX Two Math's upright display integral, or the stroke
    // drawn without that font.
    let tag = svg.split("<path").nth(1).expect("integral path");
    let d = tag.split("d=\"").nth(1).unwrap().split('"').next().unwrap();
    let points: Vec<f64> = d
        .split(|c: char| !(c.is_ascii_digit() || matches!(c, '.' | '-')))
        .filter(|part| !part.is_empty())
        .map(|part| part.parse().unwrap())
        .collect();
    let span = |k: usize| {
        let v = points.iter().skip(k).step_by(2);
        v.clone().copied().fold(f64::NEG_INFINITY, f64::max)
            - v.copied().fold(f64::INFINITY, f64::min)
    };
    let (width, height) = (span(0), span(1));
    assert!(width / height < 0.25, "too wide: {width}/{height}");
}

/// A file written without line records (by another program) is laid out on opening, its
/// lines as tall as the equations in them.
#[test]
fn paragraphs_without_line_records_are_laid_out_with_their_equations() {
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    core.insert_text_native(0, 0, 0, "앞 글자 뒤").unwrap();
    core.insert_equation_native(0, 0, 2, "{a+b} over {c+d}", 1000, 0)
        .unwrap();
    core.split_paragraph_native(0, 0, 6, None).unwrap();
    core.insert_text_native(0, 1, 0, "다음 문단").unwrap();
    let mut doc = core.document().clone();
    for p in &mut doc.sections[0].paragraphs {
        p.line_segs.clear();
    }
    core.set_document(doc);
    let s = EditSession::open(&core.export_hwp_native().unwrap()).unwrap();
    assert!(s.core.document().sections[0]
        .paragraphs
        .iter()
        .all(|p| !p.line_segs.is_empty()));
    let controls: serde_json::Value =
        serde_json::from_str(&s.core.get_page_control_layout_native(0).unwrap()).unwrap();
    let equation = controls["controls"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["type"] == "equation")
        .unwrap();
    let runs: serde_json::Value =
        serde_json::from_str(&s.core.get_page_text_layout_native(0).unwrap()).unwrap();
    let next = runs["runs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["paraIdx"] == 1)
        .unwrap();
    let bottom = equation["y"].as_f64().unwrap() + equation["h"].as_f64().unwrap();
    assert!(next["y"].as_f64().unwrap() >= bottom - 0.5);
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
        let at = s.format(1, &point(body(), 1), None).unwrap();
        assert_eq!(at.text.font.as_deref(), Some("Apple SD Gothic Neo"));
        assert_eq!((at.text.size, at.text.bold), (Some(20.0), Some(true)));
        assert_eq!(at.text.color.as_deref(), Some("#ff0000"));
        assert!(!at.fonts.is_empty());
        let after = s.format(1, &point(body(), 3), None).unwrap();
        assert_eq!(after.text.bold, Some(false));

        let style = ParaStyle {
            alignment: Some(Alignment::Center),
            line_spacing: Some(200.0),
            line_spacing_kind: Some(LineSpacingKind::Percent),
            ..Default::default()
        };
        run(&mut s, EditCommand::FormatParagraphs { selection, style }).unwrap();
        let at = s.format(2, &point(body(), 0), None).unwrap();
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
        let at = reopened.format(0, &point(body(), 1), None).unwrap();
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
            let at = s.format(s.revision, &point(body(), 1), None).unwrap();
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

/// `HWP_WRITE_FIXTURES=1` writes the hwp one, locked with 1234, as Tests/Fixtures/locked.hwp.
#[test]
fn a_document_locked_with_a_password_opens_with_it_and_saves_locked() {
    for format in ["hwp", "hwpx"] {
        let plain = DocumentCore::from_bytes(&plain_document(format, false)).unwrap();
        let mut core = plain;
        let locked = if format == "hwp" {
            core.export_hwp_with_adapter_with_password(b"1234").unwrap()
        } else {
            core.export_hwpx_native_with_password(b"1234").unwrap()
        };
        assert_eq!(
            EditSession::open(&locked).err(),
            Some(EditError::PasswordRequired),
            "{format}"
        );
        assert_eq!(
            EditSession::open_with(&locked, Some(b"0000")).err(),
            Some(EditError::PasswordRequired),
            "{format}"
        );
        let mut s = EditSession::open_with(&locked, Some(b"1234")).unwrap();
        assert!(
            s.core.document().sections[0].paragraphs[2]
                .text
                .contains("보존 문단"),
            "{format}"
        );
        let saved = s
            .export(if format == "hwp" {
                SaveFormat::Hwp
            } else {
                SaveFormat::Hwpx
            })
            .unwrap();
        assert_eq!(
            EditSession::open(&saved).err(),
            Some(EditError::PasswordRequired),
            "{format}"
        );
        assert!(
            EditSession::open_with(&saved, Some(b"1234")).is_ok(),
            "{format}"
        );
        if format == "hwp" && std::env::var_os("HWP_WRITE_FIXTURES").is_some() {
            let folder =
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Tests/Fixtures");
            std::fs::write(folder.join("locked.hwp"), &locked).unwrap();
        }
    }
}
/// An empty 머리말 is entered anywhere in its area, not only on its one short line; the
/// body below stays the body.
#[test]
fn an_empty_header_is_entered_anywhere_in_its_area() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    s.core.create_header_footer_native(0, true, 0).unwrap();
    // The header area runs from 75.6 to 132.3 px; its empty line ends near 88.
    let hit = s.hit_test(s.revision, 0, 300.0, 120.0, true).unwrap();
    assert!(hit.target.header_footer.is_some_and(|hf| !hf.footer));
    let below = s.hit_test(s.revision, 0, 300.0, 200.0, true).unwrap();
    assert!(below.target.header_footer.is_none());
    // With only a 꼬리말, the 머리말 area is the body's.
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    s.core.create_header_footer_native(0, false, 0).unwrap();
    let hit = s.hit_test(s.revision, 0, 300.0, 120.0, true).unwrap();
    assert!(hit.target.header_footer.is_none());
}
/// 새 번호로 시작, 현재 쪽만 감추기, 책갈피 and 조판 부호 지우기 change only their codes, and
/// stay through saving; 문서 통계 counts the text.
#[test]
fn page_codes_bookmarks_and_erasing_survive_saving() {
    for format in ["hwp", "hwpx"] {
        let save = if format == "hwp" {
            SaveFormat::Hwp
        } else {
            SaveFormat::Hwpx
        };
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let at = |paragraph, scalar| {
            point(
                EditTarget {
                    paragraph,
                    ..body()
                },
                scalar,
            )
        };
        for number in [3, 5] {
            run(
                &mut s,
                EditCommand::NewNumber {
                    position: at(1, 1),
                    numbering: NumberKind::Picture,
                    number,
                },
            )
            .unwrap();
        }
        let hide = PageHide {
            header: true,
            page_number: true,
            ..Default::default()
        };
        run(
            &mut s,
            EditCommand::SetPageHide {
                target: at(1, 0).target,
                hide,
            },
        )
        .unwrap();
        run(
            &mut s,
            EditCommand::AddBookmark {
                position: at(1, 1),
                name: "가".into(),
            },
        )
        .unwrap();
        assert!(run(
            &mut s,
            EditCommand::AddBookmark {
                position: at(1, 0),
                name: "가".into()
            }
        )
        .is_err());
        let mark = s.bookmarks().remove(0);
        assert_eq!((mark.name.as_str(), mark.position.scalar), ("가", 1));
        run(
            &mut s,
            EditCommand::ChangeBookmark {
                target: mark.position.target.clone(),
                control: mark.control,
                name: Some("나".into()),
            },
        )
        .unwrap();
        let stats = s.statistics();
        assert_eq!(
            (stats.tables, stats.paragraphs > 3, stats.characters > 10),
            (1, true, true),
            "{format}"
        );

        let mut s = EditSession::open(&s.export(save).unwrap()).unwrap();
        let numbers: Vec<_> = s.core.document().sections[0].paragraphs[1]
            .controls
            .iter()
            .filter_map(|c| match c {
                Control::NewNumber(n) => Some((n.number_type, n.number)),
                _ => None,
            })
            .collect();
        assert_eq!(
            numbers,
            [(rhwp::model::control::AutoNumberType::Picture, 5)],
            "{format}"
        );
        assert_eq!(s.page_hide(&at(1, 0).target).unwrap(), hide, "{format}");
        assert_eq!(
            s.bookmarks()
                .iter()
                .map(|b| b.name.as_str())
                .collect::<Vec<_>>(),
            ["나"],
            "{format}"
        );

        let kinds = vec![
            CodeKind::Table,
            CodeKind::PageHide,
            CodeKind::NewNumber(NumberKind::Picture),
        ];
        run(
            &mut s,
            EditCommand::EraseCodes {
                selection: None,
                kinds: kinds.clone(),
            },
        )
        .unwrap();
        assert!(
            codes::codes(s.core.document(), None, &kinds).is_empty(),
            "{format}"
        );
        assert_eq!(s.bookmarks().len(), 1, "{format}");
        run(&mut s, EditCommand::Undo).unwrap();
        assert_eq!(
            codes::codes(s.core.document(), None, &kinds).len(),
            3,
            "{format}"
        );
        let mark = s.bookmarks().remove(0);
        let text = s.paragraph(&mark.position.target).unwrap().text;
        run(
            &mut s,
            EditCommand::ChangeBookmark {
                target: mark.position.target.clone(),
                control: mark.control,
                name: None,
            },
        )
        .unwrap();
        assert!(s.bookmarks().is_empty(), "{format}");
        assert_eq!(
            s.paragraph(&mark.position.target).unwrap().text,
            text,
            "{format}"
        );
    }
}
/// `HWP_RENDER=<file> HWP_RENDER_DIR=<folder> cargo test render_pages -- --ignored`: each
/// page as rhwp draws it, and the PDF, for a look.
#[test]
#[ignore]
fn render_pages() {
    let bytes = std::fs::read(std::env::var("HWP_RENDER").unwrap()).unwrap();
    let folder = std::path::PathBuf::from(std::env::var("HWP_RENDER_DIR").unwrap());
    let s = EditSession::open(&bytes).unwrap();
    for page in 0..s.core.page_count() {
        let svg = s.core.render_page_svg_native(page).unwrap();
        std::fs::write(folder.join(format!("page-{}.svg", page + 1)), svg).unwrap();
    }
    let mut s = s;
    std::fs::write(folder.join("pages.pdf"), s.export(SaveFormat::Pdf).unwrap()).unwrap();
}

#[test]
fn color_emoji_svg_fits_each_glyph_to_its_layout_advance() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let end = s.paragraph(&body()).unwrap().text.chars().count() as u32;
    replace(&mut s, body(), 0, end, "📣😄📖").unwrap();
    let svg = s.core.render_page_svg_native(0).unwrap();
    for glyph in ["📣", "😄", "📖"] {
        let line = svg
            .lines()
            .find(|line| line.contains(&format!(">{glyph}</text>")))
            .unwrap_or_else(|| panic!("missing {glyph} in page SVG"));
        assert!(
            line.contains("textLength=") && line.contains("lengthAdjust=\"spacingAndGlyphs\""),
            "fallback color glyph must be fitted to its HWP layout slot: {line}"
        );
    }
}
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
    let at = s.format(3, &point(body(), 1), None).unwrap();
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
    let first = s.format(2, &point(body(), 1), None).unwrap();
    let later = s.format(2, &point(body(), 12), None).unwrap();
    assert_eq!(
        (first.text.color.as_deref(), first.text.size),
        (Some("#ff0000"), Some(20.0))
    );
    assert_eq!(
        (later.text.color.as_deref(), later.text.size),
        (Some("#000000"), Some(20.0))
    );
    // Over both runs the color is mixed; the size is not.
    let span = s
        .format(2, &point(body(), 12), Some(&point(body(), 0)))
        .unwrap();
    assert_eq!((span.text.color, span.text.size), (None, Some(20.0)));
    let red = s
        .format(2, &point(body(), 0), Some(&point(body(), 1)))
        .unwrap();
    assert_eq!(red.text.color.as_deref(), Some("#ff0000"));
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
    // A wrapped line ends where the next starts, after its last character.
    assert_eq!(end.position.scalar, line_start.position.scalar);
    assert!(end.position.upstream && !line_start.position.upstream);
    assert_eq!(end.caret.y, s.caret(0, &start).unwrap().y);
    let before = point(first.clone(), end.position.scalar - 1);
    assert!(end.caret.x > s.caret(0, &before).unwrap().x);
    assert!(end.caret.x > go(&s, end.position.clone(), Motion::Left, None).caret.x);
    // Up and down from there keep its column.
    let below = go(&s, end.position.clone(), Motion::Down, None);
    assert!(below.caret.y > end.caret.y);
    assert!((below.goal_x - end.caret.x).abs() < 0.5);
    assert_eq!(go(&s, start, Motion::LineStart, None).position.scalar, 0);
    // A click past the line's end is there too.
    let hit = s
        .hit_test(0, 0, end.caret.x + 30.0, end.caret.y + 5.0, false)
        .unwrap();
    assert_eq!(hit, end.position);
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
                    width: None,
                    height: None,
                    treat_as_char: false,
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
/// After an object in the paragraph, the text before the caret stays above the table.
#[test]
fn a_table_after_an_object_splits_where_the_caret_is() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let all = s.paragraph(&body()).unwrap().text.chars().count() as u32;
    replace(&mut s, body(), 0, all, "가나다라").unwrap();
    run(
        &mut s,
        EditCommand::InsertEquation {
            position: point(body(), 1),
            script: "x".into(),
            font_size: 1000,
            color: 0,
        },
    )
    .unwrap();
    for (scalar, before, after) in [(5, "가\u{FFFC}나다라", ""), (3, "가\u{FFFC}나", "다라")]
    {
        let mut s = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
        let reply = run(
            &mut s,
            EditCommand::InsertTable {
                position: point(body(), scalar),
                rows: 1,
                columns: 1,
                width: None,
                height: None,
                treat_as_char: false,
            },
        )
        .unwrap();
        let table = reply.selection.unwrap().focus.target.paragraph;
        assert_eq!(s.paragraph(&body()).unwrap().text, before, "{scalar}");
        let rest = (table + 1..table + 3)
            .map(|i| {
                s.paragraph(&commands::at_index(&body(), i as usize))
                    .unwrap()
                    .text
            })
            .collect::<String>();
        assert_eq!(rest, after, "{scalar}");
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
    // A cell named in a 머리말 is never taken for the body table at the same place, which
    // rhwp's table functions would change instead.
    let mut in_header = cell(0);
    in_header.header_footer = Some(HeaderFooterTarget {
        footer: false,
        apply_to: 0,
        page: 0,
    });
    assert!(commands::table(s.core.document(), &cell(0)).is_some());
    assert!(commands::table(s.core.document(), &in_header).is_none());
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
fn splits_and_attaches_tables() {
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let cell = |paragraph, index| EditTarget {
        section: 0,
        paragraph,
        cell: Some(CellTarget {
            control: 0,
            cell: index,
            paragraph: 0,
        }),
        note: None,
        header_footer: None,
    };
    let table = |s: &mut EditSession, cell, change| run(s, EditCommand::EditTable { cell, change });
    table(&mut s, cell(2, 0), TableChange::InsertRowBelow).unwrap();
    // Not from the first row, as in 한/글.
    assert!(table(&mut s, cell(2, 0), TableChange::Split).is_err());
    let reply = table(&mut s, cell(2, 2), TableChange::Split).unwrap();
    assert_eq!(reply.selection.unwrap().focus.target.paragraph, 4);
    assert_eq!(
        (table_shape(&s, 2), table_shape(&s, 4)),
        ((1, 2, 2), (1, 2, 2))
    );
    table(&mut s, cell(2, 0), TableChange::Attach).unwrap();
    assert_eq!(table_shape(&s, 2), (2, 2, 4));
    // Nothing follows to attach.
    assert!(table(&mut s, cell(2, 0), TableChange::Attach).is_err());
    s.export(SaveFormat::Hwpx).unwrap();
}
#[test]
fn flips_and_turns_tables() {
    for (turn, rows) in [
        (TableTurn::Rows, vec!["def", "abc"]),
        (TableTurn::Columns, vec!["cba", "fed"]),
        (TableTurn::Diagonal, vec!["ad", "be", "cf"]),
        (TableTurn::Left, vec!["cf", "be", "ad"]),
        (TableTurn::Half, vec!["fed", "cba"]),
        (TableTurn::Right, vec!["da", "eb", "fc"]),
    ] {
        let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
        let insert = EditCommand::InsertTable {
            position: point(body(), 0),
            rows: 2,
            columns: 3,
            width: None,
            height: None,
            treat_as_char: false,
        };
        let caret = run(&mut s, insert).unwrap().selection.unwrap().focus;
        let at = |i: usize| {
            let mut target = caret.target.clone();
            target.cell.as_mut().unwrap().cell = i as u32;
            target
        };
        for (i, text) in ["a", "b", "c", "d", "e", "f"].iter().enumerate() {
            let cell = at(i);
            replace(&mut s, cell, 0, 0, text).unwrap();
        }
        let size = |s: &EditSession| {
            let t = commands::table(s.core.document(), &caret.target).unwrap();
            (
                t.get_column_widths().iter().sum::<u32>(),
                t.get_row_heights().iter().sum::<u32>(),
            )
        };
        let (width, height) = size(&s);
        // The caret in "b" stays in it.
        let reply = run(
            &mut s,
            EditCommand::FlipTable {
                cell: at(1),
                turn,
                margins: true,
            },
        )
        .unwrap_or_else(|e| panic!("{turn:?}: {e:?}"));
        let read = |s: &EditSession| {
            let t = commands::table(s.core.document(), &caret.target).unwrap();
            (0..t.row_count)
                .map(|r| {
                    (0..t.col_count)
                        .map(|c| t.cell_at(r, c).unwrap().paragraphs[0].text.clone())
                        .collect::<String>()
                })
                .collect::<Vec<_>>()
        };
        assert_eq!(read(&s), rows, "{turn:?}");
        let focus = reply.selection.unwrap().focus.target;
        assert_eq!(s.paragraph(&focus).unwrap().text, "b", "{turn:?}");
        let turned = matches!(
            turn,
            TableTurn::Diagonal | TableTurn::Left | TableTurn::Right
        );
        // The width stays; with rows and columns swapped, every row is as tall as the tallest.
        let (new_width, new_height) = size(&s);
        assert_eq!(new_width, width, "{turn:?}");
        if turned {
            assert_eq!(new_height, height / 2 * 3, "{turn:?}");
        } else {
            assert_eq!(new_height, height, "{turn:?}");
        }
        let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
        assert_eq!(read(&reopened), rows, "{turn:?}");
    }
    // A merged cell turns with its span: "ab" across the top goes down the right.
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let insert = EditCommand::InsertTable {
        position: point(body(), 0),
        rows: 2,
        columns: 3,
        width: None,
        height: None,
        treat_as_char: false,
    };
    let caret = run(&mut s, insert).unwrap().selection.unwrap().focus;
    let mut second = caret.clone();
    second.target.cell.as_mut().unwrap().cell = 1;
    run(
        &mut s,
        EditCommand::MergeCells {
            selection: EditSelection {
                anchor: caret.clone(),
                focus: second,
            },
        },
    )
    .unwrap();
    run(
        &mut s,
        EditCommand::FlipTable {
            cell: caret.target.clone(),
            turn: TableTurn::Right,
            margins: false,
        },
    )
    .unwrap();
    let t = commands::table(s.core.document(), &caret.target).unwrap();
    let merged = t.cell_at(0, 1).unwrap();
    assert_eq!(
        (t.row_count, t.col_count, merged.row_span, merged.col_span),
        (3, 2, 2, 1)
    );
}
#[test]
fn sets_paper_and_margins() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let mut page = s.page_setup(0).unwrap();
        let width = s.core.get_page_info_native(0).unwrap();
        page.landscape = !page.landscape;
        page.margin_left += 2835;
        page.binding = 1;
        run(
            &mut s,
            EditCommand::SetPage {
                section: 0,
                page: page.clone(),
                whole: false,
            },
        )
        .unwrap();
        assert_eq!(s.page_setup(0).unwrap(), page);
        assert_ne!(s.core.get_page_info_native(0).unwrap(), width);
        page.margin_left = page.width.max(page.height);
        assert!(run(
            &mut s,
            EditCommand::SetPage {
                section: 0,
                page,
                whole: false,
            }
        )
        .is_err());
    }
}
#[test]
fn page_borders_and_backgrounds_go_on_their_pages() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, true)).unwrap();
        let new_page = EditCommand::Break {
            position: point(body(), 1),
            column: false,
        };
        run(&mut s, new_page).unwrap();
        let mut border = s.page_border(0).unwrap();
        for side in &mut border.sides {
            *side = BorderSide {
                line: 1,
                width: 7,
                color: "#123456".into(),
            };
        }
        border.spacing = [1417; 4];
        border.border_pages = ApplyPages::ExceptFirst;
        border.fill = Some(PageFill {
            color: "#abcdef".into(),
            pattern_color: "#000000".into(),
            pattern: 0,
        });
        border.fill_pages = ApplyPages::FirstOnly;
        let set = |border: PageBorder| EditCommand::SetPageBorder {
            section: 0,
            border,
            whole: false,
        };
        run(&mut s, set(border.clone())).unwrap();
        assert_eq!(s.page_border(0).unwrap(), border, "{format}");
        let drawn = |s: &EditSession, page| {
            let svg = s.core.render_page_svg_native(page).unwrap();
            (svg.contains("#123456"), svg.contains("#abcdef"))
        };
        assert_eq!(drawn(&s, 0), (false, true), "{format}");
        assert_eq!(drawn(&s, 1), (true, false), "{format}");
        let saved = s
            .export(if format == "hwp" {
                SaveFormat::Hwp
            } else {
                SaveFormat::Hwpx
            })
            .unwrap();
        let reopened = EditSession::open(&saved).unwrap();
        assert_eq!(reopened.page_border(0).unwrap(), border, "{format}");
        assert_eq!(drawn(&reopened, 1), (true, false), "{format}");
        border.spacing[0] = 7088;
        assert!(run(&mut s, set(border)).is_err());
        run(&mut s, EditCommand::Undo).unwrap();
        assert_eq!(drawn(&s, 1), (false, false), "{format}");
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
                width: None,
                height: None,
                treat_as_char: false,
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
        commands.push(EditCommand::SetPage {
            section: 0,
            page,
            whole: false,
        });
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
        let at = s.format(s.revision, &point(body(), 1), None).unwrap();
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
fn page_number_placeholder_is_not_a_document_character() {
    let mut s = EditSession::blank().unwrap();
    let before = s.statistics();
    run(
        &mut s,
        EditCommand::HeaderFooter {
            section: 0,
            footer: true,
            page_number: Some(Placement::Center),
        },
    )
    .unwrap();
    let after = s.statistics();
    assert_eq!(after.characters, before.characters);
    assert_eq!(
        after.characters_without_spaces,
        before.characters_without_spaces
    );
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
            // 글자 모양 and 문단 모양 work in the note as in the body.
            let words = EditSelection {
                anchor: point(note.clone(), 2),
                focus: point(note.clone(), 4),
            };
            run(
                &mut s,
                EditCommand::FormatText {
                    selection: words.clone(),
                    style: CharStyle {
                        bold: Some(true),
                        ..Default::default()
                    },
                },
            )
            .unwrap();
            run(
                &mut s,
                EditCommand::FormatParagraphs {
                    selection: words,
                    style: ParaStyle {
                        alignment: Some(Alignment::Center),
                        ..Default::default()
                    },
                },
            )
            .unwrap();
            let shown = s.format(s.revision, &point(note.clone(), 4), None).unwrap();
            assert_eq!(shown.text.bold, Some(true), "{label}");
            assert_eq!(
                shown.paragraph.alignment,
                Some(Alignment::Center),
                "{label}"
            );
            let plain = s.format(s.revision, &point(note.clone(), 5), None).unwrap();
            assert_eq!(plain.text.bold, Some(false), "{label}");
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
            for _ in 0..7 {
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
    let reply = s.show_marks(true, true, false).unwrap();
    assert_eq!(reply.changed_pages, [0]);
    assert!(!reply.dirty && !reply.can_undo);
    let marked = s.core.render_page_svg_native(0).unwrap();
    assert_ne!(marked, plain);
    assert!(display::build(&marked).is_some(), "{marked}");
    assert_eq!(s.export(SaveFormat::Pdf).unwrap().len(), pdf.len());
    assert!(s.core.show_paragraph_marks);
    s.show_marks(false, false, false).unwrap();
    assert_eq!(s.core.render_page_svg_native(0).unwrap(), plain);
}
#[test]
fn transparent_lines_show_on_pages_but_not_in_the_pdf() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let insert = EditCommand::InsertTable {
        position: point(body(), 0),
        rows: 2,
        columns: 2,
        width: None,
        height: None,
        treat_as_char: false,
    };
    let cell = run(&mut s, insert).unwrap().selection.unwrap().focus.target;
    // A table without lines, laid out again by an edit in it.
    let doc = s.core.document_mut();
    let mut none = doc.doc_info.border_fills[0].clone();
    for line in &mut none.borders {
        line.line_type = rhwp::model::style::BorderLineType::None;
    }
    none.raw_data = None;
    doc.doc_info.border_fills.push(none);
    let id = doc.doc_info.border_fills.len() as u16;
    let host = &mut doc.sections[0].paragraphs[cell.paragraph as usize];
    let Control::Table(table) = &mut host.controls[cell.cell.as_ref().unwrap().control as usize]
    else {
        panic!("no table")
    };
    for c in &mut table.cells {
        c.border_fill_id = id;
    }
    replace(&mut s, cell, 0, 0, "가").unwrap();
    let plain = s.core.render_page_svg_native(0).unwrap();
    let pdf = s.export(SaveFormat::Pdf).unwrap();
    s.show_marks(false, false, true).unwrap();
    let lined = s.core.render_page_svg_native(0).unwrap();
    assert_ne!(lined, plain);
    assert_eq!(s.export(SaveFormat::Pdf).unwrap().len(), pdf.len());
    assert_eq!(s.core.render_page_svg_native(0).unwrap(), lined);
    s.show_marks(false, false, false).unwrap();
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
            width: None,
            height: None,
            treat_as_char: false,
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
            width: None,
            height: None,
            treat_as_char: false,
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
    let format = s
        .format(s.revision, &point(body(), 0), None)
        .unwrap()
        .paragraph;
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
            assert_eq!(s.format(s.revision, &point(p, 0), None).unwrap().style, 2);
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
        assert_eq!(
            s.format(s.revision, &point(cell, 0), None).unwrap().style,
            1
        );
        let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
        assert_eq!(
            reopened.format(0, &point(body(), 0), None).unwrap().style,
            2
        );
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
    let now = s
        .format(s.revision, &point(body(), 0), None)
        .unwrap()
        .paragraph;
    assert_eq!((now.head.as_deref(), now.level), (Some("Number"), Some(1)));
    assert_eq!(now.numbering, Some(0));
    // ① (ㄱ) (a) 1): its second level counts ㄱ, ㄴ.
    let jamo = ParaStyle {
        head: Some("Number".into()),
        numbering: Some(3),
        ..Default::default()
    };
    let text = apply(&mut s, jamo);
    assert!(
        text.starts_with("(ㄱ)가") && text.contains("(ㄴ)보존"),
        "{text}"
    );
    // 새 번호 목록 시작 at 5.
    let restart = ParaStyle {
        level: Some(0),
        restart: Some(2),
        start_number: Some(5),
        ..Default::default()
    };
    let text = apply(&mut s, restart);
    assert!(text.starts_with("⑤가") && text.contains("⑥보존"), "{text}");
    let now = s
        .format(s.revision, &point(body(), 0), None)
        .unwrap()
        .paragraph;
    assert_eq!((now.restart, now.start_number), (Some(2), Some(5)));
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        let properties = reopened
            .format(0, &point(body(), 0), None)
            .unwrap()
            .paragraph;
        assert_eq!(
            (properties.restart, properties.start_number),
            (Some(2), Some(5)),
            "{format:?}"
        );
        let svg = reopened.core.render_page_svg_native(0).unwrap();
        let text = svg
            .split("</text>")
            .filter_map(|t| t.rsplit('>').next())
            .collect::<String>();
        assert!(
            text.starts_with("⑤가") && text.contains("⑥보존"),
            "numbering restart was not preserved in {format:?}: {text}"
        );
    }
    let bullet = ParaStyle {
        head: Some("Bullet".into()),
        bullet: Some("■".into()),
        ..Default::default()
    };
    assert!(apply(&mut s, bullet).contains('■'));
    let now = s
        .format(s.revision, &point(body(), 0), None)
        .unwrap()
        .paragraph;
    assert_eq!(now.bullet.as_deref(), Some("■"));
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        let head = reopened
            .format(0, &point(body(), 0), None)
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

    // 선 and 채우기 too, with the 무늬 kept through HWP's 0-based numbering.
    let wider = ObjectProps {
        width: Some(20_000),
        border_color: Some(0x0000ff),
        border_width: Some(34),
        line_type: Some(2),
        fill_type: Some("solid".into()),
        fill_bg_color: Some(0x00ff00),
        fill_pat_type: Some(1),
        fill_alpha: Some(128),
        ..Default::default()
    };
    let bad = ObjectProps {
        line_type: Some(12),
        ..Default::default()
    };
    assert!(s.validate_object(&first.object, &bad).is_err());
    let shape = first.object.clone();
    run(
        &mut s,
        EditCommand::SetObject {
            object: shape.clone(),
            props: wider,
        },
    )
    .unwrap();
    let kept = |p: ObjectProps| {
        (
            p.width,
            p.border_color,
            p.border_width,
            p.line_type,
            p.fill_type,
            p.fill_bg_color,
            p.fill_pat_type,
            p.fill_alpha,
        )
    };
    let expected = (
        Some(20_000),
        Some(0x0000ff),
        Some(34),
        Some(2),
        Some("solid".to_string()),
        Some(0x00ff00),
        Some(1),
        Some(128),
    );
    assert_eq!(kept(s.object_props(&shape).unwrap()), expected);
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        assert_eq!(
            kept(reopened.object_props(&shape).unwrap()),
            expected,
            "{format:?}"
        );
    }
    // 순서: 맨 뒤로, then 앞으로 a step.
    let z = |s: &EditSession| -> Vec<i32> {
        s.core.document().sections[0]
            .paragraphs
            .iter()
            .flat_map(|p| &p.controls)
            .filter_map(|c| match c {
                Control::Shape(shape) => Some(shape.z_order()),
                _ => None,
            })
            .collect()
    };
    let own = |s: &EditSession| z(s)[shape.control as usize];
    for (order, rank) in [(Order::Back, 0), (Order::Forward, 1), (Order::Front, 4)] {
        run(
            &mut s,
            EditCommand::Order {
                object: shape.clone(),
                order,
            },
        )
        .unwrap();
        let below = z(&s).iter().filter(|&&other| other < own(&s)).count();
        assert_eq!(below, rank, "{order:?} {:?}", z(&s));
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
fn drawn_shapes_group() {
    for (format, save) in [("hwpx", SaveFormat::Hwpx), ("hwp", SaveFormat::Hwp)] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        for x in [10_000, 30_000] {
            let insert = EditCommand::InsertShape {
                position: point(body(), 0),
                shape: "rectangle".into(),
                x,
                y: 20_000,
                width: 8_000,
                height: 6_000,
                flip: false,
            };
            run(&mut s, insert).unwrap();
        }
        let placed = |s: &EditSession| -> Vec<ObjectRef> {
            (0..s.core.page_count())
                .flat_map(|page| s.placed(page).unwrap())
                .map(|o| o.object)
                .collect()
        };
        let objects = placed(&s);
        let page = (0..s.core.page_count())
            .find(|&p| !s.placed(p).unwrap().is_empty())
            .unwrap();
        let lines = |s: &EditSession| {
            s.core
                .render_page_svg_native(page)
                .unwrap()
                .matches("stroke=\"#000000\"")
                .count()
        };
        let drawn = lines(&s);
        run(&mut s, EditCommand::Group { objects }).unwrap_or_else(|e| panic!("{format}: {e:?}"));
        assert_eq!(placed(&s).len(), 1);
        // Their lines stay, as 한글 draws them.
        assert_eq!(lines(&s), drawn, "{format}");
        let reopened = EditSession::open(&s.export(save).unwrap()).unwrap();
        assert_eq!(placed(&reopened).len(), 1, "{format}");
    }
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
    let format = s
        .format(s.revision, &point(second.clone(), 1), None)
        .unwrap();
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
        width: None,
        height: None,
        treat_as_char: false,
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
                width: None,
                height: None,
                treat_as_char: false,
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
            note: None,
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

#[test]
fn an_equation_in_an_endnote_is_an_object_for_its_properties() {
    // An endnote whose paragraph an equation was put in.
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    let mut doc = core.document().clone();
    let mut para = doc.sections[0].paragraphs[0].clone();
    para.controls.clear();
    doc.sections[0].paragraphs.push(para);
    core.set_document(doc);
    core.insert_equation_native(0, 0, 0, "x^2", 1000, 0)
        .unwrap();
    core.insert_endnote_native(0, 1, 0).unwrap();
    let mut doc = core.document().clone();
    let paragraphs = &mut doc.sections[0].paragraphs;
    let with_equation = paragraphs.remove(0);
    let Some(Control::Endnote(note)) = paragraphs[0]
        .controls
        .iter_mut()
        .find(|c| matches!(c, Control::Endnote(_)))
    else {
        panic!()
    };
    note.paragraphs[0] = with_equation;
    core.set_document(doc);
    let mut s = EditSession::open(&core.export_hwpx_native().unwrap()).unwrap();
    let object = s
        .placed(0)
        .unwrap()
        .into_iter()
        .find(|o| o.object.note.is_some())
        .expect("the equation in the endnote")
        .object;
    assert_eq!(object.kind, ObjectKind::Equation);
    let props = ObjectProps {
        script: Some("y^3".into()),
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
    assert_eq!(
        s.object_props(&object).unwrap().script.as_deref(),
        Some("y^3")
    );
    let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
    assert_eq!(
        reopened.object_props(&object).unwrap().script.as_deref(),
        Some("y^3")
    );
    // Only its properties: it does not move, copy or go.
    let delete = EditCommand::DeleteObject {
        object: object.clone(),
    };
    assert!(run(&mut s, delete).is_err());
    assert!(s.copy_object(&object).is_err());
    run(&mut s, EditCommand::Undo).unwrap();
    assert_eq!(
        s.object_props(&object).unwrap().script.as_deref(),
        Some("x^2")
    );
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
#[test]
fn pictures_are_replaced_in_place_and_saved_out() {
    use base64::Engine;
    const RED: &str = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==";
    for (format, save) in [("hwp", SaveFormat::Hwp), ("hwpx", SaveFormat::Hwpx)] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        run(&mut s, picture_at(point(body(), 0))).unwrap();
        let first = |s: &EditSession| {
            (0..s.core.page_count())
                .find_map(|page| s.placed(page).unwrap().into_iter().next())
                .unwrap()
                .object
        };
        let object = first(&s);
        let size = |s: &EditSession| {
            let p = s.object_props(&object).unwrap();
            (p.width, p.height)
        };
        let before = size(&s);
        let replace = EditCommand::ReplacePicture {
            object: object.clone(),
            data: RED.into(),
            natural_width: 2,
            natural_height: 2,
            extension: "png".into(),
        };
        run(&mut s, replace).unwrap_or_else(|e| panic!("{format}: {e:?}"));
        // The frame keeps its size; 삽입 그림 저장하기 gives the new image.
        assert_eq!(size(&s), before, "{format}");
        let red = base64::engine::general_purpose::STANDARD
            .decode(RED)
            .unwrap();
        assert_eq!(
            s.picture_file(&object).unwrap(),
            ("png".into(), red.clone()),
            "{format}"
        );
        let reopened = EditSession::open(&s.export(save).unwrap()).unwrap();
        let again = first(&reopened);
        assert_eq!(reopened.picture_file(&again).unwrap().1, red, "{format}");
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
        let hit = |x| s.hit_test(s.revision, r.page, x, y, false).unwrap().scalar;
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
    // 캡션 크기, 개체와의 간격 and 여백 부분까지 너비 확대.
    let sized = ObjectProps {
        caption: Some("LeftCenter".into()),
        caption_width: Some(3_000),
        caption_spacing: Some(500),
        caption_include_margin: Some(true),
        ..Default::default()
    };
    run(
        &mut s,
        EditCommand::SetObject {
            object: object.clone(),
            props: sized,
        },
    )
    .unwrap();
    let reopened = EditSession::open(&s.export(SaveFormat::Hwpx).unwrap()).unwrap();
    for session in [&s, &reopened] {
        let now = session.object_props(&object).unwrap();
        assert_eq!(
            (
                now.caption.as_deref(),
                now.caption_width,
                now.caption_spacing,
                now.caption_include_margin
            ),
            (Some("LeftCenter"), Some(3_000), Some(500), Some(true))
        );
    }

    // A table's caption is its cell `CAPTION`.
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let table = ObjectRef {
        kind: ObjectKind::Table,
        section: 0,
        paragraph: 2,
        control: 0,
        cell: None,
        note: None,
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
            .hit_test(s.revision, r.page, r.x + 0.3, r.y + r.height / 2.0, false)
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

#[test]
fn text_goes_into_drawing_objects_and_groups_come_apart() {
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
        for i in 0..2 {
            run(
                &mut s,
                EditCommand::InsertShape {
                    position: point(body(), 0),
                    shape: "rectangle".into(),
                    x: 10_000,
                    y: 20_000 + i * 8_000,
                    width: 14_000,
                    height: 6_000,
                    flip: false,
                },
            )
            .unwrap();
        }
        let rectangle = s.placed(0).unwrap()[0].object.clone();
        // 도형 안에 글자 넣기: the caret goes into the new text, which saves.
        let caret = run(
            &mut s,
            EditCommand::SetTextBox {
                object: rectangle.clone(),
                attach: true,
            },
        )
        .unwrap()
        .selection
        .unwrap()
        .focus;
        assert_eq!(caret.target.cell.as_ref().map(|c| c.cell), Some(0));
        replace(&mut s, caret.target.clone(), 0, 0, "도형 글").unwrap();
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        assert_eq!(
            reopened.paragraph(&caret.target).unwrap().text,
            "도형 글",
            "{format:?}"
        );
        let again = EditCommand::SetTextBox {
            object: rectangle.clone(),
            attach: true,
        };
        assert_eq!(
            s.validate_command(&again).unwrap_err(),
            EditError::UnsupportedTarget
        );
        // 글상자 속성 없애기.
        run(
            &mut s,
            EditCommand::SetTextBox {
                object: rectangle.clone(),
                attach: false,
            },
        )
        .unwrap();
        assert!(s.paragraph(&caret.target).is_err());

        // 개체 풀기 takes a group apart into its members, and only a group.
        let ungroup = |object: &ObjectRef| EditCommand::Ungroup {
            object: object.clone(),
        };
        assert!(s.validate_command(&ungroup(&rectangle)).is_err());
        // 개체 묶기 takes two or more, each once.
        let members: Vec<ObjectRef> = s.placed(0).unwrap().into_iter().map(|o| o.object).collect();
        let group_of = |objects: &[ObjectRef]| EditCommand::Group {
            objects: objects.to_vec(),
        };
        assert!(s.validate_command(&group_of(&members[..1])).is_err());
        assert!(s
            .validate_command(&group_of(&[members[0].clone(), members[0].clone()]))
            .is_err());
        run(&mut s, group_of(&members)).unwrap();
        let group = s.placed(0).unwrap()[0].object.clone();
        assert_eq!(s.placed(0).unwrap().len(), 1);
        assert!(s.object_props(&group).unwrap().width.is_some());
        run(&mut s, ungroup(&group)).unwrap();
        assert_eq!(s.placed(0).unwrap().len(), 2);
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        assert_eq!(reopened.placed(0).unwrap().len(), 2, "{format:?}");
    }
}

#[test]
fn block_calculations_fill_the_empty_cells_to_the_right_and_below() {
    for (function, expected) in [
        (BlockFunction::Sum, ["3", "7", "4", "6", "10"]),
        (BlockFunction::Average, ["1.5", "3.5", "2", "3", "2.5"]),
        (BlockFunction::Product, ["2", "12", "3", "8", "24"]),
    ] {
        let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
        let insert = EditCommand::InsertTable {
            position: point(body(), 0),
            rows: 3,
            columns: 3,
            width: None,
            height: None,
            treat_as_char: false,
        };
        let caret = run(&mut s, insert).unwrap().selection.unwrap().focus;
        let at = |s: &EditSession, row: u16, col: u16| {
            let t = commands::table(s.core.document(), &caret.target).unwrap();
            let cell = t
                .cells
                .iter()
                .position(|c| (c.row, c.col) == (row, col))
                .unwrap();
            let mut target = caret.target.clone();
            target.cell.as_mut().unwrap().cell = cell as u32;
            target
        };
        for (row, col, value) in [(0, 0, "1"), (0, 1, "2"), (1, 0, "3"), (1, 1, "4")] {
            let cell = at(&s, row, col);
            replace(&mut s, cell, 0, 0, value).unwrap();
        }
        let block = |s: &EditSession, to: (u16, u16)| EditCommand::CalculateBlock {
            selection: EditSelection {
                anchor: point(at(s, 0, 0), 0),
                focus: point(at(s, to.0, to.1), 0),
            },
            function,
        };
        // Without an empty cell there is nowhere to write.
        assert!(s.validate_command(&block(&s, (1, 1))).is_err());
        let whole = block(&s, (2, 2));
        run(&mut s, whole).unwrap();
        let text = |s: &EditSession, row, col| s.paragraph(&at(s, row, col)).unwrap().text;
        let cells = [(0, 2), (1, 2), (2, 0), (2, 1), (2, 2)];
        let found: Vec<String> = cells.iter().map(|&(r, c)| text(&s, r, c)).collect();
        assert_eq!(found, expected, "{function:?}");
        assert_eq!(text(&s, 1, 1), "4");
    }
}

#[test]
fn columns_change_for_the_section_and_save() {
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
        let count = |s: &EditSession| s.column_defs(0)[0].column_count;
        let columns = |count| EditCommand::SetColumns { section: 0, count };
        run(&mut s, columns(2)).unwrap();
        assert_eq!(count(&s), 2);
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        assert_eq!(count(&reopened), 2, "{format:?}");
        run(&mut s, columns(1)).unwrap();
        assert_eq!(count(&s), 1);
        assert!(s.validate_command(&columns(4)).is_err());
    }
}

#[test]
fn headers_go_page_to_page_and_are_deleted() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let header = EditCommand::HeaderFooter {
        section: 0,
        footer: false,
        page_number: Some(Placement::Center),
    };
    run(&mut s, header).unwrap();
    let new_page = EditCommand::Break {
        position: point(body(), 1),
        column: false,
    };
    run(&mut s, new_page).unwrap();
    assert!(s.core.page_count() >= 2);
    let on = |page| {
        point(
            EditTarget {
                section: 0,
                paragraph: 0,
                cell: None,
                note: None,
                header_footer: Some(HeaderFooterTarget {
                    footer: false,
                    apply_to: 0,
                    page,
                }),
            },
            0,
        )
    };
    let go = |s: &EditSession, from: &EditPosition, motion| {
        s.navigate(s.revision, from, motion, None).unwrap()
    };
    let next = go(&s, &on(0), Motion::NextHeaderFooter);
    assert_eq!(next.position, on(1));
    assert_eq!(next.caret.page, 1);
    assert_eq!(
        go(&s, &next.position, Motion::PreviousHeaderFooter).position,
        on(0)
    );
    let last = on(s.core.page_count() - 1);
    assert_eq!(go(&s, &last, Motion::NextHeaderFooter).position, last);

    // 머리말/꼬리말 지우기 leaves the caret in the body.
    replace(&mut s, on(0).target, 0, 0, "머리").unwrap();
    let reply = run(
        &mut s,
        EditCommand::DeleteHeaderFooter {
            target: on(0).target,
        },
    )
    .unwrap();
    assert!(reply
        .selection
        .unwrap()
        .focus
        .target
        .header_footer
        .is_none());
    assert!(s.paragraph(&on(0).target).is_err());
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        assert!(reopened.paragraph(&on(0).target).is_err(), "{format:?}");
    }
}

#[test]
fn copies_paste_with_their_formats() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let all = s.paragraph(&body()).unwrap().text.chars().count() as u32;
    replace(&mut s, body(), 0, all, "하나 둘\n셋 넷").unwrap();
    let second = EditTarget {
        paragraph: body().paragraph + 1,
        ..body()
    };
    let range = |from: EditPosition, to: EditPosition| EditSelection {
        anchor: from,
        focus: to,
    };
    let bold = EditCommand::FormatText {
        selection: range(point(body(), 0), point(body(), 2)),
        style: CharStyle {
            bold: Some(true),
            ..Default::default()
        },
    };
    run(&mut s, bold).unwrap();
    // 둘\n셋, from the middle of one paragraph to the middle of the next.
    let copied = s
        .copy(
            s.revision,
            &range(point(body(), 0), point(second.clone(), 1)),
        )
        .unwrap();
    assert!(
        copied.html.contains("하나") && copied.html.contains('셋'),
        "{}",
        copied.html
    );
    let paste = |at: EditPosition, copy: Option<u64>, html: Option<&str>| EditCommand::Paste {
        selection: EditSelection::caret(at),
        copy,
        html: html.map(str::to_string),
    };
    let caret = run(
        &mut s,
        paste(point(second.clone(), 3), Some(copied.copy), None),
    )
    .unwrap()
    .selection
    .unwrap()
    .focus;
    let third = EditTarget {
        paragraph: body().paragraph + 2,
        ..second.clone()
    };
    assert_eq!(s.paragraph(&second).unwrap().text, "셋 넷하나 둘");
    assert_eq!(s.paragraph(&third).unwrap().text, "셋");
    assert_eq!(caret, point(third.clone(), 1));
    let pasted = s
        .format(s.revision, &point(second.clone(), 5), None)
        .unwrap();
    assert_eq!(pasted.text.bold, Some(true));
    // An unknown copy is refused; HTML from elsewhere keeps its formats.
    assert!(s
        .validate_command(&paste(point(body(), 0), Some(copied.copy + 1), None))
        .is_err());
    run(
        &mut s,
        paste(point(third.clone(), 1), None, Some("<p><i>기울</i></p>")),
    )
    .unwrap();
    assert_eq!(s.paragraph(&third).unwrap().text, "셋기울");
    let html = s
        .format(s.revision, &point(third.clone(), 3), None)
        .unwrap();
    assert_eq!(html.text.italic, Some(true));
    // A picture in the line comes along.
    run(&mut s, picture_at(point(body(), 1))).unwrap();
    let with_picture = s
        .copy(s.revision, &range(point(body(), 0), point(body(), 3)))
        .unwrap();
    run(
        &mut s,
        paste(point(body(), 0), Some(with_picture.copy), None),
    )
    .unwrap();
    assert_eq!(
        s.paragraph(&body()).unwrap().text,
        "하\u{FFFC}나하\u{FFFC}나 둘"
    );
    // Into a table cell too.
    let cell = run(
        &mut s,
        EditCommand::InsertTable {
            position: point(body(), 0),
            rows: 1,
            columns: 1,
            width: None,
            height: None,
            treat_as_char: false,
        },
    )
    .unwrap()
    .selection
    .unwrap()
    .focus
    .target;
    // The latest copy replaces the one before.
    assert!(s
        .validate_command(&paste(point(cell.clone(), 0), Some(copied.copy), None))
        .is_err());
    run(
        &mut s,
        paste(point(cell.clone(), 0), Some(with_picture.copy), None),
    )
    .unwrap();
    assert_eq!(s.paragraph(&cell).unwrap().text, "하\u{FFFC}나");
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        assert_eq!(
            reopened.paragraph(&cell).unwrap().text,
            "하\u{FFFC}나",
            "{format:?}"
        );
    }
    // A selected object copies by itself.
    let picture = s
        .placed(0)
        .unwrap()
        .into_iter()
        .find(|o| o.object.kind == ObjectKind::Picture && o.object.cell.is_none())
        .unwrap()
        .object;
    let copied = s.copy_object(&picture).unwrap();
    run(
        &mut s,
        paste(point(cell.clone(), 3), Some(copied.copy), None),
    )
    .unwrap();
    assert_eq!(s.paragraph(&cell).unwrap().text, "하\u{FFFC}나\u{FFFC}");
}

#[test]
fn replace_all_is_one_edit() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let all = s.paragraph(&body()).unwrap().text.chars().count() as u32;
    replace(&mut s, body(), 0, all, "가나 가나\n가나").unwrap();
    let matches = s.find("가나", true).unwrap();
    assert_eq!(matches.len(), 3);
    let undo = s.undo.len();
    run(
        &mut s,
        EditCommand::ReplaceAll {
            selections: matches,
            text: "다\n라".into(),
        },
    )
    .unwrap();
    let text = |s: &EditSession, i| {
        let t = EditTarget {
            paragraph: body().paragraph + i,
            ..body()
        };
        s.paragraph(&t).unwrap().text
    };
    assert_eq!(
        (0..5).map(|i| text(&s, i)).collect::<Vec<_>>(),
        ["다", "라 다", "라", "다", "라"]
    );
    assert_eq!(s.undo.len(), undo + 1);
    run(&mut s, EditCommand::Undo).unwrap();
    assert_eq!(text(&s, 0), "가나 가나");
}

#[test]
fn line_ends_move_one_at_a_time() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    for flip in [false, true] {
        let line = EditCommand::InsertShape {
            position: point(body(), 0),
            shape: "line".into(),
            x: 10_000,
            y: 20_000,
            width: 15_000,
            height: if flip { 7_500 } else { 0 },
            flip,
        };
        run(&mut s, line).unwrap();
    }
    let placed = s.placed(0).unwrap();
    let ends = |s: &EditSession, i: usize| s.placed(0).unwrap()[i].ends.unwrap();
    // 10 000 HWPUNIT is 133.3 px; 15 000 is 200.
    let [x1, y1, x2, y2] = ends(&s, 0);
    assert!(
        (x1 - 133.3).abs() < 2.0 && (x2 - 333.3).abs() < 2.0,
        "{:?}",
        ends(&s, 0)
    );
    assert!((y1 - y2).abs() < 1.0);
    // Flipped: the other diagonal of its box.
    let [fx1, fy1, fx2, fy2] = ends(&s, 1);
    assert!((fx2 - fx1) * (fy2 - fy1) < 0.0, "{:?}", ends(&s, 1));
    let line = placed[0].object.clone();
    let lower = EditCommand::MoveLineEnd {
        object: line.clone(),
        end: true,
        dx: 0,
        dy: 7_500,
    };
    run(&mut s, lower).unwrap();
    let [nx1, ny1, nx2, ny2] = ends(&s, 0);
    assert!((nx1 - x1).abs() < 1.0 && (ny1 - y1).abs() < 1.0);
    assert!(
        (nx2 - x2).abs() < 1.0 && (ny2 - y2 - 100.0).abs() < 2.0,
        "{:?}",
        ends(&s, 0)
    );
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        let [_, a, _, b] = reopened.placed(0).unwrap()[0].ends.unwrap();
        assert!((b - a - 100.0).abs() < 2.0, "{format:?}");
    }
    let away = EditCommand::MoveLineEnd {
        object: line,
        end: false,
        dx: -50_000,
        dy: 0,
    };
    assert!(s.validate_command(&away).is_err());
}

#[test]
fn each_language_keeps_its_own_font_and_scale() {
    let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
    let all = s.paragraph(&body()).unwrap().text.chars().count() as u32;
    replace(&mut s, body(), 0, all, "한글 Latin").unwrap();
    let whole = EditSelection {
        anchor: point(body(), 0),
        focus: point(body(), 8),
    };
    let format = |s: &mut EditSession, style: CharStyle| {
        let command = EditCommand::FormatText {
            selection: whole.clone(),
            style,
        };
        run(s, command).unwrap();
        s.format(s.revision, &point(body(), 4), None)
            .unwrap()
            .languages
    };
    let before = s
        .format(s.revision, &point(body(), 4), None)
        .unwrap()
        .languages;
    // 영문 only.
    let latin = format(
        &mut s,
        CharStyle {
            language: Some(1),
            font: Some("Arial".into()),
            ratio: Some(80.0),
            ..Default::default()
        },
    );
    assert_eq!(latin[1].font.as_deref(), Some("Arial"));
    assert_eq!(latin[1].ratio, Some(80.0));
    assert_eq!(latin[0], before[0]);
    // 대표: every 언어.
    let all = format(
        &mut s,
        CharStyle {
            font: Some("돋움".into()),
            ..Default::default()
        },
    );
    assert!(
        all.iter().all(|l| l.font.as_deref() == Some("돋움")),
        "{all:?}"
    );
    assert_eq!(all[1].ratio, Some(80.0));
    for format in [SaveFormat::Hwp, SaveFormat::Hwpx] {
        let reopened = EditSession::open(&s.export(format).unwrap()).unwrap();
        let languages = reopened
            .format(0, &point(body(), 4), None)
            .unwrap()
            .languages;
        assert_eq!(languages[1].ratio, Some(80.0), "{format:?}");
        assert_eq!(languages[1].font.as_deref(), Some("돋움"), "{format:?}");
    }
}
/// Deleting across a paragraph takes its table with it; ending at the start of the table's
/// empty paragraph leaves the table.
#[test]
fn a_range_through_a_paragraph_takes_its_table() {
    let at = |paragraph| EditTarget {
        paragraph,
        ..body()
    };
    let tables = |s: &EditSession| {
        s.core.document().sections[0]
            .paragraphs
            .iter()
            .flat_map(|p| &p.controls)
            .filter(|c| matches!(c, Control::Table(_)))
            .count()
    };
    // Paragraphs: 1 text, 2 the table alone, 3 empty.
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let to_table = EditSelection {
        anchor: point(at(1), 1),
        focus: point(at(2), 0),
    };
    run(
        &mut s,
        EditCommand::Replace {
            selection: to_table,
            text: "X".into(),
        },
    )
    .unwrap();
    assert_eq!(tables(&s), 1);
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let through = EditSelection {
        anchor: point(at(1), 1),
        focus: point(at(3), 0),
    };
    run(
        &mut s,
        EditCommand::Replace {
            selection: through,
            text: "X".into(),
        },
    )
    .unwrap();
    assert_eq!(tables(&s), 0);
    assert_eq!(s.paragraph(&at(1)).unwrap().text, "가X");
    run(&mut s, EditCommand::Undo).unwrap();
    assert_eq!(tables(&s), 1);
}
#[test]
fn tables_are_made_at_a_size_and_as_characters() {
    for format in ["hwp", "hwpx"] {
        let mut s = EditSession::open(&plain_document(format, false)).unwrap();
        let insert = EditCommand::InsertTable {
            position: point(body(), 0),
            rows: 2,
            columns: 3,
            width: Some(30_000),
            height: Some(8_000),
            treat_as_char: true,
        };
        let cell = run(&mut s, insert).unwrap().selection.unwrap().focus.target;
        let table = ObjectRef {
            kind: ObjectKind::Table,
            section: 0,
            paragraph: cell.paragraph,
            control: cell.cell.unwrap().control,
            cell: None,
            note: None,
        };
        let props = s.object_props(&table).unwrap();
        assert_eq!(props.treat_as_char, Some(true), "{format}");
        let Control::Table(made) = &s.core.document().sections[0].paragraphs
            [table.paragraph as usize]
            .controls[table.control as usize]
        else {
            panic!("no table")
        };
        let first_row: u32 = made
            .cells
            .iter()
            .filter(|c| c.row == 0)
            .map(|c| c.width)
            .sum();
        assert_eq!(first_row, 30_000, "{format}");
        assert!(made.cells.iter().all(|c| c.height == 4_000), "{format}");
        let tiny = EditCommand::InsertTable {
            position: point(body(), 0),
            rows: 2,
            columns: 3,
            width: Some(100),
            height: None,
            treat_as_char: false,
        };
        assert!(run(&mut s, tiny).is_err());
    }
}

/// Part of a paragraph copied in a browser comes in as one paragraph with its bold and italic.
#[test]
fn html_from_browsers_keeps_its_formats_in_one_paragraph() {
    let samples = [
        // Chrome: styled spans and an <em>, no paragraph.
        "<meta charset='utf-8'><span style=\"color: rgb(0, 0, 0); font-weight: 700;\">굵게</span><span style=\"color: rgb(0, 0, 0);\"> </span><em style=\"color: rgb(0, 0, 0);\">기울</em>",
        // Safari: <b> and <i> with styles.
        "<meta charset=\"UTF-8\"><b style=\"font-family: -apple-system;\">굵게</b><span style=\"font-family: -apple-system;\"> </span><i style=\"font-family: -apple-system;\">기울</i>",
        "<b>굵게</b> <i>기울</i>",
    ];
    for html in samples {
        let mut s = EditSession::open(&plain_document("hwpx", false)).unwrap();
        let all = s.paragraph(&body()).unwrap().text.chars().count() as u32;
        replace(&mut s, body(), 0, all, "").unwrap();
        run(
            &mut s,
            EditCommand::Paste {
                selection: EditSelection::caret(point(body(), 0)),
                copy: None,
                html: Some(html.into()),
            },
        )
        .unwrap();
        assert_eq!(s.paragraph(&body()).unwrap().text, "굵게 기울", "{html}");
        let at = |scalar| {
            s.format(s.revision, &point(body(), scalar), None)
                .unwrap()
                .text
        };
        assert_eq!(
            (at(1).bold, at(1).italic),
            (Some(true), Some(false)),
            "{html}"
        );
        assert_eq!(
            (at(5).bold, at(5).italic),
            (Some(false), Some(true)),
            "{html}"
        );
    }
}

#[test]
fn status_counts_lines_on_the_page_and_names_cells() {
    let mut s = EditSession::open(&plain_document("hwpx", true)).unwrap();
    let all = s.paragraph(&body()).unwrap().text.chars().count() as u32;
    replace(
        &mut s,
        body(),
        0,
        all,
        &"가나다라마바사아자차카타파하 ".repeat(20),
    )
    .unwrap();
    let revision = s.reply().revision;
    let status = |s: &EditSession, p: EditPosition| s.status(revision, &p).unwrap();
    let first = status(&s, point(body(), 3));
    assert_eq!(
        (
            first.page,
            first.column,
            first.line,
            first.character,
            first.section,
            first.sections,
            first.cell
        ),
        (1, 1, 2, 4, 1, 1, None)
    );
    assert_eq!(first.characters, s.statistics().characters);
    // The empty paragraph 0 is the page's first line. The first position of the
    // paragraph's next line is its 1st 칸; upstream, the end of the line before.
    let next = (0..300)
        .find(|&k| status(&s, point(body(), k)).line == 3)
        .unwrap();
    assert_eq!(status(&s, point(body(), next)).character, 1);
    let end = status(
        &s,
        EditPosition {
            upstream: true,
            ..point(body(), next)
        },
    );
    assert_eq!((end.line, end.character), (2, next + 1));
    let empty = status(
        &s,
        point(
            EditTarget {
                paragraph: 0,
                ..body()
            },
            0,
        ),
    );
    assert_eq!((empty.line, empty.character), (1, 1));
    let cell = EditTarget {
        paragraph: 2,
        cell: Some(CellTarget {
            control: 0,
            cell: 1,
            paragraph: 0,
        }),
        ..body()
    };
    assert_eq!(status(&s, point(cell, 0)).cell.as_deref(), Some("B1"));
}
