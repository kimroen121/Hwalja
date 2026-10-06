//! Caret stops of paragraphs with an object in the line. rhwp places the body caret right
//! there, from stops it builds out of the laid-out text, but its hit test, line, selection
//! and cell caret queries count the positions after an object one way on the object's
//! line and another on the lines after it. These stops are built the same way, from the
//! page's text runs (each character's edges) and its objects, and answer every geometry
//! query for such paragraphs; other paragraphs keep rhwp's answers.
use super::*;
use rhwp::model::{control::Control, paragraph::Paragraph};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::ops::RangeInclusive;
use std::rc::Rc;

/// How far from where it is expected a run's text is looked for in the paragraph.
const REACH: usize = 16;

/// A caret place: page, left edge, top and height (page pixels).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct Stop {
    pub page: u32,
    pub x: f64,
    pub y: f64,
    pub height: f64,
}
impl Stop {
    pub fn rect(&self) -> PageRect {
        PageRect {
            page: self.page,
            x: self.x,
            y: self.y,
            width: 0.0,
            height: self.height,
        }
    }
    fn same_line(&self, other: &Stop) -> bool {
        self.page == other.page && (self.y - other.y).abs() < 0.5
    }
}
pub(super) type Stops = BTreeMap<u32, Stop>;

/// A page's laid-out text runs and objects, as rhwp lists them.
struct Layout {
    runs: Vec<Value>,
    controls: Vec<Value>,
}
/// Layouts of the pages asked for at one revision.
#[derive(Default)]
pub(super) struct Layouts {
    revision: u64,
    pages: HashMap<u32, Rc<Layout>>,
    paragraphs: HashMap<EditTarget, Option<Rc<Stops>>>,
}

fn number(v: &Value, key: &str) -> Option<f64> {
    v.get(key).and_then(Value::as_f64)
}
fn index(v: &Value, key: &str) -> Option<u32> {
    v.get(key).and_then(Value::as_u64).map(|v| v as u32)
}
/// Whether a run or object of the layout belongs to the paragraph at `t`.
fn belongs(v: &Value, t: &EditTarget) -> bool {
    match (&t.cell, v.get("cellPath").and_then(Value::as_array)) {
        (None, None) => {
            index(v, "secIdx") == Some(t.section)
                && index(v, "paraIdx") == Some(t.paragraph)
                && v.get("cellIdx").is_none()
        }
        (Some(c), Some(path)) if path.len() == 1 => {
            index(v, "parentParaIdx") == Some(t.paragraph)
                && index(&path[0], "controlIndex") == Some(c.control)
                && index(&path[0], "cellIndex") == Some(c.cell)
                && index(&path[0], "cellParaIndex") == Some(c.paragraph)
        }
        // Equations in a cell carry their cell without a path; their control index is
        // the table's.
        (Some(c), None) => {
            v.get("type").and_then(Value::as_str) == Some("equation")
                && index(v, "paraIdx") == Some(t.paragraph)
                && index(v, "controlIdx") == Some(c.control)
                && index(v, "cellIdx") == Some(c.cell)
                && index(v, "cellParaIdx") == Some(c.paragraph)
        }
        _ => false,
    }
}

/// Adds the edges of each character of the paragraph's runs on the page; a left edge
/// wins over the right edge of the character before it. A run's start
/// in rhwp's layout may count the objects before it on its line; the run's characters
/// are matched against the paragraph's text to find where it really starts.
fn add_text(stops: &mut Stops, page: u32, layout: &Layout, t: &EditTarget, p: &Paragraph) {
    let chars: Vec<char> = p.text.chars().collect();
    let objects = p.controls.iter().filter(|c| c.is_logical_inline()).count();
    let mut next: Option<usize> = None;
    for run in layout.runs.iter().filter(|r| belongs(r, t)) {
        let text: Vec<char> = run["text"].as_str().unwrap_or("").chars().collect();
        let visible: Vec<char> = text
            .iter()
            .copied()
            .filter(|&c| c != logical::OBJECT)
            .collect();
        let xs: Vec<f64> = run["charX"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_f64).collect())
            .unwrap_or_default();
        let (Some(x), Some(y), Some(height), Some(start)) = (
            number(run, "x"),
            number(run, "y"),
            number(run, "h"),
            index(run, "charStart"),
        ) else {
            continue;
        };
        if visible.is_empty() || xs.len() < text.len() + 1 {
            continue;
        }
        let fits = |at: usize| chars.get(at..at + visible.len()) == Some(&visible[..]);
        // Nearest to where the previous run ended, else to rhwp's start, which may be off
        // by the objects before it and, in cells, by a few more.
        let near = |from: usize, reach: usize| {
            (0..=reach).find_map(|d| {
                [Some(from + d), from.checked_sub(d)]
                    .into_iter()
                    .flatten()
                    .find(|&at| fits(at))
            })
        };
        let found = next
            .and_then(|at| near(at, REACH))
            .or_else(|| near(start as usize, objects + REACH));
        let Some(mut at) = found else {
            next = None;
            continue;
        };
        for (i, &c) in text.iter().enumerate() {
            if c == logical::OBJECT {
                continue;
            }
            let stop = |dx: f64| Stop {
                page,
                x: x + dx,
                y,
                height,
            };
            // Where a line wraps, the position starts the next line.
            stops.insert(logical::position(p, at, true), stop(xs[i]));
            stops
                .entry(logical::position(p, at + 1, false))
                .or_insert(stop(xs[i + 1]));
            at += 1;
        }
        next = Some(at);
    }
}

/// Adds both sides of each object in the line laid out on the page.
fn add_objects(stops: &mut Stops, page: u32, layout: &Layout, t: &EditTarget, p: &Paragraph) {
    let laid: Vec<&Value> = layout.controls.iter().filter(|c| belongs(c, t)).collect();
    // rhwp numbers every equation of a cell paragraph 0; they are laid out in order.
    let equations: Vec<usize> = p
        .controls
        .iter()
        .enumerate()
        .filter(|(_, c)| matches!(c, Control::Equation(_)))
        .map(|(i, _)| i)
        .collect();
    let laid_equations = laid
        .iter()
        .filter(|c| c["type"].as_str() == Some("equation"))
        .count();
    let mut nth_equation = 0;
    for object in laid {
        let control = if t.cell.is_some() && object["type"].as_str() == Some("equation") {
            nth_equation += 1;
            if laid_equations != equations.len() {
                continue;
            }
            equations[nth_equation - 1]
        } else {
            match index(object, "controlIdx") {
                Some(c) => c as usize,
                None => continue,
            }
        };
        let (Some(x), Some(y), Some(w), Some(h)) = (
            number(object, "x"),
            number(object, "y"),
            number(object, "w"),
            number(object, "h"),
        ) else {
            continue;
        };
        let Some(at) = logical::object_position(p, control) else {
            continue;
        };
        // The caret takes the height of the text on the object's line.
        let line = stops
            .values()
            .find(|s| s.page == page && (y..=y + h).contains(&(s.y + s.height / 2.0)))
            .map(|s| (s.y, s.height))
            .unwrap_or(((y + h * 0.85 - 9.6).max(y), 12.0));
        let stop = |x: f64| Stop {
            page,
            x,
            y: line.0,
            height: line.1,
        };
        stops.insert(at, stop(x));
        stops.entry(at + 1).or_insert(stop(x + w));
    }
}

impl EditSession {
    /// The cache, emptied when the revision has moved on.
    fn layouts(&self) -> std::cell::RefMut<'_, Layouts> {
        let mut cache = self.layouts.borrow_mut();
        if cache.revision != self.revision {
            *cache = Layouts {
                revision: self.revision,
                ..Default::default()
            };
        }
        cache
    }
    fn layout(&self, page: u32) -> Option<Rc<Layout>> {
        let mut cache = self.layouts();
        if let Some(layout) = cache.pages.get(&page) {
            return Some(layout.clone());
        }
        let list = |json: Result<String, rhwp::error::HwpError>, key: &str| {
            serde_json::from_str::<Value>(&json.ok()?)
                .ok()?
                .get(key)?
                .as_array()
                .cloned()
        };
        let layout = Rc::new(Layout {
            runs: list(self.core.get_page_text_layout_native(page), "runs")?,
            controls: list(self.core.get_page_control_layout_native(page), "controls")?,
        });
        cache.pages.insert(page, layout.clone());
        Some(layout)
    }
    /// Whether the paragraph at `t` has its own stops: an object in the line, in the body or a cell.
    pub(super) fn has_stops(&self, t: &EditTarget) -> bool {
        commands::body_or_cell(t).is_ok()
            && commands::get(self.core.document(), t)
                .is_ok_and(|p| p.controls.iter().any(Control::is_logical_inline))
    }
    /// The stops of the paragraph at `t` on `pages`.
    pub(super) fn stops(&self, t: &EditTarget, pages: RangeInclusive<u32>) -> Option<Stops> {
        if !self.has_stops(t) {
            return None;
        }
        let p = commands::get(self.core.document(), t).ok()?;
        let mut stops = Stops::new();
        for page in pages {
            let layout = self.layout(page)?;
            add_text(&mut stops, page, &layout, t, p);
            add_objects(&mut stops, page, &layout, t, p);
        }
        (!stops.is_empty()).then_some(stops)
    }
    /// The stops of the whole paragraph at `t`: from the page rhwp puts its start on, page
    /// after page while it goes on.
    pub(super) fn paragraph_stops(&self, t: &EditTarget) -> Option<Rc<Stops>> {
        if !self.has_stops(t) {
            return None;
        }
        if let Some(stops) = self.layouts().paragraphs.get(t) {
            return stops.clone();
        }
        let stops = self.collect_paragraph_stops(t).map(Rc::new);
        self.layouts().paragraphs.insert(t.clone(), stops.clone());
        stops
    }
    fn collect_paragraph_stops(&self, t: &EditTarget) -> Option<Stops> {
        let first = self
            .rhwp_caret(&EditPosition {
                target: t.clone(),
                scalar: 0,
            })
            .ok()?
            .page;
        let p = commands::get(self.core.document(), t).ok()?;
        let mut stops = Stops::new();
        for page in first..self.core.page_count() {
            let layout = self.layout(page)?;
            let before = stops.len();
            add_text(&mut stops, page, &layout, t, p);
            add_objects(&mut stops, page, &layout, t, p);
            if stops.len() == before && page > first {
                break;
            }
        }
        (!stops.is_empty()).then_some(stops)
    }
}

impl EditSession {
    /// The paragraph whose object in the line spans height `y` on the page, nearest across
    /// to `x`: rhwp's hit test misses a line that holds only objects.
    pub(super) fn object_line(&self, page: u32, x: f64, y: f64) -> Option<EditTarget> {
        let layout = self.layout(page)?;
        layout
            .controls
            .iter()
            .filter_map(|o| {
                let (ox, oy, w, h) = (
                    number(o, "x")?,
                    number(o, "y")?,
                    number(o, "w")?,
                    number(o, "h")?,
                );
                if !(oy..=oy + h).contains(&y) {
                    return None;
                }
                let section = index(o, "secIdx")?;
                let cell = match (
                    o.get("cellPath").and_then(Value::as_array),
                    o.get("cellIdx"),
                ) {
                    (None, None) => None,
                    (Some(path), _) if path.len() == 1 => Some(CellTarget {
                        control: index(&path[0], "controlIndex")?,
                        cell: index(&path[0], "cellIndex")?,
                        paragraph: index(&path[0], "cellParaIndex")?,
                    }),
                    (None, Some(_)) => Some(CellTarget {
                        control: index(o, "controlIdx")?,
                        cell: index(o, "cellIdx")?,
                        paragraph: index(o, "cellParaIdx")?,
                    }),
                    _ => return None,
                };
                let paragraph = match cell {
                    Some(_) => index(o, "parentParaIdx").or(index(o, "paraIdx"))?,
                    None => index(o, "paraIdx")?,
                };
                let target = EditTarget {
                    section,
                    paragraph,
                    cell,
                    note: None,
                    header_footer: None,
                };
                let across = if x < ox {
                    ox - x
                } else {
                    (x - ox - w).max(0.0)
                };
                self.has_stops(&target).then_some((across, target))
            })
            .min_by(|a, b| a.0.total_cmp(&b.0))
            .map(|(_, target)| target)
    }
}

/// The stop nearest a point on a page: on the line the point is in (or the nearest line),
/// the nearest one across.
pub(super) fn nearest(stops: &Stops, page: u32, x: f64, y: f64) -> Option<u32> {
    let on_page: Vec<(&u32, &Stop)> = stops.iter().filter(|(_, s)| s.page == page).collect();
    let distance = |s: &Stop| {
        if y < s.y {
            s.y - y
        } else {
            (y - (s.y + s.height)).max(0.0)
        }
    };
    let line = on_page
        .iter()
        .min_by(|a, b| distance(a.1).total_cmp(&distance(b.1)))?
        .1;
    on_page
        .iter()
        .filter(|(_, s)| s.same_line(line))
        .min_by(|a, b| (a.1.x - x).abs().total_cmp(&(b.1.x - x).abs()))
        .map(|(k, _)| **k)
}
/// The positions on the line of the stop at `at`, first and last.
pub(super) fn line(stops: &Stops, at: u32) -> Option<(u32, u32)> {
    let here = stops.get(&at)?;
    let first = stops
        .range(..=at)
        .rev()
        .take_while(|(_, s)| s.same_line(here))
        .last()?
        .0;
    let last = stops
        .range(at..)
        .take_while(|(_, s)| s.same_line(here))
        .last()?
        .0;
    Some((*first, *last))
}
/// The lines of the stops from `start` to `end`, each as its first and last stop.
pub(super) fn spans(stops: &Stops, start: u32, end: u32) -> Vec<(Stop, Stop)> {
    let mut lines: Vec<(Stop, Stop)> = Vec::new();
    for (_, s) in stops.range(start..=end) {
        match lines.last_mut() {
            Some((first, last)) if first.same_line(s) => *last = *s,
            _ => lines.push((*s, *s)),
        }
    }
    lines
}
