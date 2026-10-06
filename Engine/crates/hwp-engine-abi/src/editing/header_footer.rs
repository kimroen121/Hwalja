//! Text in a 머리말 or 꼬리말: the definition a target names, and what can be edited there.
use super::*;
use rhwp::model::{
    control::Control, document::Document, header_footer::HeaderFooterApply, paragraph::Paragraph,
};

/// The 쪽 번호, 전체 쪽 수 and 파일 이름 fields, one character each in the text.
pub(super) const FIELDS: [char; 3] = ['\u{0015}', '\u{0016}', '\u{0017}'];

/// `applyTo` as sent: 0 양쪽, 1 짝수 쪽, 2 홀수 쪽.
pub(super) fn apply(value: u8) -> Option<HeaderFooterApply> {
    match value {
        0 => Some(HeaderFooterApply::Both),
        1 => Some(HeaderFooterApply::Even),
        2 => Some(HeaderFooterApply::Odd),
        _ => None,
    }
}
pub(super) fn apply_to(apply: HeaderFooterApply) -> u8 {
    match apply {
        HeaderFooterApply::Both => 0,
        HeaderFooterApply::Even => 1,
        HeaderFooterApply::Odd => 2,
    }
}

/// The paragraphs of the definition `t` names.
pub(super) fn paragraphs<'a>(
    doc: &'a Document,
    t: &EditTarget,
) -> Result<&'a [Paragraph], EditError> {
    let hf = t
        .header_footer
        .as_ref()
        .ok_or(EditError::UnsupportedTarget)?;
    let applies = apply(hf.apply_to).ok_or(EditError::InvalidInput)?;
    doc.sections
        .get(t.section as usize)
        .ok_or(EditError::InvalidInput)?
        .paragraphs
        .iter()
        .flat_map(|p| &p.controls)
        .find_map(|c| match c {
            Control::Header(h) if !hf.footer && h.apply_to == applies => {
                Some(h.paragraphs.as_slice())
            }
            Control::Footer(f) if hf.footer && f.apply_to == applies => {
                Some(f.paragraphs.as_slice())
            }
            _ => None,
        })
        .ok_or(EditError::UnsupportedTarget)
}

/// Whether `from..to` can change: as in the body, except that fields may stand in the text
/// outside the range. Paragraphs with objects in the line stay read-only, since rhwp's
/// 머리말 caret and hit test count them differently.
pub(super) fn editable(p: &Paragraph, from: u32, to: u32) -> bool {
    let text = logical::text(p);
    commands::editable_with(p, &FIELDS)
        && !text.contains(logical::OBJECT)
        && !text
            .chars()
            .skip(from as usize)
            .take(to.saturating_sub(from) as usize)
            .any(|c| FIELDS.contains(&c))
}
