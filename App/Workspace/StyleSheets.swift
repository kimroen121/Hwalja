import AppKit
import SwiftUI

// 스타일 (F6), 스타일 추가하기/편집하기 and 스타일 지우기's 바꿀 스타일 선택.

/// A style being added (no `style`) or edited, with the shapes it starts from.
struct StyleEditor: Identifiable {
    let id = UUID()
    let style: UInt32?
    let base: Format
    var spec: StyleSpec
}

extension Viewer {
    /// 스타일 추가하기 from the caret's shapes.
    func newStyle() -> StyleEditor? {
        guard let document, let format = document.format else { return nil }
        return StyleEditor(style: nil, base: format,
                           spec: StyleSpec(name: "", englishName: "", paragraphStyle: true, next: UInt32(document.styles.count)))
    }
    /// 스타일 편집하기 of `style`.
    func styleEditor(_ style: StyleInfo) async -> StyleEditor? {
        guard let format = try? await document?.styleFormat(style.id) else { return nil }
        return StyleEditor(style: style.id, base: format,
                           spec: StyleSpec(name: style.name, englishName: style.englishName,
                                           paragraphStyle: style.paragraphStyle, next: style.next))
    }
    func finishStyle(_ editor: StyleEditor, _ spec: StyleSpec) {
        document?.edit(undoManager) { selection in
            if let style = editor.style { return .editStyle(style, spec) }
            return selection.map { .addStyle($0.focus, spec) }
        }
    }
    func deleteStyle(_ style: UInt32, replacement: UInt32) {
        document?.edit(undoManager) { _ in .deleteStyle(style, replacement: replacement) }
    }
    func moveStyle(_ style: UInt32, up: Bool) {
        document?.edit(undoManager) { _ in .moveStyle(style, up: up) }
    }
    func restyleFromCaret(_ style: UInt32) {
        document?.edit(undoManager) { selection in selection.map { .restyleFromCaret(style, $0.focus) } }
    }
    /// 스타일 지우기: a 글자 스타일 goes at once; a 문단 스타일 first asks which takes its place.
    func deleteStyle(_ style: StyleInfo, ask: (StyleInfo) -> Void) {
        if style.paragraphStyle { ask(style) } else { deleteStyle(style.id, replacement: 0) }
    }
}

/// A style's picture in a list: ¶ for 문단, 가 for 글자.
struct StyleLabel: View {
    let style: StyleInfo
    var body: some View {
        Label {
            Text(style.name)
        } icon: {
            Image(systemName: style.paragraphStyle ? "paragraphsign" : "textformat")
        }
    }
}

/// [스타일] 대화 상자: 스타일 목록 with its tools, and the chosen style's shapes.
struct StyleSheet: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UInt32?
    @State private var format: Format?
    @State private var editor: StyleEditor?
    @State private var replacing: StyleInfo?

    init(document: HwpDocument, viewer: Viewer) {
        self.document = document
        self.viewer = viewer
        _selection = State(initialValue: document.format?.style ?? 0)
    }

    private var chosen: StyleInfo? { document.styles.first { $0.id == selection } }

    var body: some View {
        DialogFrame("스타일", confirmTitle: "설정", canConfirm: chosen != nil && document.context.canApplyStyle) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("스타일 목록")
                    List(document.styles, id: \.id, selection: $selection) { StyleLabel(style: $0) }
                        .frame(width: 230, height: 300)
                    HStack(spacing: 2) {
                        listTool("스타일 추가하기", "plus") { editor = viewer.newStyle() }
                        tool("스타일 편집하기", "pencil", needs: chosen) { style in
                            Task { editor = await viewer.styleEditor(style) }
                        }
                        tool("스타일 지우기", "minus", needs: chosen.flatMap { $0.id == 0 ? nil : $0 }) { style in
                            viewer.deleteStyle(style) { replacing = $0 }
                        }
                        tool("커서 위치의 스타일로 바꾸기", "text.cursor", needs: chosen) { viewer.restyleFromCaret($0.id) }
                        tool("한 줄 위로 이동하기", "arrow.up", needs: chosen.flatMap { $0.id > 1 ? $0 : nil }) { style in
                            viewer.moveStyle(style.id, up: true)
                            selection = style.id - 1
                        }
                        tool("한 줄 아래로 이동하기", "arrow.down",
                             needs: chosen.flatMap { $0.id > 0 && Int($0.id) + 1 < document.styles.count ? $0 : nil }) { style in
                            viewer.moveStyle(style.id, up: false)
                            selection = style.id + 1
                        }
                    }
                    .disabled(document.context.locked)
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("문단 모양 정보")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        let p = format?.paragraph
                        info("왼쪽 여백", p?.marginLeft.map { "\($0.formatted()) pt" })
                        info("오른쪽 여백", p?.marginRight.map { "\($0.formatted()) pt" })
                        info("줄 간격", p?.lineSpacing.map { "\($0.formatted()) \(p?.lineSpacingKind == .percent ? "%" : "pt")" })
                        info("첫 줄", p?.indent.map { $0 == 0 ? "보통" : $0 > 0 ? "들여쓰기 \($0.formatted()) pt" : "내어쓰기 \((-$0).formatted()) pt" })
                        info("정렬 방식", p?.alignment.map { FormatChoices.label($0).title })
                    }
                    .padding(.leading, 12)
                    GroupTitle("글자 모양 정보").padding(.top, 8)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        let t = format?.text
                        info("글꼴", t?.font)
                        info("크기", t?.size.map { "\($0.formatted()) pt" })
                        info("장평", t?.ratio.map { "\($0.formatted()) %" })
                        info("자간", t?.spacing.map { "\($0.formatted()) %" })
                    }
                    .padding(.leading, 12)
                    GroupTitle("현재 커서 위치 스타일").padding(.top, 8)
                    Text(document.styles.first { $0.id == document.format?.style }?.name ?? "")
                        .padding(.leading, 12)
                }
                .frame(width: 220, alignment: .leading)
            }
        } confirm: {
            if let selection { document.applyStyle(selection, viewer.undoManager) }
            dismiss()
        }
        .task(id: [selection.map(Int.init) ?? -1, Int(document.reply.revision)]) {
            format = nil
            if let selection { format = try? await document.styleFormat(selection) }
        }
        .onChange(of: document.styles) { _, styles in
            if let selection, Int(selection) >= styles.count { self.selection = UInt32(max(styles.count - 1, 0)) }
        }
        .sheet(item: $editor) { editor in
            StyleEditSheet(editor: editor, styles: document.styles, viewer: viewer)
        }
        .sheet(item: $replacing) { style in
            StyleReplaceSheet(style: style, styles: document.styles, viewer: viewer)
        }
    }

    private func tool(_ title: String, _ symbol: String, needs style: StyleInfo?,
                      action: @escaping (StyleInfo) -> Void) -> some View {
        listTool(title, symbol) { if let style { action(style) } }.disabled(style == nil)
    }
    @ViewBuilder private func info(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value ?? "")
        }
    }
}

/// [스타일 추가하기] and [스타일 편집하기]: names, 스타일 종류, 다음 문단에 적용할 스타일, and
/// the 문단 모양 and 글자 모양 the style lays over its shapes.
struct StyleEditSheet: View {
    let editor: StyleEditor
    let styles: [StyleInfo]
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var spec: StyleSpec
    @State private var editingText = false
    @State private var editingParagraph = false

    init(editor: StyleEditor, styles: [StyleInfo], viewer: Viewer) {
        self.editor = editor
        self.styles = styles
        self.viewer = viewer
        var spec = editor.spec
        if spec.text.isEmpty { spec.text = [CharStyle()] }
        _spec = State(initialValue: spec)
    }

    private var adding: Bool { editor.style == nil }
    /// The styles 다음 문단에 적용할 스타일 offers: the 문단 스타일, and a new one itself.
    private var nexts: [(UInt32, String)] {
        let own = adding ? [(UInt32(styles.count), spec.name)] : []
        return styles.filter(\.paragraphStyle).map { ($0.id, $0.name) } + own
    }

    var body: some View {
        DialogFrame(adding ? "스타일 추가하기" : "스타일 편집하기", confirmTitle: adding ? "추가" : "설정",
                    canConfirm: !spec.name.trimmingCharacters(in: .whitespaces).isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        FieldLabel("스타일 이름")
                        TextField("", text: $spec.name).frame(width: 200)
                    }
                    GridRow {
                        FieldLabel("영문 이름")
                        TextField("", text: $spec.englishName).frame(width: 200)
                    }
                    GridRow {
                        FieldLabel("스타일 종류")
                        Picker("", selection: $spec.paragraphStyle) {
                            Text("문단").tag(true)
                            Text("글자").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                        .disabled(!adding)
                    }
                    GridRow {
                        FieldLabel("다음 문단에 적용할 스타일")
                        ChoiceField($spec.next, nexts, minWidth: 140)
                            .disabled(!spec.paragraphStyle)
                    }
                }
                HStack(spacing: 8) {
                    Button("문단 모양…") { editingParagraph = true }.disabled(!spec.paragraphStyle)
                    Button("글자 모양…") { editingText = true }
                }
            }
        } confirm: {
            viewer.finishStyle(editor, spec)
            dismiss()
        }
        .sheet(isPresented: $editingText) {
            CharShapeSheet(style: editor.base.text.merging(spec.text[0]), languages: editor.base.languages, viewer: viewer) { change in
                if change.language == nil {
                    spec.text[0] = spec.text[0].merging(change)
                } else {
                    spec.text.append(change)
                }
            }
        }
        .sheet(isPresented: $editingParagraph) {
            ParaShapeSheet(style: editor.base.paragraph.merging(spec.paragraph), viewer: viewer) { change in
                spec.paragraph = spec.paragraph.merging(change)
            }
        }
    }
}

/// [바꿀 스타일 선택]: the 문단 스타일 that takes a deleted one's place.
struct StyleReplaceSheet: View {
    let style: StyleInfo
    let styles: [StyleInfo]
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var replacement: UInt32? = 0

    var body: some View {
        DialogFrame("바꿀 스타일 선택", confirmTitle: "설정", canConfirm: replacement != nil) {
            List(styles.filter { $0.paragraphStyle && $0.id != style.id }, id: \.id, selection: $replacement) {
                StyleLabel(style: $0)
            }
            .frame(width: 240, height: 220)
        } confirm: {
            if let replacement { viewer.deleteStyle(style.id, replacement: replacement) }
            dismiss()
        }
    }
}

#Preview {
    StyleSheet(document: HwpDocument(), viewer: Viewer())
}
