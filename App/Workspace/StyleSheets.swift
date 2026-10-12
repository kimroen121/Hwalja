import AppKit
import SwiftUI

// 스타일, as Pages keeps them: in the inspector's style popover, made from the text and
// brought up to date with it.

extension Viewer {
    /// A new style from the caret's shapes, as Pages's +: named after the caret's style, and a
    /// 문단 스타일 applied to the caret's paragraphs. Returns its number.
    @discardableResult
    func addStyle(paragraphStyle: Bool) -> UInt32? {
        guard let document, document.format != nil else { return nil }
        let id = UInt32(document.styles.count)
        let base = document.styles.first { $0.id == document.format?.style }?.name ?? "스타일"
        let name = (1...).lazy.map { "\(base) \($0)" }.first { name in !document.styles.contains { $0.name == name } }!
        let spec = StyleSpec(name: name, englishName: "", paragraphStyle: paragraphStyle, next: id)
        document.edit(undoManager) { selection in selection.map { .addStyle($0.focus, spec) } }
        if paragraphStyle { document.applyStyle(id, undoManager) }
        return id
    }
    /// The style's names or 다음 문단에 적용할 스타일 changed; its shapes stay.
    func editStyle(_ style: StyleInfo, _ change: (inout StyleSpec) -> Void) {
        let old = StyleSpec(name: style.name, englishName: style.englishName, paragraphStyle: style.paragraphStyle, next: style.next)
        var spec = old
        change(&spec)
        guard spec != old else { return }
        document?.edit(undoManager) { _ in .editStyle(style.id, spec) }
    }
    func deleteStyle(_ style: UInt32, replacement: UInt32) {
        document?.edit(undoManager) { _ in .deleteStyle(style, replacement: replacement) }
    }
    func moveStyle(_ style: UInt32, up: Bool) {
        document?.edit(undoManager) { _ in .moveStyle(style, up: up) }
    }
    /// The style takes the caret's shapes, and every paragraph in it follows: Pages's 업데이트.
    func restyleFromCaret(_ style: UInt32) {
        document?.edit(undoManager) { selection in selection.map { .restyleFromCaret(style, $0.focus) } }
    }
}

/// The style popover under the inspector's style, as Pages's: the styles, the caret's checked;
/// a click applies one, + makes one from the text, and each style's menu (› or a right click)
/// names, moves or deletes it.
struct StylePane: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    /// Called once a style is applied, to close the popover.
    var done: () -> Void = {}
    /// The style whose name (or 영문 이름) is being typed.
    @State private var renaming: Renaming?
    @State private var name = ""
    @State private var hovered: UInt32?
    /// Each style's 글자 모양, to show its name in it.
    @State private var looks: [UInt32: CharStyle] = [:]
    @FocusState private var typing: Bool

    private struct Renaming: Equatable {
        let style: UInt32
        let english: Bool
    }

    var body: some View {
        let current = document.styles.first { $0.id == document.format?.style }
        VStack(spacing: 0) {
            ZStack {
                Text("스타일").font(.headline)
                HStack {
                    Spacer()
                    Menu {
                        Button("문단 스타일") { add(paragraphStyle: true) }
                        Button("글자 스타일") { add(paragraphStyle: false) }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("스타일 추가")
                        .accessibilityLabel("스타일 추가")
                        .disabled(!document.context.canApplyStyle)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            ScrollViewReader { proxy in
                List(document.styles, id: \.id) { style in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").opacity(style.id == current?.id ? 1 : 0)
                        if renaming?.style == style.id {
                            TextField("", text: $name)
                                .font(.title3)
                                .focused($typing)
                                .onAppear { typing = true }
                                .onSubmit { rename(style) }
                                .onExitCommand { renaming = nil }
                        } else {
                            Button {
                                document.applyStyle(style.id, viewer.undoManager)
                                done()
                            } label: {
                                HStack {
                                    look(style)
                                    // 글자 스타일 marked, as the list holds both kinds.
                                    if !style.paragraphStyle { Image(systemName: "textformat").foregroundStyle(.secondary) }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!document.context.canApplyStyle)
                        }
                        Menu { menu(style) } label: { Image(systemName: "chevron.right") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .opacity(hovered == style.id ? 1 : 0)
                            .accessibilityLabel("\(style.name) 스타일 메뉴")
                    }
                    .padding(.vertical, 4)
                    .onHover { hovered = $0 ? style.id : hovered == style.id ? nil : hovered }
                    .contextMenu { menu(style) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .disabled(document.context.locked)
                // The caret's style in sight, and a new one as its name is typed.
                .onAppear { proxy.scrollTo(current?.id, anchor: .center) }
                .onChange(of: renaming) { if let renaming { proxy.scrollTo(renaming.style, anchor: .center) } }
            }
        }
        .frame(width: 280, height: 420)
        .task(id: document.styles) {
            await document.loadStyles()
            var read: [UInt32: CharStyle] = [:]
            for style in document.styles {
                read[style.id] = try? await document.styleFormat(style.id).text
            }
            guard !Task.isCancelled else { return }
            looks = read
        }
        // Typing a name ends when the field is left.
        .onChange(of: typing) { if !typing, let renaming, let style = document.styles.first(where: { $0.id == renaming.style }) { rename(style) } }
    }

    /// The style's name as its text looks, as Pages's list: its font, weight, slant, lines and
    /// color, in proportion to its size. Black (and white) take the list's text color.
    private func look(_ style: StyleInfo) -> some View {
        let text = looks[style.id]
        let family = text?.font.map { font in FormatChoices.families.first { $0.name == font || $0.family == font }?.family ?? font }
        // A 10 pt style at the list's 15 pt, larger ones larger.
        let size = min(max((text?.size ?? 10) * 1.5, 11), 30)
        let color = text?.color.flatMap { ["#000000", "#ffffff"].contains($0.lowercased()) ? nil : HexColor.color($0) }
        return Text(style.name)
            .font(family.map { .custom($0, size: size) } ?? .system(size: size))
            .bold(text?.bold == true)
            .italic(text?.italic == true)
            .underline(text?.underline == true)
            .strikethrough(text?.strikethrough == true)
            .foregroundStyle(color ?? .primary)
            .lineLimit(1)
    }
    @ViewBuilder private func menu(_ style: StyleInfo) -> some View {
        Button("스타일 이름 변경") { (renaming, name) = (Renaming(style: style.id, english: false), style.name) }
        Button("영문 이름 변경") { (renaming, name) = (Renaming(style: style.id, english: true), style.englishName) }
        if style.paragraphStyle {
            Picker("다음 문단에 적용할 스타일", selection: Binding { style.next } set: { next in viewer.editStyle(style) { $0.next = next } }) {
                ForEach(document.styles.filter(\.paragraphStyle)) { Text($0.name).tag($0.id) }
            }
        }
        Button("커서 위치의 스타일로 바꾸기") { viewer.restyleFromCaret(style.id) }
        Divider()
        Button("스타일 위로") { viewer.moveStyle(style.id, up: true) }.disabled(style.id < 2)
        Button("스타일 아래로") { viewer.moveStyle(style.id, up: false) }
            .disabled(style.id == 0 || Int(style.id) + 1 >= document.styles.count)
        Divider()
        // A 문단 스타일's paragraphs take the one chosen in its place.
        if style.paragraphStyle {
            Menu("스타일 지우기") {
                Section("바꿀 스타일") {
                    ForEach(document.styles.filter { $0.paragraphStyle && $0.id != style.id }) { other in
                        Button(other.name) { viewer.deleteStyle(style.id, replacement: other.id) }
                    }
                }
            }
            .disabled(style.id == 0)
        } else {
            Button("스타일 지우기") { viewer.deleteStyle(style.id, replacement: 0) }
        }
    }
    /// + as Pages's: the new style shows with its name ready to type.
    private func add(paragraphStyle: Bool) {
        guard let id = viewer.addStyle(paragraphStyle: paragraphStyle) else { return }
        Task {
            await document.settle()
            guard let style = document.styles.first(where: { $0.id == id }) else { return }
            (renaming, name) = (Renaming(style: id, english: false), style.name)
        }
    }
    private func rename(_ style: StyleInfo) {
        guard let renaming else { return }
        self.renaming = nil
        let typed = name.trimmingCharacters(in: .whitespaces)
        if renaming.english {
            viewer.editStyle(style) { $0.englishName = typed }
        } else if !typed.isEmpty {
            viewer.editStyle(style) { $0.name = typed }
        }
    }
}
