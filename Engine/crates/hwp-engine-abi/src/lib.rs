use rhwp::DocumentCore;
pub mod editing;
pub mod layout_audit;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

pub struct HwpSnapshot {
    pdf: Vec<u8>,
    pages: u32,
    warnings: CString,
}
#[repr(C)]
pub struct HwpOpenResult {
    pub snapshot: *mut HwpSnapshot,
    /// 0 success, 1 invalid, 2 password required, 3 unsupported, 4 rendering, 5 limit, 6 panic.
    pub status: u32,
    pub message: *mut c_char,
}
#[no_mangle]
pub extern "C" fn hwp_engine_abi_version() -> u32 {
    1
}
fn failure(status: u32, message: String) -> HwpOpenResult {
    HwpOpenResult {
        snapshot: std::ptr::null_mut(),
        status,
        message: CString::new(message.replace('\0', " ")).unwrap().into_raw(),
    }
}
/// Panic containment is not process isolation.
///
/// # Safety
/// `data` must be readable for `length` bytes.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_open(data: *const u8, length: usize) -> HwpOpenResult {
    if length > 64 * 1024 * 1024 {
        return failure(5, "Files larger than 64 MiB are unsupported.".into());
    }
    if data.is_null() || length == 0 {
        return failure(1, "Empty or missing document.".into());
    }
    match catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(data, length) };
        if let Err(error) = rhwp::parser::parse_document(bytes) {
            let status = match &error {
                rhwp::parser::ParseError::EncryptedDocument => 2,
                rhwp::parser::ParseError::UnsupportedFormat { .. } => 3,
                _ => 1,
            };
            return failure(status, error.to_string());
        }
        let core = match DocumentCore::from_bytes(bytes) {
            Ok(core) => core,
            Err(error) => return failure(1, error.to_string()),
        };
        let pages = core.page_count();
        if pages > 1000 {
            return failure(5, "Documents exceeding 1,000 pages are unsupported.".into());
        }
        let warnings = match layout_audit::warnings(&core) {
            Ok(text) => CString::new(text).unwrap(),
            Err(error) => return failure(4, error.to_string()),
        };
        match core.render_document_pdf_native() {
            Ok(pdf) => HwpOpenResult {
                snapshot: Box::into_raw(Box::new(HwpSnapshot {
                    pdf,
                    pages,
                    warnings,
                })),
                status: 0,
                message: std::ptr::null_mut(),
            },
            Err(error) => failure(4, error.to_string()),
        }
    })) {
        Ok(result) => result,
        Err(_) => failure(6, "The document engine stopped unexpectedly.".into()),
    }
}
/// Borrowed UTF-8 warning text, valid until snapshot_free. Empty is not a fidelity guarantee.
/// # Safety
/// `snapshot` must be null or a live snapshot.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_layout_warnings(snapshot: *const HwpSnapshot) -> *const c_char {
    if snapshot.is_null() {
        std::ptr::null()
    } else {
        unsafe { (*snapshot).warnings.as_ptr() }
    }
}
/// Borrowed bytes stay valid until snapshot_free; do not mutate or free them.
/// # Safety
/// `snapshot` must be null or a live snapshot.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_pdf_data(snapshot: *const HwpSnapshot) -> *const u8 {
    if snapshot.is_null() {
        std::ptr::null()
    } else {
        unsafe { (*snapshot).pdf.as_ptr() }
    }
}
/// # Safety
/// `snapshot` must be null or a live snapshot.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_pdf_length(snapshot: *const HwpSnapshot) -> usize {
    if snapshot.is_null() {
        0
    } else {
        unsafe { (*snapshot).pdf.len() }
    }
}
/// # Safety
/// `snapshot` must be null or a live snapshot.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_page_count(snapshot: *const HwpSnapshot) -> u32 {
    if snapshot.is_null() {
        0
    } else {
        unsafe { (*snapshot).pages }
    }
}
/// # Safety
/// Free once; null allowed. Snapshot access must not overlap release.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_snapshot_free(snapshot: *mut HwpSnapshot) {
    if !snapshot.is_null() {
        drop(unsafe { Box::from_raw(snapshot) });
    }
}
/// # Safety
/// `value` must be null or a message returned by this library, freed once.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_empty_and_oversized_before_reading() {
        for (length, status) in [(0, 1), (64 * 1024 * 1024 + 1, 5)] {
            let result = unsafe { hwp_engine_open(std::ptr::null(), length) };
            assert_eq!(result.status, status);
            unsafe { hwp_engine_string_free(result.message) };
        }
    }
    #[test]
    fn generated_hwp_and_hwpx_produce_owned_pdf_snapshots() {
        let mut source = DocumentCore::new_empty();
        source.create_blank_document_native().unwrap();
        source
            .insert_text_native(0, 0, 0, "HwpStudio generated fixture — 한글 읽기 전용")
            .unwrap();
        for (extension, bytes) in [
            ("hwp", source.export_hwp_native().unwrap()),
            ("hwpx", source.export_hwpx_native().unwrap()),
        ] {
            let result = unsafe { hwp_engine_open(bytes.as_ptr(), bytes.len()) };
            if result.status != 0 {
                panic!(
                    "{}",
                    unsafe { std::ffi::CStr::from_ptr(result.message) }.to_string_lossy()
                );
            }
            unsafe {
                assert!(
                    std::ffi::CStr::from_ptr(hwp_engine_layout_warnings(result.snapshot))
                        .to_bytes()
                        .is_empty()
                );
                assert!(hwp_engine_page_count(result.snapshot) > 0);
                let pdf = std::slice::from_raw_parts(
                    hwp_engine_pdf_data(result.snapshot),
                    hwp_engine_pdf_length(result.snapshot),
                );
                assert!(pdf.starts_with(b"%PDF-"));
                hwp_engine_snapshot_free(result.snapshot);
            }
            if std::env::var_os("HWP_WRITE_FIXTURES").is_some() {
                let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../../Tests/Fixtures");
                std::fs::create_dir_all(&folder).unwrap();
                std::fs::write(folder.join(format!("generated.{extension}")), bytes).unwrap();
            }
        }
    }
    #[test]
    fn classifies_corrupt_password_and_drm_documents() {
        let mut source = DocumentCore::new_empty();
        source.create_blank_document_native().unwrap();
        let encrypted = source
            .export_hwpx_native_with_password(b"fixture-password")
            .unwrap();
        for (bytes, expected) in [
            (encrypted.as_slice(), 2),
            (b"\x9b DRMONE protected".as_slice(), 3),
            (b"PK\x03\x04broken".as_slice(), 3),
            (b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1".as_slice(), 1),
        ] {
            let result = unsafe { hwp_engine_open(bytes.as_ptr(), bytes.len()) };
            assert_eq!(result.status, expected);
            assert!(result.snapshot.is_null());
            unsafe { hwp_engine_string_free(result.message) };
        }
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
                        c.path.last().is_some_and(|p| {
                            p.cell_index == 10 && p.cell_para_index == picture_para
                        })
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
        fn source_paragraphs(
            paragraphs: &[rhwp::model::paragraph::Paragraph],
            out: &mut Vec<String>,
        ) {
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
}
