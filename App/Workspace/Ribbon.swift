import SwiftUI

/// 기본 도구 상자: the most used commands as large labeled icons, in Hancom Office Web's
/// order. Commands that do not work yet are left out.
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
            ToolTile("붙이기", "clipboard") { send(#selector(NSText.paste(_:))) }
                .disabled(!context.hasSelection)
            ToolTile("모양 복사", "paintbrush") { viewer.paintFormat() }
                .disabled(!context.hasSelection)
            RowDivider()
            ToolTile("찾기", "magnifyingglass") { viewer.showFind(replace: false) }
            RowDivider()
            ToolTile("표", "tablecells") { viewer.insertingTable = true }
                .disabled(!context.hasSelection || context.inTable)
            RowDivider()
            ToolTile("문자표", "character.book.closed") { NSApp.orderFrontCharacterPalette(nil) }
                .disabled(!context.hasSelection)
            RowDivider()
            Group {
                ToolTile("글자 모양", "textformat") { viewer.editingCharShape = true }
                ToolTile("문단 모양", "text.alignleft") { viewer.editingParaShape = true }
            }
            .disabled(!context.hasSelection)
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
                    .font(.system(size: 19, weight: .light))
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
