//! 조판 부호 without a place in the text: 새 번호로 시작, 현재 쪽만 감추기, 책갈피, and
//! 조판 부호 지우기; and 문서 정보's 문서 통계.
use super::commands::{get, text_box};
use super::*;
use rhwp::model::{
    control::{AutoNumberType, Control},
    paragraph::Paragraph,
};

fn number_type(kind: NumberKind) -> AutoNumberType {
    match kind {
        NumberKind::Page => AutoNumberType::Page,
        NumberKind::Picture => AutoNumberType::Picture,
        NumberKind::Table => AutoNumberType::Table,
        NumberKind::Equation => AutoNumberType::Equation,
        NumberKind::Footnote => AutoNumberType::Footnote,
        NumberKind::Endnote => AutoNumberType::Endnote,
    }
}

/// A paragraph of the body, the only place these codes go.
pub(super) fn body(t: &EditTarget) -> Result<(), EditError> {
    if t.cell.is_some() || t.note.is_some() || t.header_footer.is_some() {
        Err(EditError::UnsupportedTarget)
    } else {
        Ok(())
    }
}

/// Whether `control` is a code of `kind`.
fn is(kind: CodeKind, control: &Control) -> bool {
    match (kind, control) {
        (CodeKind::Footnote, Control::Footnote(_))
        | (CodeKind::Endnote, Control::Endnote(_))
        | (CodeKind::PageHide, Control::PageHide(_))
        | (CodeKind::Picture, Control::Picture(_))
        | (CodeKind::Table, Control::Table(_))
        | (CodeKind::Equation, Control::Equation(_))
        | (CodeKind::Header, Control::Header(_))
        | (CodeKind::Footer, Control::Footer(_))
        | (CodeKind::PageNumberPosition, Control::PageNumberPos(_)) => true,
        (CodeKind::Drawing, Control::Shape(s)) => text_box(s).is_none(),
        (CodeKind::TextBox, Control::Shape(s)) => text_box(s).is_some(),
        (CodeKind::NewNumber(kind), Control::NewNumber(n)) => n.number_type == number_type(kind),
        _ => false,
    }
}

/// The codes `kinds` names in the body, or in `selection`, as section, paragraph and
/// control, each paragraph's in order.
pub(super) fn codes(
    doc: &rhwp::model::document::Document,
    selection: Option<&EditSelection>,
    kinds: &[CodeKind],
) -> Vec<(usize, usize, usize)> {
    let range = selection.map(commands::ordered);
    let mut found = Vec::new();
    for (s, section) in doc.sections.iter().enumerate() {
        for (p, para) in section.paragraphs.iter().enumerate() {
            let at = |c: usize| (s as u32, p as u32, logical::control_offset(para, c));
            for (c, control) in para.controls.iter().enumerate() {
                if !kinds.iter().any(|&k| is(k, control)) {
                    continue;
                }
                if let Some((start, end)) = &range {
                    let (s, p, offset) = at(c);
                    let from = (start.target.section, start.target.paragraph);
                    let to = (end.target.section, end.target.paragraph);
                    let text = |q: &EditPosition| {
                        get(doc, &q.target).map_or(0, |para| logical::spot(para, q.scalar).text)
                    };
                    if (s, p) < from
                        || (s, p) > to
                        || ((s, p) == from && offset < text(start))
                        || ((s, p) == to && offset >= text(end))
                    {
                        continue;
                    }
                }
                found.push((s, p, c));
            }
        }
    }
    found
}

impl EditSession {
    pub(super) fn new_number(
        &mut self,
        position: &EditPosition,
        kind: NumberKind,
        number: u16,
    ) -> Result<(), EditError> {
        let t = &position.target;
        let (s, p) = (t.section as usize, t.paragraph as usize);
        let para = get(self.core.document(), t)?;
        let existing = para
            .controls
            .iter()
            .position(|c| matches!(c, Control::NewNumber(n) if n.number_type == number_type(kind)));
        let at = logical::spot(para, position.scalar).text;
        match existing {
            Some(control) => {
                if let Control::NewNumber(n) =
                    &mut self.core.document_mut().sections[s].paragraphs[p].controls[control]
                {
                    n.number = number;
                }
                self.core.document_mut().sections[s].raw_stream = None;
            }
            None => {
                self.core
                    .insert_new_number_of_native(s, p, at, number_type(kind), number)?;
            }
        }
        Ok(())
    }

    /// What 현재 쪽만 감추기 hides from the paragraph `target` on.
    pub fn page_hide(&self, t: &EditTarget) -> Result<PageHide, EditError> {
        body(t)?;
        Ok(get(self.core.document(), t)?
            .controls
            .iter()
            .find_map(|c| match c {
                Control::PageHide(h) => Some(PageHide {
                    header: h.hide_header,
                    footer: h.hide_footer,
                    page_number: h.hide_page_num,
                    border_fill: h.hide_border || h.hide_fill,
                    master_page: h.hide_master_page,
                }),
                _ => None,
            })
            .unwrap_or_default())
    }
    pub(super) fn set_page_hide(&mut self, t: &EditTarget, h: &PageHide) -> Result<(), EditError> {
        self.core.set_page_hide_native(
            t.section as usize,
            t.paragraph as usize,
            h.header,
            h.footer,
            h.master_page,
            h.border_fill,
            h.border_fill,
            h.page_number,
        )?;
        Ok(())
    }

    /// The 책갈피 of the body, in document order.
    pub fn bookmarks(&self) -> Vec<Bookmark> {
        let mut found = Vec::new();
        for (s, section) in self.core.document().sections.iter().enumerate() {
            for (p, para) in section.paragraphs.iter().enumerate() {
                for (c, control) in para.controls.iter().enumerate() {
                    let Control::Bookmark(b) = control else {
                        continue;
                    };
                    let offset = logical::control_offset(para, c);
                    found.push(Bookmark {
                        name: b.name.clone(),
                        position: EditPosition {
                            target: EditTarget {
                                section: s as u32,
                                paragraph: p as u32,
                                cell: None,
                                note: None,
                                header_footer: None,
                            },
                            scalar: logical::position(para, offset, false),
                            upstream: false,
                        },
                        control: c as u32,
                    });
                }
            }
        }
        found
    }
    pub(super) fn add_bookmark(&mut self, p: &EditPosition, name: &str) -> Result<(), EditError> {
        let at = logical::spot(get(self.core.document(), &p.target)?, p.scalar).text;
        let reply = self.core.add_bookmark_native(
            p.target.section as usize,
            p.target.paragraph as usize,
            at,
            name,
        )?;
        accepted(&reply)
    }
    pub(super) fn change_bookmark(
        &mut self,
        t: &EditTarget,
        control: u32,
        name: Option<&str>,
    ) -> Result<(), EditError> {
        let (s, p, c) = (t.section as usize, t.paragraph as usize, control as usize);
        match name {
            Some(name) => accepted(&self.core.rename_bookmark_native(s, p, c, name)?),
            // rhwp's own 책갈피 지우기 drops a character's offset with the control.
            None => self.delete_control(t, c),
        }
    }

    /// Takes out the codes, the last first so the indexes before stay.
    pub(super) fn erase_codes(
        &mut self,
        selection: Option<&EditSelection>,
        kinds: &[CodeKind],
    ) -> Result<(), EditError> {
        let found = codes(self.core.document(), selection, kinds);
        for &(s, p, c) in found.iter().rev() {
            let target = EditTarget {
                section: s as u32,
                paragraph: p as u32,
                cell: None,
                note: None,
                header_footer: None,
            };
            self.delete_control(&target, c)?;
        }
        Ok(())
    }

    /// 상황 선: 쪽, 단, 줄, 칸, 구역 and the cell's address for the caret, and the 글자 수.
    pub fn status(&self, revision: u64, p: &EditPosition) -> Result<CaretStatus, EditError> {
        let rect = self.caret(revision, p)?;
        let t = &p.target;
        let doc = self.core.document();
        let para = get(doc, t)?;
        let spot = logical::spot(para, p.scalar);
        let raw = para
            .char_offsets
            .get(spot.text)
            .copied()
            .unwrap_or(u32::MAX);
        let mut line = para
            .line_segs
            .iter()
            .rposition(|s| s.text_start <= raw)
            .unwrap_or(0);
        // At a wrapped line's end the caret shows after the line before.
        if p.upstream && line > 0 && para.line_segs[line].text_start == raw {
            line -= 1;
        }
        let start = para.line_segs.get(line).map_or(0, |s| s.text_start);
        let start = para
            .char_offsets
            .iter()
            .position(|&o| o >= start)
            .unwrap_or(0);
        let mut status = CaretStatus {
            page: rect.page + 1,
            column: 1,
            line: line as u32 + 1,
            character: p
                .scalar
                .saturating_sub(logical::position(para, start, false))
                + 1,
            section: t.section + 1,
            sections: doc.sections.len() as u32,
            cell: None,
            characters: self.statistics().characters,
        };
        let body = t.cell.is_none() && t.note.is_none() && t.header_footer.is_none();
        let host_line = if body { line } else { 0 };
        if let Some((_, column, in_page)) =
            self.core
                .line_place_native(t.section as usize, t.paragraph as usize, host_line)
        {
            status.column = column as u32 + 1;
            if body {
                status.line = in_page;
            }
        }
        if !body {
            // In a cell, note or 머리말/꼬리말: the lines of the paragraphs before it in its text.
            let before: usize = commands::paragraphs(doc, t)?
                .iter()
                .take(commands::index(t))
                .map(|p| p.line_segs.len().max(1))
                .sum();
            status.line += before as u32;
        }
        if let (Some(c), Some(table)) = (&t.cell, commands::table(doc, t)) {
            status.cell = table.cells.get(c.cell as usize).map(|cell| {
                let mut column = String::new();
                let mut n = cell.col as u32 + 1;
                while n > 0 {
                    column.insert(0, char::from(b'A' + ((n - 1) % 26) as u8));
                    n = (n - 1) / 26;
                }
                format!("{column}{}", cell.row + 1)
            });
        }
        Ok(status)
    }
    pub fn statistics(&self) -> Statistics {
        let mut n = Statistics {
            pages: self.core.page_count(),
            ..Default::default()
        };
        // Characters outside tables and text boxes, for 원고지.
        let mut plain = 0;
        fn walk(paragraphs: &[Paragraph], boxed: bool, n: &mut Statistics, plain: &mut u32) {
            for p in paragraphs {
                let text: Vec<char> = p
                    .text
                    .chars()
                    .filter(|c| !c.is_control() || *c == '\t')
                    .collect();
                let spaces = text.iter().filter(|c| c.is_whitespace()).count() as u32;
                n.characters += text.len() as u32;
                n.characters_without_spaces += text.len() as u32 - spaces;
                n.hanja += text
                    .iter()
                    .filter(|&&c| matches!(c, '\u{3400}'..='\u{4DBF}' | '\u{4E00}'..='\u{9FFF}' | '\u{F900}'..='\u{FAFF}'))
                    .count() as u32;
                n.words += p.text.split_whitespace().count() as u32;
                n.lines += p.line_segs.len().max(1) as u32;
                n.paragraphs += 1;
                if !boxed {
                    *plain += text.len() as u32;
                }
                for control in &p.controls {
                    match control {
                        Control::Table(t) => {
                            n.tables += 1;
                            for cell in &t.cells {
                                walk(&cell.paragraphs, true, n, plain);
                            }
                        }
                        Control::Picture(_) => n.pictures += 1,
                        Control::Shape(s) => {
                            if let Some(b) = text_box(s) {
                                n.text_boxes += 1;
                                walk(&b.paragraphs, true, n, plain);
                            }
                        }
                        Control::Header(h) => walk(&h.paragraphs, boxed, n, plain),
                        Control::Footer(f) => walk(&f.paragraphs, boxed, n, plain),
                        Control::Footnote(f) => walk(&f.paragraphs, boxed, n, plain),
                        Control::Endnote(e) => walk(&e.paragraphs, boxed, n, plain),
                        _ => {}
                    }
                }
            }
        }
        for section in &self.core.document().sections {
            walk(&section.paragraphs, false, &mut n, &mut plain);
        }
        // ponytail: 200 characters a sheet, ignoring the squares a 원고지 leaves at line
        // and paragraph ends; count the grid when someone needs the exact number.
        n.manuscript = plain.div_ceil(200);
        n
    }
}

/// rhwp answers a refused 책갈피 change (an empty or taken name) with `"ok":false`.
fn accepted(reply: &str) -> Result<(), EditError> {
    match serde_json::from_str::<serde_json::Value>(reply) {
        Ok(v) if v["ok"] == serde_json::Value::Bool(true) => Ok(()),
        _ => Err(EditError::InvalidInput),
    }
}
