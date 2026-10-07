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
    func go(to mark: Bookmark) {
        document?.select { _ in .caret(mark.position) }
    }
    /// 조판 부호 지우기 in the selected range, or in the whole body.
    func eraseCodes(_ kinds: [CodeKind]) {
        document?.edit(undoManager) { selection in
            let range = selection.flatMap { $0.anchor != $0.focus ? $0 : nil }
            return .eraseCodes(range, kinds: kinds)
        }
    }
    func showDocumentInfo() {
        guard let document else { return }
        Task {
            guard let statistics = try? await document.statistics() else { return NSSound.beep() }
            documentInfo = DocumentInfo(url: canvas.window?.representedURL, statistics: statistics)
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

/// 책갈피: 책갈피 이름, 책갈피 목록 (이름 or 위치 order), 넣기 and 이동, 이름 바꾸기 and 삭제.
struct BookmarkSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var marks: [Bookmark] = []
    @State private var chosen: String?
    @State private var byName = false

    private var shown: [Bookmark] { byName ? marks.sorted { $0.name < $1.name } : marks }
    private var mark: Bookmark? { marks.first { $0.name == chosen } }
    private var taken: Bool { marks.contains { $0.name == name } }

    var body: some View {
        DialogFrame("책갈피", confirmTitle: "넣기", canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty && !taken) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledField("책갈피 이름") { TextField("", text: $name).frame(width: 220) }
                HStack {
                    GroupTitle("책갈피 목록")
                    Spacer()
                    ToolIcon("책갈피 이름 바꾸기", symbol: "pencil") {
                        guard let mark else { return }
                        viewer.changeBookmark(mark, name: name)
                        reload()
                    }
                    .disabled(mark == nil || name.isEmpty || taken)
                    ToolIcon("삭제", symbol: "trash") {
                        guard let mark else { return }
                        viewer.changeBookmark(mark, name: nil)
                        reload()
                    }
                    .disabled(mark == nil)
                }
                List(shown, id: \.name, selection: $chosen) { Text($0.name) }
                    .frame(width: 300, height: 160)
                HStack {
                    Text("책갈피 정렬 기준")
                    Picker("", selection: $byName) {
                        Text("이름").tag(true)
                        Text("위치").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    Spacer()
                    Button("이동") {
                        guard let mark else { return }
                        viewer.go(to: mark)
                        dismiss()
                    }
                    .disabled(mark == nil)
                }
            }
        } confirm: {
            viewer.addBookmark(name)
            dismiss()
        }
        .task {
            reload()
            name = await viewer.wordAtCaret()
        }
    }
    private func reload() {
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
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "일반"

    var body: some View {
        DialogFrame("문서 정보") {
            TabView(selection: $tab) {
                general.tab("일반")
                statistics.tab("문서 통계")
            }
            .dialogTabs()
            .frame(height: 300)
        } confirm: { dismiss() }
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
