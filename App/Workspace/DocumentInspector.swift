import AppKit
import SwiftUI

/// 문서 and 구역, as Pages's 문서 and 섹션: the paper of the section holding the caret with its
/// 쪽 테두리/배경, and that section's 구역 설정, 단 and 주석 모양, each change applied at once.
struct DocumentInspector: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var page: PageSetup?
    @State private var border: PageBorder?
    @State private var setup: SectionSetup?
    @State private var columns: ColumnSetup?
    /// 각주 모양 then 미주 모양.
    @State private var notes: [NoteShape]?
    /// The note whose 모양 shows: 0 각주, 1 미주.
    @State private var note = 0
    /// 쪽 테두리: the line last chosen.
    @State private var pageLine = BorderSide(line: 1, width: 1, color: "#000000")
    @State private var tab: Int
    /// 사용자 정의 chosen, so 폭 and 길이 show although the size is a listed paper's.
    @State private var custom = false
    /// Changes made here: a read sent before one of them answers with what came before it.
    @State private var changes = 0

    init(document: HwpDocument, viewer: Viewer) {
        (self.document, self.viewer, _tab) = (document, viewer, State(initialValue: viewer.documentTab))
    }

    var body: some View {
        let section = document.selection?.focus.target.section ?? 0
        VStack(spacing: 0) {
            InspectorScroll(fixed: true) {
                InspectorSection {
                    Segments([0, 1], selection: $tab, accent: true, capsule: true) { let title = ["문서", "구역"][$0]; return .init(title: title, help: title) }
                        .controlSize(.large)
                        // A little wider than the groups under them.
                        .padding(.horizontal, -6)
                }
            }
            InspectorScroll {
                if tab == 0 { paperPane(section) } else { sectionPane(section) }
            }
            .disabled(document.context.locked)
        }
        .onChange(of: tab) { viewer.documentTab = tab }
        .task(id: "\(document.revision) \(section)") {
            let before = changes
            let read = (try? await document.pageSetup(section: section), try? await document.pageBorder(section: section),
                        try? await document.sectionSetup(section: section), try? await document.columns(section: section))
            let shapes = [try? await document.noteShape(section: section, footnote: true),
                          try? await document.noteShape(section: section, footnote: false)]
            // A change made while reading is newer than what was read; its own edit reads again.
            guard before == changes else { return }
            (page, border, setup, columns) = read
            notes = shapes.contains(nil) ? nil : shapes.compactMap { $0 }
        }
    }

    // MARK: 문서

    /// 용지 종류, in Hancom's names and order.
    static let papers: [(name: String, width: Double, height: Double)] = [
        ("프린트 132", 335.3, 279.4), ("레터", 215.9, 279.4), ("B5(46배판)", 182, 257), ("B4(타블로이드판)", 257, 364),
        ("A4(국배판)", 210, 297), ("A3(국배배판)", 297, 420), ("리갈", 215.9, 355.6), ("A6(문고판)", 105, 148),
        ("A5(국판)", 148, 210), ("신국판", 148, 225), ("크라운판", 176, 248), ("Executive", 184.1, 266.7),
        ("Executive(JIS)", 216, 329.9), ("Envelope DL", 110, 220), ("Envelope C5", 162, 229),
        ("Envelope B5", 176, 250), ("Envelope Monarch", 98.4, 190.5), ("점자출력용지", 230, 279.4),
        ("16절지(국판)", 159, 234),
    ]

    @ViewBuilder private func paperPane(_ section: UInt32) -> some View {
        Group {
            InspectorSection {
                let paper = paper(section)
                LabeledContent {
                    Picker("용지 종류", selection: paper) {
                        Text("사용자 정의").tag(String?.none)
                        ForEach(Self.papers, id: \.name) { Text($0.name).tag(String?.some($0.name)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: { Text("용지 종류").font(.headline.weight(.semibold)) }
                orientation(section).padding(.top, 6)
                if paper.wrappedValue == nil {
                    // 폭 and 길이 of the paper as it lies.
                    let landscape = page?.landscape ?? false
                    Pair("폭", length(landscape ? \.height : \.width, section), "길이", length(landscape ? \.width : \.height, section))
                }
            }
            // 편집 용지's 용지 여백, 머리말 and 꼬리말 with them, then 제본.
            InspectorSection("용지 여백") {
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach([[("위쪽", \PageSetup.marginTop), ("아래쪽", \.marginBottom), ("머리말", \.marginHeader)],
                             [("왼쪽", \PageSetup.marginLeft), ("오른쪽", \.marginRight), ("꼬리말", \.marginFooter)]], id: \.first!.0) { row in
                        GridRow {
                            ForEach(row, id: \.0) { title, key in
                                VStack(spacing: 3) { length(key, section); Text(title).font(.caption) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                LabeledContent("제본") {
                    HStack(spacing: 8) {
                        Picker("제본", selection: Binding(get: { page?.binding ?? 0 }, set: { binding in set(section) { $0.binding = binding } })) {
                            Text("한쪽").tag(UInt8(0)); Text("맞쪽").tag(UInt8(1)); Text("위로").tag(UInt8(2))
                        }
                        .labelsHidden()
                        .fixedSize()
                        length(\.marginGutter, section).help("제본 여백")
                    }
                }
            }
        }
        .disabled(page == nil)
        pageBorder(section)
    }

    /// 쪽 테두리 and 쪽 배경 of the section's pages, as 쪽 테두리/배경 sets them for 현재 구역.
    @ViewBuilder private func pageBorder(_ section: UInt32) -> some View {
        let pages: [(ApplyPages, String)] = [(.all, "모두"), (.exceptFirst, "첫 쪽 제외"), (.firstOnly, "첫 쪽만")]
        Group {
            InspectorSection("쪽 테두리") {
                BorderSides(sides: border?.sides, line: $pageLine) { changes in
                    edit(section) { border in for (side, line) in changes { border.sides[side] = line } }
                }
                // Where the border goes, and on which pages, while there is one.
                if border?.sides.contains(where: { $0.line != 0 }) == true {
                    HStack(spacing: 8) {
                        Picker("위치", selection: Binding { border?.paper ?? true } set: { paper in edit(section) { $0.paper = paper } }) {
                            Text("종이 기준").tag(true); Text("쪽 기준").tag(false)
                        }
                        .labelsHidden()
                        .help("위치")
                        pagesPicker(pages, Binding { border?.borderPages ?? .all } set: { p in edit(section) { $0.borderPages = p } })
                    }
                    .flexibleButtons()
                    if border?.paper == false {
                        HStack(spacing: 16) {
                            Toggle("머리말 포함", isOn: Binding { border?.headerInside == true } set: { on in edit(section) { $0.headerInside = on } })
                            Toggle("꼬리말 포함", isOn: Binding { border?.footerInside == true } set: { on in edit(section) { $0.footerInside = on } })
                        }
                        .checkbox()
                    }
                    Fold("간격", headline: false) {
                        Sides { side in
                            NumberStepper(value: border.map { Units.millimeters($0.spacing[side]) }, unit: "mm", range: 0...25, wide: true) { mm in
                                edit(section) { $0.spacing[side] = Units.units(mm) }
                            }
                        }
                    }
                }
            }
            InspectorSection {
                FillRows(title: "쪽 배경", fill: border?.fill) { fill in edit(section) { $0.fill = fill } }
                if FillRows.kind(border?.fill) != 0 {
                    HStack(spacing: 8) {
                        pagesPicker(pages, Binding { border?.fillPages ?? .all } set: { p in edit(section) { $0.fillPages = p } })
                        Picker("채울 영역", selection: Binding { border?.fillArea ?? .paper } set: { area in edit(section) { $0.fillArea = area } }) {
                            Text("종이").tag(FillArea.paper); Text("쪽").tag(FillArea.page); Text("테두리").tag(FillArea.border)
                        }
                        .labelsHidden()
                        .help("채울 영역")
                    }
                    .flexibleButtons()
                }
            }
        }
        .disabled(border == nil)
    }
    private func pagesPicker(_ pages: [(ApplyPages, String)], _ selection: Binding<ApplyPages>) -> some View {
        Picker("적용 쪽", selection: selection) {
            ForEach(pages, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .help("적용 쪽")
    }
    private func edit(_ section: UInt32, _ change: (inout PageBorder) -> Void) {
        guard var changed = border else { return }
        change(&changed)
        guard changed != border else { return }
        border = changed
        changes += 1
        viewer.setPageBorder(changed, section: section, whole: false)
    }

    /// 용지 방향 as Pages's: the paper upright and lying, the chosen one checked, its size under them.
    private func orientation(_ section: UInt32) -> some View {
        let landscape = page?.landscape ?? false
        let short = CGFloat(min(page?.width ?? 210, page?.height ?? 297)), long = CGFloat(max(page?.width ?? 210, page?.height ?? 297))
        let scale = 98 / long
        return VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                ForEach([false, true], id: \.self) { lying in
                    Button { set(section) { $0.landscape = lying } } label: {
                        Rectangle()
                            .fill(.white)
                            .frame(width: (lying ? long : short) * scale, height: (lying ? short : long) * scale)
                            // As the pages: white paper stands out from a light inspector too.
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .overlay(alignment: .bottomTrailing) {
                                if lying == landscape {
                                    Image(systemName: "checkmark").font(.title3.weight(.bold)).foregroundStyle(.black).padding(8)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(lying ? "가로" : "세로")
                    .accessibilityLabel(lying ? "가로" : "세로")
                    .accessibilityAddTraits(lying == landscape ? .isSelected : [])
                }
            }
            if let page {
                let size = landscape ? (page.height, page.width) : (page.width, page.height)
                Text("\(Units.millimeters(size.0).formatted(.number.precision(.fractionLength(0...1)))) × \(Units.millimeters(size.1).formatted(.number.precision(.fractionLength(0...1))))mm")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// A length of the paper, its unit in the field.
    private func length(_ key: WritableKeyPath<PageSetup, UInt32>, _ section: UInt32) -> some View {
        NumberStepper(value: page.map { Units.millimeters($0[keyPath: key]) }, unit: "mm", range: 0...1000, width: 50, unitInside: true) { mm in
            set(section) { $0[keyPath: key] = Units.units(mm) }
        }
    }

    /// Changes the section's paper at once, as the 세로 and 가로 commands do.
    private func set(_ section: UInt32, _ change: (inout PageSetup) -> Void) {
        guard var changed = page else { return }
        change(&changed)
        guard changed != page else { return }
        page = changed
        changes += 1
        viewer.setPage(changed, section: section)
    }
    private func paper(_ section: UInt32) -> Binding<String?> {
        Binding {
            guard let page, !custom else { return nil }
            let size = (Units.millimeters(page.width), Units.millimeters(page.height))
            return Self.papers.first { abs($0.width - size.0) < 0.5 && abs($0.height - size.1) < 0.5 }?.name
        } set: { name in
            custom = name == nil
            guard let paper = Self.papers.first(where: { $0.name == name }) else { return }
            set(section) { ($0.width, $0.height) = (Units.units(paper.width), Units.units(paper.height)) }
        }
    }

    // MARK: 구역

    /// 구역 설정's 시작 쪽 번호 in sight, its 개체 시작 번호 and 기타 folded; then 단 and 주석 모양.
    @ViewBuilder private func sectionPane(_ section: UInt32) -> some View {
        Group {
            InspectorSection {
                LabeledContent {
                    HStack(spacing: 8) {
                        Picker("시작 쪽 번호", selection: Binding(get: { (setup?.pageNum ?? 0) > 0 ? 3 : Int(setup?.pageNumType ?? 0) }, set: { kind in
                            change(section) { setup in
                                if kind == 3 { (setup.pageNum, setup.pageNumType) = (max(setup.pageNum, 1), 0) } else { (setup.pageNum, setup.pageNumType) = (0, UInt8(kind)) }
                            }
                        })) { Text("이어서").tag(0); Text("홀수").tag(1); Text("짝수").tag(2); Text("사용자").tag(3) }
                        .labelsHidden()
                        .fixedSize()
                        number(\.pageNum, section)
                    }
                } label: { Text("시작 쪽 번호").font(.headline.weight(.semibold)) }
            }
            InspectorSection {
                Fold("개체 시작 번호") {
                    start("그림", \.pictureNum, section)
                    start("표", \.tableNum, section)
                    start("수식", \.equationNum, section)
                }
            }
            InspectorSection {
                Fold("기타") {
                    Group {
                        Toggle("첫 쪽에만 머리말/꼬리말 감추기", isOn: flag(section, get: { $0.hideHeader && $0.hideFooter }, set: { ($0.hideHeader, $0.hideFooter) = ($1, $1) }))
                        Toggle("첫 쪽에만 바탕쪽 감추기", isOn: flag(section, get: { $0.hideMasterPage }, set: { $0.hideMasterPage = $1 }))
                        Toggle("첫 쪽에만 테두리/배경 감추기", isOn: flag(section, get: { $0.hideBorder && $0.hideFill }, set: { ($0.hideBorder, $0.hideFill) = ($1, $1) }))
                        Toggle("빈 줄 감추기", isOn: flag(section, get: { $0.hideEmptyLine }, set: { $0.hideEmptyLine = $1 }))
                    }
                    .checkbox()
                    LabeledContent("단 사이 간격") {
                        NumberStepper(value: setup.map { Units.millimeters($0.columnSpacing) }, unit: "mm", range: 0...100) { mm in
                            change(section) { $0.columnSpacing = Units.units(mm) }
                        }
                    }
                    LabeledContent("기본 탭 간격") {
                        // Stored at 200 to the point: 8000 is 한/글's 40pt.
                        NumberStepper(value: setup.map { Double($0.defaultTabSpacing) / 200 }, unit: "pt", range: 1...141) { pt in
                            change(section) { $0.defaultTabSpacing = UInt32((pt * 200).rounded()) }
                        }
                    }
                }
            }
        }
        .disabled(setup == nil)
        columnPane(section)
        notePane(section)
    }

    /// 단 설정: 자주 쓰이는 모양 and 단 개수, 단 종류, 간격 and 단 너비 동일하게.
    private func columnPane(_ section: UInt32) -> some View {
        InspectorSection {
            LabeledContent {
                NumberStepper(value: columns.map { Double($0.count) }, unit: "", range: 1...255) { count in
                    setColumns(section) { $0.count = UInt16(count) }
                }
                .help("단 개수")
            } label: { Text("단").font(.headline.weight(.semibold)) }
            IconTiles(selection: Binding { columns?.count ?? 1 } set: { count in setColumns(section) { $0.count = count } },
                      options: [(UInt16(1), "하나"), (2, "둘"), (3, "셋")], fill: true) { count, on in
                PagePictogram.columns(Int(count), on: on)
            }
            .flexibleButtons()
            // What only more than one 단 has.
            if (columns?.count ?? 1) > 1 {
                LabeledContent("단 종류") {
                    Picker("단 종류", selection: Binding { columns?.columnType ?? 0 } set: { type in setColumns(section) { $0.columnType = type } }) {
                        Text("일반 단").tag(UInt8(0)); Text("배분 단").tag(UInt8(1)); Text("평행 단").tag(UInt8(2))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("간격") {
                    NumberStepper(value: columns.map { Units.millimeters(UInt32(max($0.spacing, 0))) }, unit: "mm", range: 0...100) { mm in
                        setColumns(section) { $0.spacing = Int16(clamping: Units.units(mm) as Int) }
                    }
                }
                Toggle("단 너비 동일하게", isOn: Binding { columns?.sameWidth == true } set: { same in setColumns(section) { $0.sameWidth = same } })
                    .checkbox()
            }
        }
        .disabled(columns == nil)
    }
    private func setColumns(_ section: UInt32, _ change: (inout ColumnSetup) -> Void) {
        guard var changed = columns else { return }
        change(&changed)
        guard changed != columns else { return }
        columns = changed
        changes += 1
        viewer.setColumns(changed, section: section)
    }

    /// 번호 모양 of the notes, in 한/글's order; 미주 takes all but the last.
    private static let noteFormats: [(String, String)] = [
        ("digit", "1,2,3"), ("circledDigit", "①,②,③"), ("upperRoman", "I,II,III"), ("lowerRoman", "i,ii,iii"),
        ("upperAlpha", "A,B,C"), ("lowerAlpha", "a,b,c"), ("circledUpperAlpha", "Ⓐ,Ⓑ,Ⓒ"), ("circledLowerAlpha", "ⓐ,ⓑ,ⓒ"),
        ("hangulSyllable", "가,나,다"), ("circledHangulSyllable", "㉮,㉯,㉰"), ("hangulJamo", "ㄱ,ㄴ,ㄷ"),
        ("circledHangulJamo", "㉠,㉡,㉢"), ("hangulDigit", "일,이,삼"), ("hanjaDigit", "一,二,三"),
        ("circledHanjaDigit", "㊀,㊁,㊂"), ("hanjaGapEul", "갑,을,병"), ("hanjaGapEulHanja", "甲,乙,丙"),
        ("fourSymbol", "*,†,‡,§"),
    ]
    /// 주석 모양: 각주 or 미주, its 번호 서식, 구분선, 여백 and 번호 매기기.
    private func notePane(_ section: UInt32) -> some View {
        let shape = notes?[note]
        let name = note == 0 ? "각주" : "미주"
        return InspectorSection { Fold("주석 모양") {
            Segments([0, 1], selection: $note) { let title = ["각주", "미주"][$0]; return .init(title: title, help: "\(title) 모양") }
            Group {
                LabeledContent("번호 모양") {
                    Picker("번호 모양", selection: Binding { shape?.numberFormat ?? "digit" } set: { format in setNote(section) { $0.numberFormat = format } }) {
                        ForEach(Self.noteFormats.prefix(note == 0 ? 18 : 17), id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    character("앞 장식 문자", \.prefixChar, section)
                    character("뒤 장식 문자", \.suffixChar, section)
                }
                // 번호 매기기.
                Picker("번호 매기기", selection: Binding { shape?.numbering ?? "continue" } set: { way in setNote(section) { $0.numbering = way } }) {
                    Text("앞 구역에 이어서").tag("continue"); Text("현재 구역부터 새로 시작").tag("restartSection")
                }
                .labelsHidden()
                .flexibleButtons()
                Divider()
                // The line's kind beside 구분선, none for no line.
                OpeningRows(title: "구분선", open: shape?.separatorEnabled == true) {
                    ChoiceField(Binding { shape?.separatorEnabled == true ? Int(shape?.separatorLineType ?? 0) : 0 } set: { kind in
                        setNote(section) { shape in
                            shape.separatorEnabled = kind != 0
                            if kind != 0 {
                                shape.separatorLineType = UInt8(kind)
                                if shape.separatorLength == 0 { shape.separatorLength = -1 }
                            }
                        }
                    }, Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds)
                } rows: {
                    LabeledContent("색") {
                        ColorWell(hex: Binding { shape?.separatorColor ?? "#000000" } set: { color in setNote(section) { $0.separatorColor = color } })
                    }
                    LabeledContent("굵기") {
                        LineRow.width(Int(shape?.separatorLineWidth ?? 0)) { width in setNote(section) { $0.separatorLineWidth = UInt8(width) } }
                    }
                    LabeledContent("길이") {
                        // 5 cm and 2 cm are stored as their own values.
                        NumberStepper(value: shape.map { $0.separatorLength == -1 ? 50 : $0.separatorLength == -2 ? 20 : Units.millimeters(max($0.separatorLength, 0)) },
                                      unit: "mm", range: 0...100) { mm in setNote(section) { $0.separatorLength = Units.units(mm) } }
                    }
                }
                Divider()
                noteMargin("구분선 위", \.separatorMarginTop, section)
                noteMargin("구분선 아래", \.separatorMarginBottom, section)
                noteMargin("\(name) 사이", \.noteSpacing, section)
            }
            .disabled(shape == nil)
        } }
    }
    /// One character, as the 장식 문자 take, named under it.
    private func character(_ title: String, _ key: WritableKeyPath<NoteShape, String>, _ section: UInt32) -> some View {
        VStack(spacing: 3) {
            TextField("", text: Binding { notes?[note][keyPath: key] ?? "" } set: { text in setNote(section) { $0[keyPath: key] = String(text.suffix(1)) } })
                .multilineTextAlignment(.center)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
    }
    private func noteMargin(_ title: String, _ key: WritableKeyPath<NoteShape, Int32>, _ section: UInt32) -> some View {
        LabeledContent(title) {
            NumberStepper(value: notes.map { Units.millimeters($0[note][keyPath: key]) }, unit: "mm", range: 0...25) { mm in
                setNote(section) { $0[keyPath: key] = Units.units(mm) }
            }
        }
    }
    /// Changes the shown note's 모양 for the section holding the caret.
    private func setNote(_ section: UInt32, _ change: (inout NoteShape) -> Void) {
        guard var all = notes else { return }
        change(&all[note])
        guard all != notes else { return }
        notes = all
        changes += 1
        viewer.setNoteShape(all[note], footnote: note == 0, section: section, whole: false)
    }

    /// 이어서 or 사용자 and its number.
    private func start(_ title: String, _ key: WritableKeyPath<SectionSetup, UInt16>, _ section: UInt32) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Picker(title, selection: Binding(get: { (setup?[keyPath: key] ?? 0) > 0 }, set: { on in
                    change(section) { $0[keyPath: key] = on ? max($0[keyPath: key], 1) : 0 }
                })) { Text("이어서").tag(false); Text("사용자").tag(true) }
                .labelsHidden()
                .fixedSize()
                number(key, section)
            }
        }
    }
    private func number(_ key: WritableKeyPath<SectionSetup, UInt16>, _ section: UInt32) -> some View {
        NumberStepper(value: setup.map { Double(max($0[keyPath: key], 1)) }, unit: "", range: 1...65535) { value in
            change(section) { $0[keyPath: key] = UInt16(value) }
        }
        .disabled((setup?[keyPath: key] ?? 0) == 0)
    }
    private func flag(_ section: UInt32, get: @escaping (SectionSetup) -> Bool, set: @escaping (inout SectionSetup, Bool) -> Void) -> Binding<Bool> {
        Binding { setup.map(get) ?? false } set: { value in change(section) { set(&$0, value) } }
    }
    /// Changes the section holding the caret at once, as 구역 설정 does for 현재 구역.
    private func change(_ section: UInt32, _ edit: (inout SectionSetup) -> Void) {
        guard var changed = setup else { return }
        edit(&changed)
        guard changed != setup else { return }
        setup = changed
        changes += 1
        viewer.setSection(changed, section: section, whole: false)
    }
}
