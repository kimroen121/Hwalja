import AppKit
import SwiftUI

// 수식: Hancom's equation script, or LaTeX converted to it, with its template and symbol
// palettes, and a preview drawn by the same renderer as the page.

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

/// The palettes, in the order of 한글's 수식 편집 tool rows, only the ones used most, so
/// they fit in one row; the script takes the rest.
enum EquationPalette {
    /// Templates, each with its name and key in 한글's help (Ctrl there, ⌘
    /// here) and the sample its button shows. A palette of one item is a plain button; the
    /// key puts in a palette's first item.
    static let templates: [(name: String, key: KeyEquivalent?, face: String, items: [EquationItem])] = [
        ("위 첨자", nil, "{x}^{2}", [
            EquationItem(sample: "{x}^{2}", script: "{}^{}"),
            EquationItem(sample: "{x}_{1}", script: "{}_{}"),
            EquationItem(sample: "{x}_{1}^{2}", script: "{}_{}^{}"),
        ]),
        ("분수", "o", "{a} over {b}", [EquationItem(sample: "{a} over {b}", script: "{} over {}")]),
        ("근호", "r", "sqrt {x}", [EquationItem(sample: "sqrt {x}", script: "sqrt {}")]),
        ("합 기호", "s", "sum", ["sum", "prod", "coprod", "bigcup", "bigcap"].map {
            EquationItem(sample: "\($0) from {i} to {n}", script: "\($0) from {} to {}")
        }),
        ("적분", "i", "int", [
            EquationItem(sample: "int from {a} to {b}", script: "int from {} to {}"),
            EquationItem(sample: "iint", script: "iint "),
            EquationItem(sample: "iiint", script: "iiint "),
            EquationItem(sample: "oint", script: "oint "),
        ]),
        ("극한", "l", "lim", [
            EquationItem(sample: "lim from {x rarrow 0}", script: "lim from {}"),
            EquationItem(sample: "Lim from {n rarrow INF}", script: "Lim from {}"),
        ]),
        ("괄호", "9", "left ( a right )", [("(", ")"), ("[", "]"), ("lbrace", "rbrace"), ("|", "|"), ("langle", "rangle"), ("lceil", "rceil"),
                 ("lfloor", "rfloor")].map {
            EquationItem(sample: "left \($0.0) a right \($0.1)", script: "left \($0.0) {} right \($0.1)")
        }),
        ("행렬", "m", "matrix{a & b # c & d}", ["matrix", "pmatrix", "bmatrix", "dmatrix"].map {
            EquationItem(sample: "\($0){a & b # c & d}", script: "\($0){ & # & }")
        }),
    ]
    /// Then symbol groups, each with its name in 한글's help and the glyph its button shows.
    static let symbols: [(name: String, face: String, items: [EquationItem])] = [
        ("그리스 소문자", "λ", group("alpha α beta β gamma γ delta δ epsilon ε zeta ζ eta η theta θ iota ι kappa κ lambda λ mu μ nu ν xi ξ omicron ο pi π rho ρ sigma σ tau τ upsilon υ phi φ chi χ psi ψ omega ω")),
        ("합, 집합 기호", "≤", group("NEQ ≠ LEQ ≤ GEQ ≥ ll ≪ gg ≫ APPROX ≈ SIM ∼ SIMEQ ≃ CONG ≅ EQUIV ≡ PROPTO ∝ SUBSET ⊂ SUPERSET ⊃ SUBSETEQ ⊆ SUPSETEQ ⊇ IN ∈ NOTIN ∉ OWNS ∋ VDASH ⊢ MODELS ⊨")),
        ("연산, 논리 기호", "±", group("PLUSMINUS ± MINUSPLUS ∓ TIMES × DIV ÷ CDOT · CIRC ∘ BULLET • INTER ∩ UNION ∪ SQCAP ⊓ SQCUP ⊔ OPLUS ⊕ OMINUS ⊖ OTIMES ⊗ ODOT ⊙ UPLUS ⊎ WEDGE ∧ VEE ∨ LNOT ¬ FORALL ∀ EXIST ∃")),
        ("화살표", "⇔", group("larrow ← rarrow → uparrow ↑ downarrow ↓ lrarrow ↔ udarrow ↕ LARROW ⇐ RARROW ⇒ UPARROW ⇑ DOWNARROW ⇓ LRARROW ⇔ UDARROW ⇕ nwarrow ↖ nearrow ↗ swarrow ↙ searrow ↘ mapsto ↦ hookleft ↩ hookright ↪")),
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

/// A rendered equation at its size, scaled by `zoom`: SwiftMath's own size when it sets the
/// equation, its room around it drawn but not laid out, so nothing is clipped.
struct EquationGlyph: View {
    let display: PageDisplay?
    var zoom = 1.0
    /// Draws in the text color instead of the equation's own, for palette buttons.
    var tinted = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let scale = PageGeometry.pointsPerPixel * zoom
        if let display, let natural = Formulas.shared.natural(display) {
            canvas(scale) { Formulas.shared.drawNatural(display, in: $0) }
                .frame(width: natural.size.width * scale, height: natural.size.height * scale)
                .padding(-natural.pad * scale)
        } else {
            canvas(scale) { display?.draw(in: $0) }
                .frame(width: (display?.width ?? 0) * scale, height: (display?.height ?? 0) * scale)
        }
    }

    private func canvas(_ scale: Double, draw: @escaping (CGContext) -> Void) -> some View {
        let tint = scheme == .dark ? CGColor.white : CGColor.black
        return Canvas { [tinted] context, size in
            context.withCGContext { cg in
                if tinted { cg.beginTransparencyLayer(auxiliaryInfo: nil) }
                cg.saveGState()
                cg.scaleBy(x: scale, y: scale)
                draw(cg)
                cg.restoreGState()
                if tinted {
                    cg.setBlendMode(.sourceIn)
                    cg.setFillColor(tint)
                    cg.fill(CGRect(origin: .zero, size: size))
                    cg.endTransparencyLayer()
                }
            }
        }
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
    let name: String
    var key: KeyEquivalent?
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
        .help(name)
        .accessibilityLabel(name)
        .background {
            if let key { Button("") { pick(items[0]) }.keyboardShortcut(key, modifiers: .command).hidden() }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PaletteGrid(items: items, renderer: renderer, symbols: symbols) {
                open = false
                pick($0)
            }
        }
    }
}

/// 수식 편집, laid out as 한글's: the tool row, the preview, and the script under it. The
/// script is written in 한글's syntax or in LaTeX; the document keeps 한글's. The preview
/// follows every keystroke.
struct EquationEditor: View {
    let viewer: Viewer
    let document: HwpDocument
    let renderer: EquationRenderer
    @Environment(\.dismiss) private var dismiss
    @State private var edit: EquationEdit
    /// What the script view shows: `edit.script`, or it as LaTeX.
    @State private var text: String
    @AppStorage("equationLatex") private var latex = false
    @State private var preview: PageDisplay?
    @State private var script = ScriptView.Proxy()

    init(edit: EquationEdit, viewer: Viewer, document: HwpDocument) {
        self.viewer = viewer
        self.document = document
        renderer = EquationRenderer(document: document)
        _edit = State(initialValue: edit)
        _text = State(initialValue: edit.script)
    }

    private var valid: Bool {
        !edit.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && edit.script.count <= 4096
    }

    var body: some View {
        DialogFrame("수식 편집", confirmTitle: "넣기", canConfirm: valid) {
            editor
        } confirm: {
            Task {
                await syncScript()
                viewer.commit(edit)
                dismiss()
            }
        }
        .task {
            if latex { await switchSyntax(toLatex: true) }
        }
        .task(id: text) { await syncScript() }
        .onChange(of: latex) { _, latex in Task { await switchSyntax(toLatex: latex) } }
        .task(id: "\(edit.fontSize) \(edit.color) \(edit.script)") {
            let size = UInt32((min(max(edit.fontSize, 1), 127) * 100).rounded())
            // The previous preview stays until the new one is ready, so typing never blinks.
            if let display = await renderer.display(edit.script, size: size, color: edit.color) { preview = display }
        }
    }

    /// `edit.script` from what the script view shows.
    private func syncScript() async {
        guard latex else { return edit.script = text }
        if let converted = try? await document.convertEquation(text, fromLatex: true) { edit.script = converted }
    }
    /// The script view in the other syntax.
    private func switchSyntax(toLatex: Bool) async {
        if !toLatex { return text = edit.script }
        if let converted = try? await document.convertEquation(edit.script, fromLatex: false) { text = converted }
    }
    /// A palette's script at the caret, in the syntax shown.
    private func insert(_ item: EquationItem, word: Bool) {
        Task {
            var inserted = item.script
            if latex, let converted = try? await document.convertEquation(item.script, fromLatex: false) {
                inserted = converted
            }
            word ? script.insert(word: inserted) : script.insert(inserted)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                ForEach(EquationPalette.templates, id: \.face) { palette in
                    PaletteButton(name: palette.name, key: palette.key, face: palette.face, items: palette.items,
                                  renderer: renderer, symbols: false) {
                        insert($0, word: false)
                    }
                }
                RowDivider()
                ForEach(EquationPalette.symbols, id: \.face) { palette in
                    PaletteButton(name: palette.name, face: palette.face, items: palette.items, renderer: renderer, symbols: true) {
                        insert($0, word: true)
                    }
                }
                RowDivider()
                SpinField(value: $edit.fontSize, unit: "pt", range: 1...127)
                    .accessibilityLabel("글자 크기")
                ColorWell(hex: Binding { Self.hex(edit.color) } set: { edit.color = Self.color($0) })
                    .accessibilityLabel("글자 색")
                    .fixedSize()
                    .padding(.leading, 8)
                Spacer(minLength: 0)
                Picker("", selection: $latex) {
                    Text("한글").tag(false)
                    Text("LaTeX").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.bottom, 8)
            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    EquationGlyph(display: preview, zoom: 1.5)
                        .padding(16)
                        .frame(minWidth: 860, minHeight: 230, alignment: .center)
                }
                .frame(height: 230)
                .background(Color(nsColor: .underPageBackgroundColor))
                .environment(\.colorScheme, .light)
                Divider()
                ScriptView(text: $text, proxy: script)
                    .frame(height: 170)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .frame(width: 860)
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
