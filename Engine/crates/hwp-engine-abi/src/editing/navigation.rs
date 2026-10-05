//! Caret motions, resolved against the engine's own line layout.
use super::commands::{at_index, get, index, paragraphs};
use super::*;
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
        let text = &get(doc, &from.target)?.text;
        let len = text.chars().count() as u32;
        let i = index(&from.target);
        let count = paragraphs(doc, &from.target)?.len();
        let at = |i: usize, scalar: u32| EditPosition {
            target: at_index(&from.target, i),
            scalar,
        };
        let length = |i: usize| -> Result<u32, EditError> {
            Ok(get(doc, &at_index(&from.target, i))?.text.chars().count() as u32)
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
        let caret = self.caret(revision, &position)?;
        Ok(Navigation {
            goal_x: goal.unwrap_or(caret.x),
            position,
            caret,
        })
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
        Ok(hits
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
                };
                // Drops text boxes, which share the cell coordinates.
                get(doc, &target).ok()?;
                let start = field(hit, "charOffset")?;
                let at = |scalar| EditPosition {
                    target: target.clone(),
                    scalar,
                };
                Some(EditSelection {
                    anchor: at(start),
                    focus: at(start + field(hit, "length")?),
                })
            })
            .collect())
    }
}
