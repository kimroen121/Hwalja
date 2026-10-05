import AppKit
import SwiftUI

// 수식 편집기: Hancom's equation script with its template and symbol palettes, and a
// preview drawn by the same renderer as the page.

/// The equation 수식 편집기 is showing: a new one, or `object` being changed.
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
    private var document: HwpDocument? { canvas.editor.model }
    private var undoManager: UndoManager? { canvas.editor.undoManager }

    /// Opens 수식 편집기 for a new equation in the caret's text size.
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

/// A palette entry: what it shows and the script it puts at the caret. `{}` marks the
/// places to fill; the caret lands in the first.
struct EquationItem: Hashable {
    let title: String
    let sample: String
    let script: String
}

/// The palettes, in Hancom's order and names.
enum EquationPalette {
    /// Each palette with the sample its button shows.
    static let templates: [(title: String, face: String, items: [EquationItem])] = [
        ("첨자", "{x}^{2}", [
            EquationItem(title: "위 첨자", sample: "{x}^{2}", script: "{}^{}"),
            EquationItem(title: "아래 첨자", sample: "{x}_{1}", script: "{}_{}"),
            EquationItem(title: "위아래 첨자", sample: "{x}_{1}^{2}", script: "{}_{}^{}"),
        ]),
        ("장식 기호", "bar a", ["bar", "vec", "hat", "tilde", "dot", "ddot", "acute", "grave", "check", "arch", "dyad", "under"].map {
            EquationItem(title: $0, sample: "\($0) a", script: "\($0) {}")
        }),
        ("분수", "{a} over {b}", [
            EquationItem(title: "분수", sample: "{a} over {b}", script: "{} over {}"),
            EquationItem(title: "위아래", sample: "{a} atop {b}", script: "{} atop {}"),
        ]),
        ("근호", "sqrt {x}", [
            EquationItem(title: "제곱근", sample: "sqrt {x}", script: "sqrt {}"),
            EquationItem(title: "거듭제곱근", sample: "root {n} of {x}", script: "root {} of {}"),
        ]),
        ("합", "sum", ["sum", "prod", "coprod", "bigcup", "bigcap"].map {
            EquationItem(title: $0, sample: "\($0) from {i} to {n}", script: "\($0) from {} to {}")
        }),
        ("적분", "int", [
            EquationItem(title: "int", sample: "int from {a} to {b}", script: "int from {} to {}"),
            EquationItem(title: "iint", sample: "iint", script: "iint "),
            EquationItem(title: "iiint", sample: "iiint", script: "iiint "),
            EquationItem(title: "oint", sample: "oint", script: "oint "),
        ]),
        ("극한", "lim", [
            EquationItem(title: "lim", sample: "lim from {x rarrow 0}", script: "lim from {}"),
            EquationItem(title: "Lim", sample: "Lim from {n rarrow INF}", script: "Lim from {}"),
        ]),
        ("괄호", "left ( a right )", [("(", ")"), ("[", "]"), ("lbrace", "rbrace"), ("|", "|"), ("langle", "rangle"), ("lceil", "rceil"),
                 ("lfloor", "rfloor")].map {
            EquationItem(title: "\($0.0) \($0.1)", sample: "left \($0.0) a right \($0.1)", script: "left \($0.0) {} right \($0.1)")
        }),
        ("경우", "cases{a # b}", [EquationItem(title: "cases", sample: "cases{x & x>0 # -x & x<0}", script: "cases{ & # & }")]),
        ("세로 쌓기", "pile{a # b}", ["pile", "lpile", "rpile"].map {
            EquationItem(title: $0, sample: "\($0){a # bb}", script: "\($0){ # }")
        }),
        ("행렬", "matrix{a & b # c & d}", ["matrix", "pmatrix", "bmatrix", "dmatrix"].map {
            EquationItem(title: $0, sample: "\($0){a & b # c & d}", script: "\($0){ & # & }")
        }),
    ]

    static let symbols: [(title: String, items: [EquationItem])] = [
        ("그리스 대문자", group("Alpha Α Beta Β Gamma Γ Delta Δ Epsilon Ε Zeta Ζ Eta Η Theta Θ Iota Ι Kappa Κ Lambda Λ Mu Μ Nu Ν Xi Ξ Omicron Ο Pi Π Rho Ρ Sigma Σ Tau Τ Upsilon Υ Phi Φ Chi Χ Psi Ψ Omega Ω")),
        ("그리스 소문자", group("alpha α beta β gamma γ delta δ epsilon ε zeta ζ eta η theta θ iota ι kappa κ lambda λ mu μ nu ν xi ξ omicron ο pi π rho ρ sigma σ tau τ upsilon υ phi φ chi χ psi ψ omega ω")),
        ("그리스 기호", group("vartheta ϑ varpi ϖ varsigma ς varupsilon ϒ varphi φ varepsilon ε ALEPH ℵ HBAR ℏ IMATH ı JMATH ȷ ELL ℓ WP ℘ IMAG ℑ REIMAGE ℜ ANGSTROM Å OHM Ω")),
        ("합·집합 기호", group("SUM ∑ PROD ∏ COPROD ∐ INTER ∩ UNION ∪ SQCAP ⊓ SQCUP ⊔ OPLUS ⊕ OMINUS ⊖ OTIMES ⊗ ODOT ⊙ UPLUS ⊎ WEDGE ∧ VEE ∨ SUBSET ⊂ SUPERSET ⊃ SUBSETEQ ⊆ SUPSETEQ ⊇ IN ∈ NOTIN ∉ OWNS ∋ EMPTYSET ∅")),
        ("연산·논리 기호", group("PLUSMINUS ± MINUSPLUS ∓ TIMES × DIV ÷ CDOT · CIRC ∘ BULLET • NEQ ≠ LEQ ≤ GEQ ≥ ll ≪ gg ≫ APPROX ≈ SIM ∼ SIMEQ ≃ CONG ≅ EQUIV ≡ PROPTO ∝ LNOT ¬ FORALL ∀ EXIST ∃ THEREFORE ∴ BECAUSE ∵ PARTIAL ∂ nabla ∇ VDASH ⊢ MODELS ⊨")),
        ("화살표", group("larrow ← rarrow → uparrow ↑ downarrow ↓ lrarrow ↔ udarrow ↕ LARROW ⇐ RARROW ⇒ UPARROW ⇑ DOWNARROW ⇓ LRARROW ⇔ UDARROW ⇕ nwarrow ↖ nearrow ↗ swarrow ↙ searrow ↘ mapsto ↦ hookleft ↩ hookright ↪")),
        ("기타 기호", group("INF ∞ DEG ° prime ′ ANGLE ∠ TRIANGLE △ BOT ⊥ TOP ⊤ CDOTS ⋯ LDOTS … VDOTS ⋮ DDOTS ⋱ DAGGER † DDAGGER ‡ CENTIGRADE ℃ FAHRENHEIT ℉ HUND ‰ THOU ‱ LAPLACE ℒ STAR ★ BIGCIRC ○ DIAMOND ◇")),
    ]

    /// "keyword glyph keyword glyph …" as items that show the glyph and put the keyword.
    private static func group(_ pairs: String) -> [EquationItem] {
        let words = pairs.split(separator: " ").map(String.init)
        return stride(from: 0, to: words.count - 1, by: 2).map {
            EquationItem(title: words[$0], sample: words[$0 + 1], script: words[$0])
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

/// One palette in the editor's tool row: its first sample, opening a grid of all of them.
private struct PaletteButton: View {
    let title: String
    /// The button's sample; the first item's when nil.
    var face: String?
    let items: [EquationItem]
    let renderer: EquationRenderer
    /// Symbols show their glyph as text; templates show the rendered sample.
    let symbols: Bool
    let pick: (EquationItem) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 2) {
                Group {
                    if let face { Sample(script: face, renderer: renderer, zoom: 1.1) } else { self.face(items[0]) }
                }
                .frame(minWidth: 22, minHeight: 22)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
        }
        .buttonStyle(ToolButtonStyle(on: open))
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.callout.weight(.semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(symbols ? 30 : 76), spacing: 4),
                                         count: symbols ? 8 : min(4, items.count)), spacing: 4) {
                    ForEach(items, id: \.self) { item in
                        Button {
                            open = false
                            pick(item)
                        } label: {
                            face(item).frame(width: symbols ? 30 : 76, height: symbols ? 30 : 52)
                        }
                        .buttonStyle(ToolButtonStyle())
                        .help(item.title)
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private func face(_ item: EquationItem) -> some View {
        if symbols {
            Text(item.sample).font(.custom("Times New Roman", size: 17))
        } else {
            Sample(script: item.sample, renderer: renderer, zoom: 1.2)
        }
    }
}

/// 수식 편집기: palettes and size above, the preview, and the script below it.
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 1) {
                ForEach(EquationPalette.templates, id: \.title) { palette in
                    PaletteButton(title: palette.title, face: palette.face, items: palette.items, renderer: renderer,
                                  symbols: false) {
                        script.insert($0.script)
                    }
                }
            }
            HStack(spacing: 1) {
                ForEach(EquationPalette.symbols, id: \.title) { palette in
                    PaletteButton(title: palette.title, items: palette.items, renderer: renderer, symbols: true) {
                        script.insert(word: $0.script)
                    }
                }
                Spacer(minLength: 16)
                LabeledField("글자 크기") {
                    SpinField(value: $edit.fontSize, unit: "pt", range: 1...127)
                }
                LabeledField("글자 색") {
                    ColorWell(hex: Binding { Self.hex(edit.color) } set: { edit.color = Self.color($0) })
                }
                .padding(.leading, 8)
            }
            ScrollView([.horizontal, .vertical]) {
                EquationGlyph(display: preview, zoom: 1.5)
                    .padding(16)
                    .frame(minWidth: 680, minHeight: 150)
            }
            .frame(height: 170)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .environment(\.colorScheme, .light)
            ScriptView(text: $edit.script, proxy: script)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(edit.object == nil ? "넣기" : "확인") {
                    viewer.commit(edit)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 720)
        .task(id: "\(edit.fontSize) \(edit.color) \(edit.script)") {
            let size = UInt32((min(max(edit.fontSize, 1), 127) * 100).rounded())
            // The previous preview stays until the new one is ready, so typing never blinks.
            if let display = await renderer.display(edit.script, size: size, color: edit.color) { preview = display }
        }
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
