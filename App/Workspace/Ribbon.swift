import SwiftUI

/// The window's menu row (파일·편집·보기·입력·서식·쪽·표), as in Hancom Office Web.
struct MenuRow: View {
    @ObservedObject var document: HwpDocument
    @ObservedObject var viewer: Viewer

    var body: some View {
        let items = MenuItems(document: document, viewer: viewer, shortcuts: false)
        HStack(spacing: 2) {
            menu("파일") { items.fileMenu }
            menu("편집") { items.editMenu }
            menu("보기") { items.viewMenu }
            menu("입력") { items.insert }
            menu("서식") { items.format }
            menu("쪽") { items.page }
            menu("표") { items.table }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func menu(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        Menu(title, content: content)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
    }
}

/// 기본 도구 상자: the most used commands as large labeled icons.
struct ToolRow: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer

    var body: some View {
        let context = document.context
        HStack(spacing: 2) {
            ToolTile("저장하기", "square.and.arrow.down") { send(#selector(NSDocument.save(_:))) }
            RowDivider()
            ToolTile("오려 두기", "scissors") { send(#selector(NSText.cut(_:))) }
                .disabled(!context.hasRange)
            ToolTile("복사하기", "doc.on.doc") { send(#selector(NSText.copy(_:))) }
                .disabled(!context.hasRange)
            ToolTile("붙이기", "doc.on.clipboard") { send(#selector(NSText.paste(_:))) }
                .disabled(!context.hasSelection)
            ToolTile("모양 복사", "paintbrush") { viewer.paintFormat() }
                .disabled(!context.hasSelection)
            RowDivider()
            ToolTile("찾기", "magnifyingglass") { viewer.showFind(replace: false) }
            RowDivider()
            Group {
                ToolTile("표", "tablecells") { viewer.insertingTable = true }
                ToolTile("쪽 나누기", "rectangle.split.1x2") { viewer.insertBreak(column: false) }
            }
            .disabled(!context.hasSelection || context.inTable)
            ToolTile("문자표", "character.book.closed") { NSApp.orderFrontCharacterPalette(nil) }
                .disabled(!context.hasSelection)
            RowDivider()
            ToolTile("편집 용지", "doc.text") { viewer.showPageSetup() }
            ToolTile("프린트", "printer") { send(#selector(DocumentCanvas.printDocument(_:))) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// A large icon over its name.
struct ToolTile: View {
    let title: String, symbol: String, action: () -> Void
    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        (self.title, self.symbol, self.action) = (title, symbol, action)
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .light))
                    .frame(height: 22)
                Text(title).font(.system(size: 11))
            }
            .frame(minWidth: 52)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        }
        .buttonStyle(ToolButtonStyle())
    }
}
