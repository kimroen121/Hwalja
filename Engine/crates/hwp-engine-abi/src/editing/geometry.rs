use super::*;
use serde_json::Value;

fn field(json: &Value, key: &str) -> Result<u32, EditError> {
    json.get(key)
        .and_then(Value::as_u64)
        .map(|v| v as u32)
        .ok_or(EditError::UnsupportedTarget)
}
fn rect(json: &Value) -> Result<PageRect, EditError> {
    let number = |key| {
        json.get(key)
            .and_then(Value::as_f64)
            .ok_or(EditError::RenderFailed)
    };
    Ok(PageRect {
        page: field(json, "pageIndex")?,
        x: number("x")?,
        y: number("y")?,
        width: 0.0,
        height: number("height")?,
    })
}
fn parse(text: Result<String, rhwp::error::HwpError>) -> Result<Value, EditError> {
    serde_json::from_str(&text.map_err(|_| EditError::UnsupportedTarget)?)
        .map_err(|_| EditError::RenderFailed)
}

impl EditSession {
    pub(super) fn check_revision(&self, revision: u64) -> Result<(), EditError> {
        if self.locked {
            return Err(EditError::Locked);
        }
        if revision == self.revision {
            Ok(())
        } else {
            Err(EditError::StaleRevision)
        }
    }
    /// Document position under a page point (96 dpi, top-left origin). Only body text and
    /// one level of table cells are addressable; text boxes and nested tables are refused.
    pub fn hit_test(
        &self,
        revision: u64,
        page: u32,
        x: f64,
        y: f64,
        include_header_footer: bool,
    ) -> Result<EditPosition, EditError> {
        self.check_revision(revision)?;
        if page >= self.core.page_count() {
            return Err(EditError::InvalidInput);
        }
        if include_header_footer {
            if let Some(position) = self.hit_test_header_footer(page, x, y)? {
                return Ok(position);
            }
        }
        if let Some(position) = self.hit_test_footnote(page, x, y)? {
            return Ok(position);
        }
        let hit = parse(self.core.hit_test_native(page, x, y))?;
        let section = field(&hit, "sectionIndex")?;
        let target = match hit.get("cellPath").and_then(Value::as_array) {
            None => EditTarget {
                section,
                paragraph: field(&hit, "paragraphIndex")?,
                cell: None,
                note: None,
                header_footer: None,
            },
            Some(path) if path.len() == 1 => EditTarget {
                section,
                paragraph: field(&hit, "parentParaIndex")?,
                cell: Some(CellTarget {
                    control: field(&hit, "controlIndex")?,
                    cell: field(&hit, "cellIndex")?,
                    paragraph: field(&hit, "cellParaIndex")?,
                }),
                note: None,
                header_footer: None,
            },
            Some(_) => return Err(EditError::UnsupportedTarget),
        };
        commands::get(self.core.document(), &target)?;
        let rhwp = EditPosition {
            target,
            scalar: field(&hit, "charOffset")?,
            upstream: false,
        };
        // A line of objects alone is the objects' paragraph, wherever rhwp's answer went.
        let target = match self.object_line(page, x, y) {
            Some(line) if line != rhwp.target => {
                let at = self.rhwp_caret(&rhwp)?;
                if at.page == page && (at.y..=at.y + at.height).contains(&y) {
                    rhwp.target
                } else {
                    line
                }
            }
            _ => rhwp.target,
        };
        let scalar = match self.stops(&target, page..=page) {
            Some(stops) => stops::nearest(&stops, page, x, y).ok_or(EditError::RenderFailed)?,
            None => rhwp.scalar,
        };
        Ok(self.wrap_end(
            EditPosition {
                target,
                scalar,
                upstream: false,
            },
            page,
            x,
            y,
        ))
    }
    /// A point on a wrapped line past the middle of its last character is at the line's end.
    fn wrap_end(&self, p: EditPosition, page: u32, x: f64, y: f64) -> EditPosition {
        let Some(stops) = self.drawn_stops(&p.target) else {
            return p;
        };
        for k in [p.scalar, p.scalar + 1] {
            let (Some(next), Some((_, last))) = (stops.get(&k), stops.range(..k).next_back())
            else {
                continue;
            };
            let on_line = last.page == page && (last.y..=last.y + last.height).contains(&y);
            let right = self.line_right(&p.target, &last.rect()).unwrap_or(last.x);
            if !last.same_line(next) && on_line && x > (last.x + right) / 2.0 {
                return EditPosition {
                    scalar: k,
                    upstream: true,
                    ..p
                };
            }
        }
        p
    }
    /// A position in the 머리말 or 꼬리말 shown on `page`, when the point is on its text.
    fn hit_test_header_footer(
        &self,
        page: u32,
        x: f64,
        y: f64,
    ) -> Result<Option<EditPosition>, EditError> {
        for footer in [false, true] {
            let hit = parse(
                self.core
                    .hit_test_in_header_footer_native(page, !footer, x, y),
            )?;
            if hit.get("hit") != Some(&Value::Bool(true)) {
                continue;
            }
            // rhwp takes the nearest line from anywhere on the page; only its text and the
            // 머리말 (꼬리말) area count, so an empty one can be entered too.
            let line = hit.get("cursorRect").ok_or(EditError::RenderFailed)?;
            let number = |value: &Value, key| {
                value
                    .get(key)
                    .and_then(Value::as_f64)
                    .ok_or(EditError::RenderFailed)
            };
            let (top, height) = (number(line, "y")?, number(line, "height")?);
            let info = parse(self.core.get_page_info_native(page))?;
            let area = &info[if footer { "footerArea" } else { "headerArea" }];
            let in_area = number(area, "y")
                .and_then(|top| Ok(top <= y && y <= top + number(area, "height")?))
                .unwrap_or(false);
            if !in_area && (y < top - 2.0 || y > top + height + 2.0) {
                continue;
            }
            let target = EditTarget {
                section: field(&hit, "sectionIndex")?,
                paragraph: field(&hit, "paraIndex")?,
                cell: None,
                note: None,
                header_footer: Some(HeaderFooterTarget {
                    footer,
                    apply_to: field(&hit, "applyTo")? as u8,
                    page,
                }),
            };
            // rhwp answers for a 머리말 the page does not have, from its 꼬리말.
            if commands::get(self.core.document(), &target).is_err() {
                continue;
            }
            return Ok(Some(EditPosition {
                target,
                scalar: field(&hit, "charOffset")?,
                upstream: false,
            }));
        }
        Ok(None)
    }
    /// A position in the 각주 area at the foot of the page, if the point falls there.
    fn hit_test_footnote(
        &self,
        page: u32,
        x: f64,
        y: f64,
    ) -> Result<Option<EditPosition>, EditError> {
        if !self.core.page_has_footnote_footholds_native(page)
            || parse(self.core.hit_test_footnote_native(page, x, y))?.get("hit")
                != Some(&Value::Bool(true))
        {
            return Ok(None);
        }
        let hit = parse(self.core.hit_test_in_footnote_native(page, x, y))?;
        if hit.get("hit") != Some(&Value::Bool(true)) {
            return Ok(None);
        }
        let source = parse(
            self.core
                .get_page_footnote_info_native(page, field(&hit, "footnoteIndex")? as usize),
        )?;
        let target = EditTarget {
            section: field(&source, "sectionIdx")?,
            paragraph: field(&source, "paraIdx")?,
            cell: None,
            note: Some(NoteTarget {
                control: field(&source, "controlIdx")?,
                paragraph: field(&hit, "fnParaIndex")?,
            }),
            header_footer: None,
        };
        commands::get(self.core.document(), &target)?;
        Ok(Some(EditPosition {
            target,
            scalar: field(&hit, "charOffset")?,
            upstream: false,
        }))
    }
    /// Where the 각주 holding `t` is listed on `page`.
    fn footnote_index(&self, page: u32, t: &EditTarget) -> Result<usize, EditError> {
        let control = t.note.as_ref().ok_or(EditError::UnsupportedTarget)?.control;
        (0..)
            .map_while(|i| {
                parse(self.core.get_page_footnote_info_native(page, i))
                    .ok()
                    .map(|info| (i, info))
            })
            .find(|(_, info)| {
                field(info, "sectionIdx").ok() == Some(t.section)
                    && field(info, "paraIdx").ok() == Some(t.paragraph)
                    && field(info, "controlIdx").ok() == Some(control)
            })
            .map(|(i, _)| i)
            .ok_or(EditError::UnsupportedTarget)
    }
    /// Caret rectangle (96 dpi, top-left origin) for a position at the current revision.
    pub fn caret(&self, revision: u64, p: &EditPosition) -> Result<PageRect, EditError> {
        self.check_revision(revision)?;
        let drawn = self.drawn_stops(&p.target);
        if let Some(stops) = &drawn {
            // At a wrapped line's end: after the last character of the line before.
            if p.upstream {
                if let Some((_, before)) = stops.range(..p.scalar).next_back() {
                    let line = before.rect();
                    return Ok(PageRect {
                        x: self.line_right(&p.target, &line).unwrap_or(line.x),
                        ..line
                    });
                }
            }
            if let Some(stop) = stops.get(&p.scalar) {
                return Ok(stop.rect());
            }
        }
        self.rhwp_caret(p)
    }
    /// rhwp's caret rectangle for `p`.
    pub(super) fn rhwp_caret(&self, p: &EditPosition) -> Result<PageRect, EditError> {
        commands::get(self.core.document(), &p.target)?;
        let t = &p.target;
        if let Some(hf) = &t.header_footer {
            let get = |page| {
                self.core.get_cursor_rect_in_header_footer_native(
                    t.section as usize,
                    !hf.footer,
                    hf.apply_to,
                    t.paragraph as usize,
                    p.scalar as usize,
                    page,
                )
            };
            return rect(&parse(get(hf.page as i32)).or_else(|_| parse(get(-1)))?);
        }
        if let Some(n) = &t.note {
            return rect(&parse(self.core.get_cursor_rect_in_note_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
                p.scalar as usize,
            ))?);
        }
        let json = parse(match &t.cell {
            Some(c) => self.core.get_cursor_rect_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                p.scalar as usize,
            ),
            None => self.core.get_cursor_rect_native(
                t.section as usize,
                t.paragraph as usize,
                p.scalar as usize,
            ),
        })?;
        rect(&json)
    }
    /// Highlight rectangles for a selection inside one paragraph container.
    pub fn selection_rects(
        &self,
        revision: u64,
        selection: &EditSelection,
    ) -> Result<Vec<PageRect>, EditError> {
        self.check_revision(revision)?;
        if cells::is_block(selection) {
            return self.block_rects(revision, selection);
        }
        let (a, b) = (&selection.anchor, &selection.focus);
        if a.target.section != b.target.section
            || a.target.header_footer != b.target.header_footer
            || a.target.cell.as_ref().map(|c| (c.control, c.cell))
                != b.target.cell.as_ref().map(|c| (c.control, c.cell))
            || a.target.note.as_ref().map(|n| n.control)
                != b.target.note.as_ref().map(|n| n.control)
            || ((a.target.cell.is_some() || a.target.note.is_some())
                && a.target.paragraph != b.target.paragraph)
        {
            return Err(EditError::UnsupportedTarget);
        }
        let key = |p: &EditPosition| (commands::index(&p.target), p.scalar);
        let (start, end) = if key(a) <= key(b) { (a, b) } else { (b, a) };
        commands::get(self.core.document(), &start.target)?;
        commands::get(self.core.document(), &end.target)?;
        let t = &start.target;
        let (s, e) = (commands::index(&start.target), commands::index(&end.target));
        // Ask for each paragraph separately so selecting its paragraph break does not
        // paint the unused width from the last glyph to the body margin.
        if s != e
            || (t.note.is_none() && (s..=e).any(|i| self.has_stops(&commands::at_index(t, i))))
        {
            return self.rects_by_paragraph(revision, start, end);
        }
        let json = parse(if let Some(hf) = &t.header_footer {
            let page = self.caret(revision, start)?.page;
            self.core.get_selection_rects_in_header_footer_native(
                t.section as usize,
                !hf.footer,
                hf.apply_to,
                page,
                commands::index(&start.target),
                start.scalar as usize,
                commands::index(&end.target),
                end.scalar as usize,
            )
        } else if t.note.is_some() {
            let page = self.caret(revision, start)?.page;
            self.core.get_selection_rects_in_footnote_native(
                page,
                self.footnote_index(page, t)?,
                commands::index(&start.target),
                start.scalar as usize,
                commands::index(&end.target),
                end.scalar as usize,
            )
        } else {
            self.core.get_selection_rects_native(
                t.section as usize,
                commands::index(&start.target),
                start.scalar as usize,
                commands::index(&end.target),
                end.scalar as usize,
                t.cell
                    .as_ref()
                    .map(|c| (t.paragraph as usize, c.control as usize, c.cell as usize)),
                None,
            )
        })?;
        let rects = json.as_array().ok_or(EditError::RenderFailed)?;
        rects
            .iter()
            .map(|r| {
                let mut rect = rect(r)?;
                rect.width = r
                    .get("width")
                    .and_then(Value::as_f64)
                    .ok_or(EditError::RenderFailed)?;
                Ok(rect)
            })
            .collect()
    }
    /// Highlight rectangles one paragraph at a time, from the stops of those that have them.
    fn rects_by_paragraph(
        &self,
        revision: u64,
        start: &EditPosition,
        end: &EditPosition,
    ) -> Result<Vec<PageRect>, EditError> {
        let (s, e) = (commands::index(&start.target), commands::index(&end.target));
        let mut rects = Vec::new();
        for i in s..=e {
            let target = commands::at_index(&start.target, i);
            let from = if i == s { start.scalar } else { 0 };
            let to = if i == e {
                end.scalar
            } else {
                logical::length(commands::get(self.core.document(), &target)?)
            };
            match self.paragraph_stops(&target) {
                Some(stops) => rects.extend(stops::spans(&stops, from, to).into_iter().map(
                    |(first, last)| PageRect {
                        width: last.x - first.x,
                        ..first.rect()
                    },
                )),
                None if from < to => {
                    let at = |scalar| EditPosition {
                        target: target.clone(),
                        scalar,
                        upstream: false,
                    };
                    rects.extend(self.selection_rects(
                        revision,
                        &EditSelection {
                            anchor: at(from),
                            focus: at(to),
                        },
                    )?);
                }
                None => {}
            }
        }
        Ok(rects)
    }
}
