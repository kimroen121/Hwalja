//! Positions as the editor counts them: each character, and each object that sits in the
//! line (a 글자처럼 취급 picture, equation, table or drawing object, or a 각주/미주 mark),
//! as one position. rhwp's caret, hit-test, line and selection queries count this way;
//! its text edits count characters only. These convert between the two.
use rhwp::model::{control::Control, paragraph::Paragraph};

/// What the editor shows for an object in the line.
pub(super) const OBJECT: char = '\u{FFFC}';

/// The character offset of each control. In a paragraph without characters rhwp numbers
/// them one after another; they all stand at 0.
fn offsets(p: &Paragraph) -> Vec<usize> {
    if p.text.is_empty() {
        vec![0; p.controls.len()]
    } else {
        p.control_text_positions()
    }
}
/// The character offset control `control` stands at.
pub(super) fn control_offset(p: &Paragraph, control: usize) -> usize {
    offsets(p)
        .get(control)
        .copied()
        .unwrap_or(p.text.chars().count())
}
/// The position of control `control`, an object in the line.
pub(super) fn control_position(p: &Paragraph, control: usize) -> u32 {
    (control_offset(p, control) + in_line(p).filter(|&(i, _)| i < control).count()) as u32
}
/// Each control in the line with its character offset, in control order.
fn in_line(p: &Paragraph) -> impl Iterator<Item = (usize, usize)> + '_ {
    let at = offsets(p);
    let len = p.text.chars().count();
    p.controls
        .iter()
        .enumerate()
        .filter(|(_, c)| c.is_logical_inline())
        .map(move |(i, _)| (i, at.get(i).copied().unwrap_or(len)))
}

/// The paragraph's text with `OBJECT` in place of each object in the line.
pub(super) fn text(p: &Paragraph) -> String {
    let mut objects = in_line(p).map(|(_, at)| at).peekable();
    let mut out = String::with_capacity(p.text.len());
    for (k, ch) in p.text.chars().enumerate() {
        while objects.next_if(|&at| at <= k).is_some() {
            out.push(OBJECT);
        }
        out.push(ch);
    }
    out.extend(objects.map(|_| OBJECT));
    out
}
pub(super) fn length(p: &Paragraph) -> u32 {
    (p.text.chars().count() + in_line(p).count()) as u32
}

/// Where a position falls in rhwp's text.
pub(super) struct Spot {
    /// The character offset.
    pub text: usize,
    /// The last control at that offset the position comes after, when there is one.
    pub after: Option<usize>,
}
impl Spot {
    /// The controls standing at the character offset that come before the position: the
    /// number rhwp's insertion skips (`DocumentCore::set_insert_skip`).
    pub fn skip(&self, p: &Paragraph) -> usize {
        self.controls_before(p, |c| c.occupies_ctrl_char_slot())
    }
    /// The offset rhwp's paragraph split (and paste) takes: characters, plus the objects
    /// it moves with the text, table, picture, note, number… each as one.
    pub fn split(&self, p: &Paragraph) -> usize {
        let movable = |c: &Control| {
            matches!(
                c,
                Control::Shape(_)
                    | Control::Table(_)
                    | Control::Picture(_)
                    | Control::Equation(_)
                    | Control::Footnote(_)
                    | Control::Endnote(_)
                    | Control::AutoNumber(_)
                    | Control::CharOverlap(_)
            )
        };
        let at = offsets(p);
        let earlier = p
            .controls
            .iter()
            .zip(&at)
            .filter(|(c, &pos)| pos < self.text && movable(c))
            .count();
        self.text + earlier + self.controls_before(p, movable)
    }
    fn controls_before(&self, p: &Paragraph, counted: impl Fn(&Control) -> bool) -> usize {
        let Some(last) = self.after else { return 0 };
        let at = offsets(p);
        p.controls
            .iter()
            .zip(&at)
            .enumerate()
            .filter(|&(i, (c, &pos))| i <= last && pos == self.text && counted(c))
            .count()
    }
}
/// Where `position` falls; past the end, the end.
pub(super) fn spot(p: &Paragraph, position: u32) -> Spot {
    let position = position as usize;
    let len = p.text.chars().count();
    let mut objects = in_line(p).peekable();
    let mut counted = 0;
    for k in 0..=len {
        let mut after = None;
        loop {
            if counted == position {
                return Spot { text: k, after };
            }
            match objects.next_if(|&(_, at)| at <= k) {
                Some((i, _)) => {
                    after = Some(i);
                    counted += 1;
                }
                None => break,
            }
        }
        counted += 1;
    }
    Spot {
        text: len,
        after: None,
    }
}
/// The position of character offset `text`: after the objects standing there when
/// `after`, before them otherwise.
pub(super) fn position(p: &Paragraph, text: usize, after: bool) -> u32 {
    let objects = in_line(p)
        .filter(|&(_, at)| at < text || (after && at == text))
        .count();
    (text + objects) as u32
}
/// The objects in the line from `start` to `end`, by control index.
pub(super) fn objects(p: &Paragraph, start: u32, end: u32) -> Vec<usize> {
    let mut seen = 0usize;
    in_line(p)
        .filter_map(|(i, at)| {
            let slot = (at + seen) as u32;
            seen += 1;
            (start <= slot && slot < end).then_some(i)
        })
        .collect()
}
/// The position of the object that is control `control`, if it sits in the line.
pub(super) fn object_position(p: &Paragraph, control: usize) -> Option<u32> {
    in_line(p)
        .enumerate()
        .find(|(_, (i, _))| *i == control)
        .map(|(seen, (_, at))| (at + seen) as u32)
}
