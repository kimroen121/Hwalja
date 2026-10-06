import AppKit
import SwiftUI

// 수식: Hancom's equation script with its template and symbol palettes, and a
// preview drawn by the same renderer as the page.

/// The equation 수식 is showing: a new one, or `object` being changed.
struct EquationEdit: Identifiable {
    let id = UUID()
    var object: ObjectRef?
    var script: String
    /// Points.
    var fontSize: Double
    /// 0x00bbggrr.
    var color: UInt32
}

extension Viewer {

    /// Opens 수식 for a new equation in the caret's text size.
    func newEquation() {
        equation = EquationEdit(script: "", fontSize: document?.format?.text.size ?? 10, color: 0)
    }
    /// Inserts the edited equation, or changes the one it came from.
    func commit(_ edit: EquationEdit) {
        let size = UInt32((min(max(edit.fontSize, 1), 127) * 100).rounded())
        if let object = edit.object {
            setObject(object, ObjectProps(script: edit.script, fontSize: size, color: edit.color))
        } else {
            document?.edit(undoManager) { selection in
                selection.map { .insertEquation($0.ordered.start, script: edit.script, fontSize: size, color: edit.color) }
            }
        }
    }
}

/// A palette entry: what it shows and the script it puts at the caret (also its help).
/// `{}` marks the places to fill; the caret lands in the first.
struct EquationItem: Hashable {
    let sample: String
    let script: String
}

/// The palettes, in the order of 한글's 수식 편집 tool rows.
enum EquationPalette {
    /// The first row: templates, each with the sample its button shows. A palette of one
    /// item is a plain button.
    static let templates: [(face: String, items: [EquationItem])] = [
        ("{x}^{2}", [
            EquationItem(sample: "{x}^{2}", script: "{}^{}"),
            EquationItem(sample: "{x}_{1}", script: "{}_{}"),
            EquationItem(sample: "{x}_{1}^{2}", script: "{}_{}^{}"),
        ]),
        ("bar a", ["bar", "vec", "hat", "tilde", "dot", "ddot", "acute", "grave", "check", "arch", "dyad", "under"].map {
            EquationItem(sample: "\($0) a", script: "\($0) {}")
        }),
        ("{a} over {b}", [EquationItem(sample: "{a} over {b}", script: "{} over {}")]),
        ("sqrt {x}", [EquationItem(sample: "sqrt {x}", script: "sqrt {}")]),
        ("sum", ["sum", "prod", "coprod", "bigcup", "bigcap"].map {
            EquationItem(sample: "\($0) from {i} to {n}", script: "\($0) from {} to {}")
        }),
        ("int", [
            EquationItem(sample: "int from {a} to {b}", script: "int from {} to {}"),
            EquationItem(sample: "iint", script: "iint "),
            EquationItem(sample: "iiint", script: "iiint "),
            EquationItem(sample: "oint", script: "oint "),
        ]),
        ("lim", [
            EquationItem(sample: "lim from {x rarrow 0}", script: "lim from {}"),
            EquationItem(sample: "Lim from {n rarrow INF}", script: "Lim from {}"),
        ]),
        ("left ( a right )", [("(", ")"), ("[", "]"), ("lbrace", "rbrace"), ("|", "|"), ("langle", "rangle"), ("lceil", "rceil"),
                 ("lfloor", "rfloor")].map {
            EquationItem(sample: "left \($0.0) a right \($0.1)", script: "left \($0.0) {} right \($0.1)")
        }),
        ("cases{a # b}", [EquationItem(sample: "cases{x & x>0 # -x & x<0}", script: "cases{ & # & }")]),
        ("pile{a # b}", [EquationItem(sample: "pile{a # bb}", script: "pile{ # }")]),
        ("matrix{a & b # c & d}", ["matrix", "pmatrix", "bmatrix", "dmatrix"].map {
            EquationItem(sample: "\($0){a & b # c & d}", script: "\($0){ & # & }")
        }),
    ]
    /// 칸 맞춤 and 줄 바꿈, after the templates: what each shows and puts.
    static let marks: [(face: String, script: String)] = [("&", "&"), ("↵", "#")]

    /// The second row: symbol groups, each with the glyph its button shows.
    static let symbols: [(face: String, items: [EquationItem])] = [
        ("Λ", group("Alpha Α Beta Β Gamma Γ Delta Δ Epsilon Ε Zeta Ζ Eta Η Theta Θ Iota Ι Kappa Κ Lambda Λ Mu Μ Nu Ν Xi Ξ Omicron Ο Pi Π Rho Ρ Sigma Σ Tau Τ Upsilon Υ Phi Φ Chi Χ Psi Ψ Omega Ω")),
        ("λ", group("alpha α beta β gamma γ delta δ epsilon ε zeta ζ eta η theta θ iota ι kappa κ lambda λ mu μ nu ν xi ξ omicron ο pi π rho ρ sigma σ tau τ upsilon υ phi φ chi χ psi ψ omega ω")),
        ("ℵ", group("vartheta ϑ varpi ϖ varsigma ς varupsilon ϒ varphi φ varepsilon ε ALEPH ℵ HBAR ℏ IMATH ı JMATH ȷ ELL ℓ WP ℘ IMAG ℑ REIMAGE ℜ ANGSTROM Å OHM Ω")),
        ("≤", group("NEQ ≠ LEQ ≤ GEQ ≥ ll ≪ gg ≫ APPROX ≈ SIM ∼ SIMEQ ≃ CONG ≅ EQUIV ≡ PROPTO ∝ SUBSET ⊂ SUPERSET ⊃ SUBSETEQ ⊆ SUPSETEQ ⊇ IN ∈ NOTIN ∉ OWNS ∋ VDASH ⊢ MODELS ⊨")),
        ("±", group("PLUSMINUS ± MINUSPLUS ∓ TIMES × DIV ÷ CDOT · CIRC ∘ BULLET • INTER ∩ UNION ∪ SQCAP ⊓ SQCUP ⊔ OPLUS ⊕ OMINUS ⊖ OTIMES ⊗ ODOT ⊙ UPLUS ⊎ WEDGE ∧ VEE ∨ LNOT ¬ FORALL ∀ EXIST ∃")),
        ("⇔", group("larrow ← rarrow → uparrow ↑ downarrow ↓ lrarrow ↔ udarrow ↕ LARROW ⇐ RARROW ⇒ UPARROW ⇑ DOWNARROW ⇓ LRARROW ⇔ UDARROW ⇕ nwarrow ↖ nearrow ↗ swarrow ↙ searrow ↘ mapsto ↦ hookleft ↩ hookright ↪")),
        ("Δ", group("INF ∞ DEG ° prime ′ PARTIAL ∂ nabla ∇ THEREFORE ∴ BECAUSE ∵ EMPTYSET ∅ ANGLE ∠ TRIANGLE △ BOT ⊥ TOP ⊤ CDOTS ⋯ LDOTS … VDOTS ⋮ DDOTS ⋱ DAGGER † DDAGGER ‡ CENTIGRADE ℃ FAHRENHEIT ℉ HUND ‰ THOU ‱ LAPLACE ℒ STAR ★ BIGCIRC ○ DIAMOND ◇")),
    ]

    /// "keyword glyph keyword glyph …" as items that show the glyph and put the keyword.
    private static func group(_ pairs: String) -> [EquationItem] {
        let words = pairs.split(separator: " ").map(String.init)
        return stride(from: 0, to: words.count - 1, by: 2).map {
            EquationItem(sample: words[$0 + 1], script: words[$0])
        }
    }
}

/// Lays out scripts with the engine's equation renderer. Palette samples are kept for
/// every window; the live preview is not.
@MainActor
final class EquationRenderer {
    private static var samples: [String: PageDisplay] = [:]
    private weak var document: HwpDocument?
    init(document: HwpDocument?) { self.document = document }

    func display(_ script: String, size: UInt32 = 1000, color: UInt32 = 0, keep: Bool = false) async -> PageDisplay? {
        let key = "\(size) \(color) \(script)"
        if let display = Self.samples[key] { return display }
        guard let display = try? await document?.equationPreview(script, fontSize: size, color: color) else { return nil }
        if keep { Self.samples[key] = display }
        return display
    }
}

/// A rendered equation at its size, scaled by `zoom`.
struct EquationGlyph: View {
    let display: PageDisplay?
    var zoom = 1.0
    /// Draws in the text color instead of the equation's own, for palette buttons.
    var tinted = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let scale = PageGeometry.pointsPerPixel * zoom
        let tint = scheme == .dark ? CGColor.white : CGColor.black
        Canvas { context, size in
            guard let display else { return }
            context.withCGContext { cg in
                if tinted { cg.beginTransparencyLayer(auxiliaryInfo: nil) }
                cg.saveGState()
                cg.scaleBy(x: scale, y: scale)
                display.draw(in: cg)
                cg.restoreGState()
                if tinted {
                    cg.setBlendMode(.sourceIn)
                    cg.setFillColor(tint)
                    cg.fill(CGRect(origin: .zero, size: size))
                    cg.endTransparencyLayer()
                }
            }
        }
        .frame(width: (display?.width ?? 0) * scale, height: (display?.height ?? 0) * scale)
    }
}

/// A palette sample, rendered once and kept.
private struct Sample: View {
    let script: String
    let renderer: EquationRenderer
    var zoom = 1.0
    @State private var display: PageDisplay?
    var body: some View {
        EquationGlyph(display: display, zoom: zoom, tinted: true)
            .task(id: script) { display = await renderer.display(script, keep: true) }
    }
}

/// A palette's samples, opened from its button. Each column is as wide as its widest
/// sample, so the cells hug what they show.
struct PaletteGrid: View {
    let items: [EquationItem]
    let renderer: EquationRenderer
    let symbols: Bool
    let pick: (EquationItem) -> Void

    var body: some View {
        let columns = symbols ? 10 : min(4, items.count)
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)], id: \.self) { item in
                        Button { pick(item) } label: {
                            PaletteFace(item: item, renderer: renderer, symbols: symbols)
                                .fixedSize()
                                .padding(.horizontal, symbols ? 4 : 6)
                                .padding(.vertical, symbols ? 2 : 4)
                                .frame(minWidth: symbols ? 22 : 30, minHeight: symbols ? 22 : 30)
                        }
                        .buttonStyle(ToolButtonStyle())
                        .help(item.script)
                    }
                }
            }
        }
        .padding(5)
    }
}

/// A sample: a symbol's glyph as text, a template rendered.
private struct PaletteFace: View {
    let item: EquationItem
    let renderer: EquationRenderer
    let symbols: Bool
    var body: some View {
        if symbols {
            SymbolGlyph(item.sample)
        } else {
            Sample(script: item.sample, renderer: renderer, zoom: 1.1)
        }
    }
}

/// A symbol as text, in a math face so that every symbol is drawn at its size.
private struct SymbolGlyph: View {
    let glyph: String
    init(_ glyph: String) { self.glyph = glyph }
    var body: some View { Text(glyph).font(.custom("STIX Two Math", size: 17)) }
}

/// A button of the tool rows: a palette's sample opening a grid of all of them, or, for a
/// palette of one, putting that one in at once.
private struct PaletteButton: View {
    /// The button's sample, rendered (templates) or as text (symbols).
    let face: String
    let items: [EquationItem]
    let renderer: EquationRenderer
    let symbols: Bool
    let pick: (EquationItem) -> Void
    @State private var open = false

    var body: some View {
        Button { items.count == 1 ? pick(items[0]) : (open = true) } label: {
            HStack(spacing: 3) {
                Group {
                    if symbols { SymbolGlyph(face) } else { Sample(script: face, renderer: renderer, zoom: 1.1) }
                }
                .frame(minWidth: 22, minHeight: 22)
                if items.count > 1 {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
        }
        .buttonStyle(ToolButtonStyle(on: open))
        .help(items.count == 1 ? items[0].script : "")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PaletteGrid(items: items, renderer: renderer, symbols: symbols) {
                open = false
                pick($0)
            }
        }
    }
}

/// 수식 편집, laid out as 한글's: two tool rows, the preview, and the script under it. The
/// preview follows every keystroke.
struct EquationEditor: View {
    let viewer: Viewer
    let renderer: EquationRenderer
    @Environment(\.dismiss) private var dismiss
    @State private var edit: EquationEdit
    @State private var preview: PageDisplay?
    @State private var script = ScriptView.Proxy()

    init(edit: EquationEdit, viewer: Viewer, document: HwpDocument) {
        self.viewer = viewer
        renderer = EquationRenderer(document: document)
        _edit = State(initialValue: edit)
    }

    private var valid: Bool {
        !edit.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && edit.script.count <= 4096
    }

    var body: some View {
        DialogFrame("수식 편집", canConfirm: valid) {
            editor
        } confirm: {
            viewer.commit(edit)
            dismiss()
        }
        .task(id: "\(edit.fontSize) \(edit.color) \(edit.script)") {
            let size = UInt32((min(max(edit.fontSize, 1), 127) * 100).rounded())
            // The previous preview stays until the new one is ready, so typing never blinks.
            if let display = await renderer.display(edit.script, size: size, color: edit.color) { preview = display }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                ForEach(EquationPalette.templates, id: \.face) { palette in
                    PaletteButton(face: palette.face, items: palette.items, renderer: renderer, symbols: false) {
                        script.insert($0.script)
                    }
                }
                RowDivider()
                ForEach(EquationPalette.marks, id: \.script) { mark in
                    Button { script.insert(mark.script) } label: {
                        Text(mark.face).font(.system(size: 16)).frame(minWidth: 26, minHeight: 30)
                    }
                    .buttonStyle(ToolButtonStyle())
                    .help(mark.script)
                }
            }
            HStack(spacing: 1) {
                ForEach(EquationPalette.symbols, id: \.face) { palette in
                    PaletteButton(face: palette.face, items: palette.items, renderer: renderer, symbols: true) {
                        script.insert(word: $0.script)
                    }
                }
                Spacer(minLength: 16)
                SpinField(value: $edit.fontSize, unit: "pt", range: 1...127)
                    .accessibilityLabel("글자 크기")
                ColorWell(hex: Binding { Self.hex(edit.color) } set: { edit.color = Self.color($0) })
                    .accessibilityLabel("글자 색")
                    .padding(.leading, 8)
            }
            .padding(.bottom, 8)
            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    EquationGlyph(display: preview, zoom: 1.5)
                        .padding(16)
                        .frame(minWidth: 820, minHeight: 230, alignment: .center)
                }
                .frame(height: 230)
                .background(Color(nsColor: .underPageBackgroundColor))
                .environment(\.colorScheme, .light)
                Divider()
                ScriptView(text: $edit.script, proxy: script)
                    .frame(height: 170)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .frame(width: 820)
    }

    /// 0x00bbggrr and `#rrggbb`.
    private static func hex(_ color: UInt32) -> String {
        String(format: "#%02x%02x%02x", color & 255, color >> 8 & 255, color >> 16 & 255)
    }
    private static func color(_ hex: String) -> UInt32 {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (rgb >> 16 & 255) | (rgb & 0xff00) | (rgb & 255) << 16
    }
}

/// The script, in a plain text view that palettes insert into at the caret.
struct ScriptView: NSViewRepresentable {
    @Binding var text: String
    let proxy: Proxy

    /// Inserts into the text view at its caret.
    @MainActor final class Proxy {
        fileprivate weak var view: NSTextView?
        /// Puts `script` at the caret, with the caret in its first `{}`.
        func insert(_ script: String) {
            guard let view else { return }
            let start = view.selectedRange().location
            view.insertText(script, replacementRange: view.selectedRange())
            if let hole = script.range(of: "{}") {
                let offset = script.utf16.distance(from: script.startIndex, to: hole.lowerBound) + 1
                view.setSelectedRange(NSRange(location: start + offset, length: 0))
            }
            view.window?.makeFirstResponder(view)
        }
        /// Puts a keyword at the caret, apart from the words around it.
        func insert(word: String) {
            guard let view else { return }
            let text = view.string as NSString, range = view.selectedRange()
            let before = range.location > 0 ? text.substring(with: NSRange(location: range.location - 1, length: 1)) : " "
            insert((before.first?.isWhitespace == true || before == "{" ? "" : " ") + word + " ")
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.string = text
        view.delegate = context.coordinator
        proxy.view = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
