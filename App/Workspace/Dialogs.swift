import AppKit
import ImageIO
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
    func setPage(_ page: PageSetup, section: UInt32, whole: Bool = false) {
        document?.edit(undoManager) { _ in .setPage(section: section, page, whole: whole) }
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
    /// 이전 or 다음 머리말/꼬리말 from the one holding the caret.
    func goToHeaderFooter(_ motion: Motion) {
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
    /// 단 하나, 둘 or 셋 for the section holding the caret.
    func setColumns(_ count: UInt16) {
        document?.edit(undoManager) { selection in
            .setColumns(section: selection?.focus.target.section ?? 0, count: count)
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
    private static let papers: [(name: String, width: Double, height: Double)] = [
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
                    GridRow { field("폭", \.width); field("길이", \.height) }
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

/// 용지 방향 and 제본 as the web dialog draws them: a page with lines of text, and pages
/// with 가 (and 나) by their bound edge.
private enum PagePictogram {
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
