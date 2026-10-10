//! Blocks of table cells: a selection whose ends are in two cells of one table covers
//! every cell of the rectangle between them, as in Hancom's cell blocks.
use super::*;
use rhwp::model::table::{Cell, Table};
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
                header_footer: None,
                ..t.clone()
            },
            scalar: 0,
            upstream: false,
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
            EditCommand::CalculateBlock {
                selection,
                function,
            } => !self.results(selection, *function)?.is_empty(),
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
        | EditCommand::EqualizeCells { selection, .. }
        | EditCommand::CalculateBlock { selection, .. }) = command
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
            EditCommand::CalculateBlock { function, .. } => {
                for (row, col, formula) in self.results(selection, *function)? {
                    self.core
                        .evaluate_table_formula(s, p, control, row, col, &formula, true)?;
                }
                return Ok(selection.clone());
            }
            _ => {}
        }
        self.caret_in_cell(t, r0, c0)
    }
    /// Where 블록 계산식 writes, as Hancom fills the empty cells to the right and below:
    /// each empty cell of the block's last column takes the result over the rest of its
    /// row, and each empty cell of its last row the result over the rest of its column
    /// (the corner last, over the results above it).
    fn results(
        &self,
        selection: &EditSelection,
        function: BlockFunction,
    ) -> Result<Vec<(usize, usize, String)>, EditError> {
        let b = self.block(selection)?;
        let table = commands::table(self.core.document(), &selection.anchor.target)
            .ok_or(EditError::UnsupportedTarget)?;
        let empty = |row: u16, col: u16| {
            table.cells.iter().any(|c| {
                (c.row, c.col) == (row, col)
                    && c.paragraphs.iter().all(|p| p.text.trim().is_empty())
            })
        };
        let name = match function {
            BlockFunction::Sum => "SUM",
            BlockFunction::Average => "AVG",
            BlockFunction::Product => "PRODUCT",
        };
        let cell = |row: u16, col: u16| {
            let mut letters = String::new();
            let mut n = col as u32 + 1;
            while n > 0 {
                letters.insert(0, (b'A' + ((n - 1) % 26) as u8) as char);
                n = (n - 1) / 26;
            }
            format!("{letters}{}", row + 1)
        };
        let ((r0, r1), (c0, c1)) = (b.rows, b.cols);
        let mut results = Vec::new();
        if c0 < c1 {
            for row in r0..=r1 {
                if empty(row, c1) && !(r0 < r1 && row == r1) {
                    let range = format!("{}:{}", cell(row, c0), cell(row, c1 - 1));
                    results.push((row as usize, c1 as usize, format!("{name}({range})")));
                }
            }
        }
        if r0 < r1 {
            for col in c0..=c1 {
                if empty(r1, col) {
                    let range = format!("{}:{}", cell(r0, col), cell(r1 - 1, col));
                    results.push((r1 as usize, col as usize, format!("{name}({range})")));
                }
            }
        }
        Ok(results)
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

    /// The draggable table borders on `page`: each cell's right and bottom edges, for
    /// cells spanning one column (row). Tables in cells, notes and headers are left out.
    pub fn table_lines(&self, revision: u64, page: u32) -> Result<Vec<TableLine>, EditError> {
        self.check_revision(revision)?;
        let layout: Value = serde_json::from_str(
            &self
                .core
                .get_page_control_layout_native(page)
                .map_err(|_| EditError::RenderFailed)?,
        )
        .map_err(|_| EditError::RenderFailed)?;
        let index = |v: &Value, k: &str| v.get(k).and_then(Value::as_u64).map(|n| n as u32);
        let number = |v: &Value, k: &str| v.get(k).and_then(Value::as_f64).unwrap_or(0.0);
        let mut lines = Vec::new();
        for t in layout["controls"].as_array().into_iter().flatten() {
            if t["type"] != "table"
                || ["cellIdx", "cellPath", "noteRef", "headerFooter"]
                    .iter()
                    .any(|k| t.get(k).is_some())
            {
                continue;
            }
            let (Some(section), Some(paragraph), Some(control)) = (
                index(t, "secIdx"),
                index(t, "paraIdx"),
                index(t, "controlIdx"),
            ) else {
                continue;
            };
            let table = ObjectRef {
                kind: ObjectKind::Table,
                section,
                paragraph,
                control,
                cell: None,
                note: None,
            };
            for c in t["cells"].as_array().into_iter().flatten() {
                let span = |k| index(c, k).unwrap_or(1).max(1) as u16;
                let (x, y, w, h) = (
                    number(c, "x"),
                    number(c, "y"),
                    number(c, "w"),
                    number(c, "h"),
                );
                if span("colSpan") == 1 {
                    lines.push(TableLine {
                        table: table.clone(),
                        row: false,
                        line: index(c, "col").unwrap_or(0) as u16,
                        at: x + w,
                        start: x,
                        from: y,
                        to: y + h,
                    });
                }
                if span("rowSpan") == 1 {
                    lines.push(TableLine {
                        table: table.clone(),
                        row: true,
                        line: index(c, "row").unwrap_or(0) as u16,
                        at: y + h,
                        start: y,
                        from: x,
                        to: x + w,
                    });
                }
            }
        }
        Ok(lines)
    }
    fn table_of(&self, o: &ObjectRef) -> Result<&Table, EditError> {
        let target = EditTarget {
            section: o.section,
            paragraph: o.paragraph,
            cell: Some(CellTarget {
                control: o.control,
                cell: 0,
                paragraph: 0,
            }),
            note: None,
            header_footer: None,
        };
        if o.kind != ObjectKind::Table {
            return Err(EditError::UnsupportedTarget);
        }
        commands::table(self.core.document(), &target).ok_or(EditError::UnsupportedTarget)
    }
    /// The cells a border drag changes, with their new width (or height): the cells
    /// ending at the border take the change, and for an inner column border the cells
    /// starting after it give it back.
    fn resized_cells(&self, command: &EditCommand) -> Result<Vec<(usize, u32)>, EditError> {
        const MIN: i64 = 200;
        let EditCommand::ResizeTable {
            table,
            row,
            line,
            size,
        } = command
        else {
            return Err(EditError::UnsupportedTarget);
        };
        let t = self.table_of(table)?;
        let count = if *row { t.row_count } else { t.col_count };
        if *line >= count || (*size as i64) < MIN || *size > 1_000_000 {
            return Err(EditError::InvalidInput);
        }
        let sizes = if *row {
            t.get_row_heights()
        } else {
            t.get_column_widths()
        };
        let delta = *size as i64 - sizes[*line as usize] as i64;
        let measure = |c: &Cell| {
            if *row {
                (c.row, c.row_span.max(1), c.height as i64)
            } else {
                (c.col, c.col_span.max(1), c.width as i64)
            }
        };
        let mut changes = Vec::new();
        for (i, c) in t.cells.iter().enumerate() {
            let (start, span, length) = measure(c);
            let new = if start + span - 1 == *line {
                length + delta
            } else if !*row && start == *line + 1 {
                length - delta
            } else {
                continue;
            };
            if new < MIN {
                return Err(EditError::InvalidInput);
            }
            if new != length {
                changes.push((i, new as u32));
            }
        }
        Ok(changes)
    }
    /// 계산식: works `formula` out for the cell holding `p` and writes the result over
    /// the cell's first paragraph.
    pub(super) fn calculate(
        &mut self,
        p: &EditPosition,
        formula: &str,
        format: u8,
        separators: bool,
    ) -> Result<EditSelection, EditError> {
        let t = &p.target;
        let c = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let table = commands::table(self.core.document(), t).ok_or(EditError::UnsupportedTarget)?;
        let cell = table
            .cells
            .get(c.cell as usize)
            .ok_or(EditError::InvalidInput)?;
        let (row, col) = (cell.row as usize, cell.col as usize);
        // A formula starts with = or @, which the box may leave out.
        let formula = match formula.trim() {
            f if f.starts_with(['=', '@']) => format!("={}", &f[1..]),
            f => format!("={f}"),
        };
        let reply: Value = serde_json::from_str(&self.core.evaluate_table_formula(
            t.section as usize,
            t.paragraph as usize,
            c.control as usize,
            row,
            col,
            &formula,
            false,
        )?)
        .map_err(|_| EditError::InvalidInput)?;
        let value = reply["result"].as_f64().ok_or(EditError::InvalidInput)?;
        let first = EditTarget {
            cell: Some(CellTarget {
                paragraph: 0,
                ..c.clone()
            }),
            ..t.clone()
        };
        let end = self.paragraph(&first)?.text.chars().count() as u32;
        let at = |scalar| EditPosition {
            target: first.clone(),
            scalar,
            upstream: false,
        };
        self.replace(&at(0), &at(end), &calculated(value, format, separators))
    }
    /// Sizes a table of the body to `width` × `height` (HWPUNIT), each column and row
    /// in proportion.
    pub(super) fn scale_table(
        &mut self,
        o: &ObjectRef,
        width: Option<u32>,
        height: Option<u32>,
    ) -> Result<(), EditError> {
        let t = self.table_of(o)?;
        let ratio = |to: Option<u32>, sizes: Vec<u32>| {
            let total: u32 = sizes.iter().sum();
            to.filter(|_| total > 0).map(|to| to as f64 / total as f64)
        };
        let (across, down) = (
            ratio(width, t.get_column_widths()),
            ratio(height, t.get_row_heights()),
        );
        let changes: Vec<(usize, String)> = t
            .cells
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let mut json = serde_json::Map::new();
                let scaled = |v: u32, r: f64| Value::from(((v as f64 * r).round() as u32).max(200));
                if let Some(r) = across {
                    json.insert("width".into(), scaled(c.width, r));
                }
                if let Some(r) = down {
                    json.insert("height".into(), scaled(c.height, r));
                }
                (i, Value::Object(json).to_string())
            })
            .collect();
        if across.is_none() && down.is_none() {
            return Ok(());
        }
        let (s, p, c) = (o.section as usize, o.paragraph as usize, o.control as usize);
        self.core.begin_batch_native()?;
        let scaled = changes.iter().try_for_each(|(i, json)| {
            self.core
                .set_cell_properties_native(s, p, c, *i, json)
                .map(|_| ())
        });
        self.core.end_batch_native()?;
        scaled?;
        Ok(())
    }
    pub(super) fn validate_resize(&self, command: &EditCommand) -> Result<(), EditError> {
        self.resized_cells(command).map(|_| ())
    }
    pub(super) fn resize_table(&mut self, command: &EditCommand) -> Result<(), EditError> {
        let EditCommand::ResizeTable { table, row, .. } = command else {
            return Err(EditError::UnsupportedTarget);
        };
        let key = if *row { "height" } else { "width" };
        // ponytail: one re-layout per cell, as in `equalize`.
        for (index, value) in self.resized_cells(command)? {
            self.core.set_cell_properties_native(
                table.section as usize,
                table.paragraph as usize,
                table.control as usize,
                index,
                &format!(r#"{{"{key}":{value}}}"#),
            )?;
        }
        Ok(())
    }
}

/// A 계산식 result in its 형식: 기본 형식 shows a whole number without a point, 정수형
/// rounds, and the others keep one to four decimals.
fn calculated(value: f64, format: u8, separators: bool) -> String {
    let text = match format {
        0 if value == value.trunc() && value.abs() < 1e15 => format!("{}", value as i64),
        0 => format!("{value}"),
        n => format!("{value:.*}", n as usize - 1),
    };
    if !separators {
        return text;
    }
    let (sign, rest) = text.split_at(usize::from(text.starts_with('-')));
    let (whole, fraction) = rest.split_at(rest.find('.').unwrap_or(rest.len()));
    let digits: Vec<char> = whole.chars().collect();
    let grouped: String = digits
        .iter()
        .enumerate()
        .flat_map(|(i, d)| {
            let comma = i > 0 && (digits.len() - i).is_multiple_of(3);
            comma.then_some(',').into_iter().chain([*d])
        })
        .collect();
    format!("{sign}{grouped}{fraction}")
}
