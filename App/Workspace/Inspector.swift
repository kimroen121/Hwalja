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
    /// The caret cell's properties and its 테두리/배경, read with `props`.
    @State private var cell: CellProps?
    @State private var cellBorder: CellBorder?
    /// 셀's 테두리: the line and the sides it last went on.
    @State private var cellLine = BorderSide(line: 1, width: 1, color: "#000000")
    @State private var cellSides: [Int] = []
    /// 대각선 over a block as one cell (하나의 셀처럼 적용).
    @State private var diagonalOne = false
    /// 표 테두리: the line and the sides it last went on.
    @State private var tableLine = BorderSide(line: 1, width: 1, color: "#000000")
    @State private var tableSides: [Int] = []

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
            var read: (cell: CellProps?, border: CellBorder?)?
            if let target = document.selection?.focus.target, target.cell != nil, document.object == nil {
                read = (try? await document.cellProps(target), try? await document.cellBorder(target))
            }
            let object = viewer.arrangedObject
            let objectProps = object == nil ? nil : try? await document.objectProps(object!)
            // A read overtaken by a newer one keeps what that one shows: cancelled, it reads nothing.
            guard !Task.isCancelled else { return }
            if let read { (cell, cellBorder) = read }
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
                lineWidth
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
        InspectorSection { Fold("자르기") { sides([\.cropLeft, \.cropRight, \.cropTop, \.cropBottom]) } }
        InspectorSection { Fold("그림 여백") { sides([\.paddingLeft, \.paddingRight, \.paddingTop, \.paddingBottom]) } }
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
    /// A drawing object as Pages's 스타일: 채우기, 선 (with 화살표 for a 직선, 호 테두리 and 모서리
    /// 곡률 where they apply), 그림자, then 글상자.
    @ViewBuilder private var shape: some View {
        InspectorSection {
            OpeningRows(title: "채우기", open: props?.fillType == "solid") {
                Picker("채우기", selection: Binding { props?.fillType == "solid" ? "solid" : "none" } set: { kind in
                    var change = ObjectProps(fillType: kind)
                    if kind == "solid", props?.fillBgColor == nil { change.fillBgColor = 0xffffff }
                    viewer.arrange(change)
                }) { Text("없음").tag("none"); Text("색").tag("solid") }
                .labelsHidden()
                .fixedSize()
            } rows: {
                LabeledContent("면 색") { ColorWell(hex: color(\.fillBgColor, "#ffffff")) }
                LabeledContent("무늬") {
                    HStack(spacing: 8) {
                        ChoiceField(Binding { max(0, Int(props?.fillPatType ?? 0)) } set: { set(\.fillPatType, Int32($0)) },
                                    Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns)
                        ColorWell(hex: color(\.fillPatColor))
                    }
                }
                LabeledContent("투명도") {
                    NumberStepper(value: props?.fillAlpha.map { (Double($0) * 100 / 255).rounded() }, unit: "%", range: 0...100) {
                        set(\.fillAlpha, UInt32(($0 * 255 / 100).rounded()))
                    }
                }
            }
        }
        InspectorSection {
            OpeningRows(title: "선", open: (props?.lineType ?? 0) != 0) {
                ChoiceField(index(\.lineType), Swatches.lineKinds.indices.prefix(12).map { ($0, "") }, images: Array(Swatches.lineKinds.prefix(12)))
            } rows: {
                lineWidth
                LabeledContent("끝 모양") { ChoiceField(index(\.lineEndShape), Swatches.lineEnds.indices.map { ($0, "") }, images: Swatches.lineEnds) }
                if document.object?.ends != nil {
                    // 화살표 over its 크기 at each end, as Pages's 끝점.
                    HStack(alignment: .top, spacing: 8) {
                        captioned("시작") {
                            VStack(spacing: 8) {
                                arrow(\.arrowStart, Swatches.arrowStarts).help("시작 화살표")
                                arrow(\.arrowStartSize, Swatches.arrowStartSizes).help("시작 크기")
                            }
                        }
                        captioned("끝") {
                            VStack(spacing: 8) {
                                arrow(\.arrowEnd, Swatches.arrowEnds).help("끝 화살표")
                                arrow(\.arrowEndSize, Swatches.arrowEndSizes).help("끝 크기")
                            }
                        }
                    }
                }
            }
            if props?.arcType != nil {
                LabeledContent("호 테두리") {
                    Picker("호 테두리", selection: Binding { props?.arcType ?? 0 } set: { set(\.arcType, $0) }) {
                        Text("호").tag(UInt8(0)); Text("부채꼴").tag(UInt8(1)); Text("활 모양").tag(UInt8(2))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if props?.roundRate != nil {
                LabeledContent("모서리 곡률") {
                    NumberStepper(value: props?.roundRate.map(Double.init), unit: "%", range: 0...50, step: 5) { set(\.roundRate, UInt32($0)) }
                }
            }
        }
        InspectorSection {
            OpeningRows(title: "그림자", open: (props?.shadowType ?? 0) != 0) {
                Picker("그림자", selection: Binding { props?.shadowType ?? 0 } set: { type in
                    let kind = Self.shadows.first { $0.type == type }!
                    var change = ObjectProps(shadowType: type, shadowOffsetX: kind.x * 567, shadowOffsetY: kind.y * 567)
                    if type != 0, props?.shadowColor == nil { change.shadowColor = 0xb2b2b2 }
                    viewer.arrange(change)
                }) {
                    ForEach(Self.shadows, id: \.type) { Text($0.title).tag($0.type) }
                }
                .labelsHidden()
                .fixedSize()
            } rows: {
                LabeledContent("색") { ColorWell(hex: color(\.shadowColor, "#b2b2b2")) }
                HStack(spacing: 8) {
                    captioned("가로 이동") { length(props?.shadowOffsetX, range: -100...100) { set(\.shadowOffsetX, Units.units($0)) } }
                    // Up is positive, as 한/글 shows it.
                    captioned("세로 이동") {
                        length(props?.shadowOffsetY.map { -$0 }, range: -100...100) { set(\.shadowOffsetY, Units.units(-$0)) }
                    }
                }
                LabeledContent("투명도") {
                    NumberStepper(value: props?.shadowAlpha.map { (Double($0) / 2.55).rounded() }, unit: "%", range: 0...100) {
                        set(\.shadowAlpha, UInt32(($0 * 2.55).rounded()))
                    }
                }
            }
        }
        textBox
    }
    /// 글자 넣기, and the 글상자's 세로 정렬, 글자 방향 and 안쪽 여백.
    private var textBox: some View {
        InspectorSection {
            let textBox = document.object?.textBox
            Toggle("글자 넣기", isOn: Binding(get: { textBox == true }, set: { attach in viewer.change { .setTextBox($0, attach: attach) } }))
                .checkbox()
                .disabled(textBox == nil)
            if textBox == true {
                LabeledContent("세로 정렬") {
                    Segments(["Top", "Center", "Bottom"], selection: Binding { props?.tbVerticalAlign ?? "Top" } set: { set(\.tbVerticalAlign, $0) }) {
                        let (title, symbol) = ["Top": ("위", "arrow.up.to.line"), "Center": ("가운데", "arrow.up.and.down"),
                                               "Bottom": ("아래", "arrow.down.to.line")][$0]!
                        return .init(symbol: symbol, help: title)
                    }
                    .fixedSize()
                }
                if props?.tbTextDirection != nil {
                    LabeledContent("글자 방향") {
                        Picker("글자 방향", selection: Binding { props?.tbTextDirection ?? 0 } set: { set(\.tbTextDirection, $0) }) {
                            Text("가로").tag(UInt8(0)); Text("영문 눕힘").tag(UInt8(1)); Text("영문 세움").tag(UInt8(2))
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Fold("안쪽 여백", headline: false) { sides([\.tbMarginLeft, \.tbMarginRight, \.tbMarginTop, \.tbMarginBottom]) }
            }
        }
    }
    /// 그림자 종류 in 한/글's order, with where each puts the shadow (in 2 mm steps).
    private static let shadows: [(type: UInt32, title: String, x: Int32, y: Int32)] = [
        (0, "없음", 0, 0), (9, "작게", -1, -1), (10, "크게", -1, -1),
        (1, "왼쪽 위", -1, -1), (3, "왼쪽 아래", -1, 1), (2, "오른쪽 위", 1, -1), (4, "오른쪽 아래", 1, 1),
        (5, "왼쪽 뒤", -1, 1), (7, "왼쪽 앞", -1, 1), (6, "오른쪽 뒤", 1, 1), (8, "오른쪽 앞", 1, 1),
    ]
    /// The 선's color and width side by side.
    private var lineWidth: some View {
        HStack(spacing: 8) {
            ColorWell(hex: color(\.borderColor), flexible: true)
                .frame(maxWidth: .infinity)
            NumberStepper(value: props?.borderWidth.map { (Double($0) / Units.perMillimeter * 100).rounded() / 100 }, unit: "mm",
                          range: 0...20, step: 0.1, wide: true) { set(\.borderWidth, Units.units($0)) }
                .frame(maxWidth: .infinity)
        }
    }
    private func arrow(_ key: WritableKeyPath<ObjectProps, UInt32?>, _ images: [NSImage]) -> some View {
        ChoiceField(index(key), images.indices.map { ($0, "") }, images: images, flexible: true)
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
            // How far the text keeps off, as Pages's 텍스트 감싸기 간격.
            Fold("바깥 여백", headline: false) { sides([\.outerMarginLeft, \.outerMarginRight, \.outerMarginTop, \.outerMarginBottom]) }
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
            HStack(spacing: 16) {
                Toggle("비율 유지", isOn: $keepsRatio).checkbox()
                if props?.sizeProtect != nil { flag("크기 고정", \.sizeProtect) }
            }
            Button("원래 크기") { viewer.arrange(ObjectProps(width: props?.originalWidth, height: props?.originalHeight)) }
                .flexibleButtons()
                .disabled(props?.originalWidth == nil)
        }
        // Each offset from where 기준 and its side put the object.
        InspectorSection("위치") {
            Group {
                LabeledContent("가로") {
                    HStack(spacing: 4) {
                        choice(\.horzRelTo, "Para", [("Paper", "종이"), ("Page", "쪽"), ("Column", "단"), ("Para", "문단")])
                        choice(\.horzAlign, "Left", [("Left", "왼쪽"), ("Center", "가운데"), ("Right", "오른쪽")])
                    }
                }
                LabeledContent("세로") {
                    HStack(spacing: 4) {
                        choice(\.vertRelTo, "Para", [("Paper", "종이"), ("Page", "쪽"), ("Para", "문단")])
                        choice(\.vertAlign, "Top", [("Top", "위쪽"), ("Center", "가운데"), ("Bottom", "아래쪽")])
                    }
                }
                HStack(spacing: 8) {
                    captioned("X") { length(props?.horzOffset) { set(\.horzOffset, Units.units($0)) } }
                    captioned("Y") { length(props?.vertOffset) { set(\.vertOffset, Units.units($0)) } }
                }
                flag("쪽 영역 안으로 제한", \.restrictInPage)
                flag("서로 겹침 허용", \.allowOverlap)
            }
            .disabled(inLine || props == nil)
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
    }
    /// 캡션 of a picture: where it goes, then its size and gap while there is one.
    private var captions: some View {
        InspectorSection("캡션") {
            captionPicker.flexibleButtons()
            captionRows
        }
        .disabled(!document.context.canCaption)
    }
    /// 크기 (of a caption beside the object), 개체와의 간격, and for a picture 여백 부분까지 너비 확대.
    @ViewBuilder private var captionRows: some View {
        if (props?.caption ?? "None") != "None" {
            HStack(spacing: 8) {
                captioned("크기") { length(props?.captionWidth, range: 0...1000) { set(\.captionWidth, Units.units($0)) } }
                captioned("개체와의 간격") { length(props?.captionSpacing, range: 0...1000) { set(\.captionSpacing, Units.units($0)) } }
            }
            if props?.captionIncludeMargin != nil { flag("여백 부분까지 너비 확대", \.captionIncludeMargin) }
        }
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
    private func length<T: BinaryInteger>(_ units: T?, range: ClosedRange<Double> = -1000...1000,
                                          apply: @escaping (Double) -> Void) -> some View {
        NumberStepper(value: units.map { Units.millimeters($0) }, unit: "mm", range: range, wide: true, apply: apply)
    }
    /// Four lengths of the object, keyed 왼쪽, 오른쪽, 위쪽, 아래쪽.
    private func sides(_ keys: [WritableKeyPath<ObjectProps, Int32?>]) -> some View {
        Sides { i in length(props?[keyPath: keys[i]], range: 0...1000) { set(keys[i], Units.units($0)) } }
    }
    /// One property of the selected object, or the table holding the caret, changed.
    private func set<T>(_ key: WritableKeyPath<ObjectProps, T?>, _ value: T) {
        var change = ObjectProps()
        change[keyPath: key] = value
        viewer.arrange(change)
    }
    private func flag(_ title: String, _ key: WritableKeyPath<ObjectProps, Bool?>) -> some View {
        Toggle(title, isOn: Binding { props?[keyPath: key] == true } set: { set(key, $0) }).checkbox()
    }
    private func index(_ key: WritableKeyPath<ObjectProps, UInt32?>) -> Binding<Int> {
        Binding { Int(props?[keyPath: key] ?? 0) } set: { set(key, UInt32($0)) }
    }
    private func color(_ key: WritableKeyPath<ObjectProps, UInt32?>, _ fallback: String = "#000000") -> Binding<String> {
        Binding { props?[keyPath: key].map { HexColor.hex(bgr: $0) } ?? fallback } set: { set(key, HexColor.bgr($0)) }
    }
    private func choice(_ key: WritableKeyPath<ObjectProps, String?>, _ fallback: String,
                        _ options: [(value: String, title: String)]) -> some View {
        ChoiceField(Binding { props?[keyPath: key] ?? fallback } set: { set(key, $0) }, options)
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

    /// The table as Pages's 표: its options, rows and columns, 윤곽, and the caret cell's size.
    @ViewBuilder private func table(_ context: EditingContext) -> some View {
        InspectorSection("표 옵션") {
            LabeledContent("캡션") { captionPicker }
                .disabled(!context.canCaption)
            captionRows
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
        Group {
            InspectorSection("표 테두리") {
                HStack(alignment: .top, spacing: 8) {
                    SideButtons(rows: [[("모두", [0, 1, 2, 3]), ("위쪽", [2]), ("아래쪽", [3])], [("왼쪽", [0]), ("오른쪽", [1])]],
                                chosen: tableSides) { tableSides = $0; applyTableLine() }
                    LineRow(line: Binding(get: { tableLine }, set: { tableLine = $0; applyTableLine() }), stacked: true)
                }
                // Without it the table's own sides do not show.
                LabeledContent("셀 간격") {
                    NumberStepper(value: props?.cellSpacing.map { Units.millimeters($0) }, unit: "mm", range: 0...100) {
                        set(\.cellSpacing, Units.units($0))
                    }
                }
            }
            InspectorSection {
                FillRows(title: "표 배경", fill: props?.tableBorder?.fill, extended: true) {
                    viewer.arrange(ObjectProps(tableBorder: CellBorder(fill: $0)))
                }
            }
            InspectorSection { Fold("모든 셀의 안 여백") { sides([\.paddingLeft, \.paddingRight, \.paddingTop, \.paddingBottom]) } }
        }
        .disabled(props == nil)
        InspectorSection("줄 및 칸 크기") {
            LabeledContent("높이") {
                HStack(spacing: 8) {
                    NumberStepper(value: cell?.height.map { Units.millimeters($0) }, unit: "mm", range: 1...1000) { setCell(CellProps(height: Units.units($0))) }
                    Button("같게") { viewer.editCells { .equalizeCells($0, height: true) } }.help("셀 높이를 같게").disabled(!context.cellBlock)
                }
            }
            LabeledContent("너비") {
                HStack(spacing: 8) {
                    NumberStepper(value: cell?.width.map { Units.millimeters($0) }, unit: "mm", range: 1...1000) { setCell(CellProps(width: Units.units($0))) }
                    Button("같게") { viewer.editCells { .equalizeCells($0, height: false) } }.help("셀 너비를 같게").disabled(!context.cellBlock)
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
    /// Puts the 표 테두리's line on the sides chosen.
    private func applyTableLine() {
        guard !tableSides.isEmpty else { return }
        var border = CellBorder()
        for side in tableSides { border.sides[side] = tableLine }
        viewer.arrange(ObjectProps(tableBorder: border))
    }
    private func setCell(_ change: CellProps) {
        guard let target = document.selection?.focus.target, target.cell != nil else { return }
        viewer.setCell(target, change)
    }
    /// The cells as Pages's 셀: 채우기, 테두리 by the sides it goes on, then split, merged and 계산식.
    @ViewBuilder private func cells(_ context: EditingContext) -> some View {
        InspectorSection {
            FillRows(title: "채우기", fill: cellBorder?.fill, extended: true) {
                viewer.setCellBorder(CellBorder(fill: $0), all: false, one: false)
            }
        }
        InspectorSection("테두리") {
            HStack(alignment: .top, spacing: 8) {
                // The sides a line goes on, as Pages's: 모두, 안쪽, 바깥쪽; 왼쪽, 세로 안쪽, 오른쪽;
                // 위쪽, 가로 안쪽, 아래쪽.
                SideButtons(rows: [[("모두", [0, 1, 2, 3, 4, 5]), ("안쪽", [4, 5]), ("바깥쪽", [0, 1, 2, 3])],
                                   [("왼쪽", [0]), ("세로 안쪽", [5]), ("오른쪽", [1])],
                                   [("위쪽", [2]), ("가로 안쪽", [4]), ("아래쪽", [3])]],
                            chosen: cellSides) { cellSides = $0; applyCellLine() }
                LineRow(line: Binding(get: { cellLine }, set: { cellLine = $0; applyCellLine() }), stacked: true)
            }
        }
        diagonals(context)
        InspectorSection("속성") {
            LabeledContent("세로 정렬") {
                Segments([UInt8(0), 1, 2], selection: Binding { cell?.verticalAlign ?? 0 } set: { cellFlag(\.verticalAlign, $0) }) {
                    let (title, symbol) = [("위", "arrow.up.to.line"), ("가운데", "arrow.up.and.down"), ("아래", "arrow.down.to.line")][Int($0)]
                    return .init(symbol: symbol, help: title)
                }
                .fixedSize()
            }
            Toggle("제목 셀", isOn: Binding { cell?.isHeader == true } set: { cellFlag(\.isHeader, $0) }).checkbox()
            Toggle("셀 보호", isOn: Binding { cell?.cellProtect == true } set: { cellFlag(\.cellProtect, $0) }).checkbox()
        }
        InspectorSection {
            Fold("안 여백") {
                Toggle("안 여백 지정", isOn: Binding { cell?.applyInnerMargin == true } set: { cellFlag(\.applyInnerMargin, $0) }).checkbox()
                Sides { i in cellLength([\.paddingLeft, \.paddingRight, \.paddingTop, \.paddingBottom][i]) }
                    .disabled(cell?.applyInnerMargin != true)
            }
        }
        // 셀 너비·높이를 같게 are 표's 줄 및 칸 크기 같게.
        InspectorSection("셀") {
            Tiles {
                command("셀 나누기…", Icon.splitCells) { viewer.splittingCells = true }
                command("셀 합치기", Icon.mergeCells) { viewer.editCells { .mergeCells($0) } }
                    .disabled(!context.cellBlock)
            }
            TransparentLinesToggle(viewer: viewer)
        }
        InspectorSection("계산식") {
            ChoiceButtons(items: MenuItems.blockFunctions.map { function in
                Choice(title: function.title, enabled: context.cellBlock) { viewer.editCells { .calculateBlock($0, function.function) } }
            } + [Choice(title: "계산식…", symbol: Icon.calculation, enabled: !context.cellBlock) { viewer.calculating = true }])
        }
    }
    /// 대각선 as the dialog's: ＼ and ／, or the 중심선 (not in a block taken as one cell), and their line.
    private func diagonals(_ context: EditingContext) -> some View {
        let diagonal = cellBorder?.diagonal ?? Diagonal(line: BorderSide(line: 1, width: 0, color: "#000000"), slash: false, backSlash: false, center: 0)
        let one = diagonalOne && context.cellBlock
        let marks: [(title: String, lines: [(CGFloat, CGFloat, CGFloat, CGFloat)], on: Bool, toggle: (inout Diagonal) -> Void)] = [
            ("＼ 대각선", [(0, 0, 1, 1)], diagonal.backSlash, { $0.backSlash.toggle(); $0.center = 0 }),
            ("／ 대각선", [(0, 1, 1, 0)], diagonal.slash, { $0.slash.toggle(); $0.center = 0 }),
            ("가로 중심선", [(0, 0.5, 1, 0.5)], diagonal.center & 1 != 0, { $0.center ^= 1; ($0.slash, $0.backSlash) = (false, false) }),
            ("세로 중심선", [(0.5, 0, 0.5, 1)], diagonal.center & 2 != 0, { $0.center ^= 2; ($0.slash, $0.backSlash) = (false, false) }),
        ]
        let apply = { (new: Diagonal) in viewer.setCellBorder(CellBorder(diagonal: new), all: false, one: one) }
        return InspectorSection("대각선") {
            HStack(alignment: .top, spacing: 8) {
                // Two to a row, as 테두리's sides.
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach([0, 2], id: \.self) { row in
                        GridRow {
                            ForEach(row..<row + 2, id: \.self) { i in
                                Button {
                                    var new = diagonal
                                    marks[i].toggle(&new)
                                    if new.line.line == 0 { new.line.line = 1 }
                                    apply(new)
                                } label: { DiagonalIcon(lines: marks[i].lines) }
                                    .buttonStyle(.borderless)
                                    .background(marks[i].on ? Color.secondary.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    .help(marks[i].title)
                                    .accessibilityLabel(marks[i].title)
                                    // rhwp keeps no 중심선 in a cell zone.
                                    .disabled(i > 1 && one)
                            }
                        }
                    }
                }
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .fixedSize()
                LineRow(line: Binding(get: { diagonal.line }, set: { line in
                    var new = diagonal
                    new.line = line
                    apply(new)
                }), stacked: true)
            }
            if context.cellBlock { Toggle("하나의 셀처럼 적용", isOn: $diagonalOne).checkbox() }
        }
    }
    private func cellFlag<T>(_ key: WritableKeyPath<CellProps, T?>, _ value: T) {
        var change = CellProps()
        change[keyPath: key] = value
        setCell(change)
    }
    private func cellLength(_ key: WritableKeyPath<CellProps, Int32?>) -> some View {
        length(cell?[keyPath: key], range: 0...1000) { cellFlag(key, Units.units($0)) }
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
                command("편집 용지", Icon.pageSetup) { viewer.reveal(.document) }
                command("지우기", Icon.eraseCodes) { document.deleteHeaderFooter(viewer.undoManager) }
            }
        } footer: {
            DialogButtons { Button("닫기") { document.closeHeaderFooter() } }
        }
    }
    @ViewBuilder private func annotations(_ context: EditingContext) -> some View {
        InspectorSection {
            Tiles {
                command("각주/미주 모양", Icon.noteShape) { viewer.reveal(.document, tab: "구역") }
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
            Fold("여백") {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 4) { length(\.marginLeft); Text("왼쪽").font(.caption) }
                    VStack(spacing: 4) { length(\.marginRight); Text("오른쪽").font(.caption) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        // 들여쓰기 (positive) and 내어쓰기 (negative) are one value of the paragraph.
        InspectorSection {
            Fold("들여쓰기") {
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
            }
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

/// Rows used less, folded under their name as Pages's 여백 and 들여쓰기: a group's title, or a
/// row's name within a group.
private struct Fold<Content: View>: View {
    let title: String
    var headline = true
    @ViewBuilder let content: Content
    init(_ title: String, headline: Bool = true, @ViewBuilder content: () -> Content) {
        (self.title, self.headline, self.content) = (title, headline, content())
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { content }
        } label: { Text(title).font(headline ? .headline.weight(.semibold) : .body) }
    }
}

/// Four lengths as 용지 여백's: 위쪽 and 아래쪽 over 왼쪽 and 오른쪽, each named under it.
/// `field` takes them in HWP's order: 왼쪽, 오른쪽, 위쪽, 아래쪽.
private struct Sides<Field: View>: View {
    @ViewBuilder let field: (Int) -> Field
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach([2, 0], id: \.self) { row in
                GridRow {
                    ForEach(row..<row + 2, id: \.self) { i in
                        VStack(spacing: 3) {
                            field(i)
                            Text(["왼쪽", "오른쪽", "위쪽", "아래쪽"][i]).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
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

/// The sides a line goes on, as Pages's: buttons in one box, the ones last chosen marked.
private struct SideButtons: View {
    let rows: [[(title: String, sides: [Int])]]
    let chosen: [Int]
    let pick: ([Int]) -> Void
    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.title) { title, sides in
                        Button { pick(sides) } label: { SideIcon(sides: sides) }
                            .buttonStyle(.borderless)
                            .background(chosen == sides ? Color.secondary.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
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
    }
}

/// A 대각선 or 중심선 button's picture: its lines across a cell.
private struct DiagonalIcon: View {
    let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)]
    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            context.stroke(Path(box), with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            for (x1, y1, x2, y2) in lines {
                context.stroke(Path {
                    $0.move(to: CGPoint(x: box.minX + x1 * box.width, y: box.minY + y1 * box.height))
                    $0.addLine(to: CGPoint(x: box.minX + x2 * box.width, y: box.minY + y2 * box.height))
                }, with: .color(.primary), lineWidth: 2)
            }
        }
        .frame(width: 22, height: 22)
        .padding(3)
    }
}

/// 채우기 as Pages's: its kind beside the title, the kind's rows under it: 색 with 무늬, and for
/// 셀·표 배경 a 그러데이션 or a 그림. A fill shown as none of them (a page's 그러데이션) stays
/// until a kind is chosen.
private struct FillRows: View {
    let title: String
    let fill: PageFill?
    var extended = false
    let apply: (PageFill) -> Void

    /// 그림 채우기 유형, in the engine's order.
    private static let modes = ["바둑판식으로-모두", "바둑판식으로-가로/위", "바둑판식으로-가로/아래", "바둑판식으로-세로/왼쪽",
                                "바둑판식으로-세로/오른쪽", "크기에 맞추어", "가운데로", "가운데 위로", "가운데 아래로",
                                "왼쪽 가운데로", "왼쪽 위로", "왼쪽 아래로", "오른쪽 가운데로", "오른쪽 위로", "오른쪽 아래로"]
    /// 0 없음, 1 색, 2 그러데이션, 3 그림; -1 for none of them.
    private var kind: Int { Self.kind(fill) }
    static func kind(_ fill: PageFill?) -> Int {
        guard let fill else { return -1 }
        if fill.gradient != nil { return 2 }
        if fill.image != nil { return 3 }
        return fill.color == "none" && fill.pattern == 0 ? 0 : 1
    }
    private var base: PageFill { fill ?? PageFill(color: "none", patternColor: "#000000", pattern: 0) }

    var body: some View {
        OpeningRows(title: title, open: kind > 0) {
            Picker(title, selection: Binding { kind } set: { choose($0) }) {
                if kind < 0 { Text("").tag(-1) }
                Text("없음").tag(0)
                Text("색").tag(1)
                if extended {
                    Text("그러데이션").tag(2)
                    Text("그림").tag(3)
                }
            }
            .labelsHidden()
            .fixedSize()
        } rows: {
            switch kind {
            case 1: colorRows
            case 2: gradientRows
            case 3: imageRows
            default: EmptyView()
            }
        }
    }
    private func choose(_ kind: Int) {
        var new = base
        (new.gradient, new.image) = (nil, nil)
        switch kind {
        case 0: (new.color, new.pattern) = ("none", 0)
        case 2: new.gradient = Gradient()
        case 3: return pickImage()
        default: if new.color == "none" { new.color = "#ffffff" }
        }
        apply(new)
    }
    private func change(_ edit: (inout PageFill) -> Void) {
        var new = base
        edit(&new)
        if new != fill { apply(new) }
    }
    @ViewBuilder private var colorRows: some View {
        LabeledContent("면 색") {
            ColorWell(hex: Binding { base.color == "none" ? "#ffffff" : base.color } set: { color in change { $0.color = color } })
        }
        LabeledContent("무늬") {
            HStack(spacing: 8) {
                ChoiceField(Binding { Int(base.pattern) } set: { pattern in change { $0.pattern = UInt8(pattern) } },
                            Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns)
                ColorWell(hex: Binding { base.patternColor } set: { color in change { $0.patternColor = color } })
            }
        }
    }
    @ViewBuilder private var gradientRows: some View {
        let g = base.gradient ?? Gradient()
        let set = { (edit: (inout Gradient) -> Void) in change { fill in
            var new = g
            edit(&new)
            fill.gradient = new
        } }
        LabeledContent("모양") {
            Picker("모양", selection: Binding { g.kind } set: { kind in set { $0.kind = kind } }) {
                Text("줄무늬").tag(UInt8(1)); Text("원형").tag(UInt8(2)); Text("원뿔형").tag(UInt8(3)); Text("사각형").tag(UInt8(4))
            }
            .labelsHidden()
            .fixedSize()
        }
        HStack(spacing: 8) {
            ForEach(0..<2) { i in
                VStack(spacing: 3) {
                    ColorWell(hex: Binding { g.colors[i] } set: { color in set { $0.colors[i] = color } }, flexible: true)
                    Text(i == 0 ? "시작 색" : "끝 색").font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
        }
        LabeledContent("기울임") {
            NumberStepper(value: Double(g.angle), unit: "°", range: 0...359) { angle in set { $0.angle = Int16(angle) } }
        }
        LabeledContent("가로 중심") {
            NumberStepper(value: Double(g.centerX), unit: "%", range: 0...100) { x in set { $0.centerX = Int16(x) } }
        }
        LabeledContent("세로 중심") {
            NumberStepper(value: Double(g.centerY), unit: "%", range: 0...100) { y in set { $0.centerY = Int16(y) } }
        }
        LabeledContent("번짐 정도") {
            NumberStepper(value: Double(g.blur), unit: "", range: 0...255) { blur in set { $0.blur = UInt8(blur) } }
        }
        LabeledContent("번짐 중심") {
            NumberStepper(value: Double(g.stepCenter), unit: "", range: 0...100) { center in set { $0.stepCenter = UInt8(center) } }
        }
    }
    @ViewBuilder private var imageRows: some View {
        let i = base.image ?? ImageBrush()
        let set = { (edit: (inout ImageBrush) -> Void) in change { fill in
            var new = i
            edit(&new)
            fill.image = new
        } }
        Button("그림 선택…") { pickImage() }.flexibleButtons()
        LabeledContent("채우기 유형") {
            Picker("채우기 유형", selection: Binding { Int(i.mode) } set: { mode in set { $0.mode = UInt8(mode) } }) {
                ForEach(Self.modes.indices, id: \.self) { Text(Self.modes[$0]).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        LabeledContent("그림 효과") {
            Picker("그림 효과", selection: Binding { i.effect } set: { effect in set { $0.effect = effect } }) {
                Text("원래 그림").tag(UInt8(0)); Text("회색조").tag(UInt8(1)); Text("흑백").tag(UInt8(2))
            }
            .labelsHidden()
            .fixedSize()
        }
        LabeledContent("밝기") {
            NumberStepper(value: Double(i.brightness), unit: "%", range: -100...100) { value in set { $0.brightness = Int8(value) } }
        }
        LabeledContent("대비") {
            NumberStepper(value: Double(i.contrast), unit: "%", range: -100...100) { value in set { $0.contrast = Int8(value) } }
        }
        Toggle("워터마크 효과", isOn: Binding { i.brightness == 70 && i.contrast == -50 } set: { on in
            set { ($0.brightness, $0.contrast) = on ? (70, -50) : (0, 0) }
        })
        .checkbox()
    }
    /// 그림 선택: an image file for the 배경, kept in the document.
    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        var new = base
        new.gradient = nil
        var image = new.image ?? ImageBrush()
        (image.data, image.extension, image.binId) = (data, url.pathExtension.lowercased(), 0)
        new.image = image
        apply(new)
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
    /// 쪽 테두리: the line and the sides it last went on.
    @State private var pageLine = BorderSide(line: 1, width: 1, color: "#000000")
    @State private var pageSides: [Int] = []
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
            InspectorSection("용지 종류") {
                let paper = paper(section)
                Picker("용지 종류", selection: paper) {
                    Text("사용자 정의").tag(String?.none)
                    ForEach(Self.papers, id: \.name) { Text($0.name).tag(String?.some($0.name)) }
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
                HStack(alignment: .top, spacing: 8) {
                    SideButtons(rows: [[("모두", [0, 1, 2, 3]), ("위쪽", [2]), ("아래쪽", [3])], [("왼쪽", [0]), ("오른쪽", [1])]],
                                chosen: pageSides) { pageSides = $0; applyPageLine(section) }
                    LineRow(line: Binding(get: { pageLine }, set: { pageLine = $0; applyPageLine(section) }), stacked: true)
                }
                // Where the border goes, and on which pages, while there is one.
                if border?.sides.contains(where: { $0.line != 0 }) == true {
                    LabeledContent("위치") {
                        Picker("위치", selection: Binding { border?.paper ?? true } set: { paper in edit(section) { $0.paper = paper } }) {
                            Text("종이 기준").tag(true); Text("쪽 기준").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    HStack(spacing: 16) {
                        Toggle("머리말 포함", isOn: Binding { border?.headerInside == true } set: { on in edit(section) { $0.headerInside = on } })
                        Toggle("꼬리말 포함", isOn: Binding { border?.footerInside == true } set: { on in edit(section) { $0.footerInside = on } })
                    }
                    .checkbox()
                    .disabled(border?.paper != false)
                    LabeledContent("적용 쪽") { pagesPicker(pages, Binding { border?.borderPages ?? .all } set: { p in edit(section) { $0.borderPages = p } }) }
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
                    LabeledContent("적용 쪽") { pagesPicker(pages, Binding { border?.fillPages ?? .all } set: { p in edit(section) { $0.fillPages = p } }) }
                    LabeledContent("채울 영역") {
                        Picker("채울 영역", selection: Binding { border?.fillArea ?? .paper } set: { area in edit(section) { $0.fillArea = area } }) {
                            Text("종이").tag(FillArea.paper); Text("쪽").tag(FillArea.page); Text("테두리").tag(FillArea.border)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
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
        .fixedSize()
    }
    /// Puts the 쪽 테두리's line on the sides chosen.
    private func applyPageLine(_ section: UInt32) {
        guard !pageSides.isEmpty else { return }
        edit(section) { border in for side in pageSides { border.sides[side] = pageLine } }
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
            return Self.papers.first { abs($0.width - size.0) < 0.5 && abs($0.height - size.1) < 0.5 }?.name
        } set: { name in
            custom = name == nil
            guard let paper = Self.papers.first(where: { $0.name == name }) else { return }
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
        columnPane(section)
        notePane(section)
    }

    /// 단 설정: 자주 쓰이는 모양 and 단 개수, 단 종류, 간격 and 단 너비 동일하게.
    private func columnPane(_ section: UInt32) -> some View {
        InspectorSection("단") {
            IconTiles(selection: Binding { columns?.count ?? 1 } set: { count in setColumns(section) { $0.count = count } },
                      options: [(UInt16(1), "하나"), (2, "둘"), (3, "셋")], fill: true) { count, on in
                PagePictogram.columns(Int(count), on: on)
            }
            .flexibleButtons()
            LabeledContent("단 개수") {
                NumberStepper(value: columns.map { Double($0.count) }, unit: "", range: 1...255) { count in
                    setColumns(section) { $0.count = UInt16(count) }
                }
            }
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
        return InspectorSection("주석 모양") {
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
                        ChoiceField(Binding { Int(shape?.separatorLineWidth ?? 0) } set: { width in setNote(section) { $0.separatorLineWidth = UInt8(width) } },
                                    Swatches.widths.indices.map { ($0, "") }, images: Swatches.widthImages)
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
        }
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
