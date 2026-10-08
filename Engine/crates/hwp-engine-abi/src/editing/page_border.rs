//! 쪽 테두리/배경: a section's border and background, with the pages they go on.
use super::commands::page_sections;
use super::*;
use rhwp::model::{control::Control, document::SectionDef};
use serde_json::{json, Value};

/// The largest 간격: 25 mm.
const MAX_SPACING: u32 = 7087;
const SIDES: [&str; 4] = ["borderLeft", "borderRight", "borderTop", "borderBottom"];

fn color(text: &str) -> bool {
    text.strip_prefix('#')
        .is_some_and(|hex| hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit()))
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
}
