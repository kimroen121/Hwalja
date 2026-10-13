import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Structure commands (breaks, tables, page setup) and the sheets that ask for their values.

extension Viewer {
    func insertBreak(column: Bool) {
        document?.edit(undoManager) { $0.map { .pageBreak($0.ordered.start, column: column) } }
    }
    func insertTable(rows: Int, columns: Int, width: UInt32? = nil, height: UInt32? = nil, asCharacter: Bool = false) {
        document?.edit(undoManager) {
            $0.map { .insertTable($0.ordered.start, rows: rows, columns: columns, width: width, height: height, asCharacter: asCharacter) }
        }
    }
    /// Asks for an image file and puts it at the caret.
    func insertPicture() {
        guard document?.selection != nil else { return NSSound.beep() }
        chooseImage { [weak self] data, name in
            guard let self else { return }
            document?.insertPicture(data, name: name, undoManager)
        }
    }
    /// Asks for an image file and hands over its bytes and file name.
    private func chooseImage(_ chosen: @escaping (Data, String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return NSSound.beep() }
            chosen(data, url.lastPathComponent)
        }
    }
    /// The name a file saved from this document starts with.
    private var baseName: String {
        canvas.window?.representedURL?.deletingPathExtension().lastPathComponent ?? canvas.window?.title ?? "문서"
    }
    /// 다른 파일 형식으로 저장하기: 텍스트 문서(*.txt) in the chosen 문자 코드, 서식 있는
    /// 인터넷 문서(*.html), and for a document opened from HWPML, HWPML 문서(*.hml).
    func saveInOtherFormat() {
        guard let window = canvas.window, let document else { return }
        let panel = NSSavePanel()
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        let hml = (window.windowController?.document as? NSDocument)?.fileType == UTType.hml.identifier
        format.addItems(withTitles: ["텍스트 문서(*.txt)", "서식 있는 인터넷 문서(*.html)"] + (hml ? ["HWPML 문서(*.hml)"] : []))
        let encodings: [(String, String.Encoding)] = [
            ("유니코드(UTF-8)", .utf8), ("유니코드", .utf16LittleEndian), ("유니코드(Big-Endian)", .utf16BigEndian),
            ("한국(KS)", String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))),
        ]
        let encoding = NSPopUpButton(frame: .zero, pullsDown: false)
        encoding.addItems(withTitles: encodings.map(\.0))
        let accessory = ActionTarget.form([("파일 형식", format), ("문자 코드", encoding)])
        panel.accessoryView = accessory
        let types: [UTType] = [.plainText, .html, .hml]
        let update = { [weak panel] in
            let text = format.indexOfSelectedItem == 0, type = types[format.indexOfSelectedItem]
            panel?.allowedContentTypes = [type]
            panel?.nameFieldStringValue = self.baseName + "." + (type.preferredFilenameExtension ?? "")
            (accessory.subviews.first as? NSGridView)?.row(at: 1).isHidden = !text
        }
        let target = ActionTarget(update)
        format.target = target
        format.action = #selector(ActionTarget.run)
        update()
        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(target) {}
            guard response == .OK, let url = panel.url else { return }
            let chosen = encodings[encoding.indexOfSelectedItem].1
            let index = format.indexOfSelectedItem
            Task {
                do {
                    let data = switch index {
                    case 0: try await document.textDocument().data(using: chosen, allowLossyConversion: true)
                    case 1: try await document.webDocument().data(using: .utf8)
                    default: try await document.hmlDocument()
                    }
                    try data?.write(to: url, options: .atomic)
                } catch {
                    NSApp.presentError(error)
                }
            }
        }
    }
    /// 블록 저장: the selected text as a 한/글 document of its own, in the chosen 파일 형식.
    func saveBlock() {
        guard let window = canvas.window, let document, let selection = document.selection,
              selection.anchor != selection.focus else { return }
        let panel = NSSavePanel()
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        let formats: [(String, UTType, SaveFormat)] = [("한글 표준 문서(*.hwpx)", .hwpx, .hwpx), ("한글 문서(*.hwp)", .hwp, .hwp)]
        format.addItems(withTitles: formats.map(\.0))
        panel.accessoryView = ActionTarget.form([("파일 형식", format)])
        let update = { [weak panel] in
            let type = formats[format.indexOfSelectedItem].1
            panel?.allowedContentTypes = [type]
            panel?.nameFieldStringValue = self.baseName + "." + (type.preferredFilenameExtension ?? "")
        }
        let target = ActionTarget(update)
        format.target = target
        format.action = #selector(ActionTarget.run)
        update()
        panel.prompt = "블록 저장"
        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(target) {}
            guard response == .OK, let url = panel.url else { return }
            let chosen = formats[format.indexOfSelectedItem].2
            Task {
                do {
                    try await document.exportBlock(selection, chosen).write(to: url, options: .atomic)
                } catch {
                    NSSound.beep()
                }
            }
        }
    }
    /// 그림으로 저장하기: each page as a picture in the chosen folder, the name followed by
    /// 001, 002, …, in the chosen 파일 형식 and 해상도.
    func saveAsPictures() {
        guard let window = canvas.window, let document else { return }
        let types: [(String, UTType, NSBitmapImageRep.FileType)] = [
            ("BMP(*.bmp)", .bmp, .bmp), ("GIF(*.gif)", .gif, .gif), ("PNG(*.png)", .png, .png), ("JPG(*.jpg)", .jpeg, .jpeg),
        ]
        let resolutions: [(String, CGFloat)] = [
            ("최저 해상도(72DPI)", 72), ("저 해상도(120DPI)", 120), ("중간 해상도(150DPI)", 150),
            ("고 해상도(180DPI)", 180), ("최고 해상도(300DPI)", 300),
        ]
        let name = NSTextField(string: baseName)
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: types.map(\.0))
        let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
        resolution.addItems(withTitles: resolutions.map(\.0))
        resolution.selectItem(at: 1)
        let accessory = ActionTarget.form([("파일 이름", name), ("파일 형식", format), ("해상도", resolution)])
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "저장"
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            let (_, type, fileType) = types[format.indexOfSelectedItem]
            let scale = resolutions[resolution.indexOfSelectedItem].1 / 72
            let base = name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? self.baseName : name.stringValue
            Task {
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                do {
                    guard let pdf = PDFDocument(data: try await document.pdf()) else { return NSSound.beep() }
                    for index in 0..<pdf.pageCount {
                        guard let page = pdf.page(at: index) else { continue }
                        let bounds = page.bounds(for: .mediaBox)
                        guard let image = NSBitmapImageRep(
                            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: image) else { continue }
                        context.cgContext.setFillColor(.white)
                        context.cgContext.fill(CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh))
                        context.cgContext.scaleBy(x: scale, y: scale)
                        page.draw(with: .mediaBox, to: context.cgContext)
                        let file = folder.appendingPathComponent(base + String(format: "%03d", index + 1))
                            .appendingPathExtension(type.preferredFilenameExtension ?? "png")
                        try image.representation(using: fileType, properties: [:])?.write(to: file, options: .atomic)
                    }
                } catch {
                    NSApp.presentError(error)
                }
            }
        }
    }
    /// 문서 끼워 넣기: the chosen HWP and HWPX files at the caret, one after another, each
    /// marked with a 책갈피 of its name when 파일 이름으로 책갈피 넣기 is on.
    func insertDocuments() {
        guard document?.context.inBody == true else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = UTType.hwpFamily
        panel.prompt = "넣기"
        let bookmark = NSButton(checkboxWithTitle: "파일 이름으로 책갈피 넣기", target: nil, action: nil)
        panel.accessoryView = bookmark
        panel.isAccessoryViewDisclosed = true
        panel.begin { [weak self] response in
            guard response == .OK, let self, let document else { return }
            for url in panel.urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return NSSound.beep() }
                let name = bookmark.state == .on ? url.deletingPathExtension().lastPathComponent : nil
                document.edit(undoManager) { selection in
                    selection.map { .insertDocument($0.focus, data: data, bookmark: name) }
                }
            }
        }
    }
    /// 그림 바꾸기: an image file in place of `object` (the selected picture), at its size.
    func replacePicture(_ object: ObjectRef? = nil) {
        guard let object = object ?? document?.object?.object, object.kind == .picture else { return NSSound.beep() }
        chooseImage { [weak self] data, _ in
            guard let self else { return }
            document?.replacePicture(data, object: object, undoManager)
        }
    }
    /// 삽입 그림 저장하기: `object`'s (the selected picture's) image to a file, in its own format.
    func savePicture(_ object: ObjectRef? = nil) {
        guard let document, let object = object ?? document.object?.object, object.kind == .picture else { return NSSound.beep() }
        Task {
            guard let file = try? await document.pictureFile(object) else { return NSSound.beep() }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "그림.\(file.extension)"
            panel.allowedContentTypes = UTType(filenameExtension: file.extension).map { [$0] } ?? []
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do { try file.data.write(to: url) } catch { NSSound.beep() }
        }
    }
    func insertNote(endnote: Bool) {
        document?.edit(undoManager) { $0.map { .insertNote($0.ordered.start, endnote: endnote) } }
    }
    /// The cell table commands work from: the caret's, or the first of a table chosen whole.
    func tableCell(_ selection: EditSelection?) -> EditTarget? {
        if let target = selection?.focus.target, target.cell != nil { return target }
        guard let table = document?.object?.object, table.kind == .table, table.cell == nil, table.note == nil else { return nil }
        return EditTarget(section: table.section, paragraph: table.paragraph, cell: CellTarget(control: table.control, cell: 0, paragraph: 0))
    }
    func editTable(_ change: TableChange) {
        document?.edit(undoManager) { [self] selection in tableCell(selection).map { .editTable($0, change) } }
    }
    func setTableSize(rows: Int, columns: Int) {
        document?.edit(undoManager) { [self] selection in tableCell(selection).map { .setTableSize($0, rows: rows, columns: columns) } }
    }

    /// 표 뒤집기 of the table holding the caret.
    func flipTable(_ turn: TableTurn, margins: Bool) {
        document?.edit(undoManager) { [self] selection in tableCell(selection).map { .flipTable($0, turn, margins: margins) } }
    }

    /// Runs a cell command over the cells the selection covers.
    func editCells(_ make: @escaping (EditSelection) -> EditCommand) {
        document?.edit(undoManager) { selection in
            guard let selection, selection.focus.target.cell != nil else { return nil }
            return make(selection)
        }
    }
    /// 계산식 into the cell holding the caret.
    func calculate(_ formula: String, format: UInt8, separators: Bool) {
        editCells { .calculate($0.focus, formula: formula, format: format, separators: separators) }
    }

    func setPage(_ page: PageSetup, section: UInt32, whole: Bool = false) {
        document?.edit(undoManager) { _ in .setPage(section: section, page, whole: whole) }
    }
    func setCellBorder(_ border: CellBorder, all: Bool, one: Bool) {
        document?.edit(undoManager) { selection in selection.map { .setCellBorder($0, all: all, one: one, border) } }
    }
    func setPageBorder(_ border: PageBorder, section: UInt32, whole: Bool) {
        document?.edit(undoManager) { _ in .setPageBorder(section: section, border, whole: whole) }
    }
    func setNoteShape(_ shape: NoteShape, footnote: Bool, section: UInt32, whole: Bool) {
        document?.edit(undoManager) { _ in .setNoteShape(section: section, footnote: footnote, shape, whole: whole) }
    }
    func setSection(_ setup: SectionSetup, section: UInt32, whole: Bool) {
        document?.edit(undoManager) { _ in .setSection(section: section, setup, whole: whole) }
    }
    /// 이전 or 다음 머리말/꼬리말 (or 주석) from the one holding the caret.
    func goTo(_ motion: Motion) {
        document?.select { document in
            guard let focus = document.selection?.focus else { return nil }
            return try await .caret(document.navigate(from: focus, motion).position)
        }
    }
    /// Replaces the section's 머리말 (or 꼬리말) for every page, turning 쪽 윤곽 on to show it.
    func headerFooter(footer: Bool, pageNumber: Placement?) {
        showsOutline = true
        document?.edit(undoManager) { selection in
            .headerFooter(section: selection?.focus.target.section ?? 0, footer: footer, pageNumber: pageNumber)
        }
    }
    func setColumns(_ setup: ColumnSetup, section: UInt32) {
        document?.edit(undoManager) { _ in
            .setColumns(section: section, count: setup.count, columnType: setup.columnType, sameWidth: setup.sameWidth,
                        spacing: setup.spacing)
        }
    }
    /// 단 하나, 둘 or 셋 for the section holding the caret.
    func setColumns(_ count: UInt16) {
        document?.edit(undoManager) { selection in
            .setColumns(section: selection?.focus.target.section ?? 0, count: count)
        }
    }
}

extension Viewer {
    /// 개인 정보 바꾸기 › 바로 바꾸기: the selected text becomes ***.
    func hidePrivateInfo() {
        document?.edit(undoManager) { selection in
            guard let selection, selection.anchor != selection.focus else { return nil }
            return .replace(selection, text: "***")
        }
    }
}

/// [개인 정보 바꾸기] (찾아서 바꾸기): 개인 정보 선택 사항 found one at a time or all at
/// once, and 바꿀 문자 선택. It stays until 닫기, as in 한/글.
struct PrivateInfoSheet: View {
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var kinds: Set<String> = ["phone", "ssn", "email", "card"]
    @State private var other = false
    @State private var otherText = ""
    @State private var mark = "***"
    @State private var custom = ""
    @State private var found = false

    private static let options = [("phone", "전화번호"), ("ssn", "주민등록번호"), ("email", "전자우편"), ("card", "신용카드 번호")]
    private var replacement: String { mark.isEmpty ? custom : mark }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("개인 정보 바꾸기").font(.headline.weight(.medium))
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("개인 정보 선택 사항")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.options, id: \.0) { kind, title in
                            Toggle(title, isOn: Binding { kinds.contains(kind) } set: { on in
                                if on { kinds.insert(kind) } else { kinds.remove(kind) }
                            })
                        }
                        HStack {
                            Toggle("기타", isOn: $other)
                            TextField("", text: $otherText).frame(width: 120).disabled(!other)
                        }
                    }
                    .padding(.leading, 12)
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("바꿀 문자 선택")
                    Picker("", selection: $mark) {
                        Text("***").tag("***")
                        Text("~~~").tag("~~~")
                        Text("XXX").tag("XXX")
                        HStack {
                            Text("사용자 정의 문자")
                            TextField("", text: $custom).frame(width: 80).disabled(!mark.isEmpty)
                        }
                        .tag("")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .padding(.leading, 12)
                }
            }
            HStack {
                Spacer()
                Button(found ? "다음 찾기" : "찾기") { findNext() }
                Button("바꾸기") { replace() }
                Button("모두 바꾸기") { replaceAll() }
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .disabled(kinds.isEmpty && !(other && !otherText.isEmpty))
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Every match in document order: the kinds rhwp finds, and 기타's text.
    private func matches(_ document: HwpDocument) async throws -> [EditSelection] {
        var all = try await document.privateInfo(Self.options.map(\.0).filter(kinds.contains))
        if other, !otherText.isEmpty { all += try await document.find(otherText) }
        return all.sorted { $0.ordered.start.order.lexicographicallyPrecedes($1.ordered.start.order) }
    }
    private func findNext() {
        guard let document = viewer.document else { return }
        found = true
        document.select { document in
            let all = try await matches(document)
            guard !all.isEmpty else {
                NSSound.beep()
                return nil
            }
            guard let end = document.selection?.ordered.end.order else { return all[0] }
            return all.first { !$0.ordered.start.order.lexicographicallyPrecedes(end) } ?? all[0]
        }
    }
    private func replace() {
        guard let document = viewer.document else { return }
        let text = replacement
        Task {
            await document.settle()
            let all = (try? await matches(document)) ?? []
            guard let selection = document.selection, all.contains(selection) else { return findNext() }
            document.edit(viewer.undoManager) { $0 == selection ? .replace(selection, text: text) : nil }
            findNext()
        }
    }
    private func replaceAll() {
        guard let document = viewer.document else { return }
        let text = replacement
        Task {
            await document.settle()
            let all = (try? await matches(document)) ?? []
            guard !all.isEmpty else { return NSSound.beep() }
            document.edit(viewer.undoManager) { _ in .replaceAll(all, text: text) }
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
        DialogFrame("셀 나누기", confirmTitle: "나누기") {
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

/// [계산식]: the formula, with 함수 and 쉬운 범위 to write it, 형식 and 세 자리마다 쉼표로 자리 구분.
struct CalculationSheet: View {
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var formula = ""
    @State private var function = ""
    @State private var range = ""
    @State private var format: UInt8 = 0
    @State private var separators = false

    /// 시트 함수 in the help's order.
    private static let functions = ["SUM", "AVERAGE", "PRODUCT", "MIN", "MAX", "COUNT", "COS", "SIN", "TAN", "ACOS", "ASIN",
                                    "ATAN", "ABS", "EXP", "LN", "LOG", "SQRT", "DEGTORAD", "RADTODEG", "SIGN", "CEILING",
                                    "FLOOR", "INT", "ROUND", "MOD"]
    private static let ranges = ["LEFT", "RIGHT", "ABOVE", "BELOW"]
    private static let formats: [(UInt8, String)] = [(0, "기본 형식"), (1, "정수형"), (2, "소수점 이하 한 자리"),
                                                     (3, "소수점 이하 두 자리"), (4, "소수점 이하 세 자리"), (5, "소수점 이하 네 자리")]

    var body: some View {
        DialogFrame("계산식", confirmTitle: "설정", canConfirm: !formula.trimmingCharacters(in: .whitespaces).isEmpty) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    FieldLabel("계산식")
                    TextField("", text: $formula).frame(width: 240)
                }
                GridRow {
                    FieldLabel("함수")
                    ChoiceField($function, [("", "")] + Self.functions.map { ($0, "\($0)(..)") }, minWidth: 140)
                }
                GridRow {
                    FieldLabel("쉬운 범위")
                    ChoiceField($range, [("", "")] + Self.ranges.map { ($0, $0) }, minWidth: 140)
                }
                GridRow {
                    FieldLabel("형식")
                    ChoiceField($format, Self.formats, minWidth: 140)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("세 자리마다 쉼표로 자리 구분", isOn: $separators)
                }
            }
        } confirm: {
            viewer.calculate(formula, format: format, separators: separators)
            dismiss()
        }
        // A 함수 or 쉬운 범위 chosen writes the formula from them.
        .onChange(of: [function, range]) {
            formula = function.isEmpty ? (range.isEmpty ? formula : "=SUM(\(range))") : "=\(function)(\(range))"
        }
    }
}

/// A side button's picture: its sides (왼쪽, 오른쪽, 위쪽, 아래쪽, 가로, 세로) over a dashed box.
struct SideIcon: View {
    let sides: [Int]
    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            context.stroke(Path(box), with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let path = Path { path in
                for side in sides {
                    let (from, to): (CGPoint, CGPoint) = switch side {
                    case 0: (CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.maxY))
                    case 1: (CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY))
                    case 2: (CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY))
                    case 3: (CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY))
                    case 4: (CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY))
                    default: (CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.midX, y: box.maxY))
                    }
                    path.move(to: from)
                    path.addLine(to: to)
                }
            }
            context.stroke(path, with: .color(.primary), lineWidth: 2)
        }
        .frame(width: 22, height: 22)
        .padding(3)
    }
    /// The same picture for a segmented control: a template, in the control's colors.
    static func image(_ sides: [Int]) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let box = rect.insetBy(dx: 2.5, dy: 2.5)
            let dashed = NSBezierPath(rect: box)
            dashed.setLineDash([2, 2], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.4).setStroke()
            dashed.stroke()
            let line = NSBezierPath()
            line.lineWidth = 2
            for side in sides {
                let (from, to): (NSPoint, NSPoint) = switch side {
                case 0: (NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.minX, y: box.maxY))
                case 1: (NSPoint(x: box.maxX, y: box.minY), NSPoint(x: box.maxX, y: box.maxY))
                case 2: (NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY))
                default: (NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY))
                }
                line.move(to: from)
                line.line(to: to)
            }
            NSColor.black.setStroke()
            line.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 용지 방향 and 제본 as the web dialog draws them: a page with lines of text, and pages
/// with 가 (and 나) by their bound edge.
enum PagePictogram {
    /// A page with `count` columns of lines.
    static func columns(_ count: Int, on: Bool) -> some View {
        Canvas { context, size in
            let ink: Color = on ? .white : .secondary
            let page = CGRect(x: size.width * 0.19, y: size.height * 0.05, width: size.width * 0.62, height: size.height * 0.9)
            context.stroke(Path(page), with: .color(ink), lineWidth: 1)
            let gap = 2.0, inner = page.insetBy(dx: 4, dy: 4)
            let width = (inner.width - gap * Double(count - 1)) / Double(count)
            for column in 0..<count {
                let x = inner.minX + Double(column) * (width + gap)
                for y in stride(from: inner.minY, to: inner.maxY, by: 3) {
                    context.fill(Path(CGRect(x: x, y: y, width: width, height: 1)), with: .color(ink))
                }
            }
        }
    }
}

/// 문자표, laid out as 수식 편집기: 문자 영역 beside 문자 선택 in one box, the character
/// pointed at shown large with its 유니코드 (typed, it finds the character), 최근 사용한 문자,
/// and 입력 문자 by 넣기. A double click (or 선택) adds the chosen character to 입력 문자.
struct SymbolSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var area = 0
    @State private var chosen: String?
    @State private var hovered: String?
    @State private var code = ""
    @State private var text = ""
    @AppStorage("recentSymbols") private var recent = ""

    /// 문자 영역 in the web editor's names and order: 기호1 and 기호2 are KS X 1001's first two
    /// rows, the others their Unicode blocks (일반 문장 부호, 화살표 …) in full.
    static let areas: [(name: String, characters: [String])] = [
        ("일반 문장 부호", blocks(0x2010...0x2027, 0x2030...0x205E)),
        ("기호1", "、。·‥…¨〃―∥＼∼‘’“”〔〕〈〉《》「」『』【】±×÷≠≤≥∞∴°′″℃Å￠￡￥♂♀∠⊥⌒∂∇≡≒§※☆★○●◎◇◆□■△▲▽▼→←↑↓↔〓≪≫√∽∝∵∫∬∈∋⊆⊇⊂⊃∪∩∧∨￢".map(String.init)),
        ("기호2", "⇒⇔∀∃´～ˇ˘˝˚˙¸˛¡¿ː∮∑∏¤℉‰◁◀▷▶♤♠♡♥♧♣⊙◈▣◐◑▒▤▥▨▧▦▩♨☏☎☜☞¶†‡↕↗↙↖↘♭♩♪♬㉿㈜№㏇™㏂㏘℡€®".map(String.init)),
        ("통화 기호", "¢£¤¥".map(String.init) + blocks(0x20A0...0x20C0)),
        ("글자 모양 기호", blocks(0x2100...0x214F)),
        ("숫자 형식", blocks(0x2150...0x2189)),
        ("화살표", blocks(0x2190...0x21FF)),
        ("괄호", "()[]{}〈〉《》「」『』【】〔〕〖〗〘〙〚〛｛｝［］（）".map(String.init)),
        ("수학 연산자", blocks(0x2200...0x22FF)),
        ("그리스어", blocks(0x0391...0x03A9, 0x03B1...0x03C9)),
        ("단위기호", blocks(0x3380...0x33FF)),
        ("원문자", blocks(0x2460...0x2473, 0x24B6...0x24E9, 0x3260...0x327B, 0x327F...0x327F)),
        ("괄호문자", blocks(0x2474...0x2487, 0x249C...0x24B5, 0x3200...0x321E)),
        ("상자 그리기", blocks(0x2500...0x257F)),
        ("도형", blocks(0x25A0...0x25FF)),
        ("기타 기호", blocks(0x2600...0x26FF)),
        ("한중일 기호 및 구두점", blocks(0x3001...0x303F)),
        ("호환용 한글 자모", blocks(0x3131...0x318E)),
    ]
    /// The assigned, visible characters of `ranges`.
    private static func blocks(_ ranges: ClosedRange<UInt32>...) -> [String] {
        ranges.flatMap { $0 }.compactMap(Unicode.Scalar.init).filter {
            ![.unassigned, .control, .format, .spaceSeparator, .privateUse, .surrogate].contains($0.properties.generalCategory)
        }.map { String($0) }
    }
    private static let cell: CGFloat = 36
    private static let columns = Array(repeating: GridItem(.fixed(cell), spacing: 0), count: 13)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("문자표").font(.headline.weight(.regular))
            HStack(spacing: 0) {
                List(Self.areas.indices, id: \.self, selection: Binding { area } set: { area = $0 ?? area }) {
                    Text(Self.areas[$0].name)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: 172)
                Divider()
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: Self.columns, spacing: 0) {
                                ForEach(Self.areas[area].characters, id: \.self) { cell($0) }
                            }
                        }
                        .onChange(of: area) { proxy.scrollTo(Self.areas[area].characters.first, anchor: .top) }
                    }
                    Divider()
                    magnified
                }
            }
            .frame(width: 640, height: 380)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            if !recent.isEmpty { HStack(spacing: 8) {
                Text("최근 사용한 문자").foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    ForEach(recent.map(String.init), id: \.self) { character in
                        Button(character) { text += character }
                            .buttonStyle(.borderless)
                            .font(.system(size: 17))
                            .frame(width: 28, height: 28)
                    }
                }
            } }
            HStack(spacing: 8) {
                Text("입력 문자")
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("넣기") { insert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
        .fixedSize()
        .onChange(of: chosen) { code = chosen.map(Self.code) ?? "" }
    }

    /// 선택 문자 확대: the character pointed at, else the one chosen, with its 유니코드.
    private var magnified: some View {
        let shown = hovered ?? chosen
        return HStack(spacing: 14) {
            Text(shown ?? " ")
                .font(.system(size: 34))
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            LabeledContent("유니코드") {
                TextField("", text: $code)
                    .monospaced()
                    .frame(width: 70)
                    .onSubmit(find)
            }
            .fixedSize()
            Spacer()
            Button("선택") { chosen.map { text += $0 } }
                .disabled(chosen == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 76)
    }

    private func cell(_ character: String) -> some View {
        Text(character)
            .font(.system(size: 19))
            .frame(width: Self.cell, height: Self.cell)
            .background(character == chosen ? Color.accentColor.opacity(0.25) : character == hovered ? Color.primary.opacity(0.08) : .clear)
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? character : hovered == character ? nil : hovered }
            .onTapGesture(count: 2) { text += character }
            .onTapGesture { chosen = character }
            .id(character)
    }

    private static func code(_ character: String) -> String {
        character.unicodeScalars.first.map { String(format: "%04X", $0.value) } ?? ""
    }
    /// The character of the 유니코드 typed, in its 문자 영역 when one holds it.
    private func find() {
        guard let value = UInt32(code.trimmingCharacters(in: .whitespaces), radix: 16), let scalar = Unicode.Scalar(value) else { return NSSound.beep() }
        let character = String(scalar)
        if let index = Self.areas.firstIndex(where: { $0.characters.contains(character) }) { area = index }
        chosen = character
    }
    private func insert() {
        viewer.document?.type(text, viewer.undoManager)
        let used = text.reduce(into: [Character]()) { if !$0.contains($1) { $0.append($1) } }
        recent = String((used + recent.filter { !used.contains($0) }).prefix(16))
        dismiss()
    }
}

extension HwpDocument {
    /// Puts an image at the caret in the body or a table cell (beside the table, floating), at its own size up to the text width, in
    /// the line like a character. PNG and JPEG go in as they are; other images as PNG, or
    /// as JPEG when they would not fit the engine's 5 MB.
    /// 그림 바꾸기 for `object`.
    func replacePicture(_ data: Data, object: ObjectRef, _ undoManager: UndoManager?) {
        guard let picture = Picture(data) else { return NSSound.beep() }
        edit(undoManager) { _ in
            .replacePicture(object, data: picture.data, naturalWidth: picture.width, naturalHeight: picture.height,
                            extension: picture.ext)
        }
    }
    func insertPicture(_ data: Data, name: String, _ undoManager: UndoManager?) {
        guard let position = selection?.ordered.start, position.target.note == nil,
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

/// Runs a closure as an AppKit control's action.
final class ActionTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }

    /// A panel's accessory: each title beside its control, the titles right-aligned.
    @MainActor static func form(_ rows: [(String, NSView)]) -> NSView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 20),
        ])
        return box
    }
}
