import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Structure commands (breaks, tables, page setup) and the sheets that ask for their values.

extension Viewer {
    /// Whether the caret is in body text, where breaks and tables go.
    var inBody: Bool { document?.selection.map { $0.focus.target.cell == nil && $0.focus.target.note == nil } ?? false }
    /// Whether the caret is in a table cell.
    var inTable: Bool { document?.context.inTable ?? false }

    func insertBreak(column: Bool) {
        document?.edit(undoManager) { $0.map { .pageBreak($0.ordered.start, column: column) } }
    }
    func insertTable(rows: Int, columns: Int) {
        document?.edit(undoManager) { $0.map { .insertTable($0.ordered.start, rows: rows, columns: columns) } }
    }
    /// Asks for an image file and puts it at the caret.
    func insertPicture() {
        guard document?.selection != nil else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return NSSound.beep() }
            document?.insertPicture(data, name: url.lastPathComponent, undoManager)
        }
    }
    func insertNote(endnote: Bool) {
        document?.edit(undoManager) { $0.map { .insertNote($0.ordered.start, endnote: endnote) } }
    }
    func editTable(_ change: TableChange) {
        document?.edit(undoManager) { selection in
            guard let target = selection?.focus.target, target.cell != nil else { return nil }
            return .editTable(target, change)
        }
    }

    /// Runs a cell command over the cells the selection covers.
    func editCells(_ make: @escaping (EditSelection) -> EditCommand) {
        document?.edit(undoManager) { selection in
            guard let selection, selection.focus.target.cell != nil else { return nil }
            return make(selection)
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
    /// Replaces the section's 머리말 (or 꼬리말) for every page.
    func headerFooter(footer: Bool, pageNumber: Placement?) {
        document?.edit(undoManager) { selection in
            .headerFooter(section: selection?.focus.target.section ?? 0, footer: footer, pageNumber: pageNumber)
        }
    }
}

/// 표 만들기: row and column counts.
struct TableSheet: View {
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 5.0
    @State private var columns = 5.0

    var body: some View {
        DialogFrame("표 만들기") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { FieldLabel("줄 개수"); SpinField(value: $rows, unit: "", range: 1...1000) }
                GridRow { FieldLabel("칸 개수"); SpinField(value: $columns, unit: "", range: 1...256) }
            }
        } confirm: {
            viewer.insertTable(rows: Int(rows), columns: Int(columns))
            dismiss()
        }
    }
}

/// 셀 나누기: rows and columns for each covered cell.
struct SplitCellSheet: View {
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 2.0
    @State private var columns = 1.0
    @State private var equalHeight = true
    @State private var mergeFirst = false

    var body: some View {
        DialogFrame("셀 나누기") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { FieldLabel("줄 개수"); SpinField(value: $rows, unit: "", range: 1...256) }
                    GridRow { FieldLabel("칸 개수"); SpinField(value: $columns, unit: "", range: 1...256) }
                }
                Toggle("줄 높이를 같게 나누기", isOn: $equalHeight)
                Toggle("셀을 합친 후 나누기", isOn: $mergeFirst)
                    .disabled(viewer.canvas.editor.model?.context.cellBlock != true)
            }
        } confirm: {
            let (rows, columns, equalHeight, mergeFirst) = (Int(rows), Int(columns), equalHeight, mergeFirst)
            viewer.editCells { .splitCells($0, rows: rows, columns: columns, equalHeight: equalHeight, mergeFirst: mergeFirst) }
            dismiss()
        }
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

    var body: some View {
        DialogFrame("편집 용지") {
            VStack(alignment: .leading, spacing: 14) {
                GroupTitle("용지 종류")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("종류")
                        ChoiceField(paper, Self.papers.map { (Optional($0.name), $0.name) } + [(nil, "사용자 정의")])
                        FieldLabel("용지 방향")
                        Picker("용지 방향", selection: $page.landscape) {
                            Text("세로").tag(false)
                            Text("가로").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow { field("폭", \.width); field("길이", \.height) }
                }
                .padding(.leading, 12)
                GroupTitle("용지 여백")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { field("위쪽", \.marginTop); field("아래쪽", \.marginBottom) }
                    GridRow { field("왼쪽", \.marginLeft); field("오른쪽", \.marginRight) }
                    GridRow { field("머리말", \.marginHeader); field("꼬리말", \.marginFooter) }
                    GridRow { field("제본", \.marginGutter) }
                }
                .padding(.leading, 12)
            }
        } confirm: {
            viewer.setPage(page, section: section)
            dismiss()
        }
    }

    /// The named paper matching the size within half a millimeter.
    private var paper: Binding<String?> {
        Binding {
            let size = (Units.millimeters(page.width), Units.millimeters(page.height))
            return Self.papers.first { abs($0.width - size.0) < 0.5 && abs($0.height - size.1) < 0.5 }?.name
        } set: { name in
            guard let paper = Self.papers.first(where: { $0.name == name }) else { return }
            page.width = Units.units(paper.width)
            page.height = Units.units(paper.height)
        }
    }
    @ViewBuilder private func field(_ title: String, _ key: WritableKeyPath<PageSetup, UInt32>) -> some View {
        FieldLabel(title)
        SpinField(value: Binding { Units.millimeters(page[keyPath: key]) } set: { page[keyPath: key] = Units.units($0) },
                  unit: "mm", range: 0...1000)
    }
}

extension HwpDocument {
    /// Puts an image at the caret in the body, at its own size up to the text width, in
    /// the line like a character. PNG and JPEG go in as they are; other images as PNG, or
    /// as JPEG when they would not fit the engine's 5 MB.
    func insertPicture(_ data: Data, name: String, _ undoManager: UndoManager?) {
        guard let position = selection?.ordered.start, position.target.cell == nil, position.target.note == nil,
              let picture = Picture(data)
        else { return NSSound.beep() }
        Task {
            let page = try? await pageSetup(section: position.target.section)
            let pixels = Double(picture.width) * 75
            let text = page.map { Double(($0.landscape ? $0.height : $0.width) - $0.marginLeft - $0.marginRight - $0.marginGutter) }
            let scale = min(1, (text ?? pixels) / pixels)
            edit(undoManager) { _ in
                .insertPicture(position, data: picture.data, width: UInt32(max(1, (pixels * scale).rounded())),
                               height: UInt32(max(1, (Double(picture.height) * 75 * scale).rounded())),
                               naturalWidth: picture.width, naturalHeight: picture.height,
                               extension: picture.ext, description: name)
            }
        }
    }
}

/// An image as the engine embeds it.
private struct Picture {
    let data: Data, ext: String, width: UInt32, height: UInt32
    private static let limit = 5 * 1024 * 1024

    init?(_ original: Data) {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              (1...20_000).contains(image.width), (1...20_000).contains(image.height),
              image.width * image.height <= 100_000_000
        else { return nil }
        (width, height) = (UInt32(image.width), UInt32(image.height))
        if (type == .png || type == .jpeg), original.count <= Self.limit {
            (data, ext) = (original, type == .png ? "png" : "jpg")
        } else if let png = Self.encode(image, as: .png), png.count <= Self.limit {
            (data, ext) = (png, "png")
        } else if let jpeg = Self.encode(image, as: .jpeg), jpeg.count <= Self.limit {
            (data, ext) = (jpeg, "jpg")
        } else {
            return nil
        }
    }
    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
