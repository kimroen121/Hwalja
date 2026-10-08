//! 셀 테두리/배경: each cell for itself, or a block of cells as one (a cell zone).
use super::cells::Block;
use super::*;
use serde_json::{json, Map, Value};

const SIDES: [&str; 4] = ["borderLeft", "borderRight", "borderTop", "borderBottom"];
/// 중심선 in rhwp's names: a `VERTICAL` one is drawn across, a `HORIZONTAL` one down.
const CENTERS: [&str; 4] = ["NONE", "VERTICAL", "HORIZONTAL", "CROSS"];

fn side(v: &Value) -> BorderSide {
    BorderSide {
        line: v["type"].as_u64().unwrap_or(0) as u8,
        width: v["width"].as_u64().unwrap_or(0) as u8,
        color: v["color"].as_str().unwrap_or("#000000").into(),
    }
}
fn valid_side(s: &BorderSide) -> bool {
    s.line <= 16 && s.width <= 15 && s.color.starts_with('#') && s.color.len() == 7
}

/// rhwp's property JSON for `border` over the border fill `base`, with `sides` for the
/// cell's left, right, top and bottom.
fn props(base: u16, sides: [Option<&BorderSide>; 4], border: &CellBorder) -> String {
    let mut j = Map::new();
    j.insert("borderFillId".into(), json!(base));
    for (key, s) in SIDES.iter().zip(sides) {
        if let Some(s) = s {
            j.insert(
                (*key).into(),
                json!({ "type": s.line, "width": s.width, "color": s.color }),
            );
        }
    }
    if let Some(f) = &border.fill {
        let plain = f.color == "none" && f.pattern == 0;
        j.insert(
            "fillType".into(),
            json!(if plain { "none" } else { "solid" }),
        );
        j.insert("fillColor".into(), json!(f.color));
        j.insert("patternColor".into(), json!(f.pattern_color));
        j.insert("patternType".into(), json!(f.pattern));
    }
    if let Some(d) = &border.diagonal {
        j.insert("diagonalLine".into(), json!(d.line.line));
        j.insert("diagonalWidth".into(), json!(d.line.width));
        j.insert("diagonalColor".into(), json!(d.line.color));
        j.insert("diagonalSlash".into(), json!(if d.slash { 2 } else { 0 }));
        j.insert(
            "diagonalBackSlash".into(),
            json!(if d.back_slash { 2 } else { 0 }),
        );
        j.insert("centerLine".into(), json!(CENTERS[d.center as usize]));
    }
    Value::Object(j).to_string()
}

impl EditSession {
    /// 셀 테두리/배경 of the cell holding `t`, as drawn (a zone over it included).
    pub fn cell_border(&self, t: &EditTarget) -> Result<CellBorder, EditError> {
        commands::get(self.core.document(), t)?;
        let c = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let v: Value = serde_json::from_str(&self.core.get_cell_properties_native(
            t.section as usize,
            t.paragraph as usize,
            c.control as usize,
            c.cell as usize,
        )?)
        .map_err(|_| EditError::RenderFailed)?;
        let fill = self
            .core
            .document()
            .doc_info
            .border_fills
            .get((v["borderFillId"].as_u64().unwrap_or(0) as usize).wrapping_sub(1))
            .map(|bf| &bf.fill);
        let text = |v: &Value| v.as_str().unwrap_or("#000000").to_string();
        Ok(CellBorder {
            sides: [
                Some(side(&v["borderLeft"])),
                Some(side(&v["borderRight"])),
                Some(side(&v["borderTop"])),
                Some(side(&v["borderBottom"])),
                None,
                None,
            ],
            fill: match fill {
                Some(f) if f.gradient.is_some() || f.image.is_some() => None,
                _ => Some(PageFill {
                    color: if v["fillType"] == "solid" {
                        text(&v["fillColor"])
                    } else {
                        "none".into()
                    },
                    pattern_color: text(&v["patternColor"]),
                    pattern: (v["patternType"].as_u64().unwrap_or(0) as u8).min(6),
                }),
            },
            diagonal: Some(Diagonal {
                line: BorderSide {
                    line: v["diagonalLine"].as_u64().unwrap_or(0) as u8,
                    width: v["diagonalWidth"].as_u64().unwrap_or(0) as u8,
                    color: text(&v["diagonalColor"]),
                },
                slash: v["diagonalSlash"].as_u64().unwrap_or(0) != 0,
                back_slash: v["diagonalBackSlash"].as_u64().unwrap_or(0) != 0,
                center: CENTERS
                    .iter()
                    .position(|c| v["centerLine"] == *c)
                    .unwrap_or(0) as u8,
            }),
        })
    }
    pub(super) fn validate_cell_border(
        &self,
        selection: &EditSelection,
        border: &CellBorder,
    ) -> Result<(), EditError> {
        self.block(selection)?;
        let fill_ok = border.fill.as_ref().is_none_or(|f| {
            f.pattern <= 6
                && (f.color == "none" || f.color.len() == 7)
                && f.pattern_color.len() == 7
        });
        let diagonal_ok = border
            .diagonal
            .as_ref()
            .is_none_or(|d| valid_side(&d.line) && d.center <= 3);
        if border.sides.iter().flatten().all(valid_side) && fill_ok && diagonal_ok {
            Ok(())
        } else {
            Err(EditError::InvalidInput)
        }
    }
    pub(super) fn set_cell_border(
        &mut self,
        selection: &EditSelection,
        all: bool,
        one: bool,
        border: &CellBorder,
    ) -> Result<(), EditError> {
        let t = &selection.anchor.target;
        let c = t.cell.as_ref().ok_or(EditError::UnsupportedTarget)?;
        let (s, p, control) = (t.section as usize, t.paragraph as usize, c.control as usize);
        let table = commands::table(self.core.document(), t).ok_or(EditError::UnsupportedTarget)?;
        let b = if all {
            Block {
                rows: (0, table.row_count.saturating_sub(1)),
                cols: (0, table.col_count.saturating_sub(1)),
            }
        } else {
            self.block(selection)?
        };
        let ((r0, r1), (c0, c1)) = (b.rows, b.cols);
        // A cell's place and spans, its index and its border fill.
        let cells: Vec<_> = table
            .cells
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let (rs, cs) = (c.row_span.max(1), c.col_span.max(1));
                (
                    i,
                    c.row,
                    c.col,
                    c.row + rs - 1,
                    c.col + cs - 1,
                    c.border_fill_id,
                )
            })
            .filter(|&(_, row, col, last_row, last_col, _)| {
                row >= r0 && col >= c0 && last_row <= r1 && last_col <= c1
            })
            .collect();
        let sides: Vec<_> = border.sides.iter().map(Option::as_ref).collect();
        if one {
            let base = table
                .zones
                .iter()
                .find(|z| (z.start_row, z.start_col, z.end_row, z.end_col) == (r0, c0, r1, c1))
                .map(|z| z.border_fill_id)
                .or_else(|| cells.iter().find(|c| (c.1, c.2) == (r0, c0)).map(|c| c.5))
                .unwrap_or(0);
            let json = props(base, [sides[0], sides[1], sides[2], sides[3]], border);
            self.core
                .set_cell_zone_properties_native(s, p, control, r0, c0, r1, c1, &json)?;
            return Ok(());
        }
        for (i, row, col, last_row, last_col, base) in cells {
            let edge =
                |outer: bool, at: usize, inner: usize| if outer { sides[at] } else { sides[inner] };
            let json = props(
                base,
                [
                    edge(col == c0, 0, 5),
                    edge(last_col == c1, 1, 5),
                    edge(row == r0, 2, 4),
                    edge(last_row == r1, 3, 4),
                ],
                border,
            );
            self.core
                .set_cell_properties_native(s, p, control, i, &json)?;
        }
        Ok(())
    }
}
