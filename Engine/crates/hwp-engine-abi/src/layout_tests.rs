//! Regressions for the downstream rhwp layout patch (Vendor/rhwp-layout.patch).
use crate::layout_audit;
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
        !bold.contains("'Pretendard Variable'"),
        "PDF backend cannot instantiate variable bold; preserve existing bold fallback"
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

#[test]
#[ignore = "Private local regression: set HWP_LAYOUT_FIXTURE to the physics report; never commit it."]
fn private_report_must_not_overlap_text_and_images() {
    let path = std::env::var_os("HWP_LAYOUT_FIXTURE").expect("set HWP_LAYOUT_FIXTURE");
    let bytes = std::fs::read(path).unwrap();
    let core = DocumentCore::from_bytes(&bytes).unwrap();
    assert_eq!(core.page_count(), 6, "Hancom Docs reference has six pages");
    // Hancom Docs screenshot: this paragraph fills the cell and finishes
    // before its MOSFET image, rather than wrapping at a fixed char count.
    fn reference_geometry(
        node: &rhwp::renderer::render_tree::RenderNode,
        right: &mut f64,
        bottom: &mut f64,
        image_top: &mut f64,
    ) {
        use rhwp::renderer::render_tree::RenderNodeType;
        match &node.node_type {
            RenderNodeType::TextRun(run)
                if run.cell_context.as_ref().is_some_and(|c| {
                    c.path
                        .last()
                        .is_some_and(|p| p.cell_index == 10 && p.cell_para_index == 16)
                }) && !run.text.trim().is_empty() =>
            {
                *right = right.max(node.bbox.x + node.bbox.width);
                *bottom = bottom.max(node.bbox.y + node.bbox.height);
            }
            RenderNodeType::Image(image)
                if image.cell_context.as_ref().is_some_and(|c| {
                    c.path
                        .last()
                        .is_some_and(|p| p.cell_index == 10 && p.cell_para_index == 16)
                }) =>
            {
                *image_top = image_top.min(node.bbox.y);
            }
            _ => {}
        }
        for child in &node.children {
            reference_geometry(child, right, bottom, image_top);
        }
    }
    let (mut right, mut bottom, mut image_top) = (0.0_f64, 0.0_f64, f64::INFINITY);
    reference_geometry(
        &core.build_page_render_tree(1).unwrap().root,
        &mut right,
        &mut bottom,
        &mut image_top,
    );
    assert!(
        right > 690.0,
        "reference paragraph should fill cell width, right={right}"
    );
    assert!(
        image_top.is_finite() && bottom <= image_top + 1.0,
        "reference paragraph must finish before image: text={bottom}, image={image_top}"
    );
    fn next_text_gap(
        node: &rhwp::renderer::render_tree::RenderNode,
        next: &mut f64,
        picture_bottom: &mut f64,
        picture_para: usize,
        next_para: usize,
    ) {
        use rhwp::renderer::render_tree::RenderNodeType;
        match &node.node_type {
            RenderNodeType::TextRun(run)
                if run.cell_context.as_ref().is_some_and(|c| {
                    c.path
                        .last()
                        .is_some_and(|p| p.cell_index == 10 && p.cell_para_index == next_para)
                }) && !run.text.trim().is_empty() =>
            {
                *next = next.min(node.bbox.y);
            }
            RenderNodeType::Image(image)
                if image.cell_context.as_ref().is_some_and(|c| {
                    c.path
                        .last()
                        .is_some_and(|p| p.cell_index == 10 && p.cell_para_index == picture_para)
                }) =>
            {
                *picture_bottom = picture_bottom.max(node.bbox.y + node.bbox.height);
            }
            _ => {}
        }
        for child in &node.children {
            next_text_gap(child, next, picture_bottom, picture_para, next_para);
        }
    }
    let (mut next, mut picture_bottom) = (f64::INFINITY, 0.0_f64);
    next_text_gap(
        &core.build_page_render_tree(1).unwrap().root,
        &mut next,
        &mut picture_bottom,
        16,
        17,
    );
    assert!(
        (0.0..32.0).contains(&(next - picture_bottom)),
        "reference has no large blank after first picture: gap={}",
        next - picture_bottom
    );
    let (mut next, mut picture_bottom) = (f64::INFINITY, 0.0_f64);
    next_text_gap(
        &core.build_page_render_tree(2).unwrap().root,
        &mut next,
        &mut picture_bottom,
        25,
        26,
    );
    assert!(
        (0.0..32.0).contains(&(next - picture_bottom)),
        "side-by-side pictures must not append the shared text prefix twice: gap={}",
        next - picture_bottom
    );
    let bad: Vec<_> = (0..core.page_count())
        .filter(|&p| {
            layout_audit::has_unexpected_image_overlap(
                &core.build_page_render_tree(p).unwrap().root,
            )
        })
        .map(|p| p + 1)
        .collect();
    assert!(
        bad.is_empty(),
        "unexpected text/image overlap on pages {bad:?}"
    );
    fn outside(node: &rhwp::renderer::render_tree::RenderNode, bottom: f64) -> bool {
        use rhwp::renderer::render_tree::RenderNodeType;
        if !node.visible || node.editor_only {
            return false;
        }
        if let RenderNodeType::TextRun(run) = &node.node_type {
            if !run.text.trim().is_empty() && node.bbox.y + node.bbox.height > bottom + 1.0 {
                return true;
            }
        }
        node.children.iter().any(|child| outside(child, bottom))
    }
    let clipped: Vec<_> = (0..core.page_count())
        .filter(|&p| {
            let tree = core.build_page_render_tree(p).unwrap();
            outside(&tree.root, tree.root.bbox.y + tree.root.bbox.height)
        })
        .map(|p| p + 1)
        .collect();
    assert!(clipped.is_empty(), "text outside page on pages {clipped:?}");
    fn collect_text(node: &rhwp::renderer::render_tree::RenderNode, text: &mut String) {
        if !node.visible || node.editor_only {
            return;
        }
        if let rhwp::renderer::render_tree::RenderNodeType::TextRun(run) = &node.node_type {
            text.push_str(&run.text);
        }
        for child in &node.children {
            collect_text(child, text);
        }
    }
    let mut rendered = String::new();
    for p in 0..core.page_count() {
        let tree = core.build_page_render_tree(p).unwrap();
        assert!(
            !layout_audit::has_out_of_page_content(&tree.root),
            "out-of-page content on page {}",
            p + 1
        );
        collect_text(&tree.root, &mut rendered);
    }
    assert_eq!(
        rendered
            .matches("이를 막기 위해 등장한 구조가 바로")
            .count(),
        1,
        "a split paragraph must not repeat text from its previous page"
    );
    fn source_paragraphs(paragraphs: &[rhwp::model::paragraph::Paragraph], out: &mut Vec<String>) {
        for paragraph in paragraphs {
            if !paragraph.text.trim().is_empty() {
                out.push(paragraph.text.clone());
            }
            for control in &paragraph.controls {
                if let rhwp::model::control::Control::Table(table) = control {
                    for cell in &table.cells {
                        source_paragraphs(&cell.paragraphs, out);
                    }
                }
            }
        }
    }
    let compact = |s: &str| s.chars().filter(|c| !c.is_whitespace()).collect::<String>();
    let rendered = compact(&rendered);
    let mut paragraphs = Vec::new();
    for section in &core.document().sections {
        source_paragraphs(&section.paragraphs, &mut paragraphs);
    }
    for (index, paragraph) in paragraphs.iter().enumerate() {
        assert!(
            rendered.contains(&compact(paragraph)),
            "source paragraph {index} missing or interrupted in rendered text"
        );
    }
}
