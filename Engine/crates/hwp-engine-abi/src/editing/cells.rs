//! Blocks of table cells: a selection whose ends are in two cells of one table covers
//! every cell of the rectangle between them, as in Hancom's cell blocks.
use super::*;
use serde_json::Value;

/// Rows and columns (inclusive) of one table, grown to cover the merged cells they cut.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Block {
    pub rows: (u16, u16),
    pub cols: (u16, u16),
}
impl Block {
    fn covers(&self, row: u16, col: u16, row_span: u16, col_span: u16) -> bool {
        row >= self.rows.0
            && row + row_span.max(1) - 1 <= self.rows.1
            && col >= self.cols.0
            && col + col_span.max(1) - 1 <= self.cols.1
    }
    fn meets(&self, row: u16, col: u16, row_span: u16, col_span: u16) -> bool {
        row <= self.rows.1
            && row + row_span.max(1) > self.rows.0
            && col <= self.cols.1
            && col + col_span.max(1) > self.cols.0
    }
    pub fn is_cell(&self) -> bool {
        self.rows.0 == self.rows.1 && self.cols.0 == self.cols.1
    }
}

/// Whether the ends sit in two different cells of one table.
pub(super) fn is_block(s: &EditSelection) -> bool {
    let (a, b) = (&s.anchor.target, &s.focus.target);
    match (&a.cell, &b.cell) {
        (Some(x), Some(y)) => {
            (a.section, a.paragraph, x.control) == (b.section, b.paragraph, y.control)
                && x.cell != y.cell
        }
        _ => false,
    }
}

impl EditSession {
    /// The cells a selection covers: its cell, or the block between its ends.
    pub(super) fn block(&self, s: &EditSelection) -> Result<Block, EditError> {
        let doc = self.core.document();
        let (a, b) = (&s.anchor.target, &s.focus.target);
        let (Some(x), Some(y)) = (&a.cell, &b.cell) else {
            return Err(EditError::UnsupportedTarget);
        };
        if (a.section, a.paragraph, x.control) != (b.section, b.paragraph, y.control) {
            return Err(EditError::UnsupportedTarget);
        }
        let t = commands::table(doc, a).ok_or(EditError::UnsupportedTarget)?;
        let cell = |i: u32| t.cells.get(i as usize).ok_or(EditError::InvalidInput);
        let (p, q) = (cell(x.cell)?, cell(y.cell)?);
        let mut block = Block {
            rows: (p.row.min(q.row), p.row.max(q.row)),
            cols: (p.col.min(q.col), p.col.max(q.col)),
        };
        // Grow until no merged cell sticks out.
        loop {
            let grown = t
                .cells
                .iter()
                .filter(|c| block.meets(c.row, c.col, c.row_span, c.col_span))
                .fold(block, |b, c| Block {
                    rows: (
                        b.rows.0.min(c.row),
                        b.rows.1.max(c.row + c.row_span.max(1) - 1),
                    ),
                    cols: (
                        b.cols.0.min(c.col),
                        b.cols.1.max(c.col + c.col_span.max(1) - 1),
                    ),
                });
            if grown == block {
                return Ok(block);
            }
            block = grown;
        }
    }
    /// Highlight for a cell block: the frames of its cells on every page they are on.
    pub(super) fn block_rects(
        &self,
        revision: u64,
        s: &EditSelection,
    ) -> Result<Vec<PageRect>, EditError> {
        let block = self.block(s)?;
        let t = &s.anchor.target;
        let control = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?.control;
        let (a, b) = (
            self.caret(revision, &s.anchor)?.page,
            self.caret(revision, &s.focus)?.page,
        );
        let (first, last) = (a.min(b), a.max(b));
        let mut rects = Vec::new();
        for page in first..=last {
            let layout: Value = serde_json::from_str(
                &self
                    .core
                    .get_page_control_layout_native(page)
                    .map_err(|_| EditError::RenderFailed)?,
            )
            .map_err(|_| EditError::RenderFailed)?;
            let index = |v: &Value, k: &str| v.get(k).and_then(Value::as_u64).map(|n| n as u32);
            let number = |v: &Value, k: &str| v.get(k).and_then(Value::as_f64).unwrap_or(0.0);
            let tables = layout["controls"].as_array().into_iter().flatten();
            for table in tables.filter(|c| {
                c["type"] == "table"
                    && index(c, "secIdx") == Some(t.section)
                    && index(c, "paraIdx") == Some(t.paragraph)
                    && index(c, "controlIdx") == Some(control)
            }) {
                for cell in table["cells"].as_array().into_iter().flatten() {
                    let span = |k| index(cell, k).unwrap_or(1) as u16;
                    let (row, col) = (span("row"), span("col"));
                    if block.covers(row, col, span("rowSpan"), span("colSpan")) {
                        rects.push(PageRect {
                            page,
                            x: number(cell, "x"),
                            y: number(cell, "y"),
                            width: number(cell, "w"),
                            height: number(cell, "h"),
                        });
                    }
                }
            }
        }
        Ok(rects)
    }
    /// A caret at the start of the cell covering `row`, `col` of the table holding `t`.
    pub(super) fn caret_in_cell(
        &self,
        t: &EditTarget,
        row: u16,
        col: u16,
    ) -> Result<EditSelection, EditError> {
        let c = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let table = commands::table(self.core.document(), t).ok_or(EditError::RenderFailed)?;
        let (row, col) = (
            row.min(table.row_count.saturating_sub(1)),
            col.min(table.col_count.saturating_sub(1)),
        );
        let cell = table
            .cells
            .iter()
            .position(|x| {
                (x.row..x.row + x.row_span.max(1)).contains(&row)
                    && (x.col..x.col + x.col_span.max(1)).contains(&col)
            })
            .unwrap_or(0);
        Ok(EditSelection::caret(EditPosition {
            target: EditTarget {
                cell: Some(CellTarget {
                    control: c.control,
                    cell: cell as u32,
                    paragraph: 0,
                }),
                note: None,
                ..t.clone()
            },
            scalar: 0,
        }))
    }
    pub(super) fn validate_cells(&self, command: &EditCommand) -> Result<(), EditError> {
        let valid = match command {
            EditCommand::MergeCells { selection } => !self.block(selection)?.is_cell(),
            EditCommand::SplitCells {
                selection,
                rows,
                columns,
                merge_first,
                ..
            } => {
                self.block(selection)?;
                (1..=256).contains(rows)
                    && (1..=256).contains(columns)
                    && (*rows > 1 || *columns > 1 || *merge_first)
            }
            EditCommand::EqualizeCells { selection, height } => {
                let b = self.block(selection)?;
                if *height {
                    b.rows.0 < b.rows.1
                } else {
                    b.cols.0 < b.cols.1
                }
            }
            _ => false,
        };
        if valid {
            Ok(())
        } else {
            Err(EditError::InvalidInput)
        }
    }
    pub(super) fn edit_cells(&mut self, command: &EditCommand) -> Result<EditSelection, EditError> {
        let (EditCommand::MergeCells { selection }
        | EditCommand::SplitCells { selection, .. }
        | EditCommand::EqualizeCells { selection, .. }) = command
        else {
            return Err(EditError::UnsupportedTarget);
        };
        let b = self.block(selection)?;
        let t = &selection.anchor.target;
        let c = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let (s, p, control) = (t.section as usize, t.paragraph as usize, c.control as usize);
        let ((r0, r1), (c0, c1)) = (b.rows, b.cols);
        match command {
            EditCommand::MergeCells { .. } => {
                self.core
                    .merge_table_cells_native(s, p, control, r0, c0, r1, c1)?;
            }
            EditCommand::SplitCells {
                rows,
                columns,
                equal_height,
                merge_first,
                ..
            } => {
                if b.is_cell() || *merge_first {
                    if !b.is_cell() {
                        self.core
                            .merge_table_cells_native(s, p, control, r0, c0, r1, c1)?;
                    }
                    self.core.split_table_cell_into_native(
                        s,
                        p,
                        control,
                        r0,
                        c0,
                        *rows,
                        *columns,
                        *equal_height,
                        false,
                    )?;
                } else {
                    self.core.split_table_cells_in_range_native(
                        s,
                        p,
                        control,
                        r0,
                        c0,
                        r1,
                        c1,
                        *rows,
                        *columns,
                        *equal_height,
                    )?;
                }
            }
            EditCommand::EqualizeCells { height, .. } => {
                self.equalize(t, b, *height)?;
                return Ok(selection.clone());
            }
            _ => {}
        }
        self.caret_in_cell(t, r0, c0)
    }
    /// 셀 높이를 같게 or 셀 너비를 같게: shares the block's total height (or width)
    /// evenly among its rows (or columns).
    fn equalize(&mut self, t: &EditTarget, b: Block, height: bool) -> Result<(), EditError> {
        let table = commands::table(self.core.document(), t).ok_or(EditError::RenderFailed)?;
        let inside: Vec<(usize, u16, u32)> = table
            .cells
            .iter()
            .enumerate()
            .filter(|(_, c)| b.covers(c.row, c.col, c.row_span, c.col_span))
            .map(|(i, c)| {
                if height {
                    (i, c.row_span.max(1), c.height)
                } else {
                    (i, c.col_span.max(1), c.width)
                }
            })
            .collect();
        // One line through the block: its first column (for heights) or row (for widths).
        let total: u64 = table
            .cells
            .iter()
            .filter(|c| b.covers(c.row, c.col, c.row_span, c.col_span))
            .filter(|c| {
                if height {
                    c.col == b.cols.0
                } else {
                    c.row == b.rows.0
                }
            })
            .map(|c| (if height { c.height } else { c.width }) as u64)
            .sum();
        let lines = if height {
            b.rows.1 - b.rows.0 + 1
        } else {
            b.cols.1 - b.cols.0 + 1
        } as u64;
        let each = total / lines;
        let c = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let key = if height { "height" } else { "width" };
        // ponytail: one re-layout per cell; batch in rhwp if large blocks lag.
        for (index, span, size) in inside {
            let new = each * span as u64;
            if new != size as u64 {
                self.core.set_cell_properties_native(
                    t.section as usize,
                    t.paragraph as usize,
                    c.control as usize,
                    index,
                    &format!(r#"{{"{key}":{new}}}"#),
                )?;
            }
        }
        Ok(())
    }
}
