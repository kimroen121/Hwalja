//! Character and paragraph formats: the caret query and the rhwp property JSON for changes.
use super::commands::{get, index};
use super::*;
use serde_json::{json, Map, Value};

pub(super) fn validate_char(style: &CharStyle) -> Result<(), EditError> {
    let font_ok = style.font.as_ref().is_none_or(|f| {
        !f.trim().is_empty() && f.chars().count() <= 64 && !f.chars().any(char::is_control)
    });
    let size_ok = style.size.is_none_or(|s| (1.0..=4096.0).contains(&s));
    let color_ok = [
        &style.color,
        &style.shade,
        &style.underline_color,
        &style.strike_color,
    ]
    .iter()
    .all(|c| c.as_ref().is_none_or(|c| color(c).is_some()));
    let shapes_ok = [style.underline_shape, style.strike_shape]
        .iter()
        .all(|s| s.is_none_or(|s| s <= 12));
    let scale_ok = style.ratio.is_none_or(|r| (50.0..=200.0).contains(&r))
        && style.spacing.is_none_or(|s| (-50.0..=50.0).contains(&s))
        && style
            .relative_size
            .is_none_or(|r| (10.0..=250.0).contains(&r))
        && style.offset.is_none_or(|o| (-100.0..=100.0).contains(&o))
        && style.language.is_none_or(|l| l < 7);
    let border_ok = BorderFill::of_char(style).valid();
    if font_ok
        && size_ok
        && color_ok
        && shapes_ok
        && scale_ok
        && border_ok
        && *style != CharStyle::default()
    {
        Ok(())
    } else {
        Err(EditError::InvalidInput)
    }
}
pub(super) fn validate_para(style: &ParaStyle) -> Result<(), EditError> {
    let spacing_ok = match style.line_spacing_kind.unwrap_or(LineSpacingKind::Percent) {
        LineSpacingKind::Percent => style
            .line_spacing
            .is_none_or(|s| (50.0..=500.0).contains(&s)),
        _ => style
            .line_spacing
            .is_none_or(|s| (0.0..=1000.0).contains(&s)),
    };
    let lengths_ok = [
        style.margin_left,
        style.margin_right,
        style.spacing_before,
        style.spacing_after,
    ]
    .iter()
    .all(|v| v.is_none_or(|v| (0.0..=1000.0).contains(&v)))
        && style.indent.is_none_or(|v| (-1000.0..=1000.0).contains(&v));
    let head_ok = match style.head.as_deref() {
        None | Some("None") => style.numbering.is_none() && style.bullet.is_none(),
        Some("Number") => {
            style
                .numbering
                .is_none_or(|n| (n as usize) < NUMBERINGS.len())
                && style.bullet.is_none()
        }
        Some("Bullet") => {
            style.bullet.as_ref().is_none_or(|b| b.chars().count() == 1)
                && style.numbering.is_none()
        }
        _ => false,
    };
    if spacing_ok
        && lengths_ok
        && head_ok
        && style.level.is_none_or(|v| v <= 6)
        && style.korean_break_unit.is_none_or(|v| v <= 1)
        && match (style.restart, style.start_number) {
            (None | Some(0 | 1), None) => true,
            (Some(2), Some(n)) => (1..=u16::MAX as u32).contains(&n),
            _ => false,
        }
        && style.english_break_unit.is_none_or(|v| v <= 2)
        && style.line_spacing_kind.is_some() == style.line_spacing.is_some()
        && BorderFill::of_para(style).valid()
        && *style != ParaStyle::default()
    {
        Ok(())
    } else {
        Err(EditError::InvalidInput)
    }
}
/// 테두리 and 배경 of a character or paragraph change, all set or none.
struct BorderFill<'a> {
    line: Option<u8>,
    width: Option<u8>,
    color: Option<&'a String>,
    fill: Option<&'a String>,
    pattern_color: Option<&'a String>,
    pattern: Option<u8>,
}
impl<'a> BorderFill<'a> {
    fn of_char(s: &'a CharStyle) -> Self {
        BorderFill {
            line: s.border_line,
            width: s.border_width,
            color: s.border_color.as_ref(),
            fill: s.fill_color.as_ref(),
            pattern_color: s.pattern_color.as_ref(),
            pattern: s.pattern,
        }
    }
    fn of_para(s: &'a ParaStyle) -> Self {
        BorderFill {
            line: s.border_line,
            width: s.border_width,
            color: s.border_color.as_ref(),
            fill: s.fill_color.as_ref(),
            pattern_color: s.pattern_color.as_ref(),
            pattern: s.pattern,
        }
    }
    fn set(&self) -> [bool; 6] {
        [
            self.line.is_some(),
            self.width.is_some(),
            self.color.is_some(),
            self.fill.is_some(),
            self.pattern_color.is_some(),
            self.pattern.is_some(),
        ]
    }
    fn valid(&self) -> bool {
        let set = self.set();
        if set.iter().all(|s| !s) {
            return true;
        }
        set.iter().all(|s| *s)
            && self.line.is_some_and(|l| l <= 17)
            && self.width.is_some_and(|w| w <= 15)
            && self.pattern.is_some_and(|p| p <= 6)
            && self.color.is_some_and(|c| color(c).is_some())
            && self.pattern_color.is_some_and(|c| color(c).is_some())
            && self.fill.is_some_and(|c| c == "none" || color(c).is_some())
    }
    /// rhwp's keys: the same line on all four sides, and a solid fill or none.
    fn insert(&self, props: &mut Map<String, Value>) {
        let (Some(line), Some(width), Some(c), Some(fill), Some(pc), Some(pattern)) = (
            self.line,
            self.width,
            self.color,
            self.fill,
            self.pattern_color,
            self.pattern,
        ) else {
            return;
        };
        let side = json!({ "type": line, "width": width, "color": c.to_lowercase() });
        for key in ["borderLeft", "borderRight", "borderTop", "borderBottom"] {
            props.insert(key.into(), side.clone());
        }
        // A pattern alone still needs a solid fill under it.
        let none = fill == "none" && pattern == 0;
        props.insert(
            "fillType".into(),
            json!(if none { "none" } else { "solid" }),
        );
        props.insert(
            "fillColor".into(),
            json!(if fill == "none" {
                "#ffffff".into()
            } else {
                fill.to_lowercase()
            }),
        );
        props.insert("patternColor".into(), json!(pc.to_lowercase()));
        props.insert("patternType".into(), json!(pattern));
    }
}
/// 테두리 and 배경 as rhwp reports them: the left side stands for all four.
type ReadBorderFill = (
    Option<u8>,
    Option<u8>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<u8>,
);
fn read_border_fill(v: &Value) -> ReadBorderFill {
    let side = &v["borderLeft"];
    let text = |v: &Value| v.as_str().map(str::to_string);
    let solid = v["fillType"] == "solid";
    (
        side["type"].as_u64().map(|n| n as u8),
        side["width"].as_u64().map(|n| n as u8),
        text(&side["color"]),
        if solid {
            text(&v["fillColor"])
        } else {
            Some("none".into())
        },
        text(&v["patternColor"]).or(Some("#000000".into())),
        Some(if solid {
            v["patternType"].as_u64().unwrap_or(0).min(6) as u8
        } else {
            0
        }),
    )
}
/// `#rrggbb` → the same string, normalized to lowercase.
fn color(text: &str) -> Option<String> {
    let hex = text.strip_prefix('#')?;
    (hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit())).then(|| text.to_lowercase())
}
/// 문단 번호 kinds of 문단 번호 모양, in its order: each level's format (`^n` is level n's
/// number) and number shape (0 1·2·3, 1 ①, 2 I, 3 i, 4 A, 5 a, 8 가, 10 ㄱ). Levels 5–7,
/// which the dialog does not show, continue as the first kind.
pub(super) const NUMBERINGS: [[(&str, u8); 7]; 10] = [
    [
        ("^1.", 0),
        ("^2.", 8),
        ("^3)", 0),
        ("^4)", 8),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("(^1)", 0),
        ("(^2)", 8),
        ("(^3)", 5),
        ("^4)", 0),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("^1)", 0),
        ("^2)", 8),
        ("^3)", 5),
        ("(^4)", 0),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("^1", 1),
        ("(^2)", 10),
        ("(^3)", 5),
        ("^4)", 0),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("^1)", 8),
        ("^2)", 5),
        ("(^3)", 0),
        ("(^4)", 8),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("(^1)", 10),
        ("(^2)", 0),
        ("(^3)", 5),
        ("^4)", 0),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("^1.", 2),
        ("^2.", 4),
        ("^3.", 0),
        ("^4)", 3),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("^1.", 3),
        ("^2.", 5),
        ("(^3)", 3),
        ("(^4)", 5),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("^1.", 4),
        ("^2.", 0),
        ("^3,", 8),
        ("(^4)", 5),
        ("(^5)", 0),
        ("(^6)", 8),
        ("^7", 1),
    ],
    [
        ("^1.", 0),
        ("^1.^2.", 0),
        ("^1.^2.^3.", 0),
        ("^1.^2.^3.^4.", 0),
        ("^1.^2.^3.^4.^5.", 0),
        ("^1.^2.^3.^4.^5.^6.", 0),
        ("^1.^2.^3.^4.^5.^6.^7.", 0),
    ],
];
/// A change to the font, 상대 크기, 장평, 글자 위치 and 자간 of some 언어, made over each
/// run's own values for the others.
pub(super) struct Languages {
    languages: std::ops::Range<usize>,
    fonts: [Option<u16>; 7],
    ratio: Option<u8>,
    spacing: Option<i8>,
    size: Option<u8>,
    offset: Option<i8>,
}
impl Languages {
    pub(super) fn is_empty(&self) -> bool {
        self.fonts.iter().all(Option::is_none)
            && self.ratio.is_none()
            && self.spacing.is_none()
            && self.size.is_none()
            && self.offset.is_none()
    }
    /// `props` with the change laid over the run's `own` shape.
    pub(super) fn over(&self, own: &rhwp::model::style::CharShape, props: &str) -> String {
        let mut map: Map<String, Value> = serde_json::from_str(props).unwrap_or_default();
        let (mut fonts, mut ratios, mut spacings, mut sizes, mut offsets) = (
            own.font_ids,
            own.ratios,
            own.spacings,
            own.relative_sizes,
            own.char_offsets,
        );
        for l in self.languages.clone() {
            fonts[l] = self.fonts[l].unwrap_or(fonts[l]);
            ratios[l] = self.ratio.unwrap_or(ratios[l]);
            spacings[l] = self.spacing.unwrap_or(spacings[l]);
            sizes[l] = self.size.unwrap_or(sizes[l]);
            offsets[l] = self.offset.unwrap_or(offsets[l]);
        }
        for (key, value) in [
            ("fontIds", json!(fonts)),
            ("ratios", json!(ratios)),
            ("spacings", json!(spacings)),
            ("relativeSizes", json!(sizes)),
            ("charOffsets", json!(offsets)),
        ] {
            map.insert(key.into(), value);
        }
        Value::Object(map).to_string()
    }
}
/// Whether numbering `n` is 문단 번호 kind `kind`.
fn is_kind(n: &rhwp::model::style::Numbering, kind: usize) -> bool {
    NUMBERINGS[kind]
        .iter()
        .enumerate()
        .all(|(i, (format, shape))| {
            n.level_formats[i] == *format && n.heads[i].number_format == *shape
        })
}
/// Paragraph lengths are stored in 1/200 pt (twice HWPUNIT).
const PARA_UNITS_PER_POINT: f64 = 200.0;

/// rhwp property JSON for a paragraph change, without its head (see `EditSession::para_props`).
fn plain_para_props(style: &ParaStyle) -> Map<String, Value> {
    let mut props = Map::new();
    if let Some(alignment) = style.alignment {
        props.insert("alignment".into(), serde_json::to_value(alignment).unwrap());
    }
    let units = |v: f64| json!((v * PARA_UNITS_PER_POINT).round() as i32);
    if let (Some(kind), Some(value)) = (style.line_spacing_kind, style.line_spacing) {
        let (name, value) = match kind {
            LineSpacingKind::Percent => ("Percent", json!(value.round() as i32)),
            LineSpacingKind::Fixed => ("Fixed", units(value)),
            LineSpacingKind::SpaceOnly => ("SpaceOnly", units(value)),
            LineSpacingKind::Minimum => ("Minimum", units(value)),
        };
        props.insert("lineSpacing".into(), value);
        props.insert("lineSpacingType".into(), json!(name));
    }
    for (key, value) in [
        ("marginLeft", style.margin_left),
        ("marginRight", style.margin_right),
        ("indent", style.indent),
        ("spacingBefore", style.spacing_before),
        ("spacingAfter", style.spacing_after),
    ] {
        if let Some(value) = value {
            props.insert(key.into(), units(value));
        }
    }
    for (key, value) in [
        ("keepWithNext", style.keep_with_next),
        ("keepLines", style.keep_lines),
        ("widowOrphan", style.widow_orphan),
        ("pageBreakBefore", style.page_break_before),
    ] {
        if let Some(value) = value {
            props.insert(key.into(), json!(value));
        }
    }
    for (key, value) in [
        ("koreanBreakUnit", style.korean_break_unit),
        ("englishBreakUnit", style.english_break_unit),
        ("paraLevel", style.level),
    ] {
        if let Some(value) = value {
            props.insert(key.into(), json!(value));
        }
    }
    if let Some(on) = style.border_connect {
        props.insert("borderConnect".into(), json!(on));
    }
    BorderFill::of_para(style).insert(&mut props);
    props
}

impl EditSession {
    /// rhwp property JSON for a paragraph change. A 문단 번호 or 글머리표 head gets its
    /// definition, added to the document when it has none like it.
    pub(super) fn para_props(&mut self, style: &ParaStyle) -> String {
        let mut props = plain_para_props(style);
        if let Some(head) = &style.head {
            let id = match head.as_str() {
                "Number" => self.numbering(style.numbering.unwrap_or(0) as usize),
                "Bullet" => self.bullet(
                    style
                        .bullet
                        .as_deref()
                        .and_then(|b| b.chars().next())
                        .unwrap_or('●'),
                ),
                _ => 0,
            };
            props.insert("headType".into(), json!(head));
            props.insert("numberingId".into(), json!(id));
        }
        Value::Object(props).to_string()
    }
    /// The 1-based id of 문단 번호 kind `kind`, added if the document lacks it.
    fn numbering(&mut self, kind: usize) -> u16 {
        use rhwp::model::style::{Numbering, NumberingHead};
        let levels = NUMBERINGS[kind];
        let info = &mut self.core.document_mut().doc_info;
        if let Some(i) = info.numberings.iter().position(|n| is_kind(n, kind)) {
            return i as u16 + 1;
        }
        let mut n = Numbering {
            start_number: 1,
            level_start_numbers: [1; 7],
            ..Default::default()
        };
        for (i, (format, shape)) in levels.iter().enumerate() {
            n.level_formats[i] = format.to_string();
            n.heads[i] = NumberingHead {
                number_format: *shape,
                ..Default::default()
            };
        }
        info.numberings.push(n);
        info.raw_stream_dirty = true;
        info.numberings.len() as u16
    }
    /// Which 문단 번호 kind the numbering with 1-based id `id` is, if one of them.
    fn numbering_kind(&self, id: u16) -> Option<u8> {
        let n = self
            .core
            .document()
            .doc_info
            .numberings
            .get(id.checked_sub(1)? as usize)?;
        (0..NUMBERINGS.len())
            .find(|&kind| is_kind(n, kind))
            .map(|kind| kind as u8)
    }
    /// The character of the 글머리표 with 1-based id `id`.
    fn bullet_char(&self, id: u16) -> Option<String> {
        let b = self
            .core
            .document()
            .doc_info
            .bullets
            .get(id.checked_sub(1)? as usize)?;
        Some(rhwp::renderer::layout::map_pua_bullet_char(b.bullet_char).to_string())
    }
    /// The 1-based id of the 글머리표 drawing `c`, added if the document lacks it.
    fn bullet(&mut self, c: char) -> u16 {
        use rhwp::model::style::Bullet;
        let info = &mut self.core.document_mut().doc_info;
        if let Some(i) = info
            .bullets
            .iter()
            .position(|b| rhwp::renderer::layout::map_pua_bullet_char(b.bullet_char) == c)
        {
            return i as u16 + 1;
        }
        info.bullets.push(Bullet {
            bullet_char: c,
            text_distance: 50,
            ..Default::default()
        });
        info.raw_stream_dirty = true;
        info.bullets.len() as u16
    }
    /// rhwp property JSON for a character change, without the values each 언어 has (see
    /// `Languages`). Registers a new font name if needed.
    pub(super) fn char_props(&mut self, style: &CharStyle) -> (String, Languages) {
        let mut props = Map::new();
        let languages = match style.language {
            Some(l) => l as usize..l as usize + 1,
            None => 0..7,
        };
        let mut fonts = [None; 7];
        if let Some(font) = &style.font {
            for l in languages.clone() {
                // Each 언어 lists its own fonts.
                let id = self.core.find_or_create_font_id_for_lang(l, font.trim());
                fonts[l] = u16::try_from(id).ok();
            }
        }
        if let Some(size) = style.size {
            props.insert("fontSize".into(), json!((size * 100.0).round() as i32));
        }
        for (key, value) in [
            ("bold", style.bold),
            ("italic", style.italic),
            ("underline", style.underline),
            ("strikethrough", style.strikethrough),
        ] {
            if let Some(value) = value {
                props.insert(key.into(), json!(value));
            }
        }
        if style.underline == Some(true) || style.underline_top.is_some() {
            let top = style.underline_top == Some(true);
            props.insert(
                "underlineType".into(),
                json!(if top { "Top" } else { "Bottom" }),
            );
        }
        if let Some(c) = style.color.as_deref().and_then(color) {
            props.insert("textColor".into(), json!(c));
        }
        if let Some(c) = style.shade.as_deref().and_then(color) {
            props.insert("shadeColor".into(), json!(c));
        }
        for (key, value) in [
            ("underlineColor", &style.underline_color),
            ("strikeColor", &style.strike_color),
        ] {
            if let Some(c) = value.as_deref().and_then(color) {
                props.insert(key.into(), json!(c));
            }
        }
        if let Some(shape) = style.underline_shape {
            props.insert("underlineShape".into(), json!(shape));
        }
        if let Some(shape) = style.strike_shape {
            props.insert("strikeShape".into(), json!(shape));
        }
        let languages = Languages {
            languages,
            fonts,
            ratio: style.ratio.map(|v| v.round() as u8),
            spacing: style.spacing.map(|v| v.round() as i8),
            size: style.relative_size.map(|v| v.round() as u8),
            offset: style.offset.map(|v| v.round() as i8),
        };
        BorderFill::of_char(style).insert(&mut props);
        // One of superscript and subscript at a time.
        if let Some(on) = style.superscript {
            props.insert("superscript".into(), json!(on));
            if on {
                props.insert("subscript".into(), json!(false));
            }
        }
        if let Some(on) = style.subscript {
            props.insert("subscript".into(), json!(on));
            if on {
                props.insert("superscript".into(), json!(false));
            }
        }
        for (key, value) in [("outlineType", style.outline), ("shadowType", style.shadow)] {
            if let Some(on) = value {
                props.insert(key.into(), json!(on as i32));
            }
        }
        for (key, value) in [("emboss", style.emboss), ("engrave", style.engrave)] {
            if let Some(on) = value {
                props.insert(key.into(), json!(on));
            }
        }
        (Value::Object(props).to_string(), languages)
    }
    /// Applies `props` to `from..to`, one existing run at a time: rhwp derives the new
    /// shape from the run at the range start, which would copy that run's other
    /// attributes (color, font, …) over the rest of the range.
    pub(super) fn format_text(
        &mut self,
        t: &EditTarget,
        from: u32,
        to: u32,
        props: &str,
        languages: &Languages,
    ) -> Result<(), EditError> {
        let para = get(self.core.document(), t)?;
        let (from, to) = (
            logical::spot(para, from).text as u32,
            logical::spot(para, to).text as u32,
        );
        let mut runs: Vec<(u32, u32)> = Vec::new();
        for offset in from..to {
            let id = para.char_shape_id_at(offset as usize);
            match runs.last_mut() {
                Some((_, end)) if para.char_shape_id_at(*end as usize - 1) == id => {
                    *end = offset + 1
                }
                _ => runs.push((offset, offset + 1)),
            }
        }
        let shapes: Vec<_> = runs
            .iter()
            .map(|&(start, _)| para.char_shape_id_at(start as usize))
            .collect();
        for ((start, end), shape) in runs.into_iter().zip(shapes) {
            let own =
                shape.and_then(|id| self.core.document().doc_info.char_shapes.get(id as usize));
            let props = match own {
                Some(own) if !languages.is_empty() => languages.over(own, props),
                _ => props.to_string(),
            };
            self.format_run(t, start, end, &props)?;
        }
        Ok(())
    }
    fn format_run(
        &mut self,
        t: &EditTarget,
        from: u32,
        to: u32,
        props: &str,
    ) -> Result<(), EditError> {
        if let Some(n) = &t.note {
            self.core.apply_char_format_in_footnote_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
                from as usize,
                to as usize,
                props,
            )?;
            return Ok(());
        }
        match (&t.header_footer, &t.cell) {
            (Some(hf), _) => self.core.apply_char_format_in_header_footer_native(
                t.section as usize,
                !hf.footer,
                hf.apply_to,
                index(t),
                from as usize,
                index(t),
                to as usize,
                props,
            ),
            (None, Some(c)) => self.core.apply_char_format_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                from as usize,
                to as usize,
                props,
            ),
            (None, None) => self.core.apply_char_format_native(
                t.section as usize,
                t.paragraph as usize,
                from as usize,
                to as usize,
                props,
            ),
        }?;
        Ok(())
    }
    pub(super) fn format_paragraph(
        &mut self,
        t: &EditTarget,
        props: &str,
    ) -> Result<(), EditError> {
        if let Some(n) = &t.note {
            self.core.apply_para_format_in_footnote_native(
                t.section as usize,
                t.paragraph as usize,
                n.control as usize,
                n.paragraph as usize,
                props,
            )?;
            return Ok(());
        }
        match (&t.header_footer, &t.cell) {
            (Some(hf), _) => self.core.apply_para_format_in_hf_native(
                t.section as usize,
                !hf.footer,
                hf.apply_to,
                index(t),
                props,
            ),
            (None, Some(c)) => self.core.apply_para_format_in_cell_native(
                t.section as usize,
                t.paragraph as usize,
                c.control as usize,
                c.cell as usize,
                c.paragraph as usize,
                props,
            ),
            (None, None) => {
                self.core
                    .apply_para_format_native(t.section as usize, t.paragraph as usize, props)
            }
        }?;
        Ok(())
    }

    /// The stored shape of the paragraph at `t`, for exact lengths.
    fn paragraph_shape(&self, t: &EditTarget) -> Result<&rhwp::model::style::ParaShape, EditError> {
        let id = get(self.core.document(), t)?.para_shape_id;
        self.core
            .document()
            .doc_info
            .para_shapes
            .get(id as usize)
            .ok_or(EditError::RenderFailed)
    }
    /// Format of the text before the caret (what typing continues with) and its paragraph.
    /// The format at `p`: of the character before it, and its paragraph. With `from`, the
    /// character attributes that differ across the characters between them are unset.
    pub fn format(
        &self,
        revision: u64,
        p: &EditPosition,
        from: Option<&EditPosition>,
    ) -> Result<Format, EditError> {
        if self.locked {
            return Err(EditError::Locked);
        }
        if revision != self.revision {
            return Err(EditError::StaleRevision);
        }
        let para = get(self.core.document(), &p.target)?;
        let offset = logical::spot(para, p.scalar).text.saturating_sub(1);
        let mut format = self.format_at(&p.target, offset)?;
        if let Some(from) = from {
            self.unset_mixed(&mut format.text, from, p)?;
        }
        Ok(format)
    }
    /// Unsets the attributes of `text` that differ across the characters from `a` to `b`,
    /// looking at one character of each character shape among them.
    fn unset_mixed(
        &self,
        text: &mut CharStyle,
        a: &EditPosition,
        b: &EditPosition,
    ) -> Result<(), EditError> {
        let (start, end) = if (index(&a.target), a.scalar) <= (index(&b.target), b.scalar) {
            (a, b)
        } else {
            (b, a)
        };
        if start == end || !super::commands::same_container(&start.target, &end.target) {
            return Ok(());
        }
        let all = super::commands::paragraphs(self.core.document(), &start.target)?;
        let (s, e) = (index(&start.target), index(&end.target));
        let Ok(Value::Object(mut kept)) = serde_json::to_value(&*text) else {
            return Err(EditError::RenderFailed);
        };
        let mut seen = std::collections::HashSet::new();
        'paragraphs: for (i, p) in all.iter().enumerate().take(e + 1).skip(s) {
            let len = p.text.chars().count();
            let from = if i == s {
                logical::spot(p, start.scalar).text
            } else {
                0
            };
            let to = if i == e {
                logical::spot(p, end.scalar).text
            } else {
                len
            };
            // A shape starts at a UTF-16 offset; `char_offsets` maps characters to them.
            let char_at = |unit: u32| match p.char_offsets.is_empty() {
                true => (unit as usize).min(len),
                false => p
                    .char_offsets
                    .iter()
                    .position(|&o| o >= unit)
                    .unwrap_or(len),
            };
            for (k, run) in p.char_shapes.iter().enumerate() {
                let first = char_at(run.start_pos).max(from);
                let last = p
                    .char_shapes
                    .get(k + 1)
                    .map_or(len, |n| char_at(n.start_pos))
                    .min(to);
                if first >= last || !seen.insert(run.char_shape_id) {
                    continue;
                }
                // ponytail: 32 shapes looked at; enough for a toolbar, a whole-file scan if not.
                if seen.len() > 32 {
                    break 'paragraphs;
                }
                let other = self.format_at(&super::commands::at_index(&start.target, i), first)?;
                let Ok(Value::Object(other)) = serde_json::to_value(&other.text) else {
                    return Err(EditError::RenderFailed);
                };
                kept.retain(|key, value| other.get(key) == Some(value));
            }
        }
        *text = serde_json::from_value(Value::Object(kept)).map_err(|_| EditError::RenderFailed)?;
        Ok(())
    }
    /// The format of character `offset` of the paragraph at `t`, and of the paragraph.
    fn format_at(&self, t: &EditTarget, offset: usize) -> Result<Format, EditError> {
        let parse = |text: Result<String, rhwp::error::HwpError>| -> Result<Value, EditError> {
            serde_json::from_str(&text?).map_err(|_| EditError::RenderFailed)
        };
        let (text, para) = match (&t.note, &t.header_footer, &t.cell) {
            (Some(n), _, _) => (
                self.core.get_char_properties_in_footnote_native(
                    t.section as usize,
                    t.paragraph as usize,
                    n.control as usize,
                    n.paragraph as usize,
                    offset,
                ),
                self.core.get_para_properties_in_footnote_native(
                    t.section as usize,
                    t.paragraph as usize,
                    n.control as usize,
                    n.paragraph as usize,
                ),
            ),
            (None, Some(hf), _) => (
                self.core.get_char_properties_in_header_footer_native(
                    t.section as usize,
                    !hf.footer,
                    hf.apply_to,
                    index(t),
                    offset,
                ),
                self.core.get_para_properties_in_hf_native(
                    t.section as usize,
                    !hf.footer,
                    hf.apply_to,
                    index(t),
                ),
            ),
            (None, None, Some(c)) => (
                self.core.get_cell_char_properties_at_native(
                    t.section as usize,
                    t.paragraph as usize,
                    c.control as usize,
                    c.cell as usize,
                    index(t),
                    offset,
                ),
                self.core.get_cell_para_properties_at_native(
                    t.section as usize,
                    t.paragraph as usize,
                    c.control as usize,
                    c.cell as usize,
                    index(t),
                ),
            ),
            (None, None, None) => (
                self.core
                    .get_char_properties_at_native(t.section as usize, index(t), offset),
                self.core
                    .get_para_properties_at_native(t.section as usize, index(t)),
            ),
        };
        let style = get(self.core.document(), t)?.style_id as u32;
        Ok(self.format_of(
            &parse(text)?,
            &parse(para)?,
            self.paragraph_shape(t)?,
            style,
            super::commands::in_text_box(self.core.document(), t),
        ))
    }
    /// A format from rhwp's character and paragraph properties and the paragraph shape.
    pub(super) fn format_of(
        &self,
        text: &Value,
        para: &Value,
        shape: &rhwp::model::style::ParaShape,
        style: u32,
        text_box: bool,
    ) -> Format {
        let flag = |key: &str| text.get(key).and_then(Value::as_bool);
        let font = text
            .get("fontFamily")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let bold = flag("bold");
        let fonts = rhwp::renderer::render_font_family_chain_for_weight(&font, bold == Some(true))
            .split(',')
            .map(|name| name.trim().trim_matches('\'').to_string())
            .filter(|name| !name.is_empty() && !name.ends_with("serif") && name != "monospace")
            .collect();
        let number = |v: &Value, key: &str| v.get(key).and_then(Value::as_f64);
        let first = |key: &str| text.get(key).and_then(|a| a.get(0)).and_then(Value::as_f64);
        let on = |key: &str| text.get(key).and_then(Value::as_i64).map(|v| v != 0);
        let head = para
            .get("headType")
            .and_then(Value::as_str)
            .map(str::to_string);
        let points = |v: i32| v as f64 / PARA_UNITS_PER_POINT;
        use rhwp::model::style::LineSpacingType;
        let (kind, spacing) = match shape.line_spacing_type {
            LineSpacingType::Percent => (LineSpacingKind::Percent, shape.line_spacing as f64),
            LineSpacingType::Fixed => (LineSpacingKind::Fixed, points(shape.line_spacing)),
            LineSpacingType::SpaceOnly => (LineSpacingKind::SpaceOnly, points(shape.line_spacing)),
            LineSpacingType::Minimum => (LineSpacingKind::Minimum, points(shape.line_spacing)),
        };
        let para_flag = |key: &str| para.get(key).and_then(Value::as_bool);
        let para_unit = |key: &str| para.get(key).and_then(Value::as_u64).map(|v| v as u8);
        let (line, width, border, fill, pattern_color, pattern) = read_border_fill(text);
        let (p_line, p_width, p_border, p_fill, p_pattern_color, p_pattern) =
            read_border_fill(para);
        let at = |key: &str, l: usize| text.get(key).and_then(|a| a.get(l)).and_then(Value::as_f64);
        let languages = (0..7)
            .map(|l| CharStyle {
                font: text
                    .get("fontFamilies")
                    .and_then(|a| a.get(l))
                    .and_then(Value::as_str)
                    .map(str::to_string),
                ratio: at("ratios", l),
                spacing: at("spacings", l),
                relative_size: at("relativeSizes", l),
                offset: at("charOffsets", l),
                ..Default::default()
            })
            .collect();
        Format {
            style,
            languages,
            text_box,
            text: CharStyle {
                language: None,
                font: Some(font),
                size: text
                    .get("fontSize")
                    .and_then(Value::as_f64)
                    .map(|s| s / 100.0),
                bold,
                italic: flag("italic"),
                underline: flag("underline"),
                strikethrough: flag("strikethrough"),
                color: text
                    .get("textColor")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                underline_shape: number(&text, "underlineShape").map(|v| v as u8),
                strike_shape: number(&text, "strikeShape").map(|v| v as u8),
                underline_color: text
                    .get("underlineColor")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                strike_color: text
                    .get("strikeColor")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                shade: text
                    .get("shadeColor")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                ratio: first("ratios"),
                spacing: first("spacings"),
                superscript: flag("superscript"),
                subscript: flag("subscript"),
                outline: on("outlineType"),
                shadow: on("shadowType"),
                emboss: flag("emboss"),
                engrave: flag("engrave"),
                underline_top: text
                    .get("underlineType")
                    .and_then(Value::as_str)
                    .map(|t| t == "Top"),
                relative_size: first("relativeSizes"),
                offset: first("charOffsets"),
                border_line: line,
                border_width: width,
                border_color: border,
                fill_color: fill,
                pattern_color,
                pattern,
            },
            paragraph: ParaStyle {
                alignment: para
                    .get("alignment")
                    .and_then(|a| serde_json::from_value(a.clone()).ok()),
                line_spacing: Some(spacing),
                line_spacing_kind: Some(kind),
                margin_left: Some(points(shape.margin_left)),
                margin_right: Some(points(shape.margin_right)),
                indent: Some(points(shape.indent)),
                spacing_before: Some(points(shape.spacing_before)),
                spacing_after: Some(points(shape.spacing_after)),
                keep_with_next: para_flag("keepWithNext"),
                keep_lines: para_flag("keepLines"),
                widow_orphan: para_flag("widowOrphan"),
                page_break_before: para_flag("pageBreakBefore"),
                numbering: (head.as_deref() == Some("Number"))
                    .then(|| self.numbering_kind(shape.numbering_id))
                    .flatten(),
                bullet: (head.as_deref() == Some("Bullet"))
                    .then(|| self.bullet_char(shape.numbering_id))
                    .flatten(),
                head,
                level: para_unit("paraLevel"),
                korean_break_unit: para_unit("koreanBreakUnit"),
                english_break_unit: para_unit("englishBreakUnit"),
                border_line: p_line,
                border_width: p_width,
                border_color: p_border,
                fill_color: p_fill,
                pattern_color: p_pattern_color,
                pattern: p_pattern,
                border_connect: para_flag("borderConnect"),
                restart: para
                    .get("numberingRestartMode")
                    .and_then(Value::as_u64)
                    .map(|value| value as u8),
                start_number: para
                    .get("numberingStartNum")
                    .and_then(Value::as_u64)
                    .map(|value| value as u32),
            },
            fonts,
        }
    }
}
