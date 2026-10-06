//! Caret motions, resolved against the engine's own line layout.
use super::commands::{at_index, get, index, paragraphs};
use super::*;
use rhwp::model::control::Control;
use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

/// Unicode scalar offsets where each grapheme starts, plus the text length.
fn grapheme_stops(text: &str) -> Vec<u32> {
    let mut stops = vec![0];
    let mut offset = 0;
    for g in text.graphemes(true) {
        offset += g.chars().count() as u32;
        stops.push(offset);
    }
    stops
}
/// Word-boundary segments as scalar ranges, each flagged when it holds letters or digits.
fn segments(text: &str) -> Vec<(u32, u32, bool)> {
    let mut offset = 0;
    text.split_word_bounds()
        .map(|s| {
            let start = offset;
            offset += s.chars().count() as u32;
            (start, offset, s.chars().any(char::is_alphanumeric))
        })
        .collect()
}

/// Where `query` stands in `text`, never across a field.
fn text_matches(text: &str, query: &str, case_sensitive: bool) -> Vec<(u32, u32)> {
    let text: Vec<char> = text.chars().collect();
    let query: Vec<char> = query.chars().collect();
    if query.is_empty() || query.len() > text.len() {
        return Vec::new();
    }
    let equal = |a: &[char], b: &[char]| {
        if case_sensitive {
            a == b
        } else {
            a.iter()
                .flat_map(|c| c.to_lowercase())
                .eq(b.iter().flat_map(|c| c.to_lowercase()))
        }
    };
    text.windows(query.len())
        .enumerate()
        .filter(|(_, window)| {
            !window.iter().any(|c| header_footer::FIELDS.contains(c)) && equal(window, &query)
        })
        .map(|(start, _)| (start as u32, (start + query.len()) as u32))
        .collect()
}

impl EditSession {
    /// Where `motion` takes a caret at `from`. `goal_x` is the column vertical motions keep
    /// (page units); the reply carries the column to pass to the next vertical motion.
    pub fn navigate(
        &self,
        revision: u64,
        from: &EditPosition,
        motion: Motion,
        goal_x: Option<f64>,
    ) -> Result<Navigation, EditError> {
        let doc = self.core.document();
        let text = &logical::text(get(doc, &from.target)?);
        let len = text.chars().count() as u32;
        let i = index(&from.target);
        let count = paragraphs(doc, &from.target)?.len();
        let at = |i: usize, scalar: u32| EditPosition {
            target: at_index(&from.target, i),
            scalar,
        };
        let length = |i: usize| -> Result<u32, EditError> {
            Ok(logical::length(get(doc, &at_index(&from.target, i))?))
        };
        let previous_end = || -> Result<EditPosition, EditError> {
            Ok(if i > 0 {
                at(i - 1, length(i - 1)?)
            } else {
                from.clone()
            })
        };
        let next_start = || {
            if i + 1 < count {
                at(i + 1, 0)
            } else {
                from.clone()
            }
        };
        let s = from.scalar;
        let mut goal = None;
        let position = match motion {
            Motion::Left => match grapheme_stops(text).into_iter().rev().find(|&b| b < s) {
                Some(b) => at(i, b),
                None => previous_end()?,
            },
            Motion::Right => match grapheme_stops(text).into_iter().find(|&b| b > s) {
                Some(b) => at(i, b),
                None => next_start(),
            },
            Motion::WordLeft => match segments(text).iter().rev().find(|w| w.2 && w.0 < s) {
                Some(w) => at(i, w.0),
                None if s > 0 => at(i, 0),
                None => previous_end()?,
            },
            Motion::WordRight => match segments(text).iter().find(|w| w.2 && w.1 > s) {
                Some(w) => at(i, w.1),
                None if s < len => at(i, len),
                None => next_start(),
            },
            Motion::WordStart | Motion::WordEnd => {
                let all = segments(text);
                // The segment under the caret; at the end of the text, the last one.
                let word = all
                    .iter()
                    .find(|w| w.0 <= s && s < w.1)
                    .or(all.last())
                    .map_or((0, 0), |w| (w.0, w.1));
                at(
                    i,
                    if motion == Motion::WordStart {
                        word.0
                    } else {
                        word.1
                    },
                )
            }
            // Notes have no line queries; their paragraphs stand in for lines.
            Motion::LineStart if from.target.note.is_some() => at(i, 0),
            Motion::LineEnd if from.target.note.is_some() => at(i, len),
            Motion::Up if from.target.note.is_some() => {
                previous_end().map(|p| at(index(&p.target), p.scalar.min(s)))?
            }
            Motion::Down if from.target.note.is_some() => {
                let next = next_start();
                let end = length(index(&next.target))?;
                at(index(&next.target), s.min(end))
            }
            Motion::LineStart | Motion::LineEnd if from.target.header_footer.is_some() => {
                let (first, last) = self.header_footer_line(from)?;
                at(
                    i,
                    if motion == Motion::LineStart {
                        first
                    } else {
                        last
                    },
                )
            }
            Motion::Up | Motion::Down if from.target.header_footer.is_some() => {
                let (moved, x) =
                    self.header_footer_vertical(from, motion == Motion::Down, goal_x)?;
                goal = Some(x);
                moved
            }
            Motion::LineStart | Motion::LineEnd if self.has_stops(&from.target) => {
                let stops = self.paragraph_stops(&from.target);
                let (first, last) = stops
                    .as_ref()
                    .and_then(|stops| stops::line(stops, s))
                    .unwrap_or((s, s));
                at(
                    i,
                    if motion == Motion::LineStart {
                        first
                    } else {
                        last
                    },
                )
            }
            Motion::LineStart | Motion::LineEnd => {
                let line = self.line(from)?;
                let field = |key| line.get(key).and_then(Value::as_u64).unwrap_or(0) as u32;
                let (start, end) = (field("charStart"), field("charEnd").min(len));
                let last = field("lineIndex") + 1 >= field("lineCount");
                let scalar = match motion {
                    Motion::LineStart => start,
                    // A wrapped line's end offset is where the next line starts; stop
                    // before the character the line wrapped after.
                    _ if last => end,
                    _ => grapheme_stops(text)
                        .into_iter()
                        .rev()
                        .find(|&b| b < end && b >= start)
                        .unwrap_or(start),
                };
                at(i, scalar)
            }
            Motion::Up | Motion::Down => {
                let (moved, x) = self.vertical(from, motion == Motion::Down, goal_x)?;
                goal = Some(x);
                moved
            }
            Motion::ParagraphStart if s > 0 => at(i, 0),
            Motion::ParagraphStart => at(i.saturating_sub(1), 0),
            Motion::ParagraphEnd if s < len => at(i, len),
            Motion::ParagraphEnd => {
                let next = (i + 1).min(count - 1);
                at(next, length(next)?)
            }
            Motion::DocumentStart => at(0, 0),
            Motion::DocumentEnd => at(count - 1, length(count - 1)?),
        };
        let (position, caret) = match self.caret(revision, &position) {
            Ok(caret) => (position, caret),
            // The last paragraphs may hold no text to show (such as one that only carries
            // section settings); the end of the document is the last one that does.
            Err(EditError::UnsupportedTarget) if motion == Motion::DocumentEnd => (0..count - 1)
                .rev()
                .find_map(|i| {
                    let p = at(i, length(i).ok()?);
                    self.caret(revision, &p).ok().map(|c| (p, c))
                })
                .ok_or(EditError::UnsupportedTarget)?,
            Err(e) => return Err(e),
        };
        Ok(Navigation {
            goal_x: goal.unwrap_or(caret.x),
            position,
            caret,
        })
    }

    /// Visual line bounds for a header/footer position, derived from its native caret geometry.
    fn header_footer_line(&self, p: &EditPosition) -> Result<(u32, u32), EditError> {
        let current = self.rhwp_caret(p)?;
        let len = logical::length(get(self.core.document(), &p.target)?);
        let same_line = |caret: &PageRect| {
            caret.page == current.page && (caret.y - current.y).abs() <= current.height * 0.5
        };
        let mut scalars = (0..=len).filter(|scalar| {
            self.rhwp_caret(&EditPosition {
                target: p.target.clone(),
                scalar: *scalar,
            })
            .is_ok_and(|caret| same_line(&caret))
        });
        let first = scalars.next().ok_or(EditError::UnsupportedTarget)?;
        Ok((first, scalars.last().unwrap_or(first)))
    }

    /// One visual line inside the same semantic header/footer definition.
    fn header_footer_vertical(
        &self,
        p: &EditPosition,
        down: bool,
        goal_x: Option<f64>,
    ) -> Result<(EditPosition, f64), EditError> {
        let current = self.rhwp_caret(p)?;
        let x = goal_x.unwrap_or(current.x);
        let count = paragraphs(self.core.document(), &p.target)?.len();
        let mut candidates = Vec::new();
        for paragraph in 0..count {
            let target = at_index(&p.target, paragraph);
            let len = logical::length(get(self.core.document(), &target)?);
            for scalar in 0..=len {
                let position = EditPosition {
                    target: target.clone(),
                    scalar,
                };
                let Ok(caret) = self.rhwp_caret(&position) else {
                    continue;
                };
                let dy = caret.y - current.y;
                if caret.page == current.page
                    && if down {
                        dy > current.height * 0.5
                    } else {
                        dy < -current.height * 0.5
                    }
                {
                    candidates.push((position, caret, dy.abs()));
                }
            }
        }
        let Some(nearest_y) = candidates
            .iter()
            .map(|(_, _, dy)| *dy)
            .min_by(f64::total_cmp)
        else {
            return Ok((p.clone(), x));
        };
        let position = candidates
            .into_iter()
            .filter(|(_, _, dy)| (*dy - nearest_y).abs() <= current.height * 0.5)
            .min_by(|(_, a, _), (_, b, _)| (a.x - x).abs().total_cmp(&(b.x - x).abs()))
            .map(|(position, _, _)| position)
            .unwrap_or_else(|| p.clone());
        Ok((position, x))
    }

    fn line(&self, p: &EditPosition) -> Result<Value, EditError> {
        let t = &p.target;
        let json = match &t.cell {
            Some(c) => self.core.get_line_info_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                p.scalar as usize,
            ),
            None => self.core.get_line_info_native(
                t.section as usize,
                t.paragraph as usize,
                p.scalar as usize,
            ),
        };
        serde_json::from_str(&json?).map_err(|_| EditError::RenderFailed)
    }

    /// One line up or down, crossing paragraphs, pages and cell edges. Positions the editor
    /// cannot address (text boxes, nested tables) keep the caret where it is.
    fn vertical(
        &self,
        p: &EditPosition,
        down: bool,
        goal_x: Option<f64>,
    ) -> Result<(EditPosition, f64), EditError> {
        // A paragraph with stops moves between its own lines, and leaves from its first
        // (or last) position, which rhwp's line queries place right.
        let mut from = p.clone();
        if let Some(stops) = self.paragraph_stops(&p.target) {
            if let Some((first, last)) = stops::line(&stops, p.scalar) {
                let x = goal_x.unwrap_or(stops[&p.scalar].x);
                let beyond = if down {
                    stops.range(last + 1..).next()
                } else {
                    stops.range(..first).next_back()
                };
                if let Some((&at, _)) = beyond {
                    let (first, last) = stops::line(&stops, at).ok_or(EditError::RenderFailed)?;
                    let scalar = stops
                        .range(first..=last)
                        .min_by(|a, b| (a.1.x - x).abs().total_cmp(&(b.1.x - x).abs()))
                        .map(|(k, _)| *k)
                        .ok_or(EditError::RenderFailed)?;
                    let target = p.target.clone();
                    return Ok((EditPosition { target, scalar }, x));
                }
                from.scalar = if down {
                    logical::length(get(self.core.document(), &p.target)?)
                } else {
                    0
                };
            }
        }
        let (moved, x) = self.rhwp_vertical(&from, down, goal_x)?;
        // Arriving in a paragraph with stops, the column is found among them.
        if let Some(stops) = self.paragraph_stops(&moved.target) {
            let line = self.rhwp_caret(&moved)?;
            if let Some(scalar) = stops::nearest(&stops, line.page, x, line.y + line.height / 2.0) {
                let target = moved.target;
                return Ok((EditPosition { target, scalar }, x));
            }
        }
        Ok((moved, x))
    }
    fn rhwp_vertical(
        &self,
        p: &EditPosition,
        down: bool,
        goal_x: Option<f64>,
    ) -> Result<(EditPosition, f64), EditError> {
        let t = &p.target;
        let cell = t.cell.as_ref().map(|c| {
            (
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
            )
        });
        let json = self.core.move_vertical_native(
            t.section as usize,
            index(t),
            p.scalar as usize,
            if down { 1 } else { -1 },
            goal_x.unwrap_or(-1.0),
            cell,
        )?;
        let moved: Value = serde_json::from_str(&json).map_err(|_| EditError::RenderFailed)?;
        let field = |key: &str| moved.get(key).and_then(Value::as_u64).map(|v| v as u32);
        let x = moved
            .get("preferredX")
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        let target = match (
            field("sectionIndex"),
            field("paragraphIndex"),
            field("parentParaIndex"),
        ) {
            _ if moved.get("isTextBox").is_some() => None,
            (Some(section), Some(paragraph), None) => Some(EditTarget {
                section,
                paragraph,
                cell: None,
                note: None,
                header_footer: None,
            }),
            (Some(section), _, Some(parent)) => match (
                field("controlIndex"),
                field("cellIndex"),
                field("cellParaIndex"),
            ) {
                (Some(control), Some(cell), Some(paragraph)) => Some(EditTarget {
                    section,
                    paragraph: parent,
                    cell: Some(CellTarget {
                        control,
                        cell,
                        paragraph,
                    }),
                    note: None,
                    header_footer: None,
                }),
                _ => None,
            },
            _ => None,
        };
        let position = target
            .filter(|t| get(self.core.document(), t).is_ok())
            .zip(field("charOffset"))
            .map(|(target, scalar)| EditPosition { target, scalar });
        Ok((position.unwrap_or_else(|| p.clone()), x))
    }

    /// Every match of `query` in document order, in the body and in top-level table cells.
    /// Matches the editor cannot address (text boxes, nested tables, equations) are left out.
    pub fn find(&self, query: &str, case_sensitive: bool) -> Result<Vec<EditSelection>, EditError> {
        let json = self
            .core
            .search_all_text_native(query, case_sensitive, true)?;
        let hits: Vec<Value> = serde_json::from_str(&json).map_err(|_| EditError::RenderFailed)?;
        let doc = self.core.document();
        let mut results: Vec<_> = hits
            .iter()
            .filter(|hit| hit.get("cellPath").is_none() && hit.get("equationControl").is_none())
            .filter_map(|hit| {
                let field = |v: &Value, key: &str| v.get(key)?.as_u64().map(|v| v as u32);
                let cell = hit.get("cellContext");
                let target = EditTarget {
                    section: field(hit, "sec")?,
                    paragraph: field(hit, "para")?,
                    cell: match cell {
                        Some(c) => Some(CellTarget {
                            control: field(c, "ctrlIdx")?,
                            cell: field(c, "cellIdx")?,
                            paragraph: field(c, "cellPara")?,
                        }),
                        None => None,
                    },
                    note: None,
                    header_footer: None,
                };
                // Drops text boxes, which share the cell coordinates.
                let para = get(doc, &target).ok()?;
                let start = field(hit, "charOffset")? as usize;
                let end = start + field(hit, "length")? as usize;
                let at = |scalar| EditPosition {
                    target: target.clone(),
                    scalar,
                };
                Some(EditSelection {
                    anchor: at(logical::position(para, start, true)),
                    focus: at(logical::position(para, end, false)),
                })
            })
            .collect();
        // rhwp's search leaves out 머리말 and 꼬리말.
        for (section, value) in doc.sections.iter().enumerate() {
            for control in value.paragraphs.iter().flat_map(|p| &p.controls) {
                let (footer, apply, paragraphs) = match control {
                    Control::Header(value) => (false, value.apply_to, &value.paragraphs),
                    Control::Footer(value) => (true, value.apply_to, &value.paragraphs),
                    _ => continue,
                };
                for (paragraph, value) in paragraphs.iter().enumerate() {
                    let mut target = EditTarget {
                        section: section as u32,
                        paragraph: paragraph as u32,
                        cell: None,
                        note: None,
                        header_footer: Some(HeaderFooterTarget {
                            footer,
                            apply_to: header_footer::apply_to(apply),
                            page: 0,
                        }),
                    };
                    // Shown on the first page it falls on.
                    let page = self.rhwp_caret(&EditPosition {
                        target: target.clone(),
                        scalar: 0,
                    });
                    if let (Ok(caret), Some(hf)) = (page, &mut target.header_footer) {
                        hf.page = caret.page;
                    }
                    for (start, end) in text_matches(&logical::text(value), query, case_sensitive) {
                        let at = |scalar| EditPosition {
                            target: target.clone(),
                            scalar,
                        };
                        results.push(EditSelection {
                            anchor: at(start),
                            focus: at(end),
                        });
                    }
                }
            }
        }
        Ok(results)
    }
}
