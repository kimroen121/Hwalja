//! Regressions for the downstream rhwp layout patch (Vendor/rhwp-layout.patch).
use rhwp::DocumentCore;

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
