//! A page as a display list the app draws with Core Graphics and Core Text, built from the
//! page SVG that PDF export converts. Faces are picked the way usvg picks them, from the
//! same font database, so the app draws the glyphs the PDF would hold. SVG this does not
//! cover yields `None`, and that page is sent as PDF instead.
use rhwp::renderer::pdf::{default_fontdb, fontdb};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use svgtypes::{FontFamily, SimplePathSegment, SimplifyingPathParser, Transform};

#[derive(Debug, PartialEq)]
pub struct Display {
    pub width: f64,
    pub height: f64,
    /// Font files the text ops refer to by index.
    pub fonts: Vec<Face>,
    pub ops: Vec<Op>,
}
#[derive(Debug, PartialEq)]
pub struct Face {
    pub path: String,
    pub index: u32,
}

/// Colors are `0xrrggbb`; a missing fill or stroke is not painted.
#[derive(Debug, PartialEq)]
pub enum Op {
    Save,
    Restore,
    Transform {
        m: [f64; 6],
    },
    Clip {
        rects: Vec<[f64; 4]>,
    },
    Rect {
        rect: [f64; 4],
        fill: Option<u32>,
        stroke: Option<u32>,
        width: f64,
    },
    Ellipse {
        rect: [f64; 4],
        fill: Option<u32>,
        stroke: Option<u32>,
        width: f64,
    },
    Line {
        points: [f64; 4],
        color: u32,
        width: f64,
        dash: Vec<f64>,
    },
    /// `d`: 0 x y (move), 1 x y (line), 2 x1 y1 x2 y2 x y (cubic), 3 x1 y1 x y (quadratic), 4 (close).
    Path {
        d: Vec<f64>,
        fill: Option<u32>,
        stroke: Option<u32>,
        width: f64,
        round: bool,
    },
    /// Base64 PNG or JPEG stretched over `rect`.
    Image {
        rect: [f64; 4],
        data: String,
    },
    /// One SVG `<text>`: `runs` are (font index, text) in order. With `length`, the glyphs
    /// are stretched horizontally to that advance; `center` anchors at the middle.
    Text {
        x: f64,
        y: f64,
        size: f64,
        color: u32,
        runs: Vec<(u16, String)>,
        length: Option<f64>,
        center: bool,
    },
}

impl Display {
    /// Little-endian binary: width, height (f32); fonts (u32 count; path, u32 index each);
    /// ops (u32 count; a u8 tag and its fields each). Strings are a u32 byte length and
    /// UTF-8; an absent color is `u32::MAX`. The app's `PageDisplay` reads it.
    pub fn encode(&self, out: &mut Vec<u8>) {
        let f = |out: &mut Vec<u8>, v: f64| out.extend((v as f32).to_le_bytes());
        let u = |out: &mut Vec<u8>, v: u32| out.extend(v.to_le_bytes());
        let text = |out: &mut Vec<u8>, v: &str| {
            u(out, v.len() as u32);
            out.extend(v.as_bytes());
        };
        let color = |out: &mut Vec<u8>, v: Option<u32>| u(out, v.unwrap_or(u32::MAX));
        f(out, self.width);
        f(out, self.height);
        u(out, self.fonts.len() as u32);
        for face in &self.fonts {
            text(out, &face.path);
            u(out, face.index);
        }
        u(out, self.ops.len() as u32);
        for op in &self.ops {
            match op {
                Op::Save => out.push(0),
                Op::Restore => out.push(1),
                Op::Transform { m } => {
                    out.push(2);
                    m.iter().for_each(|&v| f(out, v));
                }
                Op::Clip { rects } => {
                    out.push(3);
                    u(out, rects.len() as u32);
                    rects.iter().flatten().for_each(|&v| f(out, v));
                }
                Op::Rect {
                    rect,
                    fill,
                    stroke,
                    width,
                }
                | Op::Ellipse {
                    rect,
                    fill,
                    stroke,
                    width,
                } => {
                    out.push(if matches!(op, Op::Rect { .. }) { 4 } else { 5 });
                    rect.iter().for_each(|&v| f(out, v));
                    color(out, *fill);
                    color(out, *stroke);
                    f(out, *width);
                }
                Op::Line {
                    points,
                    color: c,
                    width,
                    dash,
                } => {
                    out.push(6);
                    points.iter().for_each(|&v| f(out, v));
                    u(out, *c);
                    f(out, *width);
                    u(out, dash.len() as u32);
                    dash.iter().for_each(|&v| f(out, v));
                }
                Op::Path {
                    d,
                    fill,
                    stroke,
                    width,
                    round,
                } => {
                    out.push(7);
                    u(out, d.len() as u32);
                    d.iter().for_each(|&v| f(out, v));
                    color(out, *fill);
                    color(out, *stroke);
                    f(out, *width);
                    out.push(*round as u8);
                }
                Op::Image { rect, data } => {
                    out.push(8);
                    rect.iter().for_each(|&v| f(out, v));
                    text(out, data);
                }
                Op::Text {
                    x,
                    y,
                    size,
                    color: c,
                    runs,
                    length,
                    center,
                } => {
                    out.push(9);
                    [*x, *y, *size, length.unwrap_or(-1.0)]
                        .iter()
                        .for_each(|&v| f(out, v));
                    u(out, *c);
                    out.push(*center as u8);
                    u(out, runs.len() as u32);
                    for (font, s) in runs {
                        out.extend(font.to_le_bytes());
                        text(out, s);
                    }
                }
            }
        }
    }
}

/// Builds the display list of a page SVG, or `None` when it uses anything not covered.
pub fn build(svg: &str) -> Option<Display> {
    let svg = rhwp::renderer::pdf::apply_pdf_font_options(svg, &Default::default());
    let doc = roxmltree::Document::parse(&svg).ok()?;
    let root = doc.root_element();
    let mut clips = HashMap::new();
    for node in root.descendants().filter(|n| n.has_tag_name("clipPath")) {
        let rects = node
            .children()
            .filter(|n| n.is_element())
            .map(|n| {
                (n.has_tag_name("rect") && allowed(n, &["x", "y", "width", "height", "fill"]))
                    .then(|| rect(n))
                    .flatten()
            })
            .collect::<Option<Vec<_>>>()?;
        clips.insert(node.attribute("id")?, rects);
    }
    let mut builder = Builder {
        db: default_fontdb(),
        clips,
        fonts: Vec::new(),
        font_index: HashMap::new(),
        ops: Vec::new(),
    };
    let (width, height) = (number(root, "width")?, number(root, "height")?);
    builder.viewport(root, [0.0, 0.0, width, height])?;
    Some(Display {
        width,
        height,
        fonts: builder.fonts,
        ops: builder.ops,
    })
}

struct Builder<'a> {
    db: Arc<fontdb::Database>,
    clips: HashMap<&'a str, Vec<[f64; 4]>>,
    fonts: Vec<Face>,
    font_index: HashMap<fontdb::ID, u16>,
    ops: Vec<Op>,
}

impl<'a> Builder<'a> {
    /// An `<svg>` element: its view box mapped onto `viewport`, clipped to it.
    fn viewport(&mut self, node: roxmltree::Node<'a, '_>, viewport: [f64; 4]) -> Option<()> {
        let [x, y, w, h] = viewport;
        let view = match node.attribute("viewBox") {
            Some(text) => {
                let v: Vec<f64> = text
                    .split([' ', ','])
                    .filter(|s| !s.is_empty())
                    .map(|s| s.parse().ok())
                    .collect::<Option<_>>()?;
                <[f64; 4]>::try_from(v).ok()?
            }
            None => viewport,
        };
        let (sx, sy) = (w / view[2], h / view[3]);
        // Without `preserveAspectRatio="none"` only an undistorted mapping is covered.
        if node.attribute("preserveAspectRatio") != Some("none") && (sx - sy).abs() > 1e-6 {
            return None;
        }
        self.ops.push(Op::Save);
        self.ops.push(Op::Clip {
            rects: vec![viewport],
        });
        self.ops.push(Op::Transform {
            m: [sx, 0.0, 0.0, sy, x - view[0] * sx, y - view[1] * sy],
        });
        self.children(node)?;
        self.ops.push(Op::Restore);
        Some(())
    }

    fn children(&mut self, node: roxmltree::Node<'a, '_>) -> Option<()> {
        for child in node.children() {
            if child.is_element() {
                self.element(child)?;
            } else if child.is_text() && !child.text()?.trim().is_empty() {
                return None;
            }
        }
        Some(())
    }

    fn element(&mut self, n: roxmltree::Node<'a, '_>) -> Option<()> {
        match n.tag_name().name() {
            "defs" => {
                // Only clip paths, collected up front.
                n.children()
                    .filter(|c| c.is_element())
                    .all(|c| c.has_tag_name("clipPath"))
                    .then_some(())
            }
            "svg" => {
                if !allowed(
                    n,
                    &[
                        "x",
                        "y",
                        "width",
                        "height",
                        "viewBox",
                        "preserveAspectRatio",
                    ],
                ) {
                    return None;
                }
                let at = |key| n.attribute(key).map_or(Some(0.0), |v| v.parse().ok());
                let viewport = [
                    at("x")?,
                    at("y")?,
                    number(n, "width")?,
                    number(n, "height")?,
                ];
                self.viewport(n, viewport)
            }
            "g" => {
                if !allowed(n, &["transform", "clip-path"]) {
                    return None;
                }
                self.ops.push(Op::Save);
                if let Some(t) = n.attribute("transform") {
                    self.ops.push(transform(t)?);
                }
                if let Some(c) = n.attribute("clip-path") {
                    let id = c.strip_prefix("url(#")?.strip_suffix(')')?;
                    self.ops.push(Op::Clip {
                        rects: self.clips.get(id)?.clone(),
                    });
                }
                self.children(n)?;
                self.ops.push(Op::Restore);
                Some(())
            }
            "rect" => {
                if !allowed(
                    n,
                    &[
                        "x",
                        "y",
                        "width",
                        "height",
                        "fill",
                        "stroke",
                        "stroke-width",
                    ],
                ) {
                    return None;
                }
                let (fill, stroke, width) = paint(n)?;
                self.ops.push(Op::Rect {
                    rect: rect(n)?,
                    fill,
                    stroke,
                    width,
                });
                Some(())
            }
            "circle" | "ellipse" => {
                let keys = [
                    "cx",
                    "cy",
                    "r",
                    "rx",
                    "ry",
                    "fill",
                    "stroke",
                    "stroke-width",
                ];
                if !allowed(n, &keys) {
                    return None;
                }
                let (cx, cy) = (number(n, "cx")?, number(n, "cy")?);
                let (rx, ry) = match n.attribute("r") {
                    Some(_) => (number(n, "r")?, number(n, "r")?),
                    None => (number(n, "rx")?, number(n, "ry")?),
                };
                let (fill, stroke, width) = paint(n)?;
                self.ops.push(Op::Ellipse {
                    rect: [cx - rx, cy - ry, rx * 2.0, ry * 2.0],
                    fill,
                    stroke,
                    width,
                });
                Some(())
            }
            "line" => {
                let keys = [
                    "x1",
                    "y1",
                    "x2",
                    "y2",
                    "stroke",
                    "stroke-width",
                    "stroke-dasharray",
                ];
                if !allowed(n, &keys) {
                    return None;
                }
                let (_, stroke, width) = paint(n)?;
                let dash = match n.attribute("stroke-dasharray") {
                    Some(text) => text
                        .split([' ', ','])
                        .filter(|s| !s.is_empty())
                        .map(|s| s.parse().ok())
                        .collect::<Option<_>>()?,
                    None => Vec::new(),
                };
                if let Some(color) = stroke {
                    let p = |k| number(n, k);
                    self.ops.push(Op::Line {
                        points: [p("x1")?, p("y1")?, p("x2")?, p("y2")?],
                        color,
                        width,
                        dash,
                    });
                }
                Some(())
            }
            "path" => {
                let keys = ["d", "fill", "stroke", "stroke-width", "stroke-linecap"];
                if !allowed(n, &keys) {
                    return None;
                }
                let round = match n.attribute("stroke-linecap") {
                    None | Some("butt") => false,
                    Some("round") => true,
                    _ => return None,
                };
                let mut d = Vec::new();
                for segment in SimplifyingPathParser::from(n.attribute("d")?) {
                    match segment.ok()? {
                        SimplePathSegment::MoveTo { x, y } => d.extend([0.0, x, y]),
                        SimplePathSegment::LineTo { x, y } => d.extend([1.0, x, y]),
                        SimplePathSegment::CurveTo {
                            x1,
                            y1,
                            x2,
                            y2,
                            x,
                            y,
                        } => d.extend([2.0, x1, y1, x2, y2, x, y]),
                        SimplePathSegment::Quadratic { x1, y1, x, y } => {
                            d.extend([3.0, x1, y1, x, y])
                        }
                        SimplePathSegment::ClosePath => d.push(4.0),
                    }
                }
                let (fill, stroke, width) = paint(n)?;
                self.ops.push(Op::Path {
                    d,
                    fill,
                    stroke,
                    width,
                    round,
                });
                Some(())
            }
            "image" => {
                let keys = ["x", "y", "width", "height", "preserveAspectRatio", "href"];
                if !allowed(n, &keys) || n.attribute("preserveAspectRatio") != Some("none") {
                    return None;
                }
                let href = n
                    .attributes()
                    .find(|a| a.name() == "href")
                    .map(|a| a.value())?;
                let data = href
                    .strip_prefix("data:image/png;base64,")
                    .or_else(|| href.strip_prefix("data:image/jpeg;base64,"))?;
                self.ops.push(Op::Image {
                    rect: rect(n)?,
                    data: data.to_string(),
                });
                Some(())
            }
            "text" => self.text(n),
            _ => None,
        }
    }

    fn text(&mut self, n: roxmltree::Node<'a, '_>) -> Option<()> {
        let keys = [
            "x",
            "y",
            "font-family",
            "font-size",
            "fill",
            "fill-opacity",
            "textLength",
            "lengthAdjust",
            "font-weight",
            "font-style",
            "text-anchor",
            "transform",
        ];
        if !allowed(n, &keys) || n.children().any(|c| !c.is_text()) {
            return None;
        }
        // Text kept only for extraction (e.g. a middle dot drawn as a circle).
        match n.attribute("fill-opacity") {
            None => {}
            Some("0") => return Some(()),
            Some(_) => return None,
        }
        let length = match (n.attribute("textLength"), n.attribute("lengthAdjust")) {
            (None, None) => None,
            (Some(l), Some("spacingAndGlyphs")) => Some(l.parse().ok()?),
            _ => return None,
        };
        let center = match n.attribute("text-anchor") {
            None | Some("start") => false,
            Some("middle") => true,
            _ => return None,
        };
        let weight = match n.attribute("font-weight").unwrap_or("normal") {
            "normal" => 400,
            "bold" => 700,
            w => w
                .parse()
                .ok()
                .filter(|w| (100..=900).contains(w) && w % 100 == 0)?,
        };
        let style = match n.attribute("font-style").unwrap_or("normal") {
            "normal" => fontdb::Style::Normal,
            "italic" => fontdb::Style::Italic,
            "oblique" => fontdb::Style::Oblique,
            _ => return None,
        };
        let text: String = n.text().unwrap_or_default().trim().into();
        if text.is_empty() {
            return Some(());
        }
        let base = pick(&self.db, n.attribute("font-family")?, weight, style)?;
        let mut runs: Vec<(u16, String)> = Vec::new();
        for (id, c) in faces(&self.db, base, &text) {
            let font = self.font(id)?;
            match runs.last_mut() {
                Some((f, s)) if *f == font => s.push(c),
                _ => runs.push((font, c.to_string())),
            }
        }
        let (fill, _, _) = paint(n)?;
        let transformed = n.attribute("transform").is_some();
        if let Some(t) = n.attribute("transform") {
            self.ops.push(Op::Save);
            self.ops.push(transform(t)?);
        }
        let at = |key| n.attribute(key).map_or(Some(0.0), |v| v.parse().ok());
        if let Some(color) = fill {
            self.ops.push(Op::Text {
                x: at("x")?,
                y: at("y")?,
                size: number(n, "font-size")?,
                color,
                runs,
                length,
                center,
            });
        }
        if transformed {
            self.ops.push(Op::Restore);
        }
        Some(())
    }

    fn font(&mut self, id: fontdb::ID) -> Option<u16> {
        if let Some(&index) = self.font_index.get(&id) {
            return Some(index);
        }
        let (source, index) = self.db.face_source(id)?;
        let path = match source {
            fontdb::Source::File(path) | fontdb::Source::SharedFile(path, _) => path,
            fontdb::Source::Binary(_) => return None,
        };
        self.fonts.push(Face {
            path: path.to_str()?.to_string(),
            index,
        });
        let font = (self.fonts.len() - 1) as u16;
        self.font_index.insert(id, font);
        Some(font)
    }
}

/// A process-wide table of results; the font database never changes once built.
type Memo<K, V> = Mutex<Option<HashMap<K, V>>>;

fn memo<K: Eq + std::hash::Hash, V: Clone>(
    table: &Memo<K, V>,
    key: K,
    compute: impl FnOnce() -> V,
) -> V {
    let lock = || table.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(value) = lock().get_or_insert_with(HashMap::new).get(&key) {
        return value.clone();
    }
    let value = compute();
    lock()
        .get_or_insert_with(HashMap::new)
        .insert(key, value.clone());
    value
}

/// usvg's default font selector: the families in order, then serif. Remembered per
/// specification, since each query scans every face.
fn pick(
    db: &fontdb::Database,
    families: &str,
    weight: u16,
    style: fontdb::Style,
) -> Option<fontdb::ID> {
    static PICKS: Memo<(String, u16, u8), Option<fontdb::ID>> = Mutex::new(None);
    memo(&PICKS, (families.to_string(), weight, style as u8), || {
        let parsed = svgtypes::parse_font_families(families).ok()?;
        let mut names: Vec<fontdb::Family> = parsed
            .iter()
            .map(|f| match f {
                FontFamily::Serif => fontdb::Family::Serif,
                FontFamily::SansSerif => fontdb::Family::SansSerif,
                FontFamily::Cursive => fontdb::Family::Cursive,
                FontFamily::Fantasy => fontdb::Family::Fantasy,
                FontFamily::Monospace => fontdb::Family::Monospace,
                FontFamily::Named(s) => fontdb::Family::Name(s),
            })
            .collect();
        names.push(fontdb::Family::Serif);
        db.query(&fontdb::Query {
            families: &names,
            weight: fontdb::Weight(weight),
            stretch: fontdb::Stretch::Normal,
            style,
        })
    })
}

/// The face each character is drawn with, following usvg's fallback: while a character is
/// missing, the first other face with the base face's style that has it is tried; a face
/// that has every character takes the whole text.
fn faces(db: &fontdb::Database, base: fontdb::ID, text: &str) -> Vec<(fontdb::ID, char)> {
    let mut glyphs: Vec<(fontdb::ID, char)> = text.chars().map(|c| (base, c)).collect();
    let mut used = vec![base];
    while let Some(&(_, c)) = glyphs.iter().find(|(id, c)| !has_char(db, *id, *c)) {
        let Some(fallback) = fallback(db, c, &used) else {
            break;
        };
        used.push(fallback);
        if text.chars().all(|c| has_char(db, fallback, c)) {
            return text.chars().map(|c| (fallback, c)).collect();
        }
        for glyph in &mut glyphs {
            if !has_char(db, glyph.0, glyph.1) && has_char(db, fallback, glyph.1) {
                glyph.0 = fallback;
            }
        }
    }
    glyphs
}

fn fallback(db: &fontdb::Database, c: char, used: &[fontdb::ID]) -> Option<fontdb::ID> {
    static FALLBACKS: Memo<(char, Vec<fontdb::ID>), Option<fontdb::ID>> = Mutex::new(None);
    memo(&FALLBACKS, (c, used.to_vec()), || {
        let base = db.face(used[0])?;
        db.faces()
            .filter(|face| !used.contains(&face.id))
            .filter(|face| {
                !(base.style != face.style
                    && base.weight != face.weight
                    && base.stretch != face.stretch)
            })
            .find(|face| has_char(db, face.id, c))
            .map(|face| face.id)
    })
}

fn has_char(db: &fontdb::Database, id: fontdb::ID, c: char) -> bool {
    static CHARS: Memo<(fontdb::ID, char), bool> = Mutex::new(None);
    memo(&CHARS, (id, c), || {
        db.with_face_data(id, |data, index| {
            ttf_parser::Face::parse(data, index)
                .ok()
                .and_then(|f| f.glyph_index(c))
                .is_some()
        })
        .unwrap_or(false)
    })
}

fn allowed(n: roxmltree::Node, keys: &[&str]) -> bool {
    n.attributes().all(|a| keys.contains(&a.name()))
}
fn number(n: roxmltree::Node, key: &str) -> Option<f64> {
    n.attribute(key)?
        .trim()
        .parse()
        .ok()
        .filter(|v: &f64| v.is_finite())
}
fn rect(n: roxmltree::Node) -> Option<[f64; 4]> {
    let at = |key| n.attribute(key).map_or(Some(0.0), |v| v.parse().ok());
    Some([
        at("x")?,
        at("y")?,
        number(n, "width")?,
        number(n, "height")?,
    ])
}
fn transform(text: &str) -> Option<Op> {
    let Transform { a, b, c, d, e, f } = text.parse().ok()?;
    Some(Op::Transform {
        m: [a, b, c, d, e, f],
    })
}
/// Fill (black by default), stroke (none by default) and stroke width (1 by default).
fn paint(n: roxmltree::Node) -> Option<(Option<u32>, Option<u32>, f64)> {
    fn color(text: Option<&str>, default: Option<u32>) -> Option<Option<u32>> {
        match text {
            None => Some(default),
            Some("none") => Some(None),
            Some(text) => {
                let hex = text.strip_prefix('#')?;
                (hex.len() == 6).then_some(())?;
                Some(Some(u32::from_str_radix(hex, 16).ok()?))
            }
        }
    }
    let width = match n.attribute("stroke-width") {
        Some(w) => w.parse().ok()?,
        None => 1.0,
    };
    Some((
        color(n.attribute("fill"), Some(0))?,
        color(n.attribute("stroke"), None)?,
        width,
    ))
}
