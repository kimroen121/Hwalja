//! Semantic addressing and safety checks for text inside a header or footer definition.
use super::*;
use rhwp::model::{
    control::Control, document::Document, header_footer::HeaderFooterApply, paragraph::Paragraph,
};

fn apply(value: u8) -> Result<HeaderFooterApply, EditError> {
    match value {
        0 => Ok(HeaderFooterApply::Both),
        1 => Ok(HeaderFooterApply::Even),
        2 => Ok(HeaderFooterApply::Odd),
        _ => Err(EditError::InvalidInput),
    }
}

/// Section, footer flag, apply kind and internal paragraph index.
pub(super) fn args(t: &EditTarget) -> Result<(usize, bool, u8, usize), EditError> {
    if t.cell.is_some() || t.note.is_some() {
        return Err(EditError::UnsupportedTarget);
    }
    let hf = t
        .header_footer
        .as_ref()
        .ok_or(EditError::UnsupportedTarget)?;
    apply(hf.apply_to)?;
    Ok((
        t.section as usize,
        hf.footer,
        hf.apply_to,
        t.paragraph as usize,
    ))
}

/// Paragraphs belonging to the exact semantic definition addressed by `target`.
pub(super) fn paragraphs<'a>(
    doc: &'a Document,
    target: &EditTarget,
) -> Result<&'a [Paragraph], EditError> {
    let (section, footer, apply_to, _) = args(target)?;
    let apply_to = apply(apply_to)?;
    let section = doc.sections.get(section).ok_or(EditError::InvalidInput)?;
    section
        .paragraphs
        .iter()
        .flat_map(|paragraph| &paragraph.controls)
        .find_map(|control| match control {
            Control::Header(header) if !footer && header.apply_to == apply_to => {
                Some(header.paragraphs.as_slice())
            }
            Control::Footer(value) if footer && value.apply_to == apply_to => {
                Some(value.paragraphs.as_slice())
            }
            _ => None,
        })
        .ok_or(EditError::UnsupportedTarget)
}

/// Whether `from..to` can be edited without consuming fields or inline controls.
pub(super) fn range_is_editable(paragraph: &Paragraph, from: u32, to: u32) -> bool {
    if from > to
        || !paragraph.title_marks.is_empty()
        || !paragraph.field_ranges.is_empty()
        || !paragraph.range_tags.is_empty()
        || !paragraph.orphan_field_ends.is_empty()
        || paragraph.ctrl_data_records.len() > paragraph.controls.len()
        || !super::logical::objects(paragraph, from, to).is_empty()
    {
        return false;
    }
    paragraph
        .text
        .chars()
        .enumerate()
        .filter(|(index, _)| from as usize <= *index && *index < to as usize)
        .all(|(_, c)| !matches!(c, '\u{0015}' | '\u{0016}' | '\u{0017}'))
        && paragraph
            .text
            .chars()
            .all(|c| !c.is_control() || matches!(c, '\t' | '\u{0015}' | '\u{0016}' | '\u{0017}'))
}
