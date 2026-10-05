import SwiftUI

// Structure commands (breaks, tables, page setup) and the sheets that ask for their values.

extension Viewer {
    private var document: HwpDocument? { canvas.editor.model }
    private var undoManager: UndoManager? { canvas.editor.undoManager }

    /// Whether the caret is in body text, where breaks and tables go.
    var inBody: Bool { document?.selection.map { $0.focus.target.cell == nil } ?? false }
    /// Whether the caret is in a table cell.
    var inTable: Bool { document?.selection?.focus.target.cell != nil }

    func insertBreak(column: Bool) {
        document?.edit(undoManager) { $0.map { .pageBreak($0.ordered.start, column: column) } }
    }
    func insertTable(rows: Int, columns: Int) {
        document?.edit(undoManager) { $0.map { .insertTable($0.ordered.start, rows: rows, columns: columns) } }
    }
    func editTable(_ change: TableChange) {
        document?.edit(undoManager) { selection in
            guard let target = selection?.focus.target, target.cell != nil else { return nil }
            return .editTable(target, change)
        }
    }

    /// Opens 편집 용지 for the section holding the caret.
    func showPageSetup() {
        guard let document else { return }
        let section = document.selection?.focus.target.section ?? 0
        Task {
            guard let page = try? await document.pageSetup(section: section) else { return NSSound.beep() }
            pageSetup = (section, page)
        }
    }
    func setPage(_ page: PageSetup, section: UInt32) {
        document?.edit(undoManager) { _ in .setPage(section: section, page) }
    }
}

/// 표 만들기: row and column counts.
struct TableSheet: View {
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 5
    @State private var columns = 5

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                Stepper(value: $rows, in: 1...1000) {
                    LabeledContent("줄 개수") { TextField("", value: $rows, format: .number).frame(width: 56) }
                }
                Stepper(value: $columns, in: 1...256) {
                    LabeledContent("칸 개수") { TextField("", value: $columns, format: .number).frame(width: 56) }
                }
            }
            HStack {
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("만들기") {
                    viewer.insertTable(rows: min(max(rows, 1), 1000), columns: min(max(columns, 1), 256))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .fixedSize()
    }
}

/// 편집 용지: paper size and orientation, and margins, in millimeters.
struct PageSetupSheet: View {
    let section: UInt32
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var page: PageSetup

    init(section: UInt32, page: PageSetup, viewer: Viewer) {
        self.section = section
        self.viewer = viewer
        _page = State(initialValue: page)
    }

    private static let papers: [(name: String, width: Double, height: Double)] = [
        ("A3", 297, 420), ("A4", 210, 297), ("A5", 148, 210), ("B4", 257, 364), ("B5", 182, 257),
        ("레터", 215.9, 279.4), ("리걸", 215.9, 355.6),
    ]
    private static let unitsPerMillimeter = 7200 / 25.4

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                Section("용지 종류") {
                    Picker("크기", selection: paper) {
                        ForEach(Self.papers, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                        Text("사용자 정의").tag(String?.none)
                    }
                    millimeters("폭", \.width)
                    millimeters("길이", \.height)
                    Picker("방향", selection: $page.landscape) {
                        Text("세로").tag(false)
                        Text("가로").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section("여백") {
                    millimeters("위쪽", \.marginTop)
                    millimeters("아래쪽", \.marginBottom)
                    millimeters("왼쪽", \.marginLeft)
                    millimeters("오른쪽", \.marginRight)
                    millimeters("머리말", \.marginHeader)
                    millimeters("꼬리말", \.marginFooter)
                    millimeters("제본", \.marginGutter)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("설정") {
                    viewer.setPage(page, section: section)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 360)
    }

    /// The named paper matching the size within half a millimeter.
    private var paper: Binding<String?> {
        Binding {
            let size = (Self.millimeters(page.width), Self.millimeters(page.height))
            return Self.papers.first { abs($0.width - size.0) < 0.5 && abs($0.height - size.1) < 0.5 }?.name
        } set: { name in
            guard let paper = Self.papers.first(where: { $0.name == name }) else { return }
            page.width = Self.units(paper.width)
            page.height = Self.units(paper.height)
        }
    }

    private func millimeters(_ title: String, _ key: WritableKeyPath<PageSetup, UInt32>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding { Self.millimeters(page[keyPath: key]) } set: { page[keyPath: key] = Self.units($0) },
                          format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }
    private static func millimeters(_ units: UInt32) -> Double { (Double(units) / unitsPerMillimeter * 10).rounded() / 10 }
    private static func units(_ millimeters: Double) -> UInt32 { UInt32(max(0, millimeters * unitsPerMillimeter).rounded()) }
}
