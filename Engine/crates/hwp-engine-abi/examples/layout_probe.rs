//! Local-only diagnostic. Input documents are never changed or uploaded.
use std::{env, fs, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(1);
    let input = PathBuf::from(args.next().ok_or("input path required")?);
    let out = PathBuf::from(args.next().ok_or("output directory required")?);
    fs::create_dir_all(&out)?;
    let bytes = fs::read(input)?;
    let doc = rhwp::parser::parse_document(&bytes)?;
    fs::write(out.join("parsed.txt"), format!("{:#?}", doc.sections))?;
    let core = rhwp::DocumentCore::from_bytes(&bytes).map_err(|e| e.to_string())?;
    println!("pages={}", core.page_count());
    for page in 0..core.page_count() {
        let tree = core
            .build_page_render_tree(page)
            .map_err(|e| e.to_string())?;
        let mut positions = String::new();
        summarize(&tree.root, &mut positions);
        fs::write(out.join(format!("positions-{}.txt", page + 1)), positions)?;
        println!(
            "page={} unexpected_overlap={}",
            page + 1,
            hwp_engine_abi::layout_audit::has_unexpected_image_overlap(
                &core
                    .build_page_render_tree(page)
                    .map_err(|e| e.to_string())?
                    .root
            )
        );
        fs::write(
            out.join(format!("page-{}.svg", page + 1)),
            core.render_page_svg_native(page)
                .map_err(|e| e.to_string())?,
        )?;
        fs::write(
            out.join(format!("tree-{}.txt", page + 1)),
            format!(
                "{:#?}",
                core.build_page_render_tree(page)
                    .map_err(|e| e.to_string())?
            ),
        )?;
    }
    fs::write(
        out.join("document.pdf"),
        core.render_document_pdf_native()
            .map_err(|e| e.to_string())?,
    )?;
    Ok(())
}

fn summarize(node: &rhwp::renderer::render_tree::RenderNode, out: &mut String) {
    use rhwp::renderer::render_tree::RenderNodeType;
    use std::fmt::Write;
    match &node.node_type {
        RenderNodeType::TextRun(t) => {
            let _ = writeln!(
                out,
                "TEXT {:?} {:?} {:?}",
                node.bbox, t.cell_context, t.text
            );
        }
        RenderNodeType::Image(i) => {
            let _ = writeln!(
                out,
                "IMAGE {:?} {:?} {:?} bin={}",
                node.bbox, i.cell_context, i.text_wrap, i.bin_data_id
            );
        }
        _ => {}
    }
    for child in &node.children {
        summarize(child, out);
    }
}
