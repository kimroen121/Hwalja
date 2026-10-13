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
    /// 표 테두리: the line last chosen.
    @State private var tableLine = BorderSide(line: 1, width: 1, color: "#000000")
    /// 표 뒤집기's 여백 뒤집기.
    @State private var flipMargins = false

    init(document: HwpDocument, viewer: Viewer, tab: String? = nil) {
        (self.document, self.viewer, _chosen) = (document, viewer, State(initialValue: tab))
    }

    static let textTabs = ["텍스트"]
    /// The 개체 탭 and 상황 탭 for what is selected.
    static func contextTabs(_ context: EditingContext) -> [String] {
        switch context.object {
        case .picture: ["스타일", "이미지", "개체"]
        // A chart's data is edited from its menu.
        case .shape: context.chart ? ["개체"] : ["도형", "개체"]
        case .equation: ["수식", "개체"]
        // A table chosen whole, by its border.
        case .table: ["표", "개체"]
        case nil:
            context.inHeaderFooter ? ["머리말/꼬리말"] : context.inNote ? ["주석"]
                : context.inTable ? ["표", "셀", "개체"] : []
        }
    }
    /// A selected object has only its own tabs; a table has 텍스트 among its own, as Pages's;
    /// other text has 텍스트 before them.
    static func tabs(_ context: EditingContext) -> [String] {
        let extra = contextTabs(context)
        if context.object != nil { return extra }
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
                            // A little wider than the groups under them.
                            .padding(.horizontal, -6)
                    }
                }
            } else if tab != "텍스트" {
                Text(tab).foregroundStyle(.secondary).padding(.top, 12).padding(.bottom, 8)
                Divider().padding(.horizontal, 16)
            }
            if !context.hasSelection && context.object == nil {
                // As Pages's, with nothing to format.
                ContentUnavailableView("선택한 항목이 없습니다.", systemImage: "paintbrush")
                    // Level with the window's middle, not the inspector's below the toolbar.
                    .padding(.bottom, 52)
            } else if tab == "텍스트" {
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
        case "표": table(context)
        case "셀": cells(context)
        case "머리말/꼬리말": headerFooter(context)
        case "주석": annotations(context)
        default: EmptyView()
        }
    }

    // MARK: 개체 탭과 상황 탭

    /// A picture's 테두리: its kind, color and width in one row under the title.
    private var pictureStyle: some View {
        InspectorSection("테두리") {
            HStack(spacing: 8) {
                LineKindField(kind: index(\.lineType), count: 12)
                Group {
                    ColorWell(hex: color(\.borderColor))
                    points(\.borderWidth)
                }
                .disabled((props?.lineType ?? 0) == 0)
            }
        }
    }
    /// The picture itself, as Pages's 이미지: 조절, 자르기, 그림 여백 and 캡션. Replacing, saving and
    /// 원본 그림으로 are its menu's.
    @ViewBuilder private var picture: some View {
        InspectorSection("조절") {
            Segments(["RealPic", "GrayScale", "BlackWhite", "Watermark"], selection: Binding(get: { Self.effect(props) }, set: { effect in
                viewer.adjustPicture { props in
                    if effect == "Watermark" { (props.effect, props.brightness, props.contrast) = ("RealPic", 70, -50) } else { props.effect = effect }
                }
            })) { let title = ["RealPic": "효과 없음", "GrayScale": "회색조", "BlackWhite": "흑백", "Watermark": "워터마크"][$0]!; return .init(title: title, help: title) }
                // Four names fit the inspector only small.
                .controlSize(.small)
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
                // Up is positive, as 한/글 shows it.
                Pair("가로 이동", length(props?.shadowOffsetX, range: -100...100, width: 62) { set(\.shadowOffsetX, Units.units($0)) },
                     "세로 이동", length(props?.shadowOffsetY.map { -$0 }, range: -100...100, width: 62) { set(\.shadowOffsetY, Units.units(-$0)) })
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
            ColorWell(hex: color(\.borderColor))
                .frame(maxWidth: .infinity)
            points(\.borderWidth)
                .frame(maxWidth: .infinity)
        }
    }
    /// A line's width in points (100 HWPUNIT each), its unit in the field.
    private func points(_ key: WritableKeyPath<ObjectProps, Int32?>) -> some View {
        NumberStepper(value: props?[keyPath: key].map { Double($0) / 100 }, unit: "pt", range: 0...56, step: 0.5,
                      width: 58, unitInside: true) { set(key, Int32(($0 * 100).rounded())) }
    }
    private func arrow(_ key: WritableKeyPath<ObjectProps, UInt32?>, _ images: [NSImage]) -> some View {
        ChoiceField(index(key), images.indices.map { ($0, "") }, images: images, flexible: true)
    }
    /// The same for every object and for a table, as Pages's 정렬: 배치, 순서, 크기, 위치 and 회전.
    /// What a table cannot do is there but off. Commands of the menus (묶기, 보호, 개체 선택) are
    /// left to them.
    @ViewBuilder private func object(_ context: EditingContext) -> some View {
        let inLine = props?.treatAsChar == true, table = context.object == nil || context.object == .table
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
        // As Pages's: 맨 뒤로 and 맨 앞으로, 뒤로 and 앞으로, each two in one control.
        InspectorSection {
            HStack(spacing: 8) {
                order(Array(Self.orders.prefix(2)))
                order(Array(Self.orders.suffix(2)))
            }
            .disabled(table || inLine)
        }
        // As Pages's: each group's name over its fields, which line up under one another.
        InspectorSection("크기") {
            VStack(alignment: .leading, spacing: 10) {
                Pair("너비", length(props?.width, width: 62) { resize(width: $0) },
                     "높이", length(props?.height, width: 62) { resize(height: $0) })
                HStack(spacing: 16) {
                    Toggle("비율 유지", isOn: $keepsRatio).checkbox()
                    if props?.sizeProtect != nil { flag("크기 고정", \.sizeProtect) }
                }
                if props?.originalWidth != nil {
                    Button { viewer.arrange(ObjectProps(width: props?.originalWidth, height: props?.originalHeight)) } label: {
                        Text("원래 크기").frame(maxWidth: .infinity)
                    }
                }
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // X and Y in sight, what they are measured from folded under them.
        InspectorSection {
            Fold("위치") {
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
                flag("쪽 영역 안으로 제한", \.restrictInPage)
                flag("서로 겹침 허용", \.allowOverlap)
            } shown: {
                Pair("X", length(props?.horzOffset, width: 62) { set(\.horzOffset, Units.units($0)) },
                     "Y", length(props?.vertOffset, width: 62) { set(\.vertOffset, Units.units($0)) })
            }
            .disabled(inLine || props == nil)
        }
        InspectorSection("회전") {
            // 한/글 keeps −360…360; shown as the dial reads it.
            let angle = props.map { Double((Int($0.rotationAngle ?? 0) % 360 + 360) % 360) }
            HStack(alignment: .top, spacing: 8) {
                RotationDial(angle: angle) { viewer.arrange(ObjectProps(rotationAngle: Int32($0))) }
                    .frame(width: 32, height: 32)
                VStack(spacing: 3) {
                    NumberStepper(value: angle, unit: "°", range: 0...359, wide: true, unitInside: true) {
                        viewer.arrange(ObjectProps(rotationAngle: Int32($0)))
                    }
                    Text("각도").font(.caption)
                }
                VStack(spacing: 3) {
                    ActionButtons(actions: [("좌우 대칭", "arrow.left.and.right.righttriangle.left.righttriangle.right", { viewer.change { .flip($0, vertical: false) } }),
                                            ("상하 대칭", "arrow.up.and.down.righttriangle.up.righttriangle.down", { viewer.change { .flip($0, vertical: true) } })])
                    Text("대칭").font(.caption)
                }
            }
        }
        // 글자처럼 취급 turns too.
        .disabled(table)
    }
    /// A caption's 크기 and 개체와의 간격 (and for a picture 여백 부분까지 너비 확대) while there is
    /// one; it is put in, moved and taken away from the object's menu.
    @ViewBuilder private var captions: some View {
        if (props?.caption ?? "None") != "None" {
            InspectorSection("캡션") {
                Pair("크기", length(props?.captionWidth, range: 0...1000, width: 62) { set(\.captionWidth, Units.units($0)) },
                     "개체와의 간격", length(props?.captionSpacing, range: 0...1000, width: 62) { set(\.captionSpacing, Units.units($0)) })
                if props?.captionIncludeMargin != nil { flag("여백 부분까지 너비 확대", \.captionIncludeMargin) }
            }
        }
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
    private static let orders: [(title: String, symbol: String, order: Order)] = [
        ("맨 뒤로", "square.3.layers.3d.bottom.filled", .back), ("맨 앞으로", "square.3.layers.3d.top.filled", .front),
        ("뒤로", "square.2.layers.3d.bottom.filled", .backward), ("앞으로", "square.2.layers.3d.top.filled", .forward),
    ]
    /// A field with its name under it, as Pages's.
    private func captioned<Field: View>(_ title: String, @ViewBuilder _ field: () -> Field) -> some View {
        VStack(spacing: 3) {
            field()
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
    }
    /// As wide as its place; or the field `width` wide, its unit in it.
    private func length<T: BinaryInteger>(_ units: T?, range: ClosedRange<Double> = -1000...1000, width: CGFloat? = nil,
                                          apply: @escaping (Double) -> Void) -> some View {
        NumberStepper(value: units.map { Units.millimeters($0) }, unit: "mm", range: range, wide: width == nil, width: width ?? 48,
                      unitInside: width != nil, apply: apply)
    }
    /// Four lengths of the object, keyed 왼쪽, 오른쪽, 위쪽, 아래쪽.
    private func sides(_ keys: [WritableKeyPath<ObjectProps, Int32?>]) -> some View {
        Sides { i in length(props?[keyPath: keys[i]], range: 0...1000, width: 62) { set(keys[i], Units.units($0)) } }
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

    /// The table as Pages's 표, the most used first: its rows and columns and the caret cell's
    /// size, 윤곽 and 배경; then, folded, 여러 쪽 지원, 안 여백 and 뒤집기. What the 표 menu does
    /// (나누기, 붙이기, 같게) is left to it.
    @ViewBuilder private func table(_ context: EditingContext) -> some View {
        // As Pages's: rows added or removed at the bottom, columns at the right.
        InspectorSection {
            LabeledContent("줄") {
                NumberStepper(value: props?.rowCount.map(Double.init), unit: "", range: 1...1000) { rows in
                    props?.colCount.map { viewer.setTableSize(rows: Int(rows), columns: Int($0)) }
                }
            }
            LabeledContent("칸") {
                NumberStepper(value: props?.colCount.map(Double.init), unit: "", range: 1...256) { columns in
                    props?.rowCount.map { viewer.setTableSize(rows: Int($0), columns: Int(columns)) }
                }
            }
        }
        .disabled(props == nil)
        // The caret cell's row and column; none for a table chosen whole.
        InspectorSection("줄 및 칸 크기") {
            Pair("높이", NumberStepper(value: cell?.height.map { Units.millimeters($0) }, unit: "mm", range: 1...1000, width: 62) { setCell(CellProps(height: Units.units($0))) },
                 "너비", NumberStepper(value: cell?.width.map { Units.millimeters($0) }, unit: "mm", range: 1...1000, width: 62) { setCell(CellProps(width: Units.units($0))) })
        }
        .disabled(context.object != nil)
        Group {
            InspectorSection("표 테두리") {
                BorderSides(sides: props?.tableBorder.map { border in
                    (0..<4).map { border.sides[$0] ?? BorderSide(line: 0, width: 0, color: "#000000") }
                }, line: $tableLine) { changes in
                    var border = CellBorder()
                    for (side, line) in changes { border.sides[side] = line }
                    viewer.arrange(ObjectProps(tableBorder: border))
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
        }
        .disabled(props == nil)
        captions
        // Less used, folded.
        Group {
            InspectorSection {
                Fold("여러 쪽 지원") {
                    LabeledContent("쪽 경계에서") {
                        Picker("쪽 경계에서", selection: Binding(get: { props?.pageBreak ?? 0 }, set: { viewer.arrange(ObjectProps(pageBreak: $0)) })) {
                            Text("셀 단위로 나눔").tag(UInt8(2))
                            Text("나눔").tag(UInt8(1))
                            Text("나누지 않음").tag(UInt8(0))
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Toggle("제목 줄 자동 반복", isOn: Binding(get: { props?.repeatHeader == true }, set: { viewer.arrange(ObjectProps(repeatHeader: $0)) }))
                        .checkbox()
                }
            }
            InspectorSection { Fold("모든 셀의 안 여백") { sides([\.paddingLeft, \.paddingRight, \.paddingTop, \.paddingBottom]) } }
        }
        .disabled(props == nil)
        // 표 뒤집기 as in 한/글: 대칭 or 회전, each applied as it is clicked.
        InspectorSection {
            Fold("표 뒤집기") {
                LabeledContent("대칭") {
                    turns([("줄 기준 뒤집기", "arrow.up.and.down.righttriangle.up.righttriangle.down", .rows),
                           ("칸 기준 뒤집기", "arrow.left.and.right.righttriangle.left.righttriangle.right", .columns),
                           ("줄/칸 뒤집기", "arrow.up.left.and.arrow.down.right", .diagonal)])
                }
                LabeledContent("회전") {
                    turns([("반시계 방향 90도", "rotate.left", .left), ("180도", "arrow.uturn.down", .half), ("시계 방향 90도", "rotate.right", .right)])
                }
                Toggle("여백 뒤집기", isOn: $flipMargins).checkbox()
            }
        }
    }
    private func turns(_ turns: [(title: String, symbol: String, turn: TableTurn)]) -> some View {
        ActionButtons(actions: turns.map { turn in (turn.title, turn.symbol, { viewer.flipTable(turn.turn, margins: flipMargins) }) })
    }
    private func setCell(_ change: CellProps) {
        guard let target = document.selection?.focus.target, target.cell != nil else { return }
        viewer.setCell(target, change)
    }
    /// The cells as Pages's 셀, the most used first: 테두리 by the sides it goes on, 채우기 and
    /// 세로 정렬; then, folded, 대각선 and 안 여백. What the 표 menu does (나누기, 합치기, 계산식) is left to it.
    @ViewBuilder private func cells(_ context: EditingContext) -> some View {
        InspectorSection("테두리") {
            HStack(alignment: .top, spacing: 6) {
                // The sides a line goes on, as Pages's: 모두, 안쪽, 바깥쪽; 왼쪽, 세로 안쪽, 오른쪽;
                // 위쪽, 가로 안쪽, 아래쪽.
                SideButtons(rows: [[("모두", [0, 1, 2, 3, 4, 5]), ("안쪽", [4, 5]), ("바깥쪽", [0, 1, 2, 3])],
                                   [("왼쪽", [0]), ("세로 안쪽", [5]), ("오른쪽", [1])],
                                   [("위쪽", [2]), ("가로 안쪽", [4]), ("아래쪽", [3])]],
                            chosen: cellSides) { cellSides = $0; applyCellLine() }
                LineRow(line: Binding(get: { cellLine }, set: { cellLine = $0; applyCellLine() }), stacked: true)
            }
        }
        InspectorSection {
            FillRows(title: "채우기", fill: cellBorder?.fill, extended: true) {
                viewer.setCellBorder(CellBorder(fill: $0), all: false, one: false)
            }
        }
        InspectorSection {
            LabeledContent("세로 정렬") {
                Segments([UInt8(0), 1, 2], selection: Binding { cell?.verticalAlign ?? 0 } set: { cellFlag(\.verticalAlign, $0) }) {
                    let (title, symbol) = [("위", "arrow.up.to.line"), ("가운데", "arrow.up.and.down"), ("아래", "arrow.down.to.line")][Int($0)]
                    return .init(symbol: symbol, help: title)
                }
                .fixedSize()
            }
            HStack(spacing: 16) {
                Toggle("제목 셀", isOn: Binding { cell?.isHeader == true } set: { cellFlag(\.isHeader, $0) })
                Toggle("셀 보호", isOn: Binding { cell?.cellProtect == true } set: { cellFlag(\.cellProtect, $0) })
            }
            .checkbox()
        }
        diagonals(context)
        InspectorSection {
            Fold("안 여백") {
                Toggle("안 여백 지정", isOn: Binding { cell?.applyInnerMargin == true } set: { cellFlag(\.applyInnerMargin, $0) }).checkbox()
                Sides { i in cellLength([\.paddingLeft, \.paddingRight, \.paddingTop, \.paddingBottom][i]) }
                    .disabled(cell?.applyInnerMargin != true)
            }
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
        // As 표 테두리: the line, then each mark turned on or off; folded, as it is used less.
        return InspectorSection { Fold("대각선") {
            LineRow(line: Binding(get: { diagonal.line }, set: { line in
                var new = diagonal
                new.line = line
                apply(new)
            }))
            // rhwp keeps no 중심선 in a cell zone.
            Segments(segments: marks.indices.map { i in .init(image: DiagonalIcon.image(marks[i].lines), help: marks[i].title, enabled: i < 2 || !one) },
                     on: marks.map(\.on), any: true) { i in
                var new = diagonal
                marks[i].toggle(&new)
                if new.line.line == 0 { new.line.line = 1 }
                apply(new)
            }
            if context.cellBlock { Toggle("하나의 셀처럼 적용", isOn: $diagonalOne).checkbox() }
        } }
    }
    private func cellFlag<T>(_ key: WritableKeyPath<CellProps, T?>, _ value: T) {
        var change = CellProps()
        change[keyPath: key] = value
        setCell(change)
    }
    private func cellLength(_ key: WritableKeyPath<CellProps, Int32?>) -> some View {
        length(cell?[keyPath: key], range: 0...1000, width: 62) { cellFlag(key, Units.units($0)) }
    }
    /// Puts the 테두리's line on the sides chosen, in the selected cells.
    private func applyCellLine() {
        guard !cellSides.isEmpty else { return }
        var border = CellBorder()
        for side in cellSides { border.sides[side] = cellLine }
        viewer.setCellBorder(border, all: false, one: false)
    }

    /// 상용구 for the 머리말 or 꼬리말 being written, and 닫기. Its shapes, the ones before and after
    /// and 지우기 are the 쪽 menu's and its own menu's.
    @ViewBuilder private func headerFooter(_ context: EditingContext) -> some View {
        InspectorSection("상용구") {
            ChoiceButtons(items: [("전체 쪽수", PageCode.total), ("현재 쪽 번호", .page), ("현재 쪽/전체 쪽수", .pageOfTotal)]
                .map { title, code in Choice(title: title) { viewer.insertPageCode(code) } })
        } footer: {
            DialogButtons { Button("닫기") { document.closeHeaderFooter() } }
        }
    }
    /// The note being written: the ones before and after it, 지우기 and 닫기. Its 모양 is the 구역's.
    @ViewBuilder private func annotations(_ context: EditingContext) -> some View {
        InspectorSection {
            ChoiceButtons(items: [Choice(title: "이전 주석으로", symbol: Icon.previous) { viewer.goTo(.previousNote) },
                                  Choice(title: "다음 주석으로", symbol: Icon.next) { viewer.goTo(.nextNote) },
                                  Choice(title: "주석 지우기", symbol: Icon.eraseCodes) { document.deleteNote(viewer.undoManager) }])
        } footer: {
            DialogButtons { Button("닫기") { document.closeNote() } }
        }
    }

    // MARK: Rows

    /// 색조 as the picker reads it; 워터마크 is no effect at its brightness and contrast.
    private static func effect(_ props: ObjectProps?) -> String {
        guard let props else { return "" }
        if props.effect == "RealPic", props.brightness == 70, props.contrast == -50 { return "Watermark" }
        return props.effect ?? "RealPic"
    }
}

#Preview {
    Inspector(document: HwpDocument(), viewer: Viewer())
        .frame(width: 280, height: 700)
}
