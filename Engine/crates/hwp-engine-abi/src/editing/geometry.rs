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
    fn check_revision(&self, revision: u64) -> Result<(), EditError> {
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
    ) -> Result<EditPosition, EditError> {
        self.check_revision(revision)?;
        if page >= self.core.page_count() {
            return Err(EditError::InvalidInput);
        }
        let hit = parse(self.core.hit_test_native(page, x, y))?;
        if hit.get("isTextBox").is_some() {
            return Err(EditError::UnsupportedTarget);
        }
        let section = field(&hit, "sectionIndex")?;
        let target = match hit.get("cellPath").and_then(Value::as_array) {
            None => EditTarget {
                section,
                paragraph: field(&hit, "paragraphIndex")?,
                cell: None,
            },
            Some(path) if path.len() == 1 => EditTarget {
                section,
                paragraph: field(&hit, "parentParaIndex")?,
                cell: Some(CellTarget {
                    control: field(&hit, "controlIndex")?,
                    cell: field(&hit, "cellIndex")?,
                    paragraph: field(&hit, "cellParaIndex")?,
                }),
            },
            Some(_) => return Err(EditError::UnsupportedTarget),
        };
        commands::get(self.core.document(), &target)?;
        Ok(EditPosition {
            target,
            scalar: field(&hit, "charOffset")?,
        })
    }
    /// Caret rectangle (96 dpi, top-left origin) for a position at the current revision.
    pub fn caret(&self, revision: u64, p: &EditPosition) -> Result<PageRect, EditError> {
        self.check_revision(revision)?;
        commands::get(self.core.document(), &p.target)?;
        let t = &p.target;
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
        let (a, b) = (&selection.anchor, &selection.focus);
        if a.target.section != b.target.section
            || a.target.cell.as_ref().map(|c| (c.control, c.cell))
                != b.target.cell.as_ref().map(|c| (c.control, c.cell))
            || (a.target.cell.is_some() && a.target.paragraph != b.target.paragraph)
        {
            return Err(EditError::UnsupportedTarget);
        }
        let key = |p: &EditPosition| (commands::index(&p.target), p.scalar);
        let (start, end) = if key(a) <= key(b) { (a, b) } else { (b, a) };
        commands::get(self.core.document(), &start.target)?;
        commands::get(self.core.document(), &end.target)?;
        let t = &start.target;
        let json = parse(
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
            ),
        )?;
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
}
