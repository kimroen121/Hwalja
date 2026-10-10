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
    func editTable(_ change: TableChange) {
        document?.edit(undoManager) { selection in
            guard let target = selection?.focus.target, target.cell != nil else { return nil }
            return .editTable(target, change)
        }
    }

    /// 표 뒤집기 of the table holding the caret.
    func flipTable(_ turn: TableTurn, margins: Bool) {
        document?.edit(undoManager) { selection in
            guard let target = selection?.focus.target, target.cell != nil else { return nil }
            return .flipTable(target, turn, margins: margins)
        }
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

    /// Opens 편집 용지 for the section holding the caret.
    func showPageSetup() {
        guard let document else { return }
        let section = document.selection?.focus.target.section ?? 0
        Task {
            guard let page = try? await document.pageSetup(section: section) else { return NSSound.beep() }
            pageSetup = (section, page)
        }
    }
    func setPage(_ page: PageSetup, section: UInt32, whole: Bool = false) {
        document?.edit(undoManager) { _ in .setPage(section: section, page, whole: whole) }
    }
    /// Opens 쪽 테두리/배경 for the section holding the caret.
    /// 셀 테두리/배경 from the cell holding the caret: 각 셀마다 적용, or `one` 하나의 셀처럼 적용.
    func showCellBorder(one: Bool, tab: String = "테두리") {
        guard let document, let selection = document.selection, selection.anchor.target.cell != nil else { return NSSound.beep() }
        let block = document.context.cellBlock
        Task {
            guard let border = try? await document.cellBorder(selection.anchor.target) else { return NSSound.beep() }
            cellBorder = CellBorderEditing(one: one, block: block, border: border, tab: tab)
        }
    }
    func setCellBorder(_ border: CellBorder, all: Bool, one: Bool) {
        document?.edit(undoManager) { selection in selection.map { .setCellBorder($0, all: all, one: one, border) } }
    }
    func showPageBorder() {
        guard let document else { return }
        let section = document.selection?.focus.target.section ?? 0
        Task {
            guard let border = try? await document.pageBorder(section: section) else { return NSSound.beep() }
            pageBorder = (section, border)
        }
    }
    func setPageBorder(_ border: PageBorder, section: UInt32, whole: Bool) {
        document?.edit(undoManager) { _ in .setPageBorder(section: section, border, whole: whole) }
    }
    /// Opens 주석 모양 for the section holding the caret.
    func showNoteShapes() {
        guard let document else { return }
        let section = document.selection?.focus.target.section ?? 0
        Task {
            guard let footnote = try? await document.noteShape(section: section, footnote: true),
                  let endnote = try? await document.noteShape(section: section, footnote: false)
            else { return NSSound.beep() }
            noteShapes = (section, footnote, endnote)
        }
    }
    func setNoteShape(_ shape: NoteShape, footnote: Bool, section: UInt32, whole: Bool) {
        document?.edit(undoManager) { _ in .setNoteShape(section: section, footnote: footnote, shape, whole: whole) }
    }
    /// Opens 구역 설정 for the section holding the caret.
    func showSectionSetup() {
        guard let document else { return }
        let section = document.selection?.focus.target.section ?? 0
        Task {
            guard let setup = try? await document.sectionSetup(section: section) else { return NSSound.beep() }
            sectionSetup = (section, setup)
        }
    }
    func setSection(_ setup: SectionSetup, section: UInt32, whole: Bool) {
        document?.edit(undoManager) { _ in .setSection(section: section, setup, whole: whole) }
    }
    /// 세로 or 가로 for the section holding the caret.
    func setOrientation(landscape: Bool) {
        guard let document else { return }
        let section = document.selection?.focus.target.section ?? 0
        Task {
            guard var page = try? await document.pageSetup(section: section) else { return NSSound.beep() }
            guard page.landscape != landscape else { return }
            page.landscape = landscape
            setPage(page, section: section)
        }
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
    /// Opens 단 설정 for the section holding the caret.
    func showColumns() {
        guard let document else { return }
        let section = document.selection?.focus.target.section ?? 0
        Task {
            guard let setup = try? await document.columns(section: section) else { return NSSound.beep() }
            columnSetup = (section, setup)
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
            Text("개인 정보 바꾸기").font(.headline)
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

/// [단 설정]: 단 종류, 자주 쓰이는 모양 with 단 개수, and 너비 및 간격.
struct ColumnSheet: View {
    let section: UInt32
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var setup: ColumnSetup

    init(section: UInt32, setup: ColumnSetup, viewer: Viewer) {
        (self.section, self.viewer) = (section, viewer)
        _setup = State(initialValue: setup)
    }

    var body: some View {
        DialogFrame("단 설정", confirmTitle: "설정") {
            VStack(alignment: .leading, spacing: 14) {
                GroupTitle("단 종류")
                Picker("", selection: $setup.columnType) {
                    Text("일반 단").tag(UInt8(0))
                    Text("배분 단").tag(UInt8(1))
                    Text("평행 단").tag(UInt8(2))
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .padding(.leading, 12)
                .disabled(setup.count < 2)
                GroupTitle("자주 쓰이는 모양")
                VStack(alignment: .leading, spacing: 8) {
                    IconTiles(selection: $setup.count, options: [(UInt16(1), "하나"), (2, "둘"), (3, "셋")]) { count, on in
                        PagePictogram.columns(Int(count), on: on)
                    }
                    LabeledField("단 개수") {
                        SpinField(value: Binding { Double(setup.count) } set: { setup.count = UInt16($0) },
                                  unit: "", range: 1...255, digits: 0)
                    }
                }
                .padding(.leading, 12)
                GroupTitle("너비 및 간격")
                VStack(alignment: .leading, spacing: 8) {
                    LabeledField("간격") {
                        SpinField(value: Binding { Units.millimeters(UInt32(max(setup.spacing, 0))) }
                                  set: { setup.spacing = Int16(clamping: Units.units($0) as Int) },
                                  unit: "mm", range: 0...100)
                    }
                    Toggle("단 너비 동일하게", isOn: $setup.sameWidth)
                }
                .padding(.leading, 12)
                .disabled(setup.count < 2)
            }
        } confirm: {
            viewer.setColumns(setup, section: section)
            dismiss()
        }
    }
}

/// 표 만들기, as the web editor's: 줄/칸, 크기 지정 and 기타.
struct TableSheet: View {
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 5.0
    @State private var columns = 5.0
    /// 0 단에 맞춤, 1 문단에 맞춤, 2 임의 값.
    @State private var widthKind = 0
    /// 0 자동, 1 임의 값.
    @State private var heightKind = 0
    @State private var width = 0.0
    @State private var height = 0.0
    @State private var asCharacter = false
    /// The width rhwp gives a new table (the paper less its margins and the table's own),
    /// and the paragraph's margins, in millimeters.
    @State private var column = 150.0
    @State private var paragraphMargins = 0.0

    /// A new row's height as rhwp makes it: one line and the cell's inner margins.
    private static let rowHeight = 1282

    var body: some View {
        DialogFrame("표 만들기", confirmTitle: "만들기") {
            VStack(alignment: .leading, spacing: 14) {
                GroupTitle("줄/칸")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { FieldLabel("줄 개수"); SpinField(value: $rows, unit: "", range: 1...1000) }
                    GridRow { FieldLabel("칸 개수"); SpinField(value: $columns, unit: "", range: 1...256) }
                }
                .padding(.leading, 12)
                GroupTitle("크기 지정")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("너비")
                        ChoiceField($widthKind, [(0, "단에 맞춤"), (1, "문단에 맞춤"), (2, "임의 값")], minWidth: 100)
                        SpinField(value: Binding { shownWidth } set: { width = $0 }, unit: "mm", range: 1...1000)
                            .disabled(widthKind != 2)
                    }
                    GridRow {
                        FieldLabel("높이")
                        ChoiceField($heightKind, [(0, "자동"), (1, "임의 값")], minWidth: 100)
                        SpinField(value: Binding { shownHeight } set: { height = $0 }, unit: "mm", range: 1...1000)
                            .disabled(heightKind != 1)
                    }
                }
                .padding(.leading, 12)
                GroupTitle("기타")
                Toggle("글자처럼 취급", isOn: $asCharacter).padding(.leading, 12)
            }
        } confirm: {
            viewer.insertTable(rows: Int(rows), columns: Int(columns),
                               width: widthKind == 0 ? nil : Units.units(shownWidth),
                               height: heightKind == 0 ? nil : Units.units(shownHeight), asCharacter: asCharacter)
            dismiss()
        }
        .task {
            guard let document = viewer.document,
                  let page = try? await document.pageSetup(section: document.selection?.focus.target.section ?? 0)
            else { return }
            column = Units.millimeters(Int(page.width) - Int(page.marginLeft) - Int(page.marginRight) - 566)
            let paragraph = document.format?.paragraph
            paragraphMargins = ((paragraph?.marginLeft ?? 0) + (paragraph?.marginRight ?? 0)) * 25.4 / 72
            width = column
        }
        .onChange(of: widthKind) { old, kind in if kind == 2 { width = shownWidth(for: old) } }
        .onChange(of: heightKind) { _, kind in if kind == 1 { height = Units.millimeters(Int(rows) * Self.rowHeight) } }
    }

    private var shownWidth: Double { widthKind == 2 ? width : shownWidth(for: widthKind) }
    private func shownWidth(for kind: Int) -> Double { kind == 1 ? max(1, column - paragraphMargins) : column }
    private var shownHeight: Double { heightKind == 1 ? height : Units.millimeters(Int(rows) * Self.rowHeight) }
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

/// 표 뒤집기, as in 한/글: one of 대칭 or 회전, and 여백 뒤집기.
struct TableFlipSheet: View {
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var turn = TableTurn.diagonal
    @State private var margins = false

    private func choices(_ options: [(TableTurn, String)]) -> some View {
        Picker("", selection: $turn) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    var body: some View {
        DialogFrame("표 뒤집기", confirmTitle: "뒤집기") {
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("대칭")
                choices([(.rows, "줄 기준 뒤집기"), (.columns, "칸 기준 뒤집기"), (.diagonal, "줄/칸 뒤집기")])
                GroupTitle("회전").padding(.top, 4)
                choices([(.left, "반시계 방향 90도"), (.half, "180도"), (.right, "시계 방향 90도")])
                GroupTitle("선택 사항").padding(.top, 4)
                Toggle("여백 뒤집기", isOn: $margins)
            }
        } confirm: {
            viewer.flipTable(turn, margins: margins)
            dismiss()
        }
    }
}

/// 편집 용지, laid out like the web editor's: 용지 종류, 용지 방향, 제본, 용지 여백 (in
/// millimeters), and 적용 범위.
struct PageSetupSheet: View {
    let section: UInt32
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var page: PageSetup
    @State private var whole = true

    init(section: UInt32, page: PageSetup, viewer: Viewer) {
        self.section = section
        self.viewer = viewer
        _page = State(initialValue: page)
    }

    /// 용지 종류, in Hancom's names and order.
    static let papers: [(name: String, width: Double, height: Double)] = [
        ("프린트 132", 335.3, 279.4), ("레터", 215.9, 279.4), ("B5(46배판)", 182, 257), ("B4(타블로이드판)", 257, 364),
        ("A4(국배판)", 210, 297), ("A3(국배배판)", 297, 420), ("리갈", 215.9, 355.6), ("A6(문고판)", 105, 148),
        ("A5(국판)", 148, 210), ("신국판", 148, 225), ("크라운판", 176, 248), ("Executive", 184.1, 266.7),
        ("Executive(JIS)", 216, 329.9), ("Envelope DL", 110, 220), ("Envelope C5", 162, 229),
        ("Envelope B5", 176, 250), ("Envelope Monarch", 98.4, 190.5), ("점자출력용지", 230, 279.4),
        ("16절지(국판)", 159, 234),
    ]

    var body: some View {
        DialogFrame("편집 용지", confirmTitle: "설정") {
            VStack(alignment: .leading, spacing: 14) {
                GroupTitle("용지 종류")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("종류")
                        ChoiceField(paper, Self.papers.map {
                            (Optional($0.name), "\($0.name) [\($0.width.formatted()) x \($0.height.formatted()) mm]")
                        } + [(nil, "사용자 정의")], minWidth: 300)
                        .gridCellColumns(3)
                    }
                    // The paper is kept upright; 가로 shows it turned.
                    GridRow {
                        field("폭", page.landscape ? \.height : \.width)
                        field("길이", page.landscape ? \.width : \.height)
                    }
                }
                .padding(.leading, 12)
                HStack(alignment: .top, spacing: 48) {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupTitle("용지 방향")
                        IconTiles(selection: $page.landscape, options: [(false, "세로"), (true, "가로")]) { landscape, on in
                            PagePictogram.orientation(landscape, on: on)
                        }
                        .padding(.leading, 12)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        GroupTitle("제본")
                        IconTiles(selection: $page.binding, options: [(UInt8(0), "한쪽"), (1, "맞쪽"), (2, "위로")]) { binding, on in
                            PagePictogram.binding(binding, on: on)
                        }
                        .padding(.leading, 12)
                    }
                }
                GroupTitle("용지 여백")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { field("위쪽", \.marginTop); field("아래쪽", \.marginBottom) }
                    GridRow { field("왼쪽", \.marginLeft); field("오른쪽", \.marginRight) }
                    GridRow { field("머리말", \.marginHeader); field("꼬리말", \.marginFooter) }
                    GridRow { field("제본", \.marginGutter) }
                }
                .padding(.leading, 12)
                Divider()
                HStack(spacing: 10) {
                    Text("적용 범위")
                    ChoiceField($whole, [(true, "문서 전체"), (false, "현재 구역")], minWidth: 100).fixedSize()
                }
            }
        } confirm: {
            viewer.setPage(page, section: section, whole: whole)
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

/// 쪽 테두리/배경: 테두리 and 배경 tabs over the section's pages, and 적용 범위.
struct PageBorderSheet: View {
    let section: UInt32
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var border: PageBorder
    @State private var tab: String
    @State private var whole = true
    /// The 종류, 굵기 and 색 the side buttons put on.
    @State private var line: BorderSide
    /// 선 종류 바로 적용: changing the line changes the sides whose button is down.
    @State private var instant = true
    @State private var pressed: Set<Int>
    /// Each side's line before its button last put one on.
    @State private var previous: [BorderSide]

    private static let none = BorderSide(line: 0, width: 0, color: "#000000")
    private static let pages: [(ApplyPages, String)] = [(.all, "모두"), (.exceptFirst, "첫 쪽 제외"), (.firstOnly, "첫 쪽만")]

    init(section: UInt32, border: PageBorder, viewer: Viewer, tab: String = "테두리") {
        self.section = section
        self.viewer = viewer
        _tab = State(initialValue: tab)
        _border = State(initialValue: border)
        _line = State(initialValue: border.sides.first { $0.line != 0 } ?? BorderSide(line: 1, width: 1, color: "#000000"))
        _pressed = State(initialValue: Set(border.sides.indices.filter { border.sides[$0].line != 0 }))
        _previous = State(initialValue: Array(repeating: Self.none, count: 4))
    }

    var body: some View {
        DialogFrame("쪽 테두리/배경", confirmTitle: "설정") {
            DialogTabs(selection: $tab, titles: ["테두리", "배경"]) { tab in
                Group { if tab == "배경" { background } else { lines } }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 22)
            }
            .frame(width: 520, height: 412)
            HStack(spacing: 10) {
                Text("적용 범위")
                ChoiceField($whole, [(true, "문서 전체"), (false, "현재 구역")], minWidth: 100).fixedSize()
            }
        } confirm: {
            viewer.setPageBorder(border, section: section, whole: whole)
            dismiss()
        }
        .onChange(of: line) { _, line in
            guard instant else { return }
            for side in pressed { border.sides[side] = line }
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("테두리")
                    LineFields(line: $line).padding(.leading, 12)
                    Toggle("선 종류 바로 적용", isOn: $instant).padding(.leading, 12)
                    Button("테두리 사용 안 함") {
                        line.line = 0
                        border.sides = Array(repeating: Self.none, count: 4)
                        pressed = []
                    }
                    .padding(.leading, 12)
                }
                preview
            }
            GroupTitle("위치")
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $border.paper) {
                    Text("종이 기준").tag(true)
                    Text("쪽 기준").tag(false)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                HStack(alignment: .top, spacing: 20) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow { gap("왼쪽", 0); gap("오른쪽", 1) }
                        GridRow { gap("위쪽", 2); gap("아래쪽", 3) }
                    }
                    .fixedSize()
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("머리말 포함", isOn: $border.headerInside)
                        Toggle("꼬리말 포함", isOn: $border.footerInside)
                    }
                    .disabled(border.paper)
                }
            }
            .padding(.leading, 12)
            LabeledField("적용 쪽") { ChoiceField($border.borderPages, Self.pages, minWidth: 90) }
        }
    }

    /// 미리 보기 with the side buttons around it: 위쪽 above, 왼쪽 and 오른쪽 beside, 아래쪽
    /// and 모두 below.
    private var preview: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                sideButton("위쪽", [2])
            }
            GridRow {
                sideButton("왼쪽", [0])
                Canvas { context, size in
                    let page = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                    context.fill(Path(page), with: .color(.white))
                    if let fill = border.fill, fill.color != "none" {
                        context.fill(Path(page.insetBy(dx: 8, dy: 8)), with: .color(HexColor.color(fill.color)))
                    }
                    context.stroke(Path(page), with: .color(Color(nsColor: .separatorColor)))
                    let box = page.insetBy(dx: 8, dy: 8)
                    let ends = [(CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.maxY)),
                                (CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)),
                                (CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY)),
                                (CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY))]
                    for (side, (from, to)) in zip(border.sides, ends) {
                        LineFields.stroke(context, side, from, to)
                    }
                }
                .frame(width: 110, height: 140)
                sideButton("오른쪽", [1])
            }
            GridRow {
                sideButton("모두", [0, 1, 2, 3])
                sideButton("아래쪽", [3])
            }
        }
    }
    /// A side button: puts the line on its sides, or takes it back off.
    private func sideButton(_ title: String, _ sides: [Int]) -> some View {
        let down = sides.allSatisfy(pressed.contains)
        return Button {
            for side in sides {
                if down {
                    border.sides[side] = previous[side]
                    pressed.remove(side)
                } else if !pressed.contains(side) {
                    previous[side] = border.sides[side]
                    border.sides[side] = line
                    pressed.insert(side)
                }
            }
        } label: {
            SideIcon(sides: sides)
        }
        .choice(down)
        .help(title)
        .accessibilityLabel(title)
    }
    @ViewBuilder private func gap(_ title: String, _ side: Int) -> some View {
        FieldLabel(title)
        SpinField(value: Binding { Units.millimeters(border.spacing[side]) } set: { border.spacing[side] = Units.units($0) },
                  unit: "mm", range: 0...25)
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupTitle("채우기")
            FillFields(fill: $border.fill).padding(.leading, 12)
            HStack(spacing: 28) {
                LabeledField("적용 쪽") { ChoiceField($border.fillPages, Self.pages, minWidth: 90) }
                LabeledField("채울 영역") {
                    ChoiceField($border.fillArea, [(.paper, "종이"), (.page, "쪽"), (.border, "테두리")], minWidth: 70)
                }
            }
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
}

/// A line's 종류, 굵기 and 색.
struct LineFields: View {
    @Binding var line: BorderSide
    /// Draws `side` from `from` to `to` in a 미리 보기, roughly as the page will.
    static func stroke(_ context: GraphicsContext, _ side: BorderSide, _ from: CGPoint, _ to: CGPoint) {
        guard side.line != 0 else { return }
        let width = Swatches.widths[min(Int(side.width), Swatches.widths.count - 1)]
        let dash: [CGFloat] = switch side.line { case 2: [5, 3]; case 3: [1.5, 2]; case 4, 5: [7, 2, 1.5, 2]; case 6: [12, 5]; default: [] }
        context.stroke(Path { $0.move(to: from); $0.addLine(to: to) }, with: .color(HexColor.color(side.color)),
                       style: StrokeStyle(lineWidth: max(1, width * 2), dash: dash))
    }
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                FieldLabel("종류")
                ChoiceField(Binding { Int(line.line) } set: { line.line = UInt8($0) },
                            Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds, minWidth: 100)
            }
            GridRow {
                FieldLabel("굵기")
                ChoiceField(Binding { Int(line.width) } set: { line.width = UInt8($0) },
                            Swatches.widths.indices.map { ($0, "") }, images: Swatches.widthImages, minWidth: 100)
            }
            GridRow {
                FieldLabel("색")
                ColorWell(hex: $line.color)
            }
        }
    }
}

/// 채우기: 색 채우기 없음, or 색 with 면 색, 무늬 색 and 무늬 모양. No fill is a 그러데이션 or
/// 그림, kept as it is until one is chosen.
struct FillFields: View {
    @Binding var fill: PageFill?
    /// 셀·표 배경 also take a 그러데이션 or a 그림.
    var extended = false
    @State private var file: String?

    /// 그림 채우기 유형, in the engine's order.
    private static let modes = ["바둑판식으로-모두", "바둑판식으로-가로/위", "바둑판식으로-가로/아래", "바둑판식으로-세로/왼쪽",
                                "바둑판식으로-세로/오른쪽", "크기에 맞추어", "가운데로", "가운데 위로", "가운데 아래로",
                                "왼쪽 가운데로", "왼쪽 위로", "왼쪽 아래로", "오른쪽 가운데로", "오른쪽 위로", "오른쪽 아래로"]
    /// 0 색 채우기 없음, 1 색, 2 그러데이션, 3 그림; -1 for a fill shown as none of them.
    private var kind: Int {
        guard let fill else { return -1 }
        if fill.gradient != nil { return 2 }
        if fill.image != nil { return 3 }
        return fill.color == "none" && fill.pattern == 0 ? 0 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding { kind } set: { choose($0) }) {
                Text("색 채우기 없음").tag(0)
                Text("색").tag(1)
                if extended {
                    Text("그러데이션").tag(2)
                    Text("그림").tag(3)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            switch kind {
            case 2: gradientFields.padding(.leading, 20)
            case 3: imageFields.padding(.leading, 20)
            default: colorFields.padding(.leading, 20).disabled(kind != 1)
            }
        }
    }
    private func choose(_ kind: Int) {
        var new = fill ?? PageFill(color: "none", patternColor: "#000000", pattern: 0)
        (new.gradient, new.image) = (nil, nil)
        switch kind {
        case 0: (new.color, new.pattern) = ("none", 0)
        case 2: new.gradient = Gradient()
        case 3: return pickImage()
        default: if new.color == "none" { new.color = "#ffffff" }
        }
        fill = new
    }
    private var colorFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                FieldLabel("면 색")
                ColorWell(hex: color(\.color, "#ffffff"))
            }
            GridRow {
                FieldLabel("무늬 색")
                ColorWell(hex: color(\.patternColor, "#000000"))
            }
            GridRow {
                FieldLabel("무늬 모양")
                ChoiceField(Binding { Int(fill?.pattern ?? 0) } set: { fill?.pattern = UInt8($0) },
                            Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns, minWidth: 100)
            }
        }
    }
    private var gradientFields: some View {
        let g = Binding { fill?.gradient ?? Gradient() } set: { fill?.gradient = $0 }
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                FieldLabel("시작 색")
                ColorWell(hex: Binding { g.wrappedValue.colors[0] } set: { g.wrappedValue.colors[0] = $0 })
                FieldLabel("끝 색")
                ColorWell(hex: Binding { g.wrappedValue.colors[1] } set: { g.wrappedValue.colors[1] = $0 })
            }
            GridRow {
                FieldLabel("모양")
                ChoiceField(Binding { g.wrappedValue.kind } set: { g.wrappedValue.kind = $0 },
                            [(UInt8(1), "줄무늬"), (2, "원형"), (3, "원뿔형"), (4, "사각형")], minWidth: 90)
                FieldLabel("기울임")
                SpinField(value: number(g, \.angle), unit: "°", range: 0...359)
            }
            GridRow {
                FieldLabel("가로 중심")
                SpinField(value: number(g, \.centerX), unit: "%", range: 0...100)
                FieldLabel("세로 중심")
                SpinField(value: number(g, \.centerY), unit: "%", range: 0...100)
            }
            GridRow {
                FieldLabel("번짐 정도")
                SpinField(value: number(g, \.blur), unit: "", range: 0...255)
                FieldLabel("번짐 중심")
                SpinField(value: number(g, \.stepCenter), unit: "", range: 0...100)
            }
        }
    }
    private var imageFields: some View {
        let i = Binding { fill?.image ?? ImageBrush() } set: { fill?.image = $0 }
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                FieldLabel("그림 파일")
                HStack {
                    Text(file ?? "").lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                    Button("그림 선택…") { pickImage() }
                }
            }
            GridRow {
                FieldLabel("채우기 유형")
                ChoiceField(Binding { Int(i.wrappedValue.mode) } set: { i.wrappedValue.mode = UInt8($0) },
                            Array(Self.modes.enumerated()).map { ($0.offset, $0.element) }, minWidth: 160)
            }
            GridRow {
                FieldLabel("그림 효과")
                ChoiceField(Binding { i.wrappedValue.effect } set: { i.wrappedValue.effect = $0 },
                            [(UInt8(0), "원래 그림"), (1, "회색조"), (2, "흑백")], minWidth: 100)
            }
            GridRow {
                FieldLabel("밝기")
                SpinField(value: number(i, \.brightness), unit: "%", range: -100...100)
            }
            GridRow {
                FieldLabel("대비")
                SpinField(value: number(i, \.contrast), unit: "%", range: -100...100)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("워터마크 효과", isOn: Binding { i.wrappedValue.brightness == 70 && i.wrappedValue.contrast == -50 } set: {
                    (i.wrappedValue.brightness, i.wrappedValue.contrast) = $0 ? (70, -50) : (0, 0)
                })
            }
        }
    }
    /// 그림 선택: an image file for the 배경, kept in the document.
    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        var new = fill ?? PageFill(color: "none", patternColor: "#000000", pattern: 0)
        new.gradient = nil
        var image = new.image ?? ImageBrush()
        (image.data, image.extension, image.binId) = (data, url.pathExtension.lowercased(), 0)
        new.image = image
        fill = new
        file = url.lastPathComponent
    }
    private func number<T, V: BinaryInteger>(_ value: Binding<T>, _ key: WritableKeyPath<T, V>) -> Binding<Double> {
        Binding { Double(value.wrappedValue[keyPath: key]) } set: { value.wrappedValue[keyPath: key] = V(clamping: Int($0.rounded())) }
    }
    private func color(_ key: WritableKeyPath<PageFill, String>, _ fallback: String) -> Binding<String> {
        Binding { fill.map { $0[keyPath: key] }.flatMap { $0 == "none" ? nil : $0 } ?? fallback } set: {
            fill?[keyPath: key] = $0
        }
    }
}

/// 주석 모양: 각주 모양 and 미주 모양 tabs, and 적용 범위.
struct NoteShapeSheet: View {
    let section: UInt32
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    private let original: [NoteShape]
    /// 각주 모양 then 미주 모양.
    @State private var shapes: [NoteShape]
    @State private var tab: String
    @State private var whole = true

    /// 번호 모양, in the dialog's order; 미주 takes all but the last.
    private static let formats: [(String, String)] = [
        ("digit", "1,2,3"), ("circledDigit", "①,②,③"), ("upperRoman", "I,II,III"), ("lowerRoman", "i,ii,iii"),
        ("upperAlpha", "A,B,C"), ("lowerAlpha", "a,b,c"), ("circledUpperAlpha", "Ⓐ,Ⓑ,Ⓒ"), ("circledLowerAlpha", "ⓐ,ⓑ,ⓒ"),
        ("hangulSyllable", "가,나,다"), ("circledHangulSyllable", "㉮,㉯,㉰"), ("hangulJamo", "ㄱ,ㄴ,ㄷ"),
        ("circledHangulJamo", "㉠,㉡,㉢"), ("hangulDigit", "일,이,삼"), ("hanjaDigit", "一,二,三"),
        ("circledHanjaDigit", "㊀,㊁,㊂"), ("hanjaGapEul", "갑,을,병"), ("hanjaGapEulHanja", "甲,乙,丙"),
        ("fourSymbol", "*,†,‡,§"),
    ]

    init(section: UInt32, footnote: NoteShape, endnote: NoteShape, viewer: Viewer, tab: String = "각주 모양") {
        self.section = section
        self.viewer = viewer
        original = [footnote, endnote]
        _shapes = State(initialValue: [footnote, endnote])
        _tab = State(initialValue: tab)
    }

    var body: some View {
        DialogFrame("주석 모양", confirmTitle: "설정") {
            DialogTabs(selection: $tab, titles: ["각주 모양", "미주 모양"]) { tab in
                page(tab == "각주 모양" ? 0 : 1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 22)
            }
            .frame(width: 520, height: 372)
            HStack(spacing: 10) {
                Text("적용 범위")
                ChoiceField($whole, [(true, "문서 전체"), (false, "현재 구역")], minWidth: 100).fixedSize()
            }
        } confirm: {
            for kind in 0..<2 where shapes[kind] != original[kind] {
                viewer.setNoteShape(shapes[kind], footnote: kind == 0, section: section, whole: whole)
            }
            dismiss()
        }
    }

    private func page(_ kind: Int) -> some View {
        let name = kind == 0 ? "각주" : "미주"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("번호 서식")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("번호 모양")
                            ChoiceField($shapes[kind].numberFormat, Array(Self.formats.prefix(kind == 0 ? 18 : 17)), minWidth: 90)
                        }
                        GridRow {
                            FieldLabel("앞 장식 문자")
                            character($shapes[kind].prefixChar)
                        }
                        GridRow {
                            FieldLabel("뒤 장식 문자")
                            character($shapes[kind].suffixChar)
                        }
                    }
                    .padding(.leading, 12)
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("여백")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow { margin("구분선 위", $shapes[kind].separatorMarginTop) }
                        GridRow { margin("구분선 아래", $shapes[kind].separatorMarginBottom) }
                        GridRow { margin("\(name) 사이", $shapes[kind].noteSpacing) }
                    }
                    .padding(.leading, 12)
                }
            }
            Toggle("구분선 넣기", isOn: Binding { shapes[kind].separatorEnabled } set: { on in
                shapes[kind].separatorEnabled = on
                if on && shapes[kind].separatorLineType == 0 {
                    (shapes[kind].separatorLength, shapes[kind].separatorLineType, shapes[kind].separatorLineWidth) = (-1, 1, 1)
                }
            })
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("길이")
                    SpinField(value: length(kind), unit: "mm", range: 0...100)
                    FieldLabel("종류")
                    ChoiceField(Binding { Int(shapes[kind].separatorLineType) } set: { shapes[kind].separatorLineType = UInt8($0) },
                                Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds, minWidth: 100)
                }
                GridRow {
                    FieldLabel("굵기")
                    ChoiceField(Binding { Int(shapes[kind].separatorLineWidth) } set: { shapes[kind].separatorLineWidth = UInt8($0) },
                                Swatches.widths.indices.map { ($0, "") }, images: Swatches.widthImages, minWidth: 100)
                    FieldLabel("색")
                    ColorWell(hex: $shapes[kind].separatorColor)
                }
            }
            .fixedSize()
            .padding(.leading, 12)
            .disabled(!shapes[kind].separatorEnabled)
            GroupTitle("번호 매기기")
            Picker("", selection: $shapes[kind].numbering) {
                Text("앞 구역에 이어서").tag("continue")
                Text("현재 구역부터 새로 시작").tag("restartSection")
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .padding(.leading, 12)
        }
    }
    /// One character, as 기호 모양 and the 장식 문자 take.
    private func character(_ text: Binding<String>) -> some View {
        TextField("", text: Binding { text.wrappedValue } set: { text.wrappedValue = String($0.suffix(1)) })
            .frame(width: 44)
    }
    @ViewBuilder private func margin(_ title: String, _ value: Binding<Int32>) -> some View {
        FieldLabel(title)
        SpinField(value: Binding { Units.millimeters(value.wrappedValue) } set: { value.wrappedValue = Units.units($0) },
                  unit: "mm", range: 0...25)
    }
    /// 구분선 길이 in millimeters; 5 cm and 2 cm are stored as their own values.
    private func length(_ kind: Int) -> Binding<Double> {
        Binding {
            switch shapes[kind].separatorLength {
            case -1: 50
            case -2: 20
            case let raw: Units.millimeters(max(raw, 0))
            }
        } set: { shapes[kind].separatorLength = Units.units($0) }
    }
}

/// 구역 설정: 시작 쪽 번호, 개체 시작 번호, 기타 and 적용 범위.
struct SectionSheet: View {
    let section: UInt32
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var setup: SectionSetup
    @State private var whole = true

    init(section: UInt32, setup: SectionSetup, viewer: Viewer) {
        self.section = section
        self.viewer = viewer
        _setup = State(initialValue: setup)
    }

    var body: some View {
        DialogFrame("구역 설정", confirmTitle: "설정") {
            VStack(alignment: .leading, spacing: 14) {
                GroupTitle("시작 쪽 번호")
                HStack(spacing: 10) {
                    FieldLabel("종류")
                    ChoiceField(Binding { setup.pageNum > 0 ? 3 : Int(setup.pageNumType) } set: { kind in
                        if kind == 3 {
                            (setup.pageNum, setup.pageNumType) = (max(setup.pageNum, 1), 0)
                        } else {
                            (setup.pageNum, setup.pageNumType) = (0, UInt8(kind))
                        }
                    }, [(0, "이어서"), (1, "홀수"), (2, "짝수"), (3, "사용자")], minWidth: 70)
                    SpinField(value: number(\.pageNum), unit: "", range: 1...65535, digits: 0)
                        .disabled(setup.pageNum == 0)
                }
                .padding(.leading, 12)
                GroupTitle("개체 시작 번호")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    start("그림", \.pictureNum)
                    start("표", \.tableNum)
                    start("수식", \.equationNum)
                }
                .padding(.leading, 12)
                GroupTitle("기타")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("첫 쪽에만 머리말/꼬리말 감추기", isOn: Binding { setup.hideHeader && setup.hideFooter } set: {
                        (setup.hideHeader, setup.hideFooter) = ($0, $0)
                    })
                    Toggle("첫 쪽에만 바탕쪽 감추기", isOn: $setup.hideMasterPage)
                    Toggle("첫 쪽에만 테두리/배경 감추기", isOn: Binding { setup.hideBorder && setup.hideFill } set: {
                        (setup.hideBorder, setup.hideFill) = ($0, $0)
                    })
                    Toggle("빈 줄 감추기", isOn: $setup.hideEmptyLine)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("단 사이 간격")
                            SpinField(value: Binding { Units.millimeters(setup.columnSpacing) } set: { setup.columnSpacing = Units.units($0) },
                                      unit: "mm", range: 0...100)
                        }
                        GridRow {
                            FieldLabel("기본 탭 간격")
                            // Stored at 200 to the point: 8000 is 한/글's 40pt.
                            SpinField(value: Binding { Double(setup.defaultTabSpacing) / 200 } set: {
                                setup.defaultTabSpacing = UInt32(($0 * 200).rounded())
                            }, unit: "pt", range: 1...141)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.leading, 12)
                Divider()
                HStack(spacing: 10) {
                    Text("적용 범위")
                    ChoiceField($whole, [(true, "문서 전체"), (false, "현재 구역")], minWidth: 100).fixedSize()
                }
            }
        } confirm: {
            viewer.setSection(setup, section: section, whole: whole)
            dismiss()
        }
    }

    /// 이어서 or 사용자 and its number.
    private func start(_ title: String, _ key: WritableKeyPath<SectionSetup, UInt16>) -> some View {
        GridRow {
            FieldLabel(title)
            ChoiceField(Binding { setup[keyPath: key] > 0 } set: { setup[keyPath: key] = $0 ? max(setup[keyPath: key], 1) : 0 },
                        [(false, "이어서"), (true, "사용자")], minWidth: 70)
            SpinField(value: number(key), unit: "", range: 1...65535, digits: 0)
                .disabled(setup[keyPath: key] == 0)
        }
    }
    private func number(_ key: WritableKeyPath<SectionSetup, UInt16>) -> Binding<Double> {
        Binding { Double(max(setup[keyPath: key], 1)) } set: { setup[keyPath: key] = UInt16($0) }
    }
}

/// 용지 방향 and 제본 as the web dialog draws them: a page with lines of text, and pages
/// with 가 (and 나) by their bound edge.
private enum PagePictogram {
    /// A page with `count` columns of lines.
    static func columns(_ count: Int, on: Bool) -> some View {
        Canvas { context, size in
            let ink: Color = on ? .accentColor : .secondary
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
    static func orientation(_ landscape: Bool, on: Bool) -> some View {
        Canvas { context, size in
            let ink: Color = on ? .accentColor : .secondary
            let (w, h) = landscape ? (size.width * 0.9, size.height * 0.62) : (size.width * 0.62, size.height * 0.9)
            let page = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            context.stroke(Path(page), with: .color(ink), lineWidth: 1)
            for y in stride(from: page.minY + 4, to: page.maxY - 3, by: 3) {
                context.fill(Path(CGRect(x: page.minX + 4, y: y, width: page.width - 8, height: 1)), with: .color(ink))
            }
        }
    }
    static func binding(_ binding: UInt8, on: Bool) -> some View {
        Canvas { context, size in
            let ink: Color = on ? .accentColor : .secondary
            let font = Font.system(size: binding == 1 ? 8 : 13, weight: .medium)
            let page = CGRect(x: size.width * 0.18, y: size.height * 0.05, width: size.width * 0.64, height: size.height * 0.9)
            switch binding {
            case 1:
                let wide = CGRect(x: size.width * 0.05, y: page.minY, width: size.width * 0.9, height: page.height)
                context.stroke(Path(wide), with: .color(ink), lineWidth: 1)
                context.stroke(Path { $0.move(to: CGPoint(x: wide.midX, y: wide.minY)); $0.addLine(to: CGPoint(x: wide.midX, y: wide.maxY)) },
                               with: .color(ink), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                context.draw(Text("가").font(font).foregroundColor(ink), at: CGPoint(x: wide.minX + wide.width / 4, y: wide.midY))
                context.draw(Text("나").font(font).foregroundColor(ink), at: CGPoint(x: wide.maxX - wide.width / 4, y: wide.midY))
            default:
                context.stroke(Path(page), with: .color(ink), lineWidth: 1)
                let top = binding == 2
                let marks = top
                    ? stride(from: page.minX + 3, to: page.maxX - 1, by: 4).map { CGRect(x: $0, y: page.minY - 1.5, width: 1, height: 3) }
                    : stride(from: page.minY + 3, to: page.maxY - 1, by: 4).map { CGRect(x: page.minX - 1.5, y: $0, width: 3, height: 1) }
                for mark in marks { context.fill(Path(mark), with: .color(ink)) }
                context.draw(Text("가").font(font).foregroundColor(ink), at: CGPoint(x: page.midX, y: page.midY))
            }
        }
    }
}

/// 문자표, as the web editor's: 문자 영역, 문자 선택, 최근 사용한 문자 and 입력 문자; 넣기 puts
/// 입력 문자 at the caret.
struct SymbolSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var area = 0
    @State private var text = ""
    @AppStorage("recentSymbols") private var recent = ""

    /// 문자 영역 in the web editor's names and order. 일반 문장 부호 is the web editor's set,
    /// 기호1 and 기호2 are KS X 1001's first two rows.
    /// ponytail: the others are their Unicode blocks narrowed to KS X 1001 and Windows-1252,
    /// which gives the web editor's 일반 문장 부호 and 상자 그리기; Hancom's own tables may differ.
    static let areas: [(name: String, characters: [String])] = [
        ("일반 문장 부호", "–—―‘’‚“”„†‡•‥…‰′″‹›※‧"),
        ("기호1", "、。·‥…¨〃―∥＼∼‘’“”〔〕〈〉《》「」『』【】±×÷≠≤≥∞∴°′″℃Å￠￡￥♂♀∠⊥⌒∂∇≡≒§※☆★○●◎◇◆□■△▲▽▼→←↑↓↔〓≪≫√∽∝∵∫∬∈∋⊆⊇⊂⊃∪∩∧∨￢"),
        ("기호2", "⇒⇔∀∃´～ˇ˘˝˚˙¸˛¡¿ː∮∑∏¤℉‰◁◀▷▶♤♠♡♥♧♣⊙◈▣◐◑▒▤▥▨▧▦▩♨☏☎☜☞¶†‡↕↗↙↖↘♭♩♪♬㉿㈜№㏇™㏂㏘℡€®"),
        ("통화 기호", "€"),
        ("글자 모양 기호", "℃℉ℓ№℡™ΩÅ"),
        ("숫자 형식", "⅓⅔⅛⅜⅝⅞ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ"),
        ("화살표", "←↑→↓↔↕↖↗↘↙⇒⇔"),
        ("괄호", "()[]{}〈〉《》「」『』【】〔〕"),
        ("수학 연산자", "∀∂∃∇∈∋∏∑√∝∞∠∥∧∨∩∪∫∬∮∴∵∼∽≒≠≡≤≥≪≫⊂⊃⊆⊇⊙⊥"),
        ("그리스어", "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩαβγδεζηθικλμνξοπρστυφχψω"),
        ("단위기호", "㎀㎁㎂㎃㎄㎈㎉㎊㎋㎌㎍㎎㎏㎐㎑㎒㎓㎔㎕㎖㎗㎘㎙㎚㎛㎜㎝㎞㎟㎠㎡㎢㎣㎤㎥㎦㎧㎨㎩㎪㎫㎬㎭㎮㎯㎰㎱㎲㎳㎴㎵㎶㎷㎸㎹㎺㎻㎼㎽㎾㎿㏀㏁㏂㏃㏄㏅㏆㏇㏈㏉㏊㏏㏐㏓㏖㏘㏛㏜㏝"),
        ("원문자", "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮ⓐⓑⓒⓓⓔⓕⓖⓗⓘⓙⓚⓛⓜⓝⓞⓟⓠⓡⓢⓣⓤⓥⓦⓧⓨⓩ㉠㉡㉢㉣㉤㉥㉦㉧㉨㉩㉪㉫㉬㉭㉮㉯㉰㉱㉲㉳㉴㉵㉶㉷㉸㉹㉺㉻㉿"),
        ("괄호문자", "⑴⑵⑶⑷⑸⑹⑺⑻⑼⑽⑾⑿⒀⒁⒂⒜⒝⒞⒟⒠⒡⒢⒣⒤⒥⒦⒧⒨⒩⒪⒫⒬⒭⒮⒯⒰⒱⒲⒳⒴⒵㈀㈁㈂㈃㈄㈅㈆㈇㈈㈉㈊㈋㈌㈍㈎㈏㈐㈑㈒㈓㈔㈕㈖㈗㈘㈙㈚㈛㈜"),
        ("상자 그리기", "─━│┃┌┍┎┏┐┑┒┓└┕┖┗┘┙┚┛├┝┞┟┠┡┢┣┤┥┦┧┨┩┪┫┬┭┮┯┰┱┲┳┴┵┶┷┸┹┺┻┼┽┾┿╀╁╂╃╄╅╆╇╈╉╊╋"),
        ("도형", "■□▣▤▥▦▧▨▩▲△▶▷▼▽◀◁◆◇◈○◎●◐◑"),
        ("기타 기호", "★☆☎☏☜☞♀♂♠♡♣♤♥♧♨♩♪♬♭"),
        ("한중일 기호 및 구두점", "、。〃〈〉《》「」『』【】〓〔〕"),
        ("호환용 한글 자모", "ㄱㄲㄳㄴㄵㄶㄷㄸㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅃㅄㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣㅥㅦㅧㅨㅩㅪㅫㅬㅭㅮㅯㅰㅱㅲㅳㅴㅵㅶㅷㅸㅹㅺㅻㅼㅽㅾㅿㆀㆁㆂㆃㆄㆅㆆㆇㆈㆉㆊㆋㆌㆍㆎ"),
    ].map { ($0.0, $0.1.map(String.init)) }
    private static let columns = Array(repeating: GridItem(.fixed(30), spacing: 0), count: 11)

    var body: some View {
        DialogFrame("문자표", confirmTitle: "넣기", canConfirm: !text.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupTitle("문자 영역")
                        List(Self.areas.indices, id: \.self, selection: Binding { area } set: { area = $0 ?? area }) {
                            Text(Self.areas[$0].name)
                        }
                        .listStyle(.bordered)
                        .frame(width: 180, height: 372)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        GroupTitle("문자 선택")
                        ScrollView {
                            cells(Self.areas[area].characters)
                        }
                        .frame(width: 346, height: 270, alignment: .topLeading)
                        .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
                        GroupTitle("최근 사용한 문자").padding(.top, 8)
                        cells(recent.map(String.init))
                            .frame(width: 346, height: 32, alignment: .topLeading)
                            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
                    }
                }
                HStack(spacing: 10) {
                    GroupTitle("입력 문자")
                    TextField("", text: $text).textFieldStyle(.roundedBorder)
                }
            }
        } confirm: {
            viewer.document?.type(text, viewer.undoManager)
            let used = text.reduce(into: [Character]()) { if !$0.contains($1) { $0.append($1) } }
            recent = String((used + recent.filter { !used.contains($0) }).prefix(11))
            dismiss()
        }
    }

    /// Characters in a grid; choosing one adds it to 입력 문자.
    private func cells(_ characters: [String]) -> some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 0) {
            ForEach(characters, id: \.self) { character in
                Button { text += character } label: {
                    Text(character).font(.system(size: 17)).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
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

/// 셀 테두리/배경 as opened: 하나의 셀처럼 (`one`) or each cell, over a block or not, from
/// the caret's cell.
struct CellBorderEditing: Identifiable {
    let id = UUID()
    let one: Bool
    let block: Bool
    let border: CellBorder
    let tab: String
}

/// [셀 테두리/배경]: 테두리, 배경 and 대각선 tabs; 적용 범위 for 각 셀마다 적용. Only what is
/// changed here changes in the cells.
struct CellBorderSheet: View {
    let editing: CellBorderEditing
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var tab: String
    /// 왼쪽, 오른쪽, 위쪽, 아래쪽, 가로 and 세로 as shown.
    @State private var sides: [BorderSide]
    @State private var touched: Set<Int> = []
    @State private var fill: PageFill?
    @State private var diagonal: Diagonal
    @State private var all: Bool
    /// The 종류, 굵기 and 색 the side buttons put on.
    @State private var line: BorderSide
    /// 선 모양 바로 적용: changing the line changes the sides whose button is down.
    @State private var instant = true
    @State private var pressed: Set<Int> = []
    /// Each side's line before its button last put one on.
    @State private var previous: [BorderSide]
    /// 표 테두리/배경, opened over this dialog.
    @State private var table: ObjectSheetState?

    private static let none = BorderSide(line: 0, width: 0, color: "#000000")

    init(editing: CellBorderEditing, viewer: Viewer) {
        self.editing = editing
        self.viewer = viewer
        let b = editing.border
        let shown = b.sides.prefix(4).map { $0 ?? Self.none }
        // Inside a block the 가로 and 세로 lines start as the caret cell's 아래쪽 and 오른쪽.
        let sides = shown + [shown[3], shown[1]]
        _tab = State(initialValue: editing.tab)
        _sides = State(initialValue: sides)
        _fill = State(initialValue: b.fill)
        _diagonal = State(initialValue: b.diagonal ?? Diagonal(line: BorderSide(line: 1, width: 0, color: "#000000"),
                                                                 slash: false, backSlash: false, center: 0))
        _all = State(initialValue: !editing.block)
        _line = State(initialValue: sides.first { $0.line != 0 } ?? BorderSide(line: 1, width: 0, color: "#000000"))
        _previous = State(initialValue: sides)
    }

    var body: some View {
        DialogFrame("셀 테두리/배경", confirmTitle: "설정") {
            DialogTabs(selection: $tab, titles: ["테두리", "배경", "대각선"]) { tab in
                Group {
                    switch tab {
                    case "배경": FillFields(fill: $fill, extended: true).padding(.leading, 12)
                    case "대각선": diagonals
                    default: lines
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 22)
            }
            .frame(width: 520, height: 330)
            HStack(spacing: 10) {
                if !editing.one {
                    Text("적용 범위")
                    ChoiceField($all, editing.block ? [(true, "모든 셀"), (false, "선택된 셀")] : [(true, "모든 셀")], minWidth: 100)
                        .fixedSize()
                }
                Spacer()
                Button("표 테두리/배경…") { Task { table = await viewer.tableSheet() } }
            }
        } confirm: {
            var border = CellBorder()
            for side in touched { border.sides[side] = sides[side] }
            if fill != editing.border.fill { border.fill = fill }
            if diagonal != editing.border.diagonal { border.diagonal = diagonal }
            viewer.setCellBorder(border, all: all, one: editing.one)
            dismiss()
        }
        .onChange(of: line) { _, line in
            guard instant else { return }
            for side in pressed {
                sides[side] = line
                touched.insert(side)
            }
        }
        .sheet(item: $table) { TableBorderSheet(state: $0, viewer: viewer) }
    }

    /// The sides a block shows: its outside, and inside it for 각 셀마다 적용.
    private var shown: [Int] { editing.one ? [0, 1, 2, 3] : [0, 1, 2, 3, 4, 5] }

    private var lines: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("테두리")
                LineFields(line: $line).padding(.leading, 12)
                Toggle("선 모양 바로 적용", isOn: $instant).padding(.leading, 12)
            }
            preview
        }
    }

    /// 미리 보기 with the side buttons around it: the lines across above, the lines down
    /// beside, and 모두, 바깥쪽 and 안쪽 below.
    private var preview: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                HStack(spacing: 4) {
                    sideButton("위쪽", [2])
                    if !editing.one { sideButton("가로", [4]) }
                    sideButton("아래쪽", [3])
                }
                .gridCellAnchor(.bottom)
            }
            GridRow {
                VStack(spacing: 4) {
                    sideButton("왼쪽", [0])
                    if !editing.one { sideButton("세로", [5]) }
                    sideButton("오른쪽", [1])
                }
                .gridCellAnchor(.trailing)
                Canvas { context, size in
                    let box = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                    let split = !editing.one
                    let cells = split ? [CGRect(x: box.minX, y: box.minY, width: box.width / 2, height: box.height / 2),
                                         CGRect(x: box.midX, y: box.minY, width: box.width / 2, height: box.height / 2),
                                         CGRect(x: box.minX, y: box.midY, width: box.width / 2, height: box.height / 2),
                                         CGRect(x: box.midX, y: box.midY, width: box.width / 2, height: box.height / 2)] : [box]
                    for cell in cells {
                        if let fill, fill.color != "none" { context.fill(Path(cell), with: .color(HexColor.color(fill.color))) }
                        let d = diagonal
                        var marks: [(CGPoint, CGPoint)] = []
                        if d.center == 0 {
                            if d.backSlash { marks.append((CGPoint(x: cell.minX, y: cell.minY), CGPoint(x: cell.maxX, y: cell.maxY))) }
                            if d.slash { marks.append((CGPoint(x: cell.minX, y: cell.maxY), CGPoint(x: cell.maxX, y: cell.minY))) }
                        }
                        if d.center & 1 != 0 { marks.append((CGPoint(x: cell.minX, y: cell.midY), CGPoint(x: cell.maxX, y: cell.midY))) }
                        if d.center & 2 != 0 { marks.append((CGPoint(x: cell.midX, y: cell.minY), CGPoint(x: cell.midX, y: cell.maxY))) }
                        for (from, to) in marks { LineFields.stroke(context, d.line, from, to) }
                    }
                    LineFields.stroke(context, sides[0], CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.maxY))
                    LineFields.stroke(context, sides[1], CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY))
                    LineFields.stroke(context, sides[2], CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY))
                    LineFields.stroke(context, sides[3], CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY))
                    if split {
                        LineFields.stroke(context, sides[4], CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY))
                        LineFields.stroke(context, sides[5], CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.midX, y: box.maxY))
                    }
                }
                .frame(width: 140, height: 140)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                HStack(spacing: 4) {
                    sideButton("모두", shown)
                    if !editing.one {
                        sideButton("바깥쪽", [0, 1, 2, 3])
                        sideButton("안쪽", [4, 5])
                    }
                }
            }
        }
    }
    /// A side button: puts the line on its sides, or takes it back off.
    private func sideButton(_ title: String, _ which: [Int]) -> some View {
        let down = which.allSatisfy(pressed.contains)
        return Button {
            for side in which {
                if down {
                    sides[side] = previous[side]
                    pressed.remove(side)
                } else if !pressed.contains(side) {
                    previous[side] = sides[side]
                    sides[side] = line
                    pressed.insert(side)
                }
                touched.insert(side)
            }
        } label: {
            SideIcon(sides: which)
        }
        .choice(down)
        .help(title)
        .accessibilityLabel(title)
    }

    private var diagonals: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("대각선")
                LineFields(line: $diagonal.line).padding(.leading, 12)
            }
            VStack(alignment: .leading, spacing: 10) {
                GroupTitle("＼ 대각선")
                HStack(spacing: 4) {
                    mark("대각선 없애기", on: !diagonal.backSlash, []) { diagonal.backSlash = false }
                    mark("＼ 대각선", on: diagonal.backSlash, [(0, 0, 1, 1)]) { (diagonal.backSlash, diagonal.center) = (true, 0) }
                }
                GroupTitle("／ 대각선")
                HStack(spacing: 4) {
                    mark("대각선 없애기", on: !diagonal.slash, []) { diagonal.slash = false }
                    mark("／ 대각선", on: diagonal.slash, [(0, 1, 1, 0)]) { (diagonal.slash, diagonal.center) = (true, 0) }
                }
                // rhwp keeps no 중심선 in a cell zone.
                if !editing.one { centers }
            }
        }
    }
    private var centers: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupTitle("＋ 중심선")
            HStack(spacing: 4) {
                let lines: [[(CGFloat, CGFloat, CGFloat, CGFloat)]] =
                    [[], [(0, 0.5, 1, 0.5)], [(0.5, 0, 0.5, 1)], [(0, 0.5, 1, 0.5), (0.5, 0, 0.5, 1)]]
                ForEach(0..<4) { center in
                    mark(["중심선 없애기", "가로 중심선", "세로 중심선", "가로세로 중심선"][center],
                         on: diagonal.center == center, lines[center]) {
                        diagonal.center = UInt8(center)
                        if center != 0 { (diagonal.slash, diagonal.backSlash) = (false, false) }
                    }
                }
            }
        }
    }
    /// A 대각선 or 중심선 button, drawn as its lines across a cell; one put on gets a line
    /// to draw with.
    private func mark(_ title: String, on: Bool, _ lines: [(CGFloat, CGFloat, CGFloat, CGFloat)],
                      action: @escaping () -> Void) -> some View {
        Button {
            action()
            if diagonal.line.line == 0 { diagonal.line.line = 1 }
        } label: {
            Canvas { context, size in
                let box = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
                context.stroke(Path(box), with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                for (x1, y1, x2, y2) in lines {
                    context.stroke(Path {
                        $0.move(to: CGPoint(x: box.minX + x1 * box.width, y: box.minY + y1 * box.height))
                        $0.addLine(to: CGPoint(x: box.minX + x2 * box.width, y: box.minY + y2 * box.height))
                    }, with: .color(.primary), lineWidth: 1.5)
                }
            }
            .frame(width: 22, height: 22)
            .padding(3)
        }
        .choice(on)
        .help(title)
        .accessibilityLabel(title)
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
