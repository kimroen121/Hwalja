//! Conservative geometry checks, not a claim of Hancom compatibility.
use rhwp::model::shape::TextWrap;
use rhwp::renderer::render_tree::{BoundingBox, RenderNode, RenderNodeType};

pub fn has_out_of_page_content(root: &RenderNode) -> bool {
    fn outside(node: &RenderNode, page: &BoundingBox) -> bool {
        if !node.visible || node.editor_only {
            return false;
        }
        if matches!(&node.node_type, RenderNodeType::TextRun(run) if !run.text.trim().is_empty()) {
            let b = node.bbox;
            if b.x < page.x - 1.0
                || b.y < page.y - 1.0
                || b.x + b.width > page.x + page.width + 1.0
                || b.y + b.height > page.y + page.height + 1.0
            {
                return true;
            }
        }
        node.children.iter().any(|child| outside(child, page))
    }
    outside(root, &root.bbox)
}

pub fn has_unexpected_image_overlap(root: &RenderNode) -> bool {
    let mut texts = Vec::new();
    let mut images = Vec::new();
    collect(root, None, &mut texts, &mut images);
    images
        .iter()
        .any(|(image, wrap)| texts.iter().any(|text| overlaps(text, image, *wrap)))
}

fn collect(
    node: &RenderNode,
    inherited: Option<TextWrap>,
    texts: &mut Vec<BoundingBox>,
    images: &mut Vec<(BoundingBox, Option<TextWrap>)>,
) {
    if !node.visible || node.editor_only {
        return;
    }
    let wrap = node
        .layer
        .as_ref()
        .and_then(|layer| layer.text_wrap)
        .or(inherited);
    match &node.node_type {
        RenderNodeType::TextRun(run) if !run.text.trim().is_empty() => texts.push(node.bbox),
        RenderNodeType::Image(image)
            if image.opacity > 0.0
                && image.transform.rotation == 0.0
                && image.fill_mode.is_none() =>
        {
            images.push((node.bbox, image.text_wrap.or(wrap)))
        }
        _ => {}
    }
    for child in &node.children {
        collect(child, wrap, texts, images);
    }
}

fn overlaps(text: &BoundingBox, image: &BoundingBox, wrap: Option<TextWrap>) -> bool {
    // Do not flag deliberately layered text, watermarks, or inline images whose
    // wrapping semantics are unavailable. A 1px tolerance ignores edge rounding.
    if !matches!(wrap, Some(TextWrap::TopAndBottom | TextWrap::Square)) {
        return false;
    }
    let width = (text.x + text.width).min(image.x + image.width) - text.x.max(image.x);
    let height = (text.y + text.height).min(image.y + image.height) - text.y.max(image.y);
    width > 1.0 && height > 1.0
}

/// Whether a zero-based page shows suspected text/image overlap or text outside the page.
/// `false` does not prove fidelity.
pub fn is_suspect_page(
    core: &rhwp::DocumentCore,
    page: u32,
) -> Result<bool, rhwp::error::HwpError> {
    let tree = core.build_page_render_tree(page)?;
    Ok(has_unexpected_image_overlap(&tree.root) || has_out_of_page_content(&tree.root))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detects_visible_text_beyond_page_but_ignores_hidden_content() {
        let mut core = rhwp::DocumentCore::new_empty();
        core.create_blank_document_native().unwrap();
        core.insert_text_native(0, 0, 0, "page edge").unwrap();
        let mut tree = core.build_page_render_tree(0).unwrap();
        assert!(!has_out_of_page_content(&tree.root));
        fn move_text(node: &mut RenderNode, y: f64, visible: bool) {
            if matches!(&node.node_type, RenderNodeType::TextRun(run) if !run.text.trim().is_empty())
            {
                node.bbox.y = y;
                node.visible = visible;
            }
            for child in &mut node.children {
                move_text(child, y, visible);
            }
        }
        let bottom = tree.root.bbox.y + tree.root.bbox.height;
        move_text(&mut tree.root, bottom + 2.0, true);
        assert!(has_out_of_page_content(&tree.root));
        move_text(&mut tree.root, bottom + 2.0, false);
        assert!(!has_out_of_page_content(&tree.root));
    }
    #[test]
    fn reads_picture_wrap_metadata_and_ignores_hidden_images() {
        use rhwp::renderer::render_tree::ImageNode;
        let mut core = rhwp::DocumentCore::new_empty();
        core.create_blank_document_native().unwrap();
        core.insert_text_native(0, 0, 0, "visible text").unwrap();
        let mut tree = core.build_page_render_tree(0).unwrap();
        fn first_text(node: &RenderNode) -> Option<BoundingBox> {
            if matches!(node.node_type, RenderNodeType::TextRun(_)) {
                return Some(node.bbox);
            }
            node.children.iter().find_map(first_text)
        }
        let text_box = first_text(&tree.root).unwrap();
        let mut picture = ImageNode::new(1, None);
        picture.text_wrap = Some(TextWrap::TopAndBottom);
        tree.root.children.push(RenderNode::new(
            10000,
            RenderNodeType::Image(picture),
            text_box,
        ));
        assert!(has_unexpected_image_overlap(&tree.root));
        tree.root.children.last_mut().unwrap().visible = false;
        assert!(!has_unexpected_image_overlap(&tree.root));
    }
    #[test]
    fn image_that_requires_clear_space_must_not_cover_text() {
        let text = BoundingBox::new(10.0, 20.0, 100.0, 12.0);
        let image = BoundingBox::new(50.0, 10.0, 80.0, 80.0);
        assert!(overlaps(&text, &image, Some(TextWrap::TopAndBottom)));
        assert!(overlaps(&text, &image, Some(TextWrap::Square)));
    }
    #[test]
    fn intentional_layering_and_touching_edges_are_not_errors() {
        let text = BoundingBox::new(10.0, 20.0, 100.0, 12.0);
        let image = BoundingBox::new(50.0, 10.0, 80.0, 80.0);
        assert!(!overlaps(&text, &image, Some(TextWrap::BehindText)));
        assert!(!overlaps(&text, &image, Some(TextWrap::InFrontOfText)));
        assert!(!overlaps(&text, &image, None));
        assert!(!overlaps(
            &text,
            &BoundingBox::new(110.0, 20.0, 30.0, 12.0),
            Some(TextWrap::Square)
        ));
    }
}
