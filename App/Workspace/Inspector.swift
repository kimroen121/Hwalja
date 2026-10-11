import AppKit
import SwiftUI

/// The inspector at the window's right, as Keynote's 포맷: 텍스트 and 스타일 for the text at the caret, and the 개체 탭 and 상황 탭 of 한/글 (그림, 도형, 표 …) while they
/// apply, in macOS's own controls. What it changes applies at once; the full dialogs open from it.
struct Inspector: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    /// The revision the properties were last read for, so an edit reads them again.
    @State private var shownRevision: UInt64 = 0
    /// The tab shown; nil for the one last chosen among these tabs.
    @State private var chosen: String?
    /// The selected object's (or the caret's table's) properties, read again after every edit.
    @State private var props: ObjectProps?
    @AppStorage("keepsRatio") private var keepsRatio = true
    /// The caret cell's size and 배경, read with `props`.
    @State private var cell: CellProps?
    @State private var cellFill: PageFill?
    /// 셀's 테두리: the line and the sides it last went on.
    @State private var cellLine = BorderSide(line: 1, width: 1, color: "#000000")
    @State private var cellSides: [Int] = []

    init(document: HwpDocument, viewer: Viewer, tab: String? = nil) {
        (self.document, self.viewer, _chosen) = (document, viewer, State(initialValue: tab))
    }

    static let textTabs = ["텍스트"]
    /// The 개체 탭 and 상황 탭 for what is selected.
    static func contextTabs(_ context: EditingContext) -> [String] {
        switch context.object {
        case .picture: ["스타일", "이미지", "개체"]
        case .shape: context.chart ? ["차트", "개체"] : ["도형", "개체"]
        case .equation: ["수식", "개체"]
        case .table, nil:
            context.inHeaderFooter ? ["머리말/꼬리말"] : context.inNote ? ["주석"]
                : context.inTable ? ["표", "셀", "개체"] : []
        }
    }
    /// A selected object has only its own tabs; a table has 텍스트 among its own, as Pages's;
    /// other text has 텍스트 before them.
    static func tabs(_ context: EditingContext) -> [String] {
        let extra = contextTabs(context)
        if [.picture, .shape, .equation].contains(context.object) { return extra }
        return extra.first == "표" ? ["표", "셀"] + textTabs + ["개체"] : textTabs + extra
    }

    var body: some View {
        let context = document.context, tabs = Self.tabs(context)
        let tab = shown(tabs)
        VStack(spacing: 0) {
            // As Pages's: what the inspector is for over it, or the tabs when there are more than one;
            // they stay while the groups under them scroll.
            if tabs.count > 1 {
                InspectorScroll(fixed: true) {
                    InspectorSection {
                        // As 문서 and 구역.
                        Segments(tabs, selection: Binding(get: { tab }, set: { tab in
                            chosen = tab
                            viewer.inspectorTabs[tabs.joined(separator: " ")] = tab
                        }), accent: true, capsule: true) { .init(title: $0, help: $0) }
                            .controlSize(.large)
                    }
                }
            } else if tab != "텍스트" {
                Text(tab).foregroundStyle(.secondary).padding(.top, 12).padding(.bottom, 8)
                Divider().padding(.horizontal, 16)
            }
            if tab == "텍스트" {
                TextTab(document: document, viewer: viewer, title: tabs.count == 1)
                    .disabled(context.locked)
            } else {
                InspectorScroll { content(tab, context).disabled(context.locked) }
            }
        }
        .onChange(of: tabs) { old, new in
            // Other tabs bring up the one last chosen among them; without one, the tab showing
            // stays when they have it (typing into a table keeps 텍스트), else their first.
            let showing = shown(old)
            chosen = viewer.inspectorTabs[new.joined(separator: " ")] == nil && new.contains(showing) ? showing : nil
        }
        // The revision is not published: a change to the chosen object alone (글자처럼 취급,
        // 본문과의 배치 …) moves nothing the view watches, so the read would wait for another click.
        .onReceive(document.presented) {
            if viewer.arrangedObject != nil, document.revision != shownRevision { shownRevision = document.revision }
        }
        .task(id: "\(shownRevision) " + Self.readKey(document, viewer)) {
            var read: (cell: CellProps?, fill: PageFill?)?
            if let target = document.selection?.focus.target, target.cell != nil, document.object == nil {
                read = (try? await document.cellProps(target), (try? await document.cellBorder(target))?.fill)
            }
            let object = viewer.arrangedObject
            let objectProps = object == nil ? nil : try? await document.objectProps(object!)
            // A read overtaken by a newer one keeps what that one shows: cancelled, it reads nothing.
            guard !Task.isCancelled else { return }
            if let read { (cell, cellFill) = read }
            props = objectProps
        }
    }

    /// The tab chosen here, else the one last chosen among `tabs`, else their first.
    private func shown(_ tabs: [String]) -> String {
        [chosen, viewer.inspectorTabs[tabs.joined(separator: " ")]].compactMap { $0 }.first(where: tabs.contains) ?? tabs[0]
    }
    /// What the shown properties are read for: a new revision, another object chosen (no
    /// edit, no caret move), or the caret in another cell.
    static func readKey(_ document: HwpDocument, _ viewer: Viewer) -> String {
        "\(document.revision) \(String(describing: viewer.arrangedObject)) \(String(describing: document.selection?.focus.target))"
    }

    @ViewBuilder private func content(_ tab: String, _ context: EditingContext) -> some View {
        switch tab {
        case "스타일": pictureStyle
        case "이미지": picture
        case "수식": equation
        case "개체": object(context)
        case "도형": shape
        case "차트": chart
        case "표": table(context)
        case "셀": cells(context)
        case "머리말/꼬리말": headerFooter(context)
        case "주석": annotations(context)
        default: EmptyView()
        }
    }

    // MARK: 개체 탭과 상황 탭

    /// A picture's 테두리, as Pages's 스타일: its kind beside the title, its color and width under it.
    private var pictureStyle: some View {
        InspectorSection {
            let kind = Int(props?.lineType ?? 0)
            OpeningRows(title: "테두리", open: kind != 0) {
                ChoiceField(Binding { kind } set: { viewer.arrange(ObjectProps(lineType: UInt32($0))) },
                            Swatches.lineKinds.indices.prefix(12).map { ($0, "") }, images: Array(Swatches.lineKinds.prefix(12)))
            } rows: {
                HStack(spacing: 8) {
                    ColorWell(hex: Binding { HexColor.hex(bgr: props?.borderColor ?? 0) } set: { viewer.arrange(ObjectProps(borderColor: HexColor.bgr($0))) },
                              flexible: true)
                        .frame(maxWidth: .infinity)
                    NumberStepper(value: props?.borderWidth.map { (Double($0) / Units.perMillimeter * 100).rounded() / 100 }, unit: "mm",
                                  range: 0...20, step: 0.1, wide: true) { viewer.arrange(ObjectProps(borderWidth: Units.units($0))) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
    /// The picture itself, as Pages's 이미지: replaced, saved or back to its original, then 조절.
    @ViewBuilder private var picture: some View {
        InspectorSection {
            Button { viewer.replacePicture() } label: { Label("그림 바꾸기…", systemImage: "folder") }
            Button { viewer.savePicture() } label: { Label("삽입 그림 저장하기…", systemImage: Icon.saveAs) }
            Button { MenuItems.restorePicture(viewer) } label: { Label("원본 그림으로", systemImage: Icon.originalPicture) }
        }
        .flexibleButtons()
        InspectorSection("조절") {
            Segments(["RealPic", "GrayScale", "BlackWhite", "Watermark"], selection: Binding(get: { Self.effect(props) }, set: { effect in
                viewer.adjustPicture { props in
                    if effect == "Watermark" { (props.effect, props.brightness, props.contrast) = ("RealPic", 70, -50) } else { props.effect = effect }
                }
            })) { let title = ["RealPic": "효과 없음", "GrayScale": "회색조", "BlackWhite": "흑백", "Watermark": "워터마크"][$0]!; return .init(title: title, help: title) }
            PictureSlider(title: "밝기", value: props?.brightness) { value in viewer.adjustPicture { $0.brightness = value } }
            PictureSlider(title: "대비", value: props?.contrast) { value in viewer.adjustPicture { $0.contrast = value } }
            Button("재설정") { viewer.adjustPicture { ($0.effect, $0.brightness, $0.contrast) = ("RealPic", 0, 0) } }
                .flexibleButtons()
                .disabled(Self.effect(props) == "RealPic" && (props?.brightness ?? 0) == 0 && (props?.contrast ?? 0) == 0)
        }
        captions
    }
    /// 글자 크기 and 글자 색 of the selected equation; its script in 수식 편집기.
    @ViewBuilder private var equation: some View {
        InspectorSection("수식") {
            LabeledContent("글자 크기") {
                NumberStepper(value: props?.fontSize.map { Double($0) / 100 }, unit: "pt", range: 1...127) { size in
                    setEquation { $0.fontSize = UInt32((size * 100).rounded()) }
                }
            }
            LabeledContent("글자 색") {
                ColorWell(hex: Binding(get: { HexColor.hex(bgr: props?.color ?? 0) }, set: { hex in setEquation { $0.color = HexColor.bgr(hex) } }))
            }
        }
        DialogButtons { Button("수식 편집…") { document.object.map(viewer.open) } }.padding(16)
    }
    /// Changes the selected equation, its script sent with the change as 수식 편집기 sends it.
    private func setEquation(_ change: (inout ObjectProps) -> Void) {
        guard let object = document.object?.object, let props else { return }
        var new = ObjectProps(script: props.script)
        change(&new)
        viewer.setObject(object, new)
    }
    /// 글자 넣기 of a shape that can hold text.
    private var shape: some View {
        InspectorSection {
            let textBox = document.object?.textBox
            Toggle("글자 넣기", isOn: Binding(get: { textBox == true }, set: { attach in viewer.change { .setTextBox($0, attach: attach) } }))
                .checkbox()
                .disabled(textBox == nil)
        }
    }
    private var chart: some View {
        InspectorSection { Tiles { command("데이터 편집…", Icon.chartData) { viewer.editChartData() } } }
    }
    /// The same for every object and for a table, as Pages's 정렬: 배치, 순서, 크기, 위치, 회전,
    /// 보호와 묶기 and 캡션, then 개체 선택 and 개체 속성. What a table cannot do is there but off.
    @ViewBuilder private func object(_ context: EditingContext) -> some View {
        let inLine = props?.treatAsChar == true, table = context.object == nil
        // 본문과의 배치 for an object out of the line, then 글자처럼 취급.
        InspectorSection("본문과의 배치") {
            IconTiles(selection: Binding(get: { inLine ? "" : props?.textWrap ?? "" }, set: { viewer.arrange(ObjectProps(treatAsChar: false, textWrap: $0)) }),
                      options: [("Square", "어울림"), ("TopAndBottom", "자리 차지"), ("BehindText", "글 뒤로"), ("InFrontOfText", "글 앞으로")],
                      fill: true) { Pictogram.wrap($0, on: $1) }
                .flexibleButtons()
                .disabled(inLine)
            Toggle("글자처럼 취급", isOn: Binding(get: { inLine }, set: { viewer.arrange(ObjectProps(treatAsChar: $0)) })).checkbox()
        }
        .disabled(props == nil)
        InspectorSection {
            HStack(spacing: 12) {
                order([("맨 뒤로", "square.3.layers.3d.bottom.filled", .back), ("맨 앞으로", "square.3.layers.3d.top.filled", .front)])
                order([("뒤로", "square.2.layers.3d.bottom.filled", .backward), ("앞으로", "square.2.layers.3d.top.filled", .forward)])
            }
            .disabled(table || inLine)
        }
        InspectorSection("크기") {
            HStack(spacing: 8) {
                captioned("너비") { length(props?.width) { resize(width: $0) } }
                captioned("높이") { length(props?.height) { resize(height: $0) } }
            }
            Toggle("비율 유지", isOn: $keepsRatio).checkbox()
            Button("원래 크기") { viewer.arrange(ObjectProps(width: props?.originalWidth, height: props?.originalHeight)) }
                .flexibleButtons()
                .disabled(props?.originalWidth == nil)
        }
        InspectorSection("위치") {
            HStack(spacing: 8) {
                captioned("X") { length(props?.horzOffset) { viewer.arrange(ObjectProps(horzOffset: Units.units($0))) } }
                captioned("Y") { length(props?.vertOffset) { viewer.arrange(ObjectProps(vertOffset: Units.units($0))) } }
            }
            .disabled(inLine)
        }
        InspectorSection("회전") {
            // 한/글 keeps −360…360; shown as the dial reads it.
            let angle = props.map { Double((Int($0.rotationAngle ?? 0) % 360 + 360) % 360) }
            HStack(alignment: .top, spacing: 8) {
                RotationDial(angle: angle) { viewer.arrange(ObjectProps(rotationAngle: Int32($0))) }
                    .frame(width: 32, height: 32)
                captioned("각도") {
                    NumberStepper(value: angle, unit: "°", range: 0...359, wide: true) {
                        viewer.arrange(ObjectProps(rotationAngle: Int32($0)))
                    }
                }
                captioned("뒤집기") {
                    Segments(segments: [.init(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "좌우 대칭"),
                                        .init(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "상하 대칭")],
                             on: [false, false], any: true) { index in viewer.change { .flip($0, vertical: index == 1) } }
                }
            }
            .disabled(table || inLine)
        }
        InspectorSection {
            ChoiceButtons(items: viewer.protectionChoices + viewer.groupChoices)
                .disabled(table)
        }
        InspectorSection { Tiles { command("개체 선택", Icon.selectObjects) { viewer.draw("select") } } }
        properties("개체 속성…")
    }
    /// 캡션 of a picture.
    private var captions: some View {
        InspectorSection("캡션") { captionPicker.flexibleButtons() }
            .disabled(!document.context.canCaption)
    }
    /// 캡션: none, or where it goes.
    private var captionPicker: some View {
        Picker("캡션", selection: Binding(get: { props?.caption ?? "None" }, set: { viewer.insertCaption($0) })) {
            Text("없음").tag("None")
            Divider()
            ForEach(Captions.all.filter { $0.value != "None" }, id: \.value) { Text($0.title).tag($0.value) }
        }
        .labelsHidden()
    }
    /// Two of 순서 as one control, each named under it.
    private func order(_ steps: [(title: String, symbol: String, order: Order)]) -> some View {
        VStack(spacing: 3) {
            Segments(segments: steps.map { .init(symbol: $0.symbol, help: $0.title) }, on: [false, false], any: true) { index in
                viewer.change { .order($0, steps[index].order) }
            }
            HStack { ForEach(steps, id: \.title) { Text($0.title).frame(maxWidth: .infinity) } }
                .font(.caption)
        }
    }
    /// A field with its name under it, as Pages's.
    private func captioned<Field: View>(_ title: String, @ViewBuilder _ field: () -> Field) -> some View {
        VStack(spacing: 3) {
            field()
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
    }
    private func length<T: BinaryInteger>(_ units: T?, apply: @escaping (Double) -> Void) -> some View {
        NumberStepper(value: units.map { Units.millimeters($0) }, unit: "mm", range: -1000...1000, wide: true, apply: apply)
    }
    /// A new width or height, the other kept in proportion while 비율 유지 is on.
    private func resize(width: Double? = nil, height: Double? = nil) {
        guard let props, let w = props.width, let h = props.height, w > 0, h > 0 else { return }
        var change = ObjectProps()
        if let width {
            change.width = Units.units(max(width, 1))
            if keepsRatio { change.height = UInt32((Double(change.width!) * Double(h) / Double(w)).rounded()) }
        } else if let height {
            change.height = Units.units(max(height, 1))
            if keepsRatio { change.width = UInt32((Double(change.height!) * Double(w) / Double(h)).rounded()) }
        }
        viewer.arrange(change)
    }
    /// The object's own dialog, under the last group.
    private func properties(_ title: String) -> some View {
        DialogButtons { Button(title) { viewer.showObjectProperties() } }.padding(16)
    }

    /// The table as Pages's 표: its options, rows and columns, 윤곽, and the caret cell's size.
    @ViewBuilder private func table(_ context: EditingContext) -> some View {
        InspectorSection("표 옵션") {
            LabeledContent("캡션") { captionPicker }
                .disabled(!context.canCaption)
            Toggle("제목 줄 자동 반복", isOn: Binding(get: { props?.repeatHeader == true }, set: { viewer.arrange(ObjectProps(repeatHeader: $0)) }))
                .checkbox()
            LabeledContent("쪽 경계에서") {
                Picker("쪽 경계에서", selection: Binding(get: { props?.pageBreak ?? 0 }, set: { viewer.arrange(ObjectProps(pageBreak: $0)) })) {
                    Text("셀 단위로 나눔").tag(UInt8(2))
                    Text("나눔").tag(UInt8(1))
                    Text("나누지 않음").tag(UInt8(0))
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        InspectorSection {
            LabeledContent("줄") {
                tableSteps([("위쪽에 줄 추가", "arrow.up.to.line", .insertRowAbove), ("아래쪽에 줄 추가", "arrow.down.to.line", .insertRowBelow),
                            ("줄 지우기", "minus", .deleteRow)])
            }
            LabeledContent("칸") {
                tableSteps([("왼쪽에 칸 추가", "arrow.left.to.line", .insertColumnLeft), ("오른쪽에 칸 추가", "arrow.right.to.line", .insertColumnRight),
                            ("칸 지우기", "minus", .deleteColumn)])
            }
        }
        InspectorSection {
            let side = (props?.tableBorder?.sides.first ?? nil) ?? BorderSide(line: 0, width: 1, color: "#000000")
            let line = Binding(get: { side }, set: { new in
                viewer.arrange(ObjectProps(tableBorder: CellBorder(sides: [new, new, new, new, nil, nil])))
            })
            // The kind beside the title, its color and width under it.
            LabeledContent { LineRow.kind(line) } label: { Text("표 윤곽").font(.headline.weight(.semibold)) }
            LineRow(line: line)
        }
        .disabled(props == nil)
        InspectorSection("줄 및 칸 크기") {
            LabeledContent("높이") {
                HStack(spacing: 8) {
                    NumberStepper(value: cell?.height.map { Units.millimeters($0) }, unit: "mm", range: 1...1000) { setCell(CellProps(height: Units.units($0))) }
                    Button("같게") { viewer.editCells { .equalizeCells($0, height: true) } }.disabled(!context.cellBlock)
                }
            }
            LabeledContent("너비") {
                HStack(spacing: 8) {
                    NumberStepper(value: cell?.width.map { Units.millimeters($0) }, unit: "mm", range: 1...1000) { setCell(CellProps(width: Units.units($0))) }
                    Button("같게") { viewer.editCells { .equalizeCells($0, height: false) } }.disabled(!context.cellBlock)
                }
            }
        }
        InspectorSection {
            Tiles {
                command("표 뒤집기…", Icon.flipTable) { viewer.flippingTable = true }
                command("표 나누기", Icon.splitTable) { viewer.editTable(.split) }
                command("표 붙이기", Icon.attachTable) { viewer.editTable(.attach) }
            }
        }
    }
    /// Three steps on a row or a column: add on one side or the other, or delete.
    private func tableSteps(_ steps: [(title: String, symbol: String, change: TableChange)]) -> some View {
        Segments(segments: steps.map { .init(symbol: $0.symbol, help: $0.title) }, on: steps.map { _ in false }, any: true) {
            viewer.editTable(steps[$0].change)
        }
        .fixedSize()
    }
    private func setCell(_ change: CellProps) {
        guard let target = document.selection?.focus.target, target.cell != nil else { return }
        viewer.setCell(target, change)
    }
    /// The cells as Pages's 셀: 채우기, 테두리 by the sides it goes on, then split, merged and 계산식.
    @ViewBuilder private func cells(_ context: EditingContext) -> some View {
        InspectorSection {
            LabeledContent("채우기") {
                ColorWell(hex: Binding(get: { cellFill?.color ?? "none" }, set: { color in
                    let fill = PageFill(color: color, patternColor: cellFill?.patternColor ?? "#000000", pattern: cellFill?.pattern ?? 0)
                    viewer.setCellBorder(CellBorder(fill: fill), all: false, one: false)
                }), none: "none")
            }
        }
        InspectorSection("테두리") {
            HStack(alignment: .top, spacing: 8) {
                // The sides a line goes on, as Pages's: 모두, 안쪽, 바깥쪽; 왼쪽, 세로 안쪽, 오른쪽;
                // 위쪽, 가로 안쪽, 아래쪽.
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach([[("모두", [0, 1, 2, 3, 4, 5]), ("안쪽", [4, 5]), ("바깥쪽", [0, 1, 2, 3])],
                             [("왼쪽", [0]), ("세로 안쪽", [5]), ("오른쪽", [1])],
                             [("위쪽", [2]), ("가로 안쪽", [4]), ("아래쪽", [3])]], id: \.first!.0) { row in
                        GridRow {
                            ForEach(row, id: \.0) { title, sides in
                                Button { cellSides = sides; applyCellLine() } label: { SideIcon(sides: sides) }
                                    .buttonStyle(.borderless)
                                    .background(cellSides == sides ? Color.secondary.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    .help(title)
                                    .accessibilityLabel(title)
                            }
                        }
                    }
                }
                // In one box, as Pages's.
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .fixedSize()
                LineRow(line: Binding(get: { cellLine }, set: { cellLine = $0; applyCellLine() }), stacked: true)
            }
        }
        InspectorSection("셀") {
            Tiles {
                command("셀 나누기…", Icon.splitCells) { viewer.splittingCells = true }
                Group {
                    command("셀 합치기", Icon.mergeCells) { viewer.editCells { .mergeCells($0) } }
                    command("셀 너비를 같게", Icon.equalWidth) { viewer.editCells { .equalizeCells($0, height: false) } }
                    command("셀 높이를 같게", Icon.equalHeight) { viewer.editCells { .equalizeCells($0, height: true) } }
                }
                .disabled(!context.cellBlock)
            }
            TransparentLinesToggle(viewer: viewer)
        }
        InspectorSection("계산식") {
            ChoiceButtons(items: MenuItems.blockFunctions.map { function in
                Choice(title: function.title, enabled: context.cellBlock) { viewer.editCells { .calculateBlock($0, function.function) } }
            } + [Choice(title: "계산식…", symbol: Icon.calculation, enabled: !context.cellBlock) { viewer.calculating = true }])
        }
        DialogButtons { Button("셀 테두리/배경…") { viewer.showCellBorder(one: false) } }.padding(16)
    }
    /// Puts the 테두리's line on the sides chosen, in the selected cells.
    private func applyCellLine() {
        guard !cellSides.isEmpty else { return }
        var border = CellBorder()
        for side in cellSides { border.sides[side] = cellLine }
        viewer.setCellBorder(border, all: false, one: false)
    }

    @ViewBuilder private func headerFooter(_ context: EditingContext) -> some View {
        InspectorSection("머리말") { ChoiceButtons(items: MenuItems.headerChoices(viewer, footer: false)) }
        InspectorSection("꼬리말") { ChoiceButtons(items: MenuItems.headerChoices(viewer, footer: true)) }
        InspectorSection("상용구") {
            ChoiceButtons(items: [("전체 쪽수", PageCode.total), ("현재 쪽 번호", .page), ("현재 쪽/전체 쪽수", .pageOfTotal)]
                .map { title, code in Choice(title: title) { viewer.insertPageCode(code) } })
        }
        InspectorSection {
            Tiles {
                command("이전 머리말/꼬리말", Icon.previous) { viewer.goTo(.previousHeaderFooter) }
                command("다음 머리말/꼬리말", Icon.next) { viewer.goTo(.nextHeaderFooter) }
                command("편집 용지…", Icon.pageSetup) { viewer.showPageSetup() }
                command("지우기", Icon.eraseCodes) { document.deleteHeaderFooter(viewer.undoManager) }
            }
        } footer: {
            DialogButtons { Button("닫기") { document.closeHeaderFooter() } }
        }
    }
    @ViewBuilder private func annotations(_ context: EditingContext) -> some View {
        InspectorSection {
            Tiles {
                command("각주/미주 모양…", Icon.noteShape) { viewer.showNoteShapes() }
                command("주석 지우기", Icon.eraseCodes) { document.deleteNote(viewer.undoManager) }
                command("이전 주석으로", Icon.previous) { viewer.goTo(.previousNote) }
                command("다음 주석으로", Icon.next) { viewer.goTo(.nextNote) }
            }
        } footer: {
            DialogButtons { Button("닫기") { document.closeNote() } }
        }
    }

    // MARK: Rows

    /// A command as a tile: its icon over its name.
    private func command(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { TileLabel(title: title, symbol: symbol) }
    }

    /// 색조 as the picker reads it; 워터마크 is no effect at its brightness and contrast.
    private static func effect(_ props: ObjectProps?) -> String {
        guard let props else { return "" }
        if props.effect == "RealPic", props.brightness == 70, props.contrast == -50 { return "Watermark" }
        return props.effect ?? "RealPic"
    }
}

/// The dialogs a group leads to: buttons as wide as the inspector, one under another, as Keynote's.
struct DialogButtons<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 8) { content }
            .controlSize(.large)
            .flexibleButtons()
    }
}

/// 텍스트, as Keynote's: the paragraph's 스타일 over 스타일 (font, character styles, colors,
/// alignment, spacing and lists) and 레이아웃 (margins, first line, line breaking, 테두리 and
/// 배경). All of 글자 모양 and 문단 모양 is here, each change applied at once.
private struct TextTab: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    /// 스타일 (0), 레이아웃 (1) or 기타 (2).
    @State private var layout: Int
    /// The 언어 the font and scales show and change; nil for 대표 (all of them).
    @State private var language: Int?
    @State private var showsMore = false
    @State private var showsStyles = false

    /// Shows 텍스트 over the style, when no tabs do.
    let title: Bool

    init(document: HwpDocument, viewer: Viewer, title: Bool) {
        (self.document, self.viewer, self.title, _layout) = (document, viewer, title, State(initialValue: viewer.textLayout))
    }

    private var editor: PageEditor { viewer.canvas.editor }
    private var text: CharStyle? { document.format?.text }
    private var paragraph: ParaStyle? { document.format?.paragraph }

    /// The title, the style and 스타일/레이아웃 stay; the groups under them scroll.
    var body: some View {
        VStack(spacing: 0) {
            InspectorScroll(fixed: true) {
                InspectorSection {
                    if title {
                        VStack(spacing: 4) {
                            Text("텍스트").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            Divider()
                        }
                    }
                    // As Pages's: the style's name, its list in a popover under it.
                    Button { showsStyles = true } label: {
                        HStack {
                            Text(document.styles.first { $0.id == document.format?.style }?.name ?? "")
                            Spacer()
                            Image(systemName: "chevron.down").font(.body.weight(.semibold))
                        }
                    }
                    .controlSize(.extraLarge)
                    .popover(isPresented: $showsStyles, arrowEdge: .bottom) {
                        StylePane(document: document, viewer: viewer) { showsStyles = false }
                    }
                    .flexibleButtons()
                    .disabled(!document.context.canApplyStyle)
                    Divider()
                    Segments([0, 1, 2], selection: $layout, accent: true) { let title = ["스타일", "레이아웃", "기타"][$0]; return .init(title: title, help: title) }
                }
            }
            InspectorScroll {
                Group { switch layout { case 1: layoutPane; case 2: otherPane; default: stylePane } }
                    .disabled(!document.context.canFormat)
            }
        }
        .onChange(of: layout) { viewer.textLayout = layout }
    }

    // MARK: 스타일

    @ViewBuilder private var stylePane: some View {
        let languages = document.format?.languages ?? []
        let font = language.flatMap { languages.indices.contains($0) ? languages[$0].font : nil } ?? text?.font
        InspectorSection("글꼴") {
            FontPicker(font: font, language: language) { editor.format(CharStyle(language: language, font: $0)) }
                .equatable()
                .flexibleButtons()
            HStack(spacing: 8) {
                Picker("언어", selection: $language) {
                    Text("대표").tag(Int?.none)
                    ForEach(CharShapeSheet.languageNames.indices, id: \.self) { Text(CharShapeSheet.languageNames[$0]).tag(Int?.some($0)) }
                }
                .labelsHidden()
                .flexibleButtons()
                .help("언어")
                NumberStepper(value: text?.size, unit: "pt", range: 1...4096) { editor.format(CharStyle(size: $0)) }
                    .help("기준 크기")
            }
            HStack(spacing: 8) {
                let styles: [(title: String, symbol: String, on: Bool?, toggle: () -> Void)] = [
                    ("진하게", "bold", text?.bold, editor.toggleBold), ("기울임", "italic", text?.italic, editor.toggleItalic),
                    ("밑줄", "underline", text?.underline, editor.toggleUnderline), ("취소선", "strikethrough", text?.strikethrough, editor.toggleStrikethrough),
                ]
                Segments(segments: styles.map { .init(symbol: $0.symbol, help: $0.title) }, on: styles.map { $0.on == true }, any: true) {
                    styles[$0].toggle()
                }
                Button { showsMore = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape")
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                }
                    .help("글자 모양")
                    .accessibilityLabel("글자 모양")
                    .popover(isPresented: $showsMore, arrowEdge: .bottom) { more }
            }
        }
        InspectorSection {
            LabeledContent("글자 색") { ColorWell(hex: char(\.color, "#000000")) }
            LabeledContent("음영 색") { ColorWell(hex: char(\.shade, FormatChoices.none), none: FormatChoices.none) }
        }
        InspectorSection {
            Segments(Alignment.allCases.map(Optional.some),
                     selection: Binding(get: { paragraph?.alignment }, set: { if let alignment = $0 { editor.format(ParaStyle(alignment: alignment)) } })) {
                let label = FormatChoices.label($0!)
                return .init(symbol: label.symbol, help: label.title)
            }
            // A list paragraph a 수준 up or down; another, its 왼쪽 여백 by 10 pt.
            Segments(segments: [.init(symbol: "decrease.indent", help: "왼쪽 여백 줄이기"), .init(symbol: "increase.indent", help: "왼쪽 여백 키우기")],
                     on: [false, false], any: true) { index in
                let step = index == 0 ? -1 : 1
                if (paragraph?.head ?? "None") != "None" {
                    editor.stepLevel(by: step)
                } else if let margin = paragraph?.marginLeft {
                    editor.format(ParaStyle(marginLeft: max(0, margin + Double(step) * 10)))
                }
            }
        }
        InspectorSection {
            DisclosureGroup {
                VStack(spacing: 10) {
                    LabeledContent("줄 간격") {
                        Picker("줄 간격", selection: Binding(get: { paragraph?.lineSpacingKind ?? .percent }, set: { kind in
                            guard kind != paragraph?.lineSpacingKind else { return }
                            editor.format(ParaStyle(lineSpacing: kind == .percent ? 160 : 12, lineSpacingKind: kind))
                        })) {
                            Text("글자에 따라").tag(LineSpacingKind.percent)
                            Text("고정 값").tag(LineSpacingKind.fixed)
                            Text("여백만 지정").tag(LineSpacingKind.spaceOnly)
                            Text("최소").tag(LineSpacingKind.minimum)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    LabeledContent("문단 위") { length(\.spacingBefore) }
                    LabeledContent("문단 아래") { length(\.spacingAfter) }
                }
            } label: {
                LabeledContent {
                    let percent = (paragraph?.lineSpacingKind ?? .percent) == .percent
                    NumberStepper(value: paragraph?.lineSpacing, unit: percent ? "%" : "pt", range: percent ? 50...500 : 0...1000,
                                  step: percent ? 10 : 1) { value in
                        editor.format(ParaStyle(lineSpacing: value, lineSpacingKind: paragraph?.lineSpacingKind ?? .percent))
                    }
                } label: { Text("간격").font(.headline.weight(.semibold)) }
            }
        }
        InspectorSection { lists }
    }

    /// 글머리표 및 문단 번호: the kind beside the title, its shapes, 수준 and 시작 번호 방식 under it.
    @ViewBuilder private var lists: some View {
        let head = paragraph?.head ?? "None"
        // Nothing to open with no list.
        if !["Bullet", "Number"].contains(head) {
            listsTitle(head)
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    if head == "Bullet" {
                        Picker("글머리표", selection: Binding(get: { paragraph?.bullet }, set: { bullet in
                            if let bullet { editor.format(ParaStyle(head: "Bullet", bullet: bullet)) }
                        })) {
                            if paragraph?.bullet.map(FormatChoices.bullets.contains) != true { Text("").tag(String?.none) }
                            ForEach(FormatChoices.bullets, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .labelsHidden()
                        .flexibleButtons()
                    } else if head == "Number" {
                        Picker("문단 번호", selection: Binding(get: { paragraph?.numbering }, set: { kind in
                            if let kind { editor.format(ParaStyle(head: "Number", numbering: kind)) }
                        })) {
                            if paragraph?.numbering == nil { Text("").tag(Int?.none) }
                            ForEach(FormatChoices.numberings.indices, id: \.self) {
                                Text(FormatChoices.numberings[$0].prefix(3).joined(separator: " ")).tag(Int?.some($0))
                            }
                        }
                        .labelsHidden()
                        .flexibleButtons()
                    }
                    if head == "Number", document.context.inBody, let numbering = paragraph?.numbering {
                        restart(numbering)
                    }
                }
            } label: { listsTitle(head) }
        }
    }

    /// 시작 번호 방식: 직전에서 계속 (the list just before), 이전에서 계속 (the one before that),
    /// 처음부터 시작 (from 1), 다음에서 시작 (from the number given).
    /// The engine reads the way back from where the paragraph's list starts, and its
    /// "앞 번호 목록에 이어" keeps the list as it is; its "이전 번호 목록에 이어" joins the
    /// nearest list before that is not the paragraph's own. So both ways go through that one:
    /// once to the list just before, again to the one before it.
    private func restart(_ numbering: Int) -> some View {
        let restart = paragraph?.restart ?? 0, start = paragraph?.startNumber ?? 1
        let way = restart < 2 ? restart : start == 1 ? 2 : 3
        return HStack(alignment: .lastTextBaseline) {
            Picker("시작 번호 방식", selection: Binding(get: { way }, set: { chosen in
                guard chosen != way else { return }
                let join = ParaStyle(head: "Number", numbering: numbering, restart: 1)
                switch chosen {
                case 0: editor.format(join)
                case 1:
                    if way != 0 { editor.format(join) }
                    editor.format(join)
                default:
                    editor.format(ParaStyle(head: "Number", numbering: numbering, restart: 2, startNumber: chosen == 2 ? 1 : max(start, 2)))
                }
            })) {
                Text("직전에서 계속").tag(0)
                Text("이전에서 계속").tag(1)
                Text("처음부터 시작").tag(2)
                Text("다음에서 시작").tag(3)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .labeledContentStyle(.automatic)
            NumberStepper(value: Double(start), unit: "", range: 1...65535) { start in
                editor.format(ParaStyle(head: "Number", numbering: numbering, restart: 2, startNumber: Int(start)))
            }
            .controlSize(.small)
            .disabled(way != 3)
        }
    }

    private func listsTitle(_ head: String) -> some View {
        LabeledContent {
            let shown = ["Bullet", "Number"].contains(head) ? head : "None"
            Picker("글머리표 및 문단 번호", selection: Binding(get: { shown }, set: { kind in
                // The same kind again keeps the paragraph's shape and numbering.
                guard kind != shown else { return }
                editor.format(kind == "Bullet" ? ParaStyle(head: kind, bullet: FormatChoices.bullets[0])
                              : kind == "Number" ? ParaStyle(head: kind, numbering: 0) : ParaStyle(head: "None"))
            })) {
                Text("없음").tag("None")
                Text("글머리표").tag("Bullet")
                Text("문단 번호").tag("Number")
            }
            .labelsHidden()
            .fixedSize()
        } label: { Text("글머리표 및 문단 번호").font(.headline.weight(.semibold)) }
    }

    /// The rest of 글자 모양: scales of the 언어, 첨자, the attributes, 밑줄, 취소선, 테두리 and 배경.
    private var more: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("추가 텍스트 옵션").font(.headline.weight(.semibold)).frame(maxWidth: .infinity)
                LabeledContent("장평") { lingual(\.ratio, range: 50...200) }
                LabeledContent("자간") { lingual(\.spacing, range: -50...50) }
                LabeledContent("상대 크기") { lingual(\.relativeSize, range: 10...250) }
                LabeledContent("글자 위치") { lingual(\.offset, range: -100...100) }
                Segments([0, 1, 2], selection: Binding(get: { text?.superscript == true ? 1 : text?.`subscript` == true ? 2 : 0 }, set: { place in
                    editor.format(CharStyle(superscript: place == 1, subscript: place == 2))
                })) { let title = ["보통", "위 첨자", "아래 첨자"][$0]; return .init(title: title, help: title) }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Toggle("외곽선", isOn: char(\.outline, false)); Toggle("그림자", isOn: char(\.shadow, false)) }
                    GridRow { Toggle("양각", isOn: char(\.emboss, false)); Toggle("음각", isOn: char(\.engrave, false)) }
                }
                .checkbox()
                Divider()
                OpeningRows(title: "밑줄", open: text?.underline == true) {
                    Picker("밑줄", selection: Binding(get: { text?.underline != true ? 0 : text?.underlineTop == true ? 2 : 1 }, set: { place in
                        editor.format(place == 0 ? CharStyle(underline: false) : CharStyle(underline: true, underlineTop: place == 2))
                    })) { Text("없음").tag(0); Text("아래").tag(1); Text("위").tag(2) }
                    .labelsHidden()
                    .fixedSize()
                } rows: {
                    LabeledContent("모양") { ChoiceField(char(\.underlineShape, 0), LineShapes.names.indices.map { ($0, LineShapes.names[$0]) }, images: LineShapes.images) }
                    LabeledContent("색") { ColorWell(hex: char(\.underlineColor, "#000000")) }
                }
                OpeningRows(title: "취소선", open: text?.strikethrough == true) {
                    ChoiceField(Binding(get: { text?.strikethrough == true ? (text?.strikeShape ?? 0) + 1 : 0 }, set: { kind in
                        editor.format(kind == 0 ? CharStyle(strikethrough: false) : CharStyle(strikethrough: true, strikeShape: kind - 1))
                    }), Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds)
                } rows: {
                    LabeledContent("색") { ColorWell(hex: char(\.strikeColor, "#000000")) }
                }
                Divider()
                BorderFillRows(style: Binding(get: { text ?? CharStyle() }, set: { new in
                    if let old = text { send(new.changesWithBorderFill(from: old)) }
                }))
            }
            .labeledContentStyle(RowStyle())
            .padding(16)
        }
        .frame(width: 300, height: 520)
    }

    // MARK: 레이아웃

    @ViewBuilder private var layoutPane: some View {
        InspectorSection {
            DisclosureGroup {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 4) { length(\.marginLeft); Text("왼쪽").font(.caption) }
                    VStack(spacing: 4) { length(\.marginRight); Text("오른쪽").font(.caption) }
                }
                .frame(maxWidth: .infinity)
            } label: { Text("여백").font(.headline.weight(.semibold)) }
        }
        // 들여쓰기 (positive) and 내어쓰기 (negative) are one value of the paragraph.
        InspectorSection {
            DisclosureGroup {
                let indent = paragraph?.indent ?? 0
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 4) {
                        NumberStepper(value: paragraph.map { max($0.indent ?? 0, 0) }, unit: "pt", range: 0...1000) { amount in
                            if amount > 0 || indent > 0 { editor.format(ParaStyle(indent: amount)) }
                        }
                        Text("들여쓰기").font(.caption)
                    }
                    VStack(spacing: 4) {
                        NumberStepper(value: paragraph.map { max(-($0.indent ?? 0), 0) }, unit: "pt", range: 0...1000) { amount in
                            if amount > 0 || indent < 0 { editor.format(ParaStyle(indent: -amount)) }
                        }
                        Text("내어쓰기").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
            } label: { Text("들여쓰기").font(.headline.weight(.semibold)) }
        }
        InspectorSection {
            BorderFillRows(style: paragraphBorderFill, fill: false)
            Toggle("문단 테두리 연결", isOn: para(\.borderConnect, false)).checkbox()
        }
        InspectorSection { BorderFillRows(style: paragraphBorderFill, border: false) }
    }

    // MARK: 기타

    @ViewBuilder private var otherPane: some View {
        InspectorSection("줄 나눔 기준") {
            LabeledContent("한글 단위") {
                Picker("한글 단위", selection: para(\.koreanBreakUnit, 1)) { Text("글자").tag(1); Text("어절").tag(0) }.labelsHidden().fixedSize()
            }
            LabeledContent("영어 단위") {
                Picker("영어 단위", selection: para(\.englishBreakUnit, 0)) { Text("단어").tag(0); Text("하이픈").tag(1); Text("글자").tag(2) }
                    .labelsHidden().fixedSize()
            }
        }
    }

    private var paragraphBorderFill: Binding<ParaStyle> {
        Binding(get: { paragraph ?? ParaStyle() }, set: { new in
            if let old = paragraph { editor.format(new.changesWithBorderFill(from: old)) }
        })
    }

    // MARK: Values

    /// A character value, applied as it is changed (테두리 and 배경 together, as the engine takes them).
    private func char<T>(_ key: WritableKeyPath<CharStyle, T?>, _ fallback: T) -> Binding<T> {
        Binding { text?[keyPath: key] ?? fallback } set: { value in
            guard let old = text else { return }
            var new = old
            new[keyPath: key] = value
            send(new.changesWithBorderFill(from: old))
        }
    }
    private func send(_ change: CharStyle) {
        if change != CharStyle() { editor.format(change) }
    }
    private func para<T>(_ key: WritableKeyPath<ParaStyle, T?>, _ fallback: T) -> Binding<T> {
        Binding { paragraph?[keyPath: key] ?? fallback } set: { value in
            guard let old = paragraph else { return }
            var new = old
            new[keyPath: key] = value
            let change = new.changes(from: old)
            if change != ParaStyle() { editor.format(change) }
        }
    }
    /// A length of the paragraph in points.
    private func length(_ key: WritableKeyPath<ParaStyle, Double?>) -> some View {
        NumberStepper(value: paragraph?[keyPath: key], unit: "pt", range: 0...1000) { value in
            var change = ParaStyle()
            change[keyPath: key] = value
            editor.format(change)
        }
    }
    /// A percentage of the chosen 언어, or of all of them.
    private func lingual(_ key: WritableKeyPath<CharStyle, Double?>, range: ClosedRange<Double>) -> some View {
        let languages = document.format?.languages ?? []
        let value = language.flatMap { languages.indices.contains($0) ? languages[$0][keyPath: key] : nil } ?? text?[keyPath: key]
        return NumberStepper(value: value, unit: "%", range: range) { value in
            var change = CharStyle(language: language)
            change[keyPath: key] = value
            editor.format(change)
        }
    }
}

/// 테두리 and 배경 of the text or paragraph, one row each.
private struct BorderFillRows<Style: BorderFillStyle>: View {
    @Binding var style: Style
    var border = true, fill = true
    var body: some View {
        if border { borderRows }
        if border && fill { Divider() }
        if fill { fillRows }
    }
    /// The line's kind beside 테두리, its color and width under it.
    private var borderRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("테두리") { ChoiceField(int(\.borderLine), Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds) }
            HStack(spacing: 8) {
                ColorWell(hex: text(\.borderColor, "#000000"), flexible: true)
                    .frame(maxWidth: .infinity)
                NumberStepper(value: Swatches.widths[min(style.borderWidth ?? 0, Swatches.widths.count - 1)], unit: "mm",
                              range: Swatches.widths.first!...Swatches.widths.last!, step: Self.widthStep, wide: true) { width($0) }
                    .frame(maxWidth: .infinity)
            }
            .disabled((style.borderLine ?? 0) == 0)
        }
    }
    /// HWP's widths are a list: a step moves along it, a typed width takes the nearest.
    private static var widthStep: Double { 0.001 }
    private func width(_ value: Double) {
        let widths = Swatches.widths, now = min(style.borderWidth ?? 0, widths.count - 1)
        let index = abs(value - (widths[now] + Self.widthStep)) < 1e-9 ? min(now + 1, widths.count - 1)
            : abs(value - (widths[now] - Self.widthStep)) < 1e-9 ? max(now - 1, 0)
            : widths.indices.min { abs(widths[$0] - value) < abs(widths[$1] - value) }!
        style.borderWidth = index
    }
    @ViewBuilder private var fillRows: some View {
        LabeledContent("배경") { ColorWell(hex: text(\.fillColor, "none"), none: "none") }
        LabeledContent("무늬") {
            HStack(spacing: 8) {
                ChoiceField(int(\.pattern), Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns)
                ColorWell(hex: text(\.patternColor, "#000000"))
            }
        }
    }
    private func int(_ key: WritableKeyPath<Style, Int?>) -> Binding<Int> {
        Binding { style[keyPath: key] ?? 0 } set: { style[keyPath: key] = $0 }
    }
    private func text(_ key: WritableKeyPath<Style, String?>, _ fallback: String) -> Binding<String> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
    }
}

/// A choice whose rows show under it only while it is on (밑줄, 취소선, 테두리): then its
/// name is bold, as a group's title, and the group stands apart from the rows around it.
private struct OpeningRows<Choice: View, Rows: View>: View {
    let title: String
    let open: Bool
    @ViewBuilder let choice: Choice
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent { choice } label: { Text(title).fontWeight(open ? .semibold : .regular) }
            if open { rows }
        }
        .padding(.vertical, open ? 6 : 0)
    }
}

/// A number typed or stepped, with its unit; it applies on Return or a step.
private struct NumberStepper: View {
    let value: Double?
    let unit: String
    let range: ClosedRange<Double>
    var step: Double = 1
    /// As wide as its place, rather than a number's width.
    var wide = false
    let apply: (Double) -> Void
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: wide ? nil : 48)
                .frame(maxWidth: wide ? .infinity : nil)
                .onSubmit { Double(text).map { apply(min(max($0, range.lowerBound), range.upperBound)) } }
            Text(unit).foregroundStyle(.secondary)
            Stepper("", onIncrement: { apply(min((value ?? range.lowerBound) + step, range.upperBound)) },
                    onDecrement: { apply(max((value ?? range.lowerBound) - step, range.lowerBound)) })
                .labelsHidden()
        }
        .onAppear { text = Self.label(value) }
        .onChange(of: value) { text = Self.label(value) }
    }
    private static func label(_ value: Double?) -> String {
        guard let value else { return "" }
        // Two places, for widths such as 0.12 mm.
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// 밝기 or 대비 of a picture, applied when the slider is let go.
private struct PictureSlider: View {
    let title: String
    let value: Int32?
    let apply: (Int32) -> Void
    @State private var shown = 0.0
    var body: some View {
        // As Pages's: the name over the slider, the number beside it.
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            HStack(spacing: 8) {
                Slider(value: $shown, in: -100...100, step: 5) { editing in
                    if !editing, Int32(shown) != value { apply(Int32(shown)) }
                }
                NumberStepper(value: value.map(Double.init), unit: "%", range: -100...100, step: 5) { apply(Int32($0)) }
            }
        }
        .onAppear { shown = Double(value ?? 0) }
        .onChange(of: value) { shown = Double(value ?? 0) }
    }
}

/// A line's 종류, 색 and 굵기, each on its own line; or only 색 and 굵기 side by side, the
/// kind shown beside a title.
private struct LineRow: View {
    @Binding var line: BorderSide
    var stacked = false
    var body: some View {
        let color = ColorWell(hex: $line.color, flexible: true)
        let width = ChoiceField(Binding { Int(line.width) } set: { line.width = UInt8($0) },
                                Swatches.widths.indices.map { ($0, "") }, images: Swatches.widthImages, flexible: true)
        if stacked {
            VStack(alignment: .leading, spacing: 8) { Self.kind($line, flexible: true); color; width }
        } else {
            HStack(spacing: 8) { color; width }
        }
    }
    static func kind(_ line: Binding<BorderSide>, flexible: Bool = false) -> some View {
        ChoiceField(Binding { Int(line.wrappedValue.line) } set: { line.wrappedValue.line = UInt8($0) },
                    Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds, flexible: flexible)
    }
}

/// 회전 as Pages's: a round slider, its knob at the angle.
private struct RotationDial: NSViewRepresentable {
    let angle: Double?
    let apply: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let dial = NSSlider(value: 0, minValue: 0, maxValue: 360, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        dial.sliderType = .circular
        // Applied when let go: each change is one edit to undo.
        dial.isContinuous = false
        return dial
    }
    func updateNSView(_ dial: NSSlider, context: Context) {
        context.coordinator.apply = apply
        dial.isEnabled = context.environment.isEnabled
        if let angle, dial.doubleValue != angle { dial.doubleValue = angle }
    }
    func makeCoordinator() -> Coordinator { Coordinator(apply: apply) }
    @MainActor final class Coordinator: NSObject {
        var apply: (Double) -> Void
        init(apply: @escaping (Double) -> Void) { self.apply = apply }
        @objc func changed(_ dial: NSSlider) { apply(dial.doubleValue.rounded().truncatingRemainder(dividingBy: 360)) }
    }
}

/// 셀's 투명 선.
private struct TransparentLinesToggle: View {
    @ObservedObject var viewer: Viewer
    var body: some View {
        Toggle("투명 선", isOn: $viewer.showsTransparentLines).checkbox()
    }
}

/// 문서 and 구역, as Pages's 문서 and 섹션: the paper of the section holding the caret, and that
/// section's 구역 설정, each change applied at once.
struct DocumentInspector: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var page: PageSetup?
    @State private var setup: SectionSetup?
    @State private var tab = 0
    /// 사용자 정의 chosen, so 폭 and 길이 show although the size is a listed paper's.
    @State private var custom = false
    /// Changes made here: a read sent before one of them answers with what came before it.
    @State private var changes = 0

    var body: some View {
        let section = document.selection?.focus.target.section ?? 0
        VStack(spacing: 0) {
            InspectorScroll(fixed: true) {
                InspectorSection {
                    Segments([0, 1], selection: $tab, accent: true, capsule: true) { let title = ["문서", "구역"][$0]; return .init(title: title, help: title) }
                        .controlSize(.large)
                }
            }
            InspectorScroll {
                if tab == 0 { paperPane(section) } else { sectionPane(section) }
            }
            .disabled(document.context.locked)
        }
        .task(id: "\(document.revision) \(section)") {
            let before = changes
            let read = (try? await document.pageSetup(section: section), try? await document.sectionSetup(section: section))
            // A change made while reading is newer than what was read; its own edit reads again.
            guard before == changes else { return }
            (page, setup) = read
        }
    }

    // MARK: 문서

    @ViewBuilder private func paperPane(_ section: UInt32) -> some View {
        Group {
            InspectorSection("용지 종류") {
                let paper = paper(section)
                Picker("용지 종류", selection: paper) {
                    Text("사용자 정의").tag(String?.none)
                    ForEach(PageSetupSheet.papers, id: \.name) { Text($0.name).tag(String?.some($0.name)) }
                }
                .labelsHidden()
                .flexibleButtons()
                if paper.wrappedValue == nil {
                    // 폭 and 길이 of the paper as it lies.
                    let landscape = page?.landscape ?? false
                    lengths(("폭", landscape ? \.height : \.width), ("길이", landscape ? \.width : \.height), section)
                }
            }
            InspectorSection("용지 방향") {
                orientation(section)
            }
            InspectorSection {
                lengths(("머리말", \.marginHeader), ("꼬리말", \.marginFooter), section)
            }
            InspectorSection("용지 여백") {
                lengths(("위쪽", \.marginTop), ("아래쪽", \.marginBottom), section)
                lengths(("왼쪽", \.marginLeft), ("오른쪽", \.marginRight), section)
            }
            InspectorSection {
                // 제본's name at the leading edge, as the inspector's rows.
                // The tiles of 편집 용지's 제본.
                IconTiles(selection: Binding(get: { page?.binding ?? 0 }, set: { binding in set(section) { $0.binding = binding } }),
                          options: [(UInt8(0), "한쪽"), (1, "맞쪽"), (2, "위로")], fill: true) { binding, on in
                    PagePictogram.binding(binding, on: on)
                }
                .flexibleButtons()
                LabeledContent("제본 여백") {
                    NumberStepper(value: page.map { Units.millimeters($0.marginGutter) }, unit: "mm", range: 0...1000) { mm in
                        set(section) { $0.marginGutter = Units.units(mm) }
                    }
                }
            } footer: {
                DialogButtons { Button("쪽 테두리/배경…") { viewer.showPageBorder() } }
            }
        }
        .disabled(page == nil)
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

    /// Two lengths side by side, each with its name under it, as Pages's 문서 여백.
    private func lengths(_ first: (String, WritableKeyPath<PageSetup, UInt32>), _ second: (String, WritableKeyPath<PageSetup, UInt32>),
                         _ section: UInt32) -> some View {
        HStack(alignment: .top, spacing: 8) {
            length(first.0, first.1, section)
            length(second.0, second.1, section)
        }
    }
    private func length(_ title: String, _ key: WritableKeyPath<PageSetup, UInt32>, _ section: UInt32) -> some View {
        VStack(spacing: 4) {
            NumberStepper(value: page.map { Units.millimeters($0[keyPath: key]) }, unit: "mm", range: 0...1000) { mm in
                set(section) { $0[keyPath: key] = Units.units(mm) }
            }
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
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
            return PageSetupSheet.papers.first { abs($0.width - size.0) < 0.5 && abs($0.height - size.1) < 0.5 }?.name
        } set: { name in
            custom = name == nil
            guard let paper = PageSetupSheet.papers.first(where: { $0.name == name }) else { return }
            set(section) { ($0.width, $0.height) = (Units.units(paper.width), Units.units(paper.height)) }
        }
    }

    // MARK: 구역

    @ViewBuilder private func sectionPane(_ section: UInt32) -> some View {
        Group {
            InspectorSection("시작 쪽 번호") {
                HStack(spacing: 8) {
                    Picker("시작 쪽 번호", selection: Binding(get: { (setup?.pageNum ?? 0) > 0 ? 3 : Int(setup?.pageNumType ?? 0) }, set: { kind in
                        change(section) { setup in
                            if kind == 3 { (setup.pageNum, setup.pageNumType) = (max(setup.pageNum, 1), 0) } else { (setup.pageNum, setup.pageNumType) = (0, UInt8(kind)) }
                        }
                    })) { Text("이어서").tag(0); Text("홀수").tag(1); Text("짝수").tag(2); Text("사용자").tag(3) }
                    .labelsHidden()
                    .flexibleButtons()
                    number(\.pageNum, section)
                }
            }
            InspectorSection("개체 시작 번호") {
                start("그림", \.pictureNum, section)
                start("표", \.tableNum, section)
                start("수식", \.equationNum, section)
            }
            InspectorSection {
                Group {
                    Toggle("첫 쪽에만 머리말/꼬리말 감추기", isOn: flag(section, get: { $0.hideHeader && $0.hideFooter }, set: { ($0.hideHeader, $0.hideFooter) = ($1, $1) }))
                    Toggle("첫 쪽에만 바탕쪽 감추기", isOn: flag(section, get: { $0.hideMasterPage }, set: { $0.hideMasterPage = $1 }))
                    Toggle("첫 쪽에만 테두리/배경 감추기", isOn: flag(section, get: { $0.hideBorder && $0.hideFill }, set: { ($0.hideBorder, $0.hideFill) = ($1, $1) }))
                    Toggle("빈 줄 감추기", isOn: flag(section, get: { $0.hideEmptyLine }, set: { $0.hideEmptyLine = $1 }))
                }
                .checkbox()
            }
            InspectorSection {
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
        .disabled(setup == nil)
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

// MARK: Keynote's inspector parts

/// The inspector's groups one under another, scrolling, with rows spread across it.
/// `fixed`, as tall as its groups and not scrolling: for what stays over the groups that do.
/// Its controls are in a scroll view all the same: out of one, macOS gives a segmented control
/// the toolbar's look, without the accent color.
private struct InspectorScroll<Content: View>: View {
    var fixed = false
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
        }
        .scrollDisabled(fixed)
        .fixedSize(horizontal: false, vertical: fixed)
        .labeledContentStyle(RowStyle())
        .disclosureGroupStyle(GroupDisclosure())
        .buttonBorderShape(.roundedRectangle)
    }
}

/// A group: its title in bold over its controls, and a line under it.
struct InspectorSection<Header: View, Content: View, Footer: View>: View {
    let header: Header
    let content: Content
    let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.font(.headline.weight(.semibold))
            content
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 16) }
    }
}
extension InspectorSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { (header, self.content, footer) = (EmptyView(), content(), EmptyView()) }
}
extension InspectorSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { (header, self.content, footer) = (Text(title), content(), EmptyView()) }
}
extension InspectorSection where Header == Text {
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        (header, self.content, self.footer) = (Text(title), content(), footer())
    }
}
extension InspectorSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        (header, self.content, self.footer) = (EmptyView(), content(), footer())
    }
}
extension InspectorSection {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        (self.header, self.content, self.footer) = (header(), content(), footer())
    }
}

/// A group that folds: its title row with the chevron opens and closes it, with
/// no more room around it than a group that does not fold.
private struct GroupDisclosure: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                configuration.label
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isExpanded.toggle() }
            if configuration.isExpanded { configuration.content }
        }
    }
}

/// A label at the leading edge and its control at the trailing one.
private struct RowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

/// Commands as tiles, two to a row.
struct Tiles<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) { content }
            .flexibleButtons()
    }
}

/// A tile's face: a large icon over the name.
struct TileLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 19)).frame(height: 22)
            Text(title).lineLimit(2).multilineTextAlignment(.center).font(.callout)
        }
        .frame(maxWidth: .infinity, minHeight: 66)
        .padding(.horizontal, 4)
    }
}

/// `Choice`s as buttons in sight, two to a row (or `columns`), in place of a menu.
private struct ChoiceButtons: View {
    let items: [Choice?]
    var columns = 2
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(items.compactMap { $0 }.indices, id: \.self) { index in
                let item = items.compactMap { $0 }[index]
                Button(action: item.action) {
                    HStack(spacing: 6) {
                        if let image = item.image { Image(nsImage: image) } else if let symbol = item.symbol { Image(systemName: symbol) }
                        if !item.title.isEmpty { Text(item.title).lineLimit(1).minimumScaleFactor(0.75) }
                    }
                }
                .disabled(!item.enabled)
                .help(item.title)
            }
        }
        .flexibleButtons()
    }
}

extension View {
    /// A checkbox before its name, as Keynote's, not spread as the inspector's rows are.
    func checkbox() -> some View { toggleStyle(.checkbox).labeledContentStyle(.automatic) }
    /// The pointing hand over a control, as a link's.
    @ViewBuilder func pointing() -> some View {
        if #available(macOS 15, *) { pointerStyle(.link) } else { self }
    }
    /// Buttons and pop-ups as wide as their place, as macOS 26 sizes them; fitted before it.
    @ViewBuilder func flexibleButtons() -> some View {
        if #available(macOS 26, *) { buttonSizing(.flexible) } else { self }
    }
}

#Preview {
    Inspector(document: HwpDocument(), viewer: Viewer())
        .frame(width: 280, height: 700)
}

/// The 퀵 메뉴 over selected text, as Freeform's: 글자 색, 글자 모양 and 크기 in a small bar;
/// 글자 모양 opens the rest above it.
struct QuickMenu: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var showsMore = false
    @State private var showsStyles = false

    private var editor: PageEditor { viewer.canvas.editor }
    private var text: CharStyle? { document.format?.text }
    private var paragraph: ParaStyle? { document.format?.paragraph }

    var body: some View {
        let bar = HStack(spacing: 8) {
            ColorWell(hex: Binding(get: { text?.color ?? "#000000" }, set: { editor.format(CharStyle(color: $0)) }), circle: true)
                .pointing()
            .help("글자 색")
            Button { showsMore = true } label: { Image(systemName: "textformat.ko") }
                .buttonStyle(.borderless)
                .pointing()
                .help("글자 모양")
                .popover(isPresented: $showsMore, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { more }
            Menu {
                ForEach(FormatChoices.sizes, id: \.self) { size in
                    Toggle(FormatChoices.points(size), isOn: Binding(get: { text?.size == size }, set: { _ in editor.format(CharStyle(size: size)) }))
                }
            } label: {
                Text(text?.size.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "")
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointing()
            .help("기준 크기")
        }
        // The bar never takes the keyboard: the selection stays the editor's, for ⌘C and ⌘V.
        .focusable(false)
        .focusEffectDisabled()
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .disabled(!document.context.canFormat)
        Group {
            if #available(macOS 26, *) {
                bar.glassEffect(in: .capsule)
            } else {
                bar.background(.regularMaterial, in: Capsule())
            }
        }
        .padding(4)
    }

    /// 진하게, 기울임, 밑줄 and 문단 스타일 over 정렬, 줄 간격 and 글머리표, and the 글꼴.
    private var more: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                let styles: [(title: String, symbol: String, on: Bool?, toggle: () -> Void)] = [
                    ("진하게", "bold", text?.bold, editor.toggleBold), ("기울임", "italic", text?.italic, editor.toggleItalic),
                    ("밑줄", "underline", text?.underline, editor.toggleUnderline),
                ]
                Segments(segments: styles.map { .init(symbol: $0.symbol, help: $0.title) }, on: styles.map { $0.on == true }, any: true) {
                    styles[$0].toggle()
                }
                .gridCellColumns(2)
                Button { showsStyles = true } label: { Text("가가").frame(maxWidth: .infinity) }
                    .help("문단 스타일")
                    .popover(isPresented: $showsStyles, arrowEdge: .bottom) {
                        StylePane(document: document, viewer: viewer) { showsStyles = false }
                    }
            }
            GridRow {
                Menu {
                    ForEach(Alignment.allCases, id: \.self) { alignment in
                        let label = FormatChoices.label(alignment)
                        Toggle(isOn: Binding(get: { paragraph?.alignment == alignment },
                                             set: { _ in editor.format(ParaStyle(alignment: alignment)) })) {
                            Label(label.title, systemImage: label.symbol)
                        }
                    }
                } label: { Image(systemName: FormatChoices.label(paragraph?.alignment ?? .justify).symbol) }
                    .help("정렬")
                Menu {
                    ForEach(FormatChoices.lineSpacings, id: \.self) { spacing in
                        Toggle("\(Int(spacing))%", isOn: Binding(get: { paragraph?.lineSpacingKind == .percent && paragraph?.lineSpacing == spacing },
                                                                 set: { _ in editor.format(ParaStyle(lineSpacing: spacing, lineSpacingKind: .percent)) }))
                    }
                } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }
                    .help("줄 간격")
                Menu {
                    let head = paragraph?.head ?? "None"
                    ForEach([("None", "없음"), ("Bullet", "글머리표"), ("Number", "문단 번호")], id: \.0) { kind, title in
                        Toggle(title, isOn: Binding(get: { head == kind }, set: { _ in
                            guard kind != head else { return }
                            editor.format(kind == "Bullet" ? ParaStyle(head: kind, bullet: FormatChoices.bullets[0])
                                          : kind == "Number" ? ParaStyle(head: kind, numbering: 0) : ParaStyle(head: "None"))
                        }))
                    }
                } label: { Image(systemName: "list.bullet") }
                    .help("글머리표 및 문단 번호")
            }
            .menuIndicator(.hidden)
            GridRow {
                FontPicker(font: text?.font, language: nil) { editor.format(CharStyle(font: $0)) }
                    .equatable()
                    .gridCellColumns(3)
            }
        }
        .flexibleButtons()
        .buttonBorderShape(.roundedRectangle)
        .frame(width: 240)
        .padding(8)
        .disabled(!document.context.canFormat)
    }
}
