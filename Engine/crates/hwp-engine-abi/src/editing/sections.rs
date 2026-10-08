//! A section's definition: 쪽 테두리/배경 (its border and background, with the pages they
//! go on) and 구역 설정.
use super::commands::page_sections;
use super::*;
use rhwp::model::{
    control::Control,
    document::{Document, SectionDef},
    footnote::FootnoteNumbering,
    paragraph::Paragraph,
};
use serde_json::{json, Value};

/// The largest 간격: 25 mm.
const MAX_SPACING: u32 = 7087;
const SIDES: [&str; 4] = ["borderLeft", "borderRight", "borderTop", "borderBottom"];

fn color(text: &str) -> bool {
    text.strip_prefix('#')
        .is_some_and(|hex| hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit()))
}
/// 기본 탭 간격 and 단 사이 간격 up to 100 mm.
const MAX_GAP: u32 = 28346;

/// 번호 모양 a 각주 takes; a 미주 takes all but the symbols. 기호 (`userChar`) is left out:
/// the mark in the body has no way to its character.
const NOTE_FORMATS: [&str; 18] = [
    "digit",
    "circledDigit",
    "upperRoman",
    "lowerRoman",
    "upperAlpha",
    "lowerAlpha",
    "circledUpperAlpha",
    "circledLowerAlpha",
    "hangulSyllable",
    "circledHangulSyllable",
    "hangulJamo",
    "circledHangulJamo",
    "hangulDigit",
    "hanjaDigit",
    "circledHanjaDigit",
    "hanjaGapEul",
    "hanjaGapEulHanja",
    "fourSymbol",
];
pub(super) fn valid_note(shape: &NoteShape, footnote: bool) -> bool {
    let formats = if footnote {
        &NOTE_FORMATS[..]
    } else {
        &NOTE_FORMATS[..17]
    };
    let one = |s: &str| s.chars().count() <= 1;
    let margin = |m: i32| (0..=MAX_SPACING as i32).contains(&m);
    formats.contains(&shape.number_format.as_str())
        && one(&shape.user_char)
        && one(&shape.prefix_char)
        && one(&shape.suffix_char)
        && (-4..=MAX_GAP as i32).contains(&shape.separator_length)
        && shape.separator_line_type <= 17
        && shape.separator_line_width <= 15
        && color(&shape.separator_color)
        && margin(shape.separator_margin_top)
        && margin(shape.separator_margin_bottom)
        && margin(shape.note_spacing)
        && match shape.numbering.as_str() {
            "continue" | "restartSection" => true,
            "restartPage" => footnote,
            _ => false,
        }
}
/// Numbers the notes through the document as each section's 번호 매기기 says: on from the
/// section before, or anew from its start number. Sections that start anew on each page keep
/// their 각주 numbers.
fn number_notes(doc: &mut Document) {
    fn walk(paragraphs: &mut [Paragraph], footnotes: Option<&mut u16>, endnotes: &mut u16) {
        let mut footnotes = footnotes;
        for p in paragraphs {
            for c in &mut p.controls {
                match c {
                    Control::Footnote(n) => {
                        if let Some(f) = footnotes.as_deref_mut() {
                            *f = f.saturating_add(1);
                            n.number = *f;
                        }
                    }
                    Control::Endnote(n) => {
                        *endnotes = endnotes.saturating_add(1);
                        n.number = *endnotes;
                    }
                    Control::Table(t) => {
                        for cell in &mut t.cells {
                            walk(&mut cell.paragraphs, footnotes.as_deref_mut(), endnotes);
                        }
                    }
                    Control::Shape(s) => {
                        if let Some(b) = s.drawing_mut().and_then(|d| d.text_box.as_mut()) {
                            walk(&mut b.paragraphs, footnotes.as_deref_mut(), endnotes);
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    let (mut footnotes, mut endnotes) = (0u16, 0u16);
    for (i, section) in doc.sections.iter_mut().enumerate() {
        let (f, e) = (
            &section.section_def.footnote_shape,
            &section.section_def.endnote_shape,
        );
        if i == 0 || f.numbering == FootnoteNumbering::RestartSection {
            footnotes = f.start_number.max(1) - 1;
        }
        if i == 0 || e.numbering == FootnoteNumbering::RestartSection {
            endnotes = e.start_number.max(1) - 1;
        }
        let by_page = f.numbering == FootnoteNumbering::RestartPage;
        walk(
            &mut section.paragraphs,
            (!by_page).then_some(&mut footnotes),
            &mut endnotes,
        );
    }
}
pub(super) fn valid_setup(setup: &SectionSetup) -> bool {
    setup.page_num_type <= 2
        && (1..=MAX_GAP).contains(&setup.default_tab_spacing)
        && (0..=MAX_GAP as i32).contains(&setup.column_spacing)
}
pub(super) fn valid(border: &PageBorder) -> bool {
    border
        .sides
        .iter()
        .all(|s| s.line <= 17 && s.width <= 15 && color(&s.color))
        && border.spacing.iter().all(|&s| s <= MAX_SPACING)
        && border.fill.as_ref().is_none_or(|f| {
            (f.color == "none" || color(&f.color)) && color(&f.pattern_color) && f.pattern <= 6
        })
}
/// 첫 쪽 제외 is the definition's hide flag, 첫 쪽만 its show-first flag (bits 3/4 and 8/9).
fn set_pages(sd: &mut SectionDef, border: ApplyPages, fill: ApplyPages) {
    sd.hide_border = border == ApplyPages::ExceptFirst;
    sd.hide_fill = fill == ApplyPages::ExceptFirst;
    sd.first_page_border = border == ApplyPages::FirstOnly;
    sd.first_page_fill = fill == ApplyPages::FirstOnly;
    for (bit, on) in [
        (0x0008, sd.hide_border),
        (0x0010, sd.hide_fill),
        (0x0100, sd.first_page_border),
        (0x0200, sd.first_page_fill),
    ] {
        if on {
            sd.flags |= bit;
        } else {
            sd.flags &= !bit;
        }
    }
}
fn pages(hide: bool, first: bool) -> ApplyPages {
    if hide {
        ApplyPages::ExceptFirst
    } else if first {
        ApplyPages::FirstOnly
    } else {
        ApplyPages::All
    }
}

impl EditSession {
    /// 쪽 테두리/배경 of a section.
    pub fn page_border(&self, section: u32) -> Result<PageBorder, EditError> {
        let v: Value =
            serde_json::from_str(&self.core.get_page_border_fill_native(section as usize)?)
                .map_err(|_| EditError::RenderFailed)?;
        let doc = self.core.document();
        let sd = &doc.sections[section as usize].section_def;
        let pbf = &sd.page_border_fill;
        let fill = (pbf.border_fill_id as usize)
            .checked_sub(1)
            .and_then(|i| doc.doc_info.border_fills.get(i))
            .map(|bf| &bf.fill);
        let text = |v: &Value| v.as_str().unwrap_or("#000000").to_string();
        let number = |v: &Value| v.as_u64().unwrap_or(0) as u8;
        Ok(PageBorder {
            sides: SIDES.map(|key| BorderSide {
                line: number(&v[key]["type"]),
                width: number(&v[key]["width"]),
                color: text(&v[key]["color"]),
            }),
            paper: v["basis"] == "paper",
            spacing: [
                pbf.spacing_left,
                pbf.spacing_right,
                pbf.spacing_top,
                pbf.spacing_bottom,
            ]
            .map(|s| s.max(0) as u32),
            header_inside: v["headerInside"] == true,
            footer_inside: v["footerInside"] == true,
            border_pages: pages(sd.hide_border, sd.first_page_border),
            fill_pages: pages(sd.hide_fill, sd.first_page_fill),
            fill: match fill {
                Some(f) if f.gradient.is_some() || f.image.is_some() => None,
                _ => Some(PageFill {
                    color: if v["fillType"] == "solid" {
                        text(&v["fillColor"])
                    } else {
                        "none".into()
                    },
                    pattern_color: text(&v["patternColor"]),
                    pattern: number(&v["patternType"]).min(6),
                }),
            },
            fill_area: match v["fillArea"].as_str() {
                Some("page") => FillArea::Page,
                Some("border") => FillArea::Border,
                _ => FillArea::Paper,
            },
        })
    }
    pub(super) fn set_page_border(
        &mut self,
        section: u32,
        border: &PageBorder,
        whole: bool,
    ) -> Result<(), EditError> {
        for s in page_sections(self.core.document(), section, whole) {
            let sec = &mut self.core.document_mut().sections[s];
            // Starting from the section's own keeps what the dialog does not show.
            let mut props = json!({
                "borderFillId": sec.section_def.page_border_fill.border_fill_id,
                "basis": if border.paper { "paper" } else { "page" },
                "spacingLeft": border.spacing[0],
                "spacingRight": border.spacing[1],
                "spacingTop": border.spacing[2],
                "spacingBottom": border.spacing[3],
                "headerInside": border.header_inside,
                "footerInside": border.footer_inside,
                "fillArea": match border.fill_area {
                    FillArea::Paper => "paper",
                    FillArea::Page => "page",
                    FillArea::Border => "border",
                },
                "hideBorder": border.border_pages == ApplyPages::ExceptFirst,
                "hideFill": border.fill_pages == ApplyPages::ExceptFirst,
            });
            for (key, side) in SIDES.iter().zip(&border.sides) {
                props[*key] = json!({
                    "type": side.line,
                    "width": side.width,
                    "color": side.color.to_lowercase(),
                });
            }
            if let Some(fill) = &border.fill {
                let none = fill.color == "none" && fill.pattern == 0;
                props["fillType"] = json!(if none { "none" } else { "solid" });
                props["fillColor"] = json!(if fill.color == "none" {
                    "#ffffff".into()
                } else {
                    fill.color.to_lowercase()
                });
                props["patternColor"] = json!(fill.pattern_color.to_lowercase());
                props["patternType"] = json!(fill.pattern);
            }
            // rhwp's setter copies the flags into the section's own definition control.
            set_pages(&mut sec.section_def, border.border_pages, border.fill_pages);
            for c in sec.paragraphs.iter_mut().flat_map(|p| &mut p.controls) {
                if let Control::SectionDef(sd) = c {
                    set_pages(sd, border.border_pages, border.fill_pages);
                    break;
                }
            }
            self.core
                .set_page_border_fill_native(s, &props.to_string())?;
        }
        Ok(())
    }
    /// 구역 설정 of a section.
    pub fn section_setup(&self, section: u32) -> Result<SectionSetup, EditError> {
        serde_json::from_str(&self.core.get_section_def_native(section as usize)?)
            .map_err(|_| EditError::RenderFailed)
    }
    pub(super) fn set_section(
        &mut self,
        section: u32,
        setup: &SectionSetup,
        whole: bool,
    ) -> Result<(), EditError> {
        // 첫 쪽에만 테두리/배경 감추기 and 쪽 테두리/배경's 첫 쪽만 share the flags: hiding
        // the first page takes 첫 쪽만 off.
        let pages = |hide: bool, first: bool| pages(hide, first && !hide);
        for s in page_sections(self.core.document(), section, whole) {
            let sec = &mut self.core.document_mut().sections[s];
            let sd = &sec.section_def;
            let (border, fill) = (
                pages(setup.hide_border, sd.first_page_border),
                pages(setup.hide_fill, sd.first_page_fill),
            );
            set_pages(&mut sec.section_def, border, fill);
            for c in sec.paragraphs.iter_mut().flat_map(|p| &mut p.controls) {
                if let Control::SectionDef(sd) = c {
                    set_pages(sd, border, fill);
                    break;
                }
            }
        }
        let json = serde_json::to_string(setup).map_err(|_| EditError::InvalidInput)?;
        if whole {
            self.core.set_section_def_all_native(&json)?;
        } else {
            self.core.set_section_def_native(section as usize, &json)?;
        }
        Ok(())
    }
    /// 각주 모양 (`footnote`) or 미주 모양 of a section.
    pub fn note_shape(&self, section: u32, footnote: bool) -> Result<NoteShape, EditError> {
        serde_json::from_str(
            &self
                .core
                .get_note_shape_native(section as usize, footnote)?,
        )
        .map_err(|_| EditError::RenderFailed)
    }
    pub(super) fn set_note_shape(
        &mut self,
        section: u32,
        footnote: bool,
        shape: &NoteShape,
        whole: bool,
    ) -> Result<(), EditError> {
        let json = serde_json::to_string(shape).map_err(|_| EditError::InvalidInput)?;
        for s in page_sections(self.core.document(), section, whole) {
            self.core
                .apply_note_shape_native(s, footnote, false, &json)?;
        }
        number_notes(self.core.document_mut());
        // Lays out every section again with its new numbers, each in its own shape.
        for s in 0..self.core.document().sections.len() {
            self.core.apply_note_shape_native(s, true, false, "{}")?;
            self.core.apply_note_shape_native(s, false, false, "{}")?;
        }
        Ok(())
    }
}
