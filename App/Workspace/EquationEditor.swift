import AppKit
import SwiftUI

// 수식: Hancom's equation script, or LaTeX converted to it, and a preview drawn by the same
// renderer as the page.

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

/// A rendered equation at its size, scaled by `zoom`: SwiftMath's own size when it sets the
/// equation, its room around it drawn but not laid out, so nothing is clipped.
struct EquationGlyph: View {
    let display: PageDisplay?
    var zoom = 1.0
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
        Canvas { context, _ in
            context.withCGContext { cg in
                cg.scaleBy(x: scale, y: scale)
                draw(cg)
            }
        }
    }
}

/// 수식 편집: the preview over the script, written in 한글's syntax or in LaTeX; the document
/// keeps 한글's. The preview follows every keystroke.
struct EquationEditor: View {
    let viewer: Viewer
    let document: HwpDocument
    @Environment(\.dismiss) private var dismiss
    @State private var edit: EquationEdit
    /// What the script view shows: `edit.script`, or it as LaTeX.
    @State private var text: String
    @AppStorage("equationLatex") private var latex = false
    @State private var preview: PageDisplay?

    init(edit: EquationEdit, viewer: Viewer, document: HwpDocument) {
        self.viewer = viewer
        self.document = document
        _edit = State(initialValue: edit)
        _text = State(initialValue: edit.script)
    }

    private var valid: Bool {
        !edit.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && edit.script.count <= 4096
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("수식 편집기").font(.headline.weight(.regular))
            editor
            HStack {
                DialogChoice(selection: Binding { latex ? 1 : 0 } set: { latex = $0 == 1 }, titles: ["한글", "LaTeX"])
                    .fixedSize()
                Spacer()
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("넣기") {
                    Task {
                        await syncScript()
                        viewer.commit(edit)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .fixedSize()
        .task {
            if latex { await switchSyntax(toLatex: true) }
        }
        .task(id: text) { await syncScript() }
        .onChange(of: latex) { _, latex in Task { await switchSyntax(toLatex: latex) } }
        .task(id: "\(edit.fontSize) \(edit.color) \(edit.script)") {
            let size = UInt32((min(max(edit.fontSize, 1), 127) * 100).rounded())
            // The previous preview stays until the new one is ready, so typing never blinks.
            if let display = try? await document.equationPreview(edit.script, fontSize: size, color: edit.color) { preview = display }
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

    private var editor: some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                EquationGlyph(display: preview, zoom: 1.5)
                    .padding(16)
                    .frame(minWidth: 640, minHeight: 180, alignment: .center)
            }
            .frame(height: 180)
            .background(Color(nsColor: .underPageBackgroundColor))
            .environment(\.colorScheme, .light)
            Divider()
            ScriptView(text: $text)
                .frame(height: 130)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(width: 640)
    }
}

/// The script, in a plain text view.
struct ScriptView: NSViewRepresentable {
    @Binding var text: String

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
