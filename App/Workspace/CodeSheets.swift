import SwiftUI

// Dialogs whose contents follow 한글's help (help.hancom.com): 새 번호로 시작, 현재 쪽만 감추기,
// 책갈피, 조판 부호 지우기 and 문서 정보.

extension Viewer {
    /// The body paragraph holding the caret: these codes go only there.
    fileprivate var bodyCaret: EditPosition? {
        guard let focus = document?.selection?.focus, focus.target.cell == nil, focus.target.note == nil,
              focus.target.headerFooter == nil else { return nil }
        return focus
    }
    func newNumber(_ kind: NumberKind, from number: UInt16) {
        guard let at = bodyCaret else { return NSSound.beep() }
        document?.edit(undoManager) { _ in .newNumber(at, numbering: kind, number: number) }
    }
    /// Opens 현재 쪽만 감추기 with what the caret paragraph hides now.
    func showPageHide() {
        guard let document, let at = bodyCaret else { return NSSound.beep() }
        Task {
            guard let hide = try? await document.pageHide(at.target) else { return NSSound.beep() }
            pageHide = hide
        }
    }
    func setPageHide(_ hide: PageHide) {
        guard let at = bodyCaret else { return NSSound.beep() }
        document?.edit(undoManager) { _ in .setPageHide(at.target, hide) }
    }
    func addBookmark(_ name: String) {
        guard let at = bodyCaret else { return NSSound.beep() }
        document?.edit(undoManager) { _ in .addBookmark(at, name: name) }
    }
    func changeBookmark(_ mark: Bookmark, name: String?) {
        document?.edit(undoManager) { _ in .changeBookmark(mark.position.target, control: mark.control, name: name) }
    }
    func go(to mark: Bookmark) { go(to: mark.position) }
    /// Moves the caret to `position` and typing back to the page.
    func go(to position: EditPosition) {
        document?.select { _ in .caret(position) }
        // After the click that asked for it, which focuses its list.
        DispatchQueue.main.async { [canvas] in canvas.window?.makeFirstResponder(canvas.editor) }
    }
    /// 조판 부호 지우기 in the selected range, or in the whole body.
    func eraseCodes(_ kinds: [CodeKind]) {
        document?.edit(undoManager) { selection in
            let range = selection.flatMap { $0.anchor != $0.focus ? $0 : nil }
            return .eraseCodes(range, kinds: kinds)
        }
    }
    func editClickHere(guide: String, memo: String, name: String, formEditable: Bool) {
        document?.edit(undoManager) { selection in
            selection.map { .editClickHere($0.focus, guide: guide, memo: memo, name: name, formEditable: formEditable) }
        }
    }
    /// 고치기: the selected object's properties, or the 누름틀 or 하이퍼링크 at the caret.
    func modify() {
        guard let document else { return }
        if document.object != nil { return showObjectProperties() }
        guard let caret = document.selection?.focus else { return NSSound.beep() }
        Task {
            if let found = try? await document.clickHere(at: caret) {
                fieldSheet = FieldEditing(existing: found)
            } else if let link = try? await document.hyperlink(at: caret) {
                hyperlinkSheet = HyperlinkEditing(existing: link, text: link.text, uri: link.uri)
            } else {
                NSSound.beep()
            }
        }
    }
    /// 입력 › 하이퍼링크: 하이퍼링크 고치기 in a link, otherwise a new one, its 표시할 문자열
    /// the selected text.
    func showHyperlink() {
        guard let document, let selection = document.selection else { return NSSound.beep() }
        Task {
            if let link = try? await document.hyperlink(at: selection.focus) {
                hyperlinkSheet = HyperlinkEditing(existing: link, text: link.text, uri: link.uri)
                return
            }
            let text = selection.anchor == selection.focus ? "" : (try? await document.text(of: selection)) ?? ""
            hyperlinkSheet = HyperlinkEditing(existing: nil, text: text, uri: "")
        }
    }
    func setHyperlink(_ editing: HyperlinkEditing, text: String, uri: String) {
        document?.edit(undoManager) { selection in
            guard let selection else { return nil }
            return editing.existing == nil
                ? .insertHyperlink(selection, text: text, uri: uri)
                : .editHyperlink(selection.focus, text: text, uri: uri)
        }
    }
    func removeHyperlink() {
        document?.edit(undoManager) { selection in selection.map { .removeHyperlink($0.focus) } }
    }
    func insertClickHere(guide: String, memo: String, name: String, formEditable: Bool) {
        document?.edit(undoManager) { selection in
            selection.map { .insertClickHere($0.ordered.start, guide: guide, memo: memo, name: name, formEditable: formEditable) }
        }
    }
    func replaceFont(language: UInt8?, from: String, to: String) {
        document?.edit(undoManager) { _ in .replaceFont(language: language, from: from, to: to) }
    }
    /// 모든 삽입 그림 저장하기: each picture's image in a chosen folder, named the name given
    /// and a serial number (image00001, image00002, …).
    func savePictures(_ pictures: [PictureInfo]) {
        guard let document else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "저장"
        let name = NSTextField(string: "image")
        let field = NSStackView(views: [NSTextField(labelWithString: "파일 이름"), name])
        field.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        name.widthAnchor.constraint(equalToConstant: 200).isActive = true
        panel.accessoryView = field
        panel.isAccessoryViewDisclosed = true
        Task {
            guard await panel.begin() == .OK, let folder = panel.url else { return }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            for (i, picture) in pictures.enumerated() {
                guard let file = try? await document.pictureFile(picture.object) else { return NSSound.beep() }
                let url = folder.appendingPathComponent(String(format: "%@%05d.%@", name.stringValue, i + 1, file.extension))
                do { try file.data.write(to: url) } catch { return NSSound.beep() }
            }
        }
    }
    /// 그림 삽입: each 연결 picture takes the image of the file chosen for it, into the document.
    func embedPictures(_ pictures: [PictureInfo]) {
        for picture in pictures {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.directoryURL = URL(fileURLWithPath: picture.path).deletingLastPathComponent()
            panel.nameFieldStringValue = URL(fileURLWithPath: picture.path).lastPathComponent
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return NSSound.beep() }
            document?.replacePicture(data, object: picture.object, undoManager)
        }
    }
    /// 모두 삽입: every 연결 picture takes its file, found by name in a chosen folder.
    func embedAllPictures(_ pictures: [PictureInfo]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = pictures.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        for picture in pictures {
            let url = folder.appendingPathComponent(URL(fileURLWithPath: picture.path).lastPathComponent)
            guard let data = try? Data(contentsOf: url) else { NSSound.beep(); continue }
            document?.replacePicture(data, object: picture.object, undoManager)
        }
    }
    /// 경로 바꾸기: the 연결 picture shows a chosen file.
    func relinkPicture(_ picture: PictureInfo) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: picture.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document?.edit(undoManager) { _ in .setPictureLink(picture.object, path: url.path) }
    }
    /// 그림 확장자 바꾸기: the 연결 pictures show the files of the same name with `ext`.
    func changeLinkExtension(_ pictures: [PictureInfo], to ext: String) {
        for picture in pictures {
            let path = (picture.path as NSString).deletingPathExtension + "." + ext
            document?.edit(undoManager) { _ in .setPictureLink(picture.object, path: path) }
        }
    }
    /// 그림 경로 복사: the 연결 pictures' paths, one a line.
    func copyLinkPaths(_ pictures: [PictureInfo]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pictures.map(\.path).joined(separator: "\n"), forType: .string)
    }
    /// 그림 목록 저장: 이름, 종류, 쪽 수 and 경로 of `pictures`, 쉼표, 탭 or 공백 구분.
    func savePictureList(_ pictures: [PictureInfo]) {
        let panel = NSSavePanel()
        let kinds = [("쉼표 구분(*.csv)", ",", "csv"), ("탭 구분(*.txt)", "\t", "txt"), ("공백 구분(*.txt)", " ", "txt")]
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItems(withTitles: kinds.map(\.0))
        let field = NSStackView(views: [NSTextField(labelWithString: "파일 형식"), kind])
        field.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = field
        panel.nameFieldStringValue = "그림 목록.csv"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsOtherFileTypes = true
        Task {
            guard await panel.begin() == .OK, var url = panel.url else { return }
            let (_, separator, ext) = kinds[kind.indexOfSelectedItem]
            url = url.deletingPathExtension().appendingPathExtension(ext)
            let rows = [["이름", "종류", "쪽 수", "경로"]] + pictures.map { [$0.name, $0.linked ? "연결" : "삽입", "\($0.page)", $0.path] }
            let text = rows.map { $0.joined(separator: separator) }.joined(separator: "\n") + "\n"
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
        }
    }
    /// 문서 암호's lengths: 5–44 for HWP, 1–255 for HWPX.
    var passwordLengths: ClosedRange<Int> {
        canvas.window?.representedURL?.pathExtension.lowercased() == "hwp" ? 5...44 : 1...255
    }
    /// Sets the 문서 암호 saving locks the document with; false (with a beep) when `current`
    /// is wrong.
    func setPassword(current: String?, new: String?) async -> Bool {
        guard let document, await document.setPassword(current: current, new: new, undoManager) else {
            NSSound.beep()
            return false
        }
        return true
    }
    func showDocumentInfo() {
        guard let document else { return }
        Task {
            guard let statistics = try? await document.statistics() else { return NSSound.beep() }
            documentInfo = DocumentInfo(url: canvas.window?.representedURL, statistics: statistics)
        }
    }
}

/// [문서 암호 설정]: 문서 암호 and 암호 확인, kept with the document when it is saved.
struct PasswordSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var again = ""

    var body: some View {
        let lengths = viewer.passwordLengths
        DialogFrame("문서 암호 설정", confirmTitle: "설정",
                    canConfirm: lengths.contains(password.count) && password == again) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    FieldLabel("문서 암호")
                    SecureField("", text: $password).frame(width: 200)
                }
                GridRow {
                    FieldLabel("암호 확인")
                    SecureField("", text: $again).frame(width: 200)
                }
            }
        } confirm: {
            Task { if await viewer.setPassword(current: nil, new: password) { dismiss() } }
        }
    }
}

/// [문서 암호 변경/해제]: 암호 변경 to 새 암호, or 암호 해제, given the 현재 암호.
struct PasswordChangeSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var change = true
    @State private var current = ""
    @State private var password = ""
    @State private var again = ""

    var body: some View {
        let lengths = viewer.passwordLengths
        DialogFrame("문서 암호 변경/해제", confirmTitle: "설정",
                    canConfirm: !current.isEmpty && (!change || (lengths.contains(password.count) && password == again))) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $change) {
                    Text("암호 변경").tag(true)
                    Text("암호 해제").tag(false)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        FieldLabel("현재 암호")
                        SecureField("", text: $current).frame(width: 200)
                    }
                    GridRow {
                        FieldLabel("새 암호")
                        SecureField("", text: $password).frame(width: 200)
                    }
                    .disabled(!change)
                    GridRow {
                        FieldLabel("암호 확인")
                        SecureField("", text: $again).frame(width: 200)
                    }
                    .disabled(!change)
                }
            }
        } confirm: {
            Task { if await viewer.setPassword(current: current, new: change ? password : nil) { dismiss() } }
        }
    }
}

/// 새 번호로 시작: 번호 종류 and 시작 번호.
struct NewNumberSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var kind = NumberKind.page
    @State private var number = 1.0

    var body: some View {
        DialogFrame("새 번호로 시작", confirmTitle: "넣기") {
            VStack(alignment: .leading, spacing: 12) {
                GroupTitle("번호 종류")
                Picker("", selection: $kind) {
                    ForEach(NumberKind.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.leading, 12)
                LabeledField("시작 번호") { SpinField(value: $number, unit: "", range: 0...65_535) }
            }
        } confirm: {
            viewer.newNumber(kind, from: UInt16(number))
            dismiss()
        }
    }
}

/// 현재 쪽만 감추기: 감출 내용.
struct PageHideSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State var hide: PageHide

    var body: some View {
        DialogFrame("현재 쪽만 감추기", confirmTitle: "설정") {
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("감출 내용")
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("머리말", isOn: $hide.header)
                    Toggle("꼬리말", isOn: $hide.footer)
                    Toggle("쪽 번호", isOn: $hide.pageNumber)
                    Toggle("쪽 테두리/배경", isOn: $hide.borderFill)
                    Toggle("바탕쪽", isOn: $hide.masterPage)
                }
                .padding(.leading, 12)
            }
        } confirm: {
            viewer.setPageHide(hide)
            dismiss()
        }
    }
}

/// 필드 입력 as opened: to put a 누름틀 in, or (`existing`) to 고치기 one.
struct FieldEditing: Identifiable {
    let id = UUID()
    var existing: ClickHere?
}

/// [필드 입력] › 누름틀: 입력할 내용의 안내문, 메모 내용, 필드 이름, 양식 모드에서 편집 가능.
struct FieldSheet: View {
    let viewer: Viewer
    /// 고치기 of this 누름틀, at the caret; nil puts a new one in.
    let editing: ClickHere?
    @Environment(\.dismiss) private var dismiss
    @State private var guide: String
    @State private var memo: String
    @State private var name: String
    @State private var formEditable: Bool
    init(viewer: Viewer, editing: ClickHere? = nil) {
        (self.viewer, self.editing) = (viewer, editing)
        _guide = State(initialValue: editing?.guide ?? "이곳을 마우스로 누르고 내용을 입력하세요.")
        _memo = State(initialValue: editing?.memo ?? "")
        _name = State(initialValue: editing?.name ?? "")
        _formEditable = State(initialValue: editing?.formEditable ?? false)
    }
    var body: some View {
        DialogFrame("필드 입력", confirmTitle: editing == nil ? "넣기" : "설정",
                    canConfirm: !guide.trimmingCharacters(in: .whitespaces).isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                GroupTitle("누름틀")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("입력할 내용의 안내문")
                        TextField("", text: $guide).frame(width: 280)
                    }
                    GridRow {
                        FieldLabel("메모 내용")
                        TextField("", text: $memo).frame(width: 280)
                    }
                    GridRow {
                        FieldLabel("필드 이름")
                        TextField("", text: $name).frame(width: 280)
                    }
                }
                Toggle("양식 모드에서 편집 가능", isOn: $formEditable)
            }
        } confirm: {
            if editing == nil {
                viewer.insertClickHere(guide: guide, memo: memo, name: name, formEditable: formEditable)
            } else {
                viewer.editClickHere(guide: guide, memo: memo, name: name, formEditable: formEditable)
            }
            dismiss()
        }
    }
}

/// [하이퍼링크] as opened: a new link, or (`existing`) 하이퍼링크 고치기.
struct HyperlinkEditing: Identifiable {
    let id = UUID()
    var existing: Hyperlink?
    var text: String
    var uri: String
}

/// [하이퍼링크] and [하이퍼링크 고치기]: 표시할 문자열 and the 연결 대상's 웹 주소.
struct HyperlinkSheet: View {
    let viewer: Viewer
    let editing: HyperlinkEditing
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var uri: String
    @FocusState private var addressFocused: Bool
    init(viewer: Viewer, editing: HyperlinkEditing) {
        (self.viewer, self.editing) = (viewer, editing)
        _text = State(initialValue: editing.text)
        _uri = State(initialValue: editing.uri)
    }
    var body: some View {
        DialogFrame(editing.existing == nil ? "하이퍼링크" : "하이퍼링크 고치기",
                    confirmTitle: editing.existing == nil ? "넣기" : "고치기",
                    canConfirm: !text.trimmingCharacters(in: .whitespaces).isEmpty && !text.contains(where: \.isNewline)
                        && Hyperlink.isWebAddress(uri)) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("표시할 문자열")
                    TextField("", text: $text).frame(width: 300)
                }
                GroupTitle("연결 대상").padding(.top, 4)
                GridRow {
                    FieldLabel("웹 주소")
                    TextField("", text: $uri).frame(width: 300).focused($addressFocused)
                }
            }
            // With the text already there, the address is what is left to type.
            .onAppear { if !text.isEmpty, uri.isEmpty { addressFocused = true } }
        } confirm: {
            viewer.setHyperlink(editing, text: text, uri: uri)
            dismiss()
        }
    }
}

/// [그림 확장자 바꾸기]: the extension the 연결 pictures' files take.
struct LinkExtensionSheet: View {
    let pictures: [PictureInfo]
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var ext = "png"
    var body: some View {
        DialogFrame("그림 확장자 바꾸기", confirmTitle: "설정") {
            LabeledField("확장자") {
                ChoiceField($ext, ["bmp", "gif", "jpg", "png", "tif", "wmf", "emf", "svg"].map { ($0, $0) }, minWidth: 100)
            }
        } confirm: {
            viewer.changeLinkExtension(pictures, to: ext)
            dismiss()
        }
    }
}

/// [사용된 글꼴 바꾸기] and [대체된 글꼴 바꾸기]: 적용할 글꼴, from the fonts this Mac has.
struct FontReplaceSheet: View {
    let title: String
    let replace: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var font: String?
    var body: some View {
        DialogFrame(title, confirmTitle: "설정", canConfirm: font != nil) {
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("적용할 글꼴")
                List(FormatChoices.families, id: \.family, selection: $font) { Text($0.name) }
                    .frame(width: 260, height: 260)
            }
        } confirm: {
            if let font { replace(font) }
            dismiss()
        }
    }
}

/// 책갈피: 책갈피 이름, 책갈피 목록 (이름 or 위치 order), 넣기 and 이동, 이름 바꾸기 and 삭제.
/// 책갈피, as a dialog: 책갈피 이름, 책갈피 목록 and its order, 넣기 and 이동.
struct BookmarkSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        DialogFrame("책갈피", confirmTitle: "넣기", canConfirm: BookmarkForm.addable(name)) {
            BookmarkForm(viewer: viewer, name: $name, listWidth: 300) { dismiss() }
        } confirm: {
            viewer.addBookmark(name)
            dismiss()
        }
        .task { name = await viewer.wordAtCaret() }
    }
}

/// [책갈피] 작업 창: the dialog's items, with 넣기 under the name.
struct BookmarkPane: View {
    let viewer: Viewer
    @State private var name = ""
    @State private var added = 0
    var body: some View {
        BookmarkForm(viewer: viewer, name: $name, reload: added) {}
            .padding([.horizontal, .bottom], 12)
            .frame(maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .bottom) {
                Button("넣기") {
                    viewer.addBookmark(name)
                    name = ""
                    added += 1
                }
                .disabled(!BookmarkForm.addable(name) || viewer.document?.context.inBody != true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding([.horizontal, .bottom], 12)
            }
    }
}

/// 책갈피 이름, 책갈피 목록 with 편집 and 지우기, 책갈피 정렬 기준 and 이동.
struct BookmarkForm: View {
    let viewer: Viewer
    @Binding var name: String
    var listWidth: CGFloat?
    /// Changes when the list is to be read again.
    var reload = 0
    let moved: () -> Void
    @State private var marks: [Bookmark] = []
    @State private var chosen: String?
    @State private var byName = false

    static func addable(_ name: String) -> Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var shown: [Bookmark] { byName ? marks.sorted { $0.name < $1.name } : marks }
    private var mark: Bookmark? { marks.first { $0.name == chosen } }
    private var taken: Bool { marks.contains { $0.name == name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if listWidth == nil {
                GroupTitle("책갈피 이름")
                TextField("", text: $name)
            } else {
                LabeledField("책갈피 이름") { TextField("", text: $name).frame(width: 220) }
            }
            HStack {
                GroupTitle("책갈피 목록")
                Spacer()
                ToolIcon("편집", symbol: "pencil") {
                    guard let mark else { return }
                    viewer.changeBookmark(mark, name: name)
                    load()
                }
                .disabled(mark == nil || name.isEmpty || taken)
                ToolIcon("지우기", symbol: "trash") {
                    guard let mark else { return }
                    viewer.changeBookmark(mark, name: nil)
                    load()
                }
                .disabled(mark == nil)
            }
            List(shown, id: \.name, selection: $chosen) { Text($0.name) }
                .frame(width: listWidth, height: listWidth == nil ? nil : 160)
                .frame(maxHeight: listWidth == nil ? .infinity : nil)
            // A narrow 작업 창 puts the order and 이동 on lines of their own.
            let layout = listWidth == nil ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
            layout {
                Text("책갈피 정렬 기준")
                Picker("", selection: $byName) {
                    Text("이름").tag(true)
                    Text("위치").tag(false)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .fixedSize()
                if listWidth != nil { Spacer() }
                Button("이동") {
                    guard let mark else { return }
                    viewer.go(to: mark)
                    moved()
                }
                .disabled(mark == nil)
            }
        }
        .task(id: reload) { load() }
    }
    private func load() {
        guard let document = viewer.document else { return }
        Task {
            await document.settle()
            marks = (try? await document.bookmarks()) ?? []
        }
    }
}

extension Viewer {
    /// The word from the caret on, which 책갈피 offers as the name.
    func wordAtCaret() async -> String {
        guard let document, let at = bodyCaret, let paragraph = try? await document.paragraph(at.target) else { return "" }
        return String(paragraph.text.scalars(at.scalar..<UInt32.max).prefix { !$0.isWhitespace && $0 != "\u{FFFC}" })
    }
}

/// 조판 부호 지우기: 개체 선택, 모두 선택 or 모두 해제, and 지우기.
struct EraseCodesSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var kinds: Set<CodeKind> = []

    var body: some View {
        DialogFrame("조판 부호 지우기", confirmTitle: "지우기", canConfirm: !kinds.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    GroupTitle("개체 선택")
                    Spacer()
                    Button(kinds.count == CodeKind.all.count ? "모두 해제" : "모두 선택") {
                        kinds = kinds.count == CodeKind.all.count ? [] : Set(CodeKind.all)
                    }
                }
                List(CodeKind.all, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding { kinds.contains(kind) } set: { on in
                        if on { kinds.insert(kind) } else { kinds.remove(kind) }
                    })
                }
                .frame(width: 260, height: 260)
            }
        } confirm: {
            viewer.eraseCodes(CodeKind.all.filter(kinds.contains))
            dismiss()
        }
    }
}

/// What 문서 정보 shows: the file, and the counts the engine made.
struct DocumentInfo: Identifiable {
    let id = UUID()
    let url: URL?
    let statistics: Statistics
}

/// 문서 정보: 일반 (the file) and 문서 통계.
struct DocumentInfoSheet: View {
    let info: DocumentInfo
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "일반"
    @State private var fonts: [[UsedFont]] = []
    /// 글꼴 정보's 언어: 0 for 대표, then 한글…사용자.
    @State private var language = 0
    @State private var usedFont: String?
    @State private var lostFont: String?
    /// The font 사용된 글꼴 바꾸기 or 대체된 글꼴 바꾸기 replaces, and which of them.
    @State private var replacing: (from: String, title: String)?
    /// Font changes made here, done on 확인.
    @State private var replaced: [(language: UInt8?, from: String, to: String)] = []
    @State private var pictures: [PictureInfo] = []
    @State private var chosenPictures: Set<ObjectRef> = []
    /// The 연결 pictures 그림 확장자 바꾸기 is open for.
    @State private var extending: [PictureInfo]?

    init(info: DocumentInfo, document: HwpDocument, viewer: Viewer, tab: String = "일반") {
        (self.info, self.document, self.viewer) = (info, document, viewer)
        _tab = State(initialValue: tab)
    }

    var body: some View {
        DialogFrame("문서 정보") {
            DialogTabs(selection: $tab, titles: ["일반", "문서 통계", "글꼴 정보", "그림 정보"]) { tab in
                switch tab {
                case "일반": general
                case "문서 통계": statistics
                case "글꼴 정보": fontInfo
                default: pictureInfo
                }
            }
            .dialogTabs()
            .frame(width: 520, height: 320)
        } confirm: {
            for r in replaced { viewer.replaceFont(language: r.language, from: r.from, to: r.to) }
            dismiss()
        }
        .task(id: document.reply.revision) {
            await document.settle()
            fonts = (try? await document.fonts()) ?? []
            pictures = (try? await document.pictures()) ?? []
        }
        .sheet(isPresented: Binding { extending != nil } set: { if !$0 { extending = nil } }) {
            if let extending { LinkExtensionSheet(pictures: extending, viewer: viewer) }
        }
        .sheet(isPresented: Binding { replacing != nil } set: { if !$0 { replacing = nil } }) {
            if let replacing {
                FontReplaceSheet(title: replacing.title) { to in
                    replaced.append((language == 0 ? nil : UInt8(language - 1), replacing.from, to))
                    usedFont = nil
                    lostFont = nil
                }
            }
        }
    }

    /// 언어 `index`'s fonts, with the changes not yet done.
    private func fontList(_ index: Int) -> [UsedFont] {
        var list = fonts.indices.contains(index) ? fonts[index] : []
        for r in replaced where r.language == nil || Int(r.language!) + 1 == index {
            guard let at = list.firstIndex(where: { $0.name == r.from }) else { continue }
            list.remove(at: at)
            if !list.contains(where: { $0.name == r.to }) { list.insert(UsedFont(name: r.to, installed: true), at: at) }
        }
        return list
    }
    private var fontInfo: some View {
        let list = fontList(language)
        return VStack(alignment: .leading, spacing: 10) {
            LabeledField("언어") {
                ChoiceField($language, Array(zip(0..., ["대표"] + CharShapeSheet.languageNames)), minWidth: 120)
            }
            fontList("사용된 글꼴", list.filter(\.installed), $usedFont)
            fontList("대체된 글꼴", list.filter { !$0.installed }, $lostFont)
        }
        .padding(16)
    }
    private func fontList(_ title: String, _ fonts: [UsedFont], _ chosen: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                GroupTitle(title)
                Spacer()
                ToolIcon("\(title) 바꾸기", symbol: "arrow.left.arrow.right") {
                    if let from = chosen.wrappedValue { replacing = (from, "\(title) 바꾸기") }
                }
                .disabled(chosen.wrappedValue.map { name in fonts.contains { $0.name == name } } != true
                          || document.context.locked)
            }
            List(fonts, id: \.name, selection: chosen) { Text($0.name) }
                .frame(height: 90)
        }
    }

    private var pictureInfo: some View {
        let chosen = pictures.filter { chosenPictures.contains($0.object) }
        return VStack(alignment: .leading, spacing: 8) {
            GroupTitle("그림 목록")
            Table(pictures, selection: $chosenPictures) {
                TableColumn("이름") { Text($0.name) }
                TableColumn("종류") { Text($0.linked ? "연결" : "삽입") }.width(50)
                TableColumn("쪽 수") { Text($0.page == 0 ? "" : "\($0.page)").monospacedDigit() }.width(40)
                TableColumn("경로") { Text($0.path) }
            }
            HStack {
                Menu("그림 삽입") {
                    Button("그림 삽입…") { viewer.embedPictures(chosen.filter(\.linked)) }
                        .disabled(!chosen.contains { $0.linked })
                    Button("모두 삽입…") { viewer.embedAllPictures(pictures.filter(\.linked)) }
                        .disabled(!pictures.contains { $0.linked })
                }
                .fixedSize()
                .disabled(document.context.locked)
                Menu("저장") {
                    Button("삽입 그림 저장하기…") { viewer.savePicture(chosen.first?.object) }
                        .disabled(chosen.count != 1 || chosen[0].linked)
                    Button("모든 삽입 그림 저장하기…") { viewer.savePictures(pictures.filter { !$0.linked }) }
                        .disabled(!pictures.contains { !$0.linked })
                }
                .fixedSize()
                Button("그림 목록 저장…") { viewer.savePictureList(chosen.isEmpty ? pictures : chosen) }
                    .disabled(pictures.isEmpty)
                Spacer()
                Menu("더 보기") {
                    Button("그림 바꾸기…") { viewer.replacePicture(chosen.first?.object) }
                        .disabled(chosen.count != 1 || document.context.locked)
                    Group {
                        Button("경로 바꾸기…") { if let picture = chosen.first { viewer.relinkPicture(picture) } }
                            .disabled(chosen.count != 1)
                        Button("그림 확장자 바꾸기…") { extending = chosen.filter(\.linked) }
                    }
                    .disabled(!chosen.allSatisfy(\.linked) || chosen.isEmpty || document.context.locked)
                    Button("그림 경로 복사") { viewer.copyLinkPaths(chosen.filter(\.linked)) }
                        .disabled(!chosen.contains { $0.linked })
                }
                .fixedSize()
            }
        }
        .padding(16)
    }

    private func rows(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    FieldLabel(row.0)
                    Text(row.1).textSelection(.enabled).monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var general: some View {
        let values = try? info.url?.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey,
                                                             .contentModificationDateKey, .contentAccessDateKey])
        let date = { (date: Date?) in date?.formatted(date: .long, time: .shortened) ?? "" }
        return rows([
            ("종류", values?.localizedTypeDescription ?? ""),
            ("위치", info.url?.deletingLastPathComponent().path ?? ""),
            ("크기", values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""),
            ("만든 날짜", date(values?.creationDate)),
            ("수정한 날짜", date(values?.contentModificationDate)),
            ("사용한 날짜", date(values?.contentAccessDate)),
        ])
    }
    private var statistics: some View {
        let n = info.statistics
        return rows([
            ("글자(공백 포함)", "\(n.characters)"),
            ("글자(공백 제외)", "\(n.charactersWithoutSpaces)"),
            ("글자에 포함된 한자 수", "\(n.hanja)"),
            ("낱말", "\(n.words)"),
            ("줄", "\(n.lines)"),
            ("문단", "\(n.paragraphs)"),
            ("쪽", "\(n.pages)"),
            ("원고지(200자 기준)", "\(n.manuscript)"),
            ("표, 그림, 글상자", "\(n.tables), \(n.pictures), \(n.textBoxes)"),
        ])
    }
}
