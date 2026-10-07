//! 한글 수식 스크립트와 LaTeX 사이의 변환. 둘 다 rhwp 수식 파서로 읽어(그 파서는 LaTeX
//! 명령도 읽는다) 같은 트리에서 한쪽 문법으로 쓴다.
use rhwp::renderer::equation::ast::{EqNode, MatrixStyle, PileAlign, SpaceKind};
use rhwp::renderer::equation::parser::parse;
use rhwp::renderer::equation::symbols::{DecoKind, FontStyleKind};

/// A 한글 equation script as LaTeX.
pub fn to_latex(script: &str) -> String {
    latex(&parse(script))
}

/// LaTeX as a 한글 equation script.
pub fn from_latex(latex: &str) -> String {
    hwp(&parse(&rewrite_latex(latex)))
}

/// Symbols: the character, its 한글 keyword and its LaTeX command (without `\`; empty when
/// LaTeX has none and the character goes in `\text`).
const SYMBOLS: &[(&str, &str, &str)] = &[
    ("α", "alpha", "alpha"),
    ("β", "beta", "beta"),
    ("γ", "gamma", "gamma"),
    ("δ", "delta", "delta"),
    ("ε", "epsilon", "epsilon"),
    ("ζ", "zeta", "zeta"),
    ("η", "eta", "eta"),
    ("θ", "theta", "theta"),
    ("ϑ", "vartheta", "vartheta"),
    ("ι", "iota", "iota"),
    ("κ", "kappa", "kappa"),
    ("λ", "lambda", "lambda"),
    ("μ", "mu", "mu"),
    ("ν", "nu", "nu"),
    ("ξ", "xi", "xi"),
    ("ο", "omicron", ""),
    ("π", "pi", "pi"),
    ("ϖ", "varpi", "varpi"),
    ("ρ", "rho", "rho"),
    ("σ", "sigma", "sigma"),
    ("ς", "varsigma", "varsigma"),
    ("τ", "tau", "tau"),
    ("υ", "upsilon", "upsilon"),
    ("φ", "phi", "phi"),
    ("χ", "chi", "chi"),
    ("ψ", "psi", "psi"),
    ("ω", "omega", "omega"),
    ("Γ", "Gamma", "Gamma"),
    ("Δ", "Delta", "Delta"),
    ("Θ", "Theta", "Theta"),
    ("Λ", "Lambda", "Lambda"),
    ("Ξ", "Xi", "Xi"),
    ("Π", "Pi", "Pi"),
    ("Σ", "Sigma", "Sigma"),
    ("Υ", "Upsilon", "Upsilon"),
    ("Φ", "Phi", "Phi"),
    ("Ψ", "Psi", "Psi"),
    ("Ω", "Omega", "Omega"),
    ("∞", "INF", "infty"),
    ("ℵ", "ALEPH", "aleph"),
    ("ℏ", "HBAR", "hbar"),
    ("ı", "IMATH", "imath"),
    ("ȷ", "JMATH", "jmath"),
    ("ℓ", "ELL", "ell"),
    ("℘", "WP", "wp"),
    ("ℑ", "IMAG", "Im"),
    ("ℜ", "REIMAGE", "Re"),
    ("⋯", "CDOTS", "cdots"),
    ("…", "LDOTS", "ldots"),
    ("⋮", "VDOTS", "vdots"),
    ("⋱", "DDOTS", "ddots"),
    ("△", "TRIANGLE", "triangle"),
    ("∠", "ANGLE", "angle"),
    ("⊥", "BOT", "perp"),
    ("⊤", "TOP", "top"),
    ("°", "DEG", ""),
    ("′", "prime", "prime"),
    ("♯", "WELL", "sharp"),
    ("×", "TIMES", "times"),
    ("÷", "DIV", "div"),
    ("±", "PLUSMINUS", "pm"),
    ("∓", "MINUSPLUS", "mp"),
    ("·", "CDOT", "cdot"),
    ("∘", "CIRC", "circ"),
    ("•", "BULLET", "bullet"),
    ("∗", "AST", "ast"),
    ("★", "STAR", "star"),
    ("≠", "NEQ", "neq"),
    ("≤", "LEQ", "leq"),
    ("≥", "GEQ", "geq"),
    ("≪", "ll", "ll"),
    ("≫", "gg", "gg"),
    ("≈", "APPROX", "approx"),
    ("∼", "SIM", "sim"),
    ("≃", "SIMEQ", "simeq"),
    ("≅", "CONG", "cong"),
    ("≡", "EQUIV", "equiv"),
    ("≍", "ASYMP", "asymp"),
    ("≐", "DOTEQ", "doteq"),
    ("∝", "PROPTO", "propto"),
    ("∪", "UNION", "cup"),
    ("∩", "INTER", "cap"),
    ("⊂", "SUBSET", "subset"),
    ("⊃", "SUPERSET", "supset"),
    ("⊆", "SUBSETEQ", "subseteq"),
    ("⊇", "SUPSETEQ", "supseteq"),
    ("⊏", "SQSUBSET", "sqsubset"),
    ("⊐", "SQSUPSET", "sqsupset"),
    ("⊑", "SQSUBSETEQ", "sqsubseteq"),
    ("⊒", "SQSUPSETEQ", "sqsupseteq"),
    ("∈", "IN", "in"),
    ("∉", "NOTIN", "notin"),
    ("∋", "OWNS", "ni"),
    ("≺", "PREC", "prec"),
    ("≻", "SUCC", "succ"),
    ("∀", "FORALL", "forall"),
    ("∃", "EXIST", "exists"),
    ("∄", "nexists", "nexists"),
    ("¬", "LNOT", "neg"),
    ("∧", "WEDGE", "wedge"),
    ("∨", "VEE", "vee"),
    ("∂", "PARTIAL", "partial"),
    ("∅", "EMPTYSET", "emptyset"),
    ("∴", "THEREFORE", "therefore"),
    ("∵", "BECAUSE", "because"),
    ("⊢", "VDASH", "vdash"),
    ("⊣", "HLEFT", "dashv"),
    ("⊨", "MODELS", "models"),
    ("†", "DAGGER", "dagger"),
    ("‡", "DDAGGER", "ddagger"),
    ("○", "BIGCIRC", "bigcirc"),
    ("◇", "DIAMOND", "diamond"),
    ("∇", "nabla", "nabla"),
    ("⊕", "OPLUS", "oplus"),
    ("⊗", "OTIMES", "otimes"),
    ("⊙", "ODOT", "odot"),
    ("⊖", "OMINUS", "ominus"),
    ("⊘", "ODIV", "oslash"),
    ("⊔", "SQCUP", "sqcup"),
    ("⊓", "SQCAP", "sqcap"),
    ("⊎", "UPLUS", "uplus"),
    ("←", "larrow", "leftarrow"),
    ("→", "rarrow", "rightarrow"),
    ("↑", "uparrow", "uparrow"),
    ("↓", "downarrow", "downarrow"),
    ("↔", "lrarrow", "leftrightarrow"),
    ("↕", "udarrow", "updownarrow"),
    ("⇐", "LARROW", "Leftarrow"),
    ("⇒", "RARROW", "Rightarrow"),
    ("⇑", "UPARROW", "Uparrow"),
    ("⇓", "DOWNARROW", "Downarrow"),
    ("⇔", "LRARROW", "Leftrightarrow"),
    ("⇕", "UDARROW", "Updownarrow"),
    ("↖", "nwarrow", "nwarrow"),
    ("↗", "nearrow", "nearrow"),
    ("↙", "swarrow", "swarrow"),
    ("↘", "searrow", "searrow"),
    ("↦", "mapsto", "mapsto"),
    ("↩", "hookleft", "hookleftarrow"),
    ("↪", "hookright", "hookrightarrow"),
    ("⟶", "longrightarrow", "longrightarrow"),
    ("⟵", "longleftarrow", "longleftarrow"),
    ("⟹", "Longrightarrow", "Longrightarrow"),
    ("⟸", "Longleftarrow", "Longleftarrow"),
    ("‖", "VERT", "|"),
    ("⌈", "lceil", "lceil"),
    ("⌉", "rceil", "rceil"),
    ("⌊", "lfloor", "lfloor"),
    ("⌋", "rfloor", "rfloor"),
    ("⟨", "langle", "langle"),
    ("⟩", "rangle", "rangle"),
];

/// Big operators: the character, its 한글 keyword and its LaTeX command.
const BIG_OPERATORS: &[(&str, &str, &str)] = &[
    ("∑", "sum", "sum"),
    ("∏", "prod", "prod"),
    ("∐", "coprod", "coprod"),
    ("∪", "bigcup", "bigcup"),
    ("∩", "bigcap", "bigcap"),
    ("⊔", "BIGSQCUP", "bigsqcup"),
    ("⊎", "BIGUPLUS", "biguplus"),
    ("⋀", "BIGWEDGE", "bigwedge"),
    ("⋁", "BIGVEE", "bigvee"),
    ("⊕", "BIGOPLUS", "bigoplus"),
    ("⊗", "BIGOTIMES", "bigotimes"),
    ("⊙", "BIGODOT", "bigodot"),
    ("∫", "int", "int"),
    ("∬", "iint", "iint"),
    ("∭", "iiint", "iiint"),
    ("∮", "oint", "oint"),
];

/// LaTeX's named operators; any other function name goes in `\operatorname`.
const LATEX_FUNCTIONS: &[&str] = &[
    "arccos", "arcsin", "arctan", "arg", "cos", "cosh", "cot", "coth", "csc", "deg", "det", "dim",
    "exp", "gcd", "hom", "inf", "ker", "lg", "lim", "liminf", "limsup", "ln", "log", "max", "min",
    "Pr", "sec", "sin", "sinh", "sup", "tan", "tanh",
];

fn symbol(c: &str) -> Option<&'static (&'static str, &'static str, &'static str)> {
    SYMBOLS.iter().find(|s| s.0 == c)
}
fn big_operator(c: &str) -> Option<&'static (&'static str, &'static str, &'static str)> {
    BIG_OPERATORS.iter().find(|s| s.0 == c)
}
fn is_integral(node: &EqNode) -> bool {
    matches!(node, EqNode::MathSymbol(s) | EqNode::BigOp { symbol: s, sub: None, sup: None }
        if matches!(s.as_str(), "∫" | "∬" | "∭" | "∮"))
}
fn integral_symbol(node: &EqNode) -> &str {
    match node {
        EqNode::MathSymbol(s) | EqNode::BigOp { symbol: s, .. } => s,
        _ => "∫",
    }
}
/// rhwp reads `int from a to b` as the integral subscripted with `a^b`.
fn integral_bounds(node: &EqNode) -> Option<(&str, Option<&EqNode>, Option<&EqNode>)> {
    match node {
        EqNode::Subscript { base, sub } if is_integral(base) => match sub.as_ref() {
            EqNode::Superscript { base: from, sup } => {
                Some((integral_symbol(base), Some(from), Some(sup)))
            }
            sub => Some((integral_symbol(base), Some(sub), None)),
        },
        EqNode::Superscript { base, sup } if is_integral(base) => {
            Some((integral_symbol(base), None, Some(sup)))
        }
        EqNode::SubSup { base, sub, sup } if is_integral(base) => {
            Some((integral_symbol(base), Some(sub), Some(sup)))
        }
        _ => None,
    }
}

// ---- LaTeX ----

fn latex(node: &EqNode) -> String {
    if let Some((c, from, to)) = integral_bounds(node) {
        return big_latex(c, from, to);
    }
    match node {
        EqNode::Row(items) => latex_row(items),
        EqNode::Text(s) => latex_text(s),
        EqNode::Number(s) | EqNode::Symbol(s) | EqNode::MathSymbol(s) => latex_text(s),
        EqNode::Function(name) => {
            let name = name.replace(' ', "");
            if LATEX_FUNCTIONS.contains(&name.as_str()) {
                format!("\\{name}")
            } else {
                format!("\\operatorname{{{name}}}")
            }
        }
        EqNode::Fraction { numer, denom } => {
            format!("\\frac{{{}}}{{{}}}", latex(numer), latex(denom))
        }
        EqNode::Atop { top, bottom } => format!("{{{} \\atop {}}}", latex(top), latex(bottom)),
        EqNode::Sqrt { index: None, body } => format!("\\sqrt{{{}}}", latex(body)),
        EqNode::Sqrt {
            index: Some(i),
            body,
        } => format!("\\sqrt[{}]{{{}}}", latex(i), latex(body)),
        EqNode::Superscript { base, sup } => format!("{}^{{{}}}", latex_base(base), latex(sup)),
        EqNode::Subscript { base, sub } => format!("{}_{{{}}}", latex_base(base), latex(sub)),
        EqNode::SubSup { base, sub, sup } => {
            format!("{}_{{{}}}^{{{}}}", latex_base(base), latex(sub), latex(sup))
        }
        EqNode::BigOp { symbol, sub, sup } => big_latex(symbol, sub.as_deref(), sup.as_deref()),
        EqNode::UnderOver { base, under, over } => {
            let mut out = match base.as_ref() {
                EqNode::Function(name) => format!("\\operatorname*{{{name}}}"),
                base => format!("\\mathop{{{}}}\\limits", latex(base)),
            };
            if let Some(under) = under {
                out += &format!("_{{{}}}", latex(under));
            }
            if let Some(over) = over {
                out += &format!("^{{{}}}", latex(over));
            }
            out
        }
        EqNode::Limit { sub, .. } => match sub {
            Some(sub) => format!("\\lim_{{{}}}", latex(sub)),
            None => "\\lim".into(),
        },
        EqNode::Matrix { rows, style } => {
            let env = match style {
                MatrixStyle::Plain => "matrix",
                MatrixStyle::Paren => "pmatrix",
                MatrixStyle::Bracket => "bmatrix",
                MatrixStyle::Vert => "vmatrix",
            };
            let rows: Vec<String> = rows
                .iter()
                .map(|row| row.iter().map(latex).collect::<Vec<_>>().join(" & "))
                .collect();
            environment(env, &rows)
        }
        EqNode::Cases { rows } => environment("cases", &rows.iter().map(latex).collect::<Vec<_>>()),
        EqNode::Pile { rows, .. } => {
            environment("matrix", &rows.iter().map(latex).collect::<Vec<_>>())
        }
        EqNode::EqAlign { rows } => {
            let rows: Vec<String> = rows
                .iter()
                .map(|(l, r)| format!("{} & {}", latex(l), latex(r)))
                .collect();
            environment("aligned", &rows)
        }
        EqNode::Rel { arrow, over, under } => {
            let under = under
                .as_ref()
                .map_or(String::new(), |u| format!("[{}]", latex(u)));
            match arrow.as_str() {
                "→" => format!("\\xrightarrow{under}{{{}}}", latex(over)),
                "←" => format!("\\xleftarrow{under}{{{}}}", latex(over)),
                arrow => format!("\\overset{{{}}}{{{}}}", latex(over), latex_text(arrow)),
            }
        }
        EqNode::Paren { left, right, body } => {
            // An empty body is kept as `{}`, the place a palette's caret goes.
            let body = Some(latex(body))
                .filter(|b| !b.is_empty())
                .unwrap_or("{}".into());
            format!(
                "\\left{} {body} \\right{}",
                delimiter(left),
                delimiter(right)
            )
        }
        EqNode::Decoration { kind, body } => {
            let wide = !is_atom(body);
            let command = match kind {
                DecoKind::Hat if wide => "widehat",
                DecoKind::Hat => "hat",
                DecoKind::Check => "check",
                DecoKind::Tilde if wide => "widetilde",
                DecoKind::Tilde => "tilde",
                DecoKind::Acute => "acute",
                DecoKind::Grave => "grave",
                DecoKind::Dot => "dot",
                DecoKind::DDot => "ddot",
                DecoKind::Bar if wide => "overline",
                DecoKind::Bar => "bar",
                DecoKind::Vec if wide => "overrightarrow",
                DecoKind::Vec => "vec",
                DecoKind::Dyad => "overleftrightarrow",
                DecoKind::Arch => "overbrace",
                DecoKind::Under | DecoKind::Underline => "underline",
                DecoKind::Overline => "overline",
                DecoKind::StrikeThrough => return format!("\\not {}", latex(body)),
            };
            format!("\\{command}{{{}}}", latex(body))
        }
        EqNode::FontStyle { style, body } => {
            let command = match style {
                FontStyleKind::Roman => "mathrm",
                FontStyleKind::Italic => "mathit",
                FontStyleKind::Bold => "mathbf",
                FontStyleKind::Blackboard => "mathbb",
                FontStyleKind::Calligraphy => "mathcal",
                FontStyleKind::Fraktur => "mathfrak",
                FontStyleKind::SansSerif => "mathsf",
                FontStyleKind::Monospace => "mathtt",
            };
            format!("\\{command}{{{}}}", latex(body))
        }
        EqNode::Color { r, g, b, body } => {
            format!("\\textcolor{{#{r:02x}{g:02x}{b:02x}}}{{{}}}", latex(body))
        }
        EqNode::Space(SpaceKind::Normal) => "\\ ".into(),
        EqNode::Space(SpaceKind::Thin) => "\\,".into(),
        EqNode::Space(SpaceKind::Tab) => " & ".into(),
        EqNode::Newline => "\\\\".into(),
        EqNode::Quoted(s) => format!("\\text{{{}}}", escape_text(s)),
        EqNode::Empty => String::new(),
    }
}

fn big_latex(c: &str, sub: Option<&EqNode>, sup: Option<&EqNode>) -> String {
    let mut out = match big_operator(c) {
        Some(op) => format!("\\{}", op.2),
        None => latex_text(c),
    };
    if let Some(sub) = sub {
        out += &format!("_{{{}}}", latex(sub));
    }
    if let Some(sup) = sup {
        out += &format!("^{{{}}}", latex(sup));
    }
    out
}

fn environment(env: &str, rows: &[String]) -> String {
    format!("\\begin{{{env}}} {} \\end{{{env}}}", rows.join(" \\\\ "))
}

fn delimiter(d: &str) -> String {
    match d {
        "" => ".".into(),
        "{" => "\\{".into(),
        "}" => "\\}".into(),
        "(" | ")" | "[" | "]" | "|" | "/" => d.into(),
        d => symbol(d).map_or(".".into(), |s| format!("\\{}", s.2)),
    }
}

fn is_atom(node: &EqNode) -> bool {
    match node {
        EqNode::Text(s) | EqNode::Number(s) | EqNode::Symbol(s) | EqNode::MathSymbol(s) => {
            s.chars().count() == 1
        }
        _ => false,
    }
}

/// A script's base, braced unless it is one character or a command.
fn latex_base(node: &EqNode) -> String {
    let s = latex(node);
    if is_atom(node) || matches!(node, EqNode::Paren { .. } | EqNode::Function(_)) {
        s
    } else {
        format!("{{{s}}}")
    }
}

/// Characters as LaTeX math: symbols by their commands, characters LaTeX has no command
/// for in `\text`, spaces by their width.
fn latex_text(s: &str) -> String {
    match s {
        "\u{2009}" => return "\\,".into(),
        "\u{205F}" => return "\\:".into(),
        "\u{2004}" | "\u{2002}" => return "\\;".into(),
        "\u{2003}" => return "\\quad".into(),
        "\u{2003}\u{2003}" => return "\\qquad".into(),
        _ => {}
    }
    let mut out = String::new();
    let mut text = String::new();
    for c in s.chars() {
        let known = symbol(c.encode_utf8(&mut [0; 4])).filter(|s| !s.2.is_empty());
        if c.is_ascii() || known.is_some() {
            if !text.is_empty() {
                out += &format!("\\text{{{}}}", escape_text(&std::mem::take(&mut text)));
            }
        }
        match (c, known) {
            (_, Some(s)) => {
                out += &format!("\\{}", s.2);
            }
            ('%' | '#' | '&' | '$' | '_' | '{' | '}', _) => {
                out.push('\\');
                out.push(c);
            }
            ('−', _) => out.push('-'),
            ('\\', _) => out += "\\backslash",
            ('~', _) => out += "\\sim",
            ('^', _) => out += "\\wedge",
            _ if c.is_ascii() => out.push(c),
            _ => text.push(c),
        }
        if known.is_some() && s.chars().count() > 1 {
            out.push(' ');
        }
    }
    if !text.is_empty() {
        out += &format!("\\text{{{}}}", escape_text(&text));
    }
    out.trim_end().to_string()
}

fn escape_text(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '%' | '#' | '&' | '$' | '_' | '{' | '}' => vec!['\\', c],
            c => vec![c],
        })
        .collect()
}

/// Items apart only where LaTeX needs it: after a command word, or between two letters.
fn latex_row(items: &[EqNode]) -> String {
    let mut out = String::new();
    for item in items {
        let s = latex(item);
        if s.is_empty() {
            continue;
        }
        let ends_command = {
            let word = out.trim_end_matches(|c: char| c.is_ascii_alphabetic());
            word.len() < out.len() && word.ends_with('\\') && !word.ends_with("\\\\")
        };
        let letters = out.ends_with(|c: char| c.is_ascii_alphanumeric() || c == '}' || c == ')')
            && s.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '\\');
        if !out.is_empty()
            && (ends_command && s.starts_with(|c: char| c.is_ascii_alphanumeric()) || letters)
        {
            out.push(' ');
        }
        out += &s;
    }
    out
}

// ---- 한글 ----

fn hwp(node: &EqNode) -> String {
    if let Some((c, from, to)) = integral_bounds(node) {
        return big_hwp(c, from, to);
    }
    match node {
        EqNode::Row(items) => items
            .iter()
            .map(hwp)
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" "),
        EqNode::Text(s) | EqNode::Number(s) | EqNode::Symbol(s) | EqNode::MathSymbol(s) => {
            hwp_text(s)
        }
        EqNode::Function(name) => name.replace(' ', ""),
        EqNode::Fraction { numer, denom } => format!("{{{}}} over {{{}}}", hwp(numer), hwp(denom)),
        EqNode::Atop { top, bottom } => format!("{{{}}} atop {{{}}}", hwp(top), hwp(bottom)),
        EqNode::Sqrt { index: None, body } => format!("sqrt {{{}}}", hwp(body)),
        EqNode::Sqrt {
            index: Some(i),
            body,
        } => format!("root {{{}}} of {{{}}}", hwp(i), hwp(body)),
        EqNode::Superscript { base, sup } => format!("{}^{{{}}}", hwp_base(base), hwp(sup)),
        EqNode::Subscript { base, sub } => format!("{}_{{{}}}", hwp_base(base), hwp(sub)),
        EqNode::SubSup { base, sub, sup } => {
            format!("{}_{{{}}}^{{{}}}", hwp_base(base), hwp(sub), hwp(sup))
        }
        EqNode::BigOp { symbol, sub, sup } => big_hwp(symbol, sub.as_deref(), sup.as_deref()),
        EqNode::UnderOver { base, under, over } => {
            let mut out = format!("UNDEROVER {{{}}}", hwp(base));
            if let Some(under) = under {
                out += &format!("_{{{}}}", hwp(under));
            }
            if let Some(over) = over {
                out += &format!("^{{{}}}", hwp(over));
            }
            out
        }
        EqNode::Limit { is_upper, sub } => {
            let name = if *is_upper { "Lim" } else { "lim" };
            match sub {
                Some(sub) => format!("{name} from {{{}}}", hwp(sub)),
                None => name.into(),
            }
        }
        EqNode::Matrix { rows, style } => {
            let name = match style {
                MatrixStyle::Plain => "matrix",
                MatrixStyle::Paren => "pmatrix",
                MatrixStyle::Bracket => "bmatrix",
                MatrixStyle::Vert => "dmatrix",
            };
            let rows: Vec<String> = rows
                .iter()
                .map(|row| row.iter().map(hwp).collect::<Vec<_>>().join(" & "))
                .collect();
            format!("{name}{{{}}}", rows.join(" # "))
        }
        EqNode::Cases { rows } => format!(
            "cases{{{}}}",
            rows.iter().map(hwp).collect::<Vec<_>>().join(" # ")
        ),
        EqNode::Pile { rows, align } => {
            let name = match align {
                PileAlign::Center => "pile",
                PileAlign::Left => "lpile",
                PileAlign::Right => "rpile",
            };
            format!(
                "{name}{{{}}}",
                rows.iter().map(hwp).collect::<Vec<_>>().join(" # ")
            )
        }
        EqNode::EqAlign { rows } => {
            let rows: Vec<String> = rows
                .iter()
                .map(|(l, r)| format!("{} & {}", hwp(l), hwp(r)))
                .collect();
            format!("eqalign{{{}}}", rows.join(" # "))
        }
        EqNode::Rel { arrow, over, under } => match under {
            Some(under) => format!(
                "REL {} {{{}}} {{{}}}",
                hwp_text(arrow),
                hwp(over),
                hwp(under)
            ),
            None => format!("BUILDREL {} {{{}}}", hwp_text(arrow), hwp(over)),
        },
        EqNode::Paren { left, right, body } => {
            let side = |d: &str| match d {
                "" => ".".to_string(),
                "{" => "lbrace".into(),
                "}" => "rbrace".into(),
                d => hwp_text(d),
            };
            format!("left {} {} right {}", side(left), hwp(body), side(right))
        }
        EqNode::Decoration { kind, body } => {
            let name = match kind {
                DecoKind::Hat => "hat",
                DecoKind::Check => "check",
                DecoKind::Tilde => "tilde",
                DecoKind::Acute => "acute",
                DecoKind::Grave => "grave",
                DecoKind::Dot => "dot",
                DecoKind::DDot => "ddot",
                DecoKind::Bar => "bar",
                DecoKind::Vec => "vec",
                DecoKind::Dyad => "dyad",
                DecoKind::Under => "under",
                DecoKind::Arch => "arch",
                DecoKind::Underline => "underline",
                DecoKind::Overline => "overline",
                DecoKind::StrikeThrough => "not",
            };
            format!("{name} {{{}}}", hwp(body))
        }
        EqNode::FontStyle { style, body } => match style {
            FontStyleKind::Roman => format!("rm {{{}}}", hwp(body)),
            FontStyleKind::Italic => format!("it {{{}}}", hwp(body)),
            FontStyleKind::Bold => format!("bold {{{}}}", hwp(body)),
            _ => hwp(body),
        },
        EqNode::Color { r, g, b, body } => format!("COLOR{{{r},{g},{b}}}{{{}}}", hwp(body)),
        EqNode::Space(SpaceKind::Normal) => "~".into(),
        EqNode::Space(SpaceKind::Thin) => "`".into(),
        EqNode::Space(SpaceKind::Tab) => "&".into(),
        EqNode::Newline => "#".into(),
        EqNode::Quoted(s) => format!("\"{s}\""),
        EqNode::Empty => String::new(),
    }
}

fn big_hwp(c: &str, sub: Option<&EqNode>, sup: Option<&EqNode>) -> String {
    let mut out = big_operator(c).map_or_else(|| hwp_text(c), |op| op.1.to_string());
    match (sub, sup) {
        (Some(sub), Some(sup)) => out += &format!(" from {{{}}} to {{{}}}", hwp(sub), hwp(sup)),
        (Some(sub), None) => out += &format!(" from {{{}}}", hwp(sub)),
        (None, Some(sup)) => out += &format!("^{{{}}}", hwp(sup)),
        (None, None) => {}
    }
    out
}

fn hwp_base(node: &EqNode) -> String {
    let s = hwp(node);
    if matches!(
        node,
        EqNode::Row(_) | EqNode::Fraction { .. } | EqNode::Atop { .. }
    ) {
        format!("{{{s}}}")
    } else {
        s
    }
}

/// Characters as script: symbols by their keywords, spaces by `~` and `` ` ``.
fn hwp_text(s: &str) -> String {
    match s {
        "\u{2009}" | "\u{205F}" => return "`".into(),
        "\u{2004}" | "\u{2002}" | "\u{2003}" => return "~".into(),
        "\u{2003}\u{2003}" => return "~~".into(),
        _ => {}
    }
    if let Some(s) = symbol(s) {
        return s.1.into();
    }
    if s == "−" {
        return "-".into();
    }
    if s.chars().count() > 1
        && s.chars()
            .any(|c| symbol(c.encode_utf8(&mut [0; 4])).is_some())
    {
        return s
            .chars()
            .map(|c| hwp_text(c.encode_utf8(&mut [0; 4])))
            .collect::<Vec<_>>()
            .join(" ");
    }
    s.into()
}

/// LaTeX the equation parser does not read, put as script it does: escaped braces,
/// spaces, colors, `\text` and extensible arrows.
fn rewrite_latex(src: &str) -> String {
    let chars: Vec<char> = src.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    // The braced group starting at `at`, and the index after it.
    let group = |at: usize| -> Option<(String, usize)> {
        let mut j = at;
        while chars.get(j)?.is_whitespace() {
            j += 1;
        }
        if chars[j] != '{' {
            return None;
        }
        let (mut depth, start) = (0, j + 1);
        while j < chars.len() {
            match chars[j] {
                '\\' => j += 1,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some((chars[start..j].iter().collect(), j + 1));
                    }
                }
                _ => {}
            }
            j += 1;
        }
        None
    };
    while i < chars.len() {
        if chars[i] != '\\' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        let start = i + 1;
        let mut end = start;
        while end < chars.len() && chars[end].is_ascii_alphabetic() {
            end += 1;
        }
        let name: String = chars[start..end].iter().collect();
        if name.is_empty() {
            match chars.get(start) {
                Some('{') => out += " lbrace ",
                Some('}') => out += " rbrace ",
                Some(' ') => out += " ~ ",
                Some('|') => out += " VERT ",
                Some(&c @ ('%' | '#' | '&' | '$' | '_')) => out.push(c),
                Some(&c) => {
                    out.push('\\');
                    out.push(c);
                }
                None => {}
            }
            i = start + 1;
            continue;
        }
        i = end;
        match name.as_str() {
            "limits" | "nolimits" | "displaystyle" | "textstyle" => {}
            "text" | "mbox" => {
                if let Some((text, next)) = group(i) {
                    out += &format!(" \"{}\" ", text.replace(['\\', '"'], ""));
                    i = next;
                }
            }
            "color" | "textcolor" => {
                if let Some((color, next)) = group(i) {
                    let rgb = match color.trim().to_ascii_lowercase().as_str() {
                        c if c.starts_with('#') && c.len() == 7 => {
                            u32::from_str_radix(&c[1..], 16).ok()
                        }
                        "black" => Some(0),
                        "white" => Some(0xffffff),
                        "red" => Some(0xff0000),
                        "green" => Some(0x00ff00),
                        "blue" => Some(0x0000ff),
                        _ => None,
                    };
                    if let Some(rgb) = rgb {
                        out += &format!(" COLOR{{{},{},{}}}", rgb >> 16, rgb >> 8 & 255, rgb & 255);
                    }
                    i = next;
                }
            }
            "xrightarrow" | "xleftarrow" => {
                let arrow = if name == "xrightarrow" {
                    "rarrow"
                } else {
                    "larrow"
                };
                let mut under = None;
                let mut j = i;
                while chars.get(j).is_some_and(|c| c.is_whitespace()) {
                    j += 1;
                }
                if chars.get(j) == Some(&'[') {
                    let close = chars[j..].iter().position(|&c| c == ']').map(|p| j + p);
                    if let Some(close) = close {
                        under = Some(rewrite_latex(
                            &chars[j + 1..close].iter().collect::<String>(),
                        ));
                        i = close + 1;
                    }
                }
                let (over, next) = group(i).unwrap_or_default();
                if next > 0 {
                    i = next;
                }
                let over = rewrite_latex(&over);
                out += &match under {
                    Some(under) => format!(" REL {arrow} {{{over}}} {{{under}}} "),
                    None => format!(" BUILDREL {arrow} {{{over}}} "),
                };
            }
            _ => {
                out.push('\\');
                out += &name;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn script_to_latex() {
        for (script, expected) in [
            ("a over b", "\\frac{a}{b}"),
            ("sum from {i=1} to n i^2", "\\sum_{i=1}^{n} i^{2}"),
            ("int from a to b f(x) dx", "\\int_{a}^{b} f(x) dx"),
            ("lim from {x rarrow 0} f", "\\lim_{x \\rightarrow 0} f"),
            ("left ( a right )", "\\left( a \\right)"),
            (
                "pmatrix{a & b # c & d}",
                "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
            ),
            ("root {3} of {x}", "\\sqrt[3]{x}"),
            ("x LEQ y TIMES z", "x \\leq y \\times z"),
            ("-b - 4", "-b-4"),
            ("alpha beta", "\\alpha \\beta"),
            ("\"넓이\" = 3", "\\text{넓이}=3"),
            ("REL rarrow {a} {b}", "\\xrightarrow[b]{a}"),
            ("COLOR{255,0,0}{x}", "\\textcolor{#ff0000}{x}"),
            (
                "cases{a & x>0 # b & x<0}",
                "\\begin{cases} a & x>0 \\\\ b & x<0 \\end{cases}",
            ),
            ("left lbrace a right .", "\\left\\{ a \\right."),
            ("{} over {}", "\\frac{}{}"),
            ("int from {} to {}", "\\int_{}^{}"),
            ("rm sin x", "\\mathrm{\\sin} x"),
            ("left ( {} right )", "\\left( {} \\right)"),
        ] {
            assert_eq!(to_latex(script), expected, "{script}");
        }
    }

    #[test]
    fn latex_to_script() {
        for (latex, expected) in [
            ("\\frac{a}{b}", "{a} over {b}"),
            ("\\sum_{i=1}^{n} i^2", "sum from {i = 1} to {n} i^{2}"),
            ("\\int_a^b f(x)\\,dx", "int from {a} to {b} f ( x ) ` dx"),
            ("\\left\\{ x \\right.", "left lbrace x right ."),
            ("\\text{넓이 } = 3", "\"넓이 \" = 3"),
            ("\\textcolor{#ff0000}{x}", "COLOR{255,0,0}{x}"),
            ("\\xrightarrow[b]{a}", "REL rarrow {a} {b}"),
            (
                "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
                "pmatrix{a & b # c & d}",
            ),
            ("\\alpha \\leq \\infty", "alpha LEQ INF"),
            ("\\sqrt[3]{x}", "root {3} of {x}"),
        ] {
            assert_eq!(from_latex(latex), expected, "{latex}");
        }
    }

    /// Script → LaTeX → script reads the same.
    #[test]
    fn round_trip() {
        for script in [
            "{a} over {b}",
            "sum from {i = 1} to {n} i^{2}",
            "left ( a right )",
            "x LEQ y TIMES z",
            "pmatrix{a & b # c & d}",
            "COLOR{255,0,0}{x}",
            "hat {a} + vec {v}",
            "\"넓이\" = 3",
            "REL rarrow {a} {b}",
        ] {
            assert_eq!(
                parse(&from_latex(&to_latex(script))),
                parse(script),
                "{script}"
            );
        }
    }
}
