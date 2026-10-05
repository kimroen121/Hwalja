use super::*;
use rhwp::model::{control::Control, document::Document, paragraph::Paragraph};

/// Text and control structure of every paragraph, including table cells.
fn outline(doc: &Document) -> Vec<String> {
    fn walk(paragraphs: &[Paragraph], out: &mut Vec<String>) {
        for p in paragraphs {
            let kinds: Vec<_> = p.controls.iter().map(std::mem::discriminant).collect();
            out.push(format!("{}|{kinds:?}", p.text));
            for c in &p.controls {
                if let Control::Table(t) = c {
                    for cell in &t.cells {
                        walk(&cell.paragraphs, out);
                    }
                }
            }
        }
    }
    let mut out = Vec::new();
    for s in &doc.sections {
        walk(&s.paragraphs, &mut out);
    }
    out
}

impl EditSession {
    /// Serializes the current document and verifies that HWP/HWPX bytes parse back to the
    /// same text and control structure. Nothing is written to disk.
    pub fn export(&mut self, format: SaveFormat) -> Result<Vec<u8>, EditError> {
        if self.locked {
            return Err(EditError::Locked);
        }
        let bytes = match format {
            SaveFormat::Pdf => {
                // Marks shown on screen stay off paper.
                let core = &mut self.core;
                let marks = (core.show_paragraph_marks, core.show_control_codes);
                (core.show_paragraph_marks, core.show_control_codes) = (false, false);
                let pdf = core.render_document_pdf_native();
                (core.show_paragraph_marks, core.show_control_codes) = marks;
                return pdf.map_err(|_| EditError::RenderFailed);
            }
            SaveFormat::Hwp => self.core.export_hwp_native(),
            SaveFormat::Hwpx => self.core.export_hwpx_native(),
        }
        .map_err(|_| EditError::SaveFailed)?;
        let reparsed = DocumentCore::from_bytes(&bytes).map_err(|_| EditError::SaveFailed)?;
        if outline(reparsed.document()) != outline(self.core.document()) {
            return Err(EditError::PreservationFailed);
        }
        Ok(bytes)
    }
}
