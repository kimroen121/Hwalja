//! Regressions for the downstream rhwp layout patch (Vendor/rhwp-layout.patch).
use rhwp::DocumentCore;

fn first_text_x(svg: &str, text: &str) -> f64 {
    let document = roxmltree::Document::parse(svg).expect("page SVG must parse");
    document
        .descendants()
        .find(|node| node.has_tag_name("text") && node.text() == Some(text))
        .and_then(|node| node.attribute("x"))
        .and_then(|value| value.parse().ok())
        .expect("requested text must have an x coordinate")
}

#[test]
fn pretendard_variable_is_tried_before_unrelated_fallbacks() {
    let chain = rhwp::renderer::render_font_family_chain("Pretendard");
    let variable = chain
        .find("'Pretendard Variable'")
        .expect("installed variable family must be recognized");
    assert!(chain.find("'Pretendard'").unwrap() < variable);
    assert!(variable < chain.find("'Apple SD Gothic Neo'").unwrap());
    let bold = rhwp::renderer::render_font_family_chain_for_weight("Pretendard", true);
    assert!(
        bold.contains("'Pretendard Variable'"),
        "bold text must retain the installed variable family instead of changing metrics"
    );
}

#[test]
fn first_section_paragraph_applies_positive_first_line_indent() {
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    core.insert_text_native(0, 0, 0, "가나다").unwrap();
    let before = first_text_x(&core.render_page_svg_native(0).unwrap(), "가");

    // Paragraph lengths use 1/200 pt, so 4,000 is a 20 pt first-line indent.
    core.apply_para_format_native(0, 0, r#"{"indent":4000}"#)
        .unwrap();

    let after = first_text_x(&core.render_page_svg_native(0).unwrap(), "가");
    let expected = 20.0 * 96.0 / 72.0;
    assert!(
        (after - before - expected).abs() < 0.2,
        "first line moved {} px, expected {expected} px",
        after - before
    );
}

#[test]
fn section_leading_paragraph_marks_hanging_indent_lines_after_reflow() {
    use rhwp::model::paragraph::LineSeg;

    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    core.insert_text_native(0, 0, 0, &"가나다라마바사 ".repeat(100))
        .unwrap();

    core.apply_para_format_native(0, 0, r#"{"indent":-4000}"#)
        .unwrap();

    let lines = &core.document().sections[0].paragraphs[0].line_segs;
    assert!(lines.len() > 1, "fixture must wrap onto multiple lines");
    assert_eq!(lines[0].tag & LineSeg::TAG_INDENTATION, 0);
    assert!(lines[1..]
        .iter()
        .all(|line| line.tag & LineSeg::TAG_INDENTATION != 0));
}

#[test]
fn synthetic_picture_line_keeps_existing_layout_owner() {
    use rhwp::model::shape::{CommonObjAttr, TextWrap, VertRelTo};
    use rhwp::model::{control::Control, image::Picture, paragraph::LineSeg};
    use rhwp::renderer::{composer, composer::ParagraphBox, style_resolver};
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    let mut para = core.document().sections[0].paragraphs[0].clone();
    para.text = "가나다라마바사아자차카타파하 ".repeat(12);
    para.line_segs = vec![LineSeg {
        tag: LineSeg::TAG_IMPLEMENTATION_PROPERTY,
        line_height: 1000,
        segment_width: 30000,
        ..Default::default()
    }];
    para.controls = vec![Control::Picture(Box::new(Picture {
        common: CommonObjAttr {
            width: 10000,
            height: 10000,
            flow_with_text: true,
            text_wrap: TextWrap::TopAndBottom,
            vert_rel_to: VertRelTo::Para,
            ..Default::default()
        },
        ..Default::default()
    }))];
    let styles = style_resolver::resolve_styles(&core.document().doc_info, 96.0);
    let mut composed = composer::compose_paragraph(&para);
    let original_lines = composed.lines.len();
    composer::recompose_cell_lines_in_frame(
        &mut composed,
        &para,
        ParagraphBox::content_width_px(600.0, 96.0),
        &styles,
        96.0,
        false,
    );
    assert_eq!(
        composed.lines.len(),
        original_lines,
        "the NO_LS fix must not replace synthetic source lines"
    );
}
