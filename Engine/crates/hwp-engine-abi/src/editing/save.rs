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
    /// Whether saving locks the document with a 문서 암호.
    pub fn has_password(&self) -> bool {
        self.password.is_some()
    }
    /// 문서 암호 설정 (`current` none), 변경 and 해제 (`new` none): the 문서 암호 saving locks
    /// the document with. `current` must be the one it has; a new one is 1–255 characters.
    pub fn set_password(
        &mut self,
        current: Option<&str>,
        new: Option<&str>,
    ) -> Result<(), EditError> {
        if self.locked {
            return Err(EditError::Locked);
        }
        if self.password.as_deref() != current.map(str::as_bytes)
            || new.is_some_and(|n| n.is_empty() || n.chars().count() > 255)
        {
            return Err(EditError::InvalidInput);
        }
        self.password = new.map(|n| n.as_bytes().to_vec());
        Ok(())
    }
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
                let marks = (
                    core.show_paragraph_marks,
                    core.show_control_codes,
                    core.show_transparent_borders,
                );
                (
                    core.show_paragraph_marks,
                    core.show_control_codes,
                    core.show_transparent_borders,
                ) = (false, false, false);
                let pdf = core.render_document_pdf_native();
                (
                    core.show_paragraph_marks,
                    core.show_control_codes,
                    core.show_transparent_borders,
                ) = marks;
                return pdf.map_err(|_| EditError::RenderFailed);
            }
            SaveFormat::Hwp => match &self.password {
                Some(password) => self.core.export_hwp_with_adapter_with_password(password),
                None => self.core.export_hwp_native(),
            },
            SaveFormat::Hwpx => match &self.password {
                Some(password) => self.core.export_hwpx_native_with_password(password),
                None => self.core.export_hwpx_native(),
            },
        }
        .map_err(|_| EditError::SaveFailed)?;
        let reparsed = match &self.password {
            Some(password) => DocumentCore::from_bytes_with_password(&bytes, password),
            None => DocumentCore::from_bytes(&bytes),
        }
        .map_err(|_| EditError::SaveFailed)?;
        if outline(reparsed.document()) != outline(self.core.document()) {
            return Err(EditError::PreservationFailed);
        }
        Ok(bytes)
    }
    /// 텍스트 문서: the document's text as 한/글 saves it.
    pub fn text_document(&self) -> Result<String, EditError> {
        serde_json::from_str(&self.core.text_file_unicode_json())
            .map_err(|_| EditError::RenderFailed)
    }
    /// 서식 있는 인터넷 문서: one page after another, each as rhwp lays it out.
    pub fn web_document(&self) -> String {
        let pages: Vec<String> = (0..self.core.page_count())
            .filter_map(|p| self.core.render_page_html_native(p).ok())
            .collect();
        format!(
            "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head>\n<body style=\"margin:0;background:#fff\">\n{}\n</body></html>\n",
            pages.join("\n")
        )
    }
}
