import SwiftUI

// Objects (pictures, equations, tables): their commands and 개체 속성.

/// The positions of 입력 › 캡션 넣기, in the web editor's order and names.
enum Captions {
    static let all: [(title: String, value: String)] = [
        ("위", "Top"), ("왼쪽 위", "LeftTop"), ("왼쪽 가운데", "LeftCenter"), ("왼쪽 아래", "LeftBottom"),
        ("오른쪽 위", "RightTop"), ("오른쪽 가운데", "RightCenter"), ("오른쪽 아래", "RightBottom"),
        ("아래", "Bottom"), ("캡션 없음", "None"),
    ]
}

/// 개체 속성 as opened: the object with its properties, and for a table the cell
/// holding the caret with its own.
struct ObjectSheetState: Identifiable {
    let id = UUID()
    let object: ObjectRef
    let props: ObjectProps
    var cell: (target: EditTarget, props: CellProps)?
    /// A 직선, the one drawing object with 화살표.
    var line = false
    /// A drawing object with a 글상자.
    var textBox = false
}

extension Viewer {

    /// 개체 속성 of the selected object, or 표/셀 속성 of the table holding the caret.
    /// The table holding the caret, with its properties and the caret cell's.
    func tableSheet() async -> ObjectSheetState? {
        guard let document, let target = document.selection?.focus.target, let cell = target.cell else { return nil }
        let table = ObjectRef(kind: .table, section: target.section, paragraph: target.paragraph, control: cell.control)
        guard let props = try? await document.objectProps(table), let cellProps = try? await document.cellProps(target)
        else { return nil }
        return ObjectSheetState(object: table, props: props, cell: (target, cellProps))
    }
    func showObjectProperties() {
        guard let document else { return }
        Task {
            if let placed = document.object {
                guard let props = try? await document.objectProps(placed.object) else { return NSSound.beep() }
                objectSheet = ObjectSheetState(object: placed.object, props: props, line: placed.ends != nil,
                                               textBox: placed.textBox == true)
            } else if document.selection?.focus.target.cell != nil {
                guard let sheet = await tableSheet() else { return NSSound.beep() }
                objectSheet = sheet
            }
        }
    }
    /// What double-click and Return open: 수식 편집기 for an equation, 차트 데이터 편집 for a
    /// 차트, else 개체 속성.
    func open(_ placed: PlacedObject) {
        if placed.chart != nil { return editChartData() }
        guard placed.object.kind == .equation, let document else { return showObjectProperties() }
        Task {
            guard let props = try? await document.objectProps(placed.object) else { return NSSound.beep() }
            equation = EquationEdit(object: placed.object, script: props.script ?? "",
                                    fontSize: Double(props.fontSize ?? 1000) / 100, color: props.color ?? 0)
        }
    }
    /// 차트 데이터 편집 of the selected 차트.
    func editChartData() {
        guard let document, let chart = document.object?.chart else { return NSSound.beep() }
        Task {
            guard let data = try? await document.chartData(chart) else { return NSSound.beep() }
            chartData = ChartEditing(chart: chart, data: data)
        }
    }
    func setChartData(_ data: ChartData, chart: UInt32) {
        document?.edit(undoManager) { _ in .setChartData(chart: chart, data) }
    }
    func setObject(_ object: ObjectRef, _ change: ObjectProps) {
        guard change != ObjectProps() else { return }
        document?.edit(undoManager) { _ in .setObject(object, change) }
    }
    func setCell(_ cell: EditTarget, _ change: CellProps) {
        guard change != CellProps() else { return }
        document?.edit(undoManager) { _ in .setCell(cell, change) }
    }
    /// Changes the selected picture from its current properties (그림 drop-downs).
    func adjustPicture(_ change: @escaping (inout ObjectProps) -> Void) {
        guard let document, let placed = document.object, placed.object.kind == .picture else { return }
        Task {
            guard let props = try? await document.objectProps(placed.object) else { return NSSound.beep() }
            var changed = props
            change(&changed)
            setObject(placed.object, changed.changes(from: props))
        }
    }
    /// The selected object, or the table holding the caret: what 캡션 and 배치 change.
    var arrangedObject: ObjectRef? {
        if let placed = document?.object { return placed.object }
        guard let target = document?.selection?.focus.target, let cell = target.cell else { return nil }
        return ObjectRef(kind: .table, section: target.section, paragraph: target.paragraph, control: cell.control)
    }
    /// 배치 (글자처럼 취급, 어울림 …) of the selected object or the table holding the caret.
    func arrange(_ change: ObjectProps) {
        guard let object = arrangedObject else { return }
        setObject(object, change)
    }
    /// 캡션 넣기: for the selected object, or the table holding the caret.
    func insertCaption(_ position: String) {
        guard let document, let object = arrangedObject else { return }
        setObject(object, ObjectProps(caption: position))
        // As in Hancom, the caret goes to the end of the caption, to write it.
        guard position != "None", object.cell == nil, [.picture, .table].contains(object.kind) else { return }
        let caption = EditTarget(section: object.section, paragraph: object.paragraph,
                                 cell: CellTarget(control: object.control, cell: object.kind == .table ? CellTarget.caption : 0,
                                                  paragraph: 0))
        document.select { document in
            let end = try await document.paragraph(caption).text.unicodeScalars.count
            return .caret(EditPosition(target: caption, scalar: UInt32(end)))
        }
    }
    /// Starts drawing a 그리기 개체 with the next drag on a page.
    func draw(_ shape: String) {
        canvas.editor.drawingShape = shape
        canvas.window?.makeFirstResponder(canvas.editor)
    }
    func deleteObject() {
        guard let object = document?.object?.object else { return }
        document?.edit(undoManager) { _ in .deleteObject(object) }
    }
    /// 순서, 개체 풀기, 도형 안에 글자 넣기 and 글상자 속성 없애기, for the selected object.
    func change(_ command: @escaping (ObjectRef) -> EditCommand) {
        guard let object = document?.object?.object else { return }
        document?.edit(undoManager) { _ in command(object) }
    }
    /// 개체 묶기: the chosen objects into one; as in 한/글, not across pages.
    func groupObjects() {
        guard let document, let object = document.object, !document.others.isEmpty else { return }
        guard document.others.allSatisfy({ $0.rect.page == object.rect.page }) else { return NSSound.beep() }
        let objects = document.others.map(\.object) + [object.object]
        document.edit(undoManager) { _ in .group(objects) }
    }
    /// 그룹: 개체 묶기 and 개체 풀기, as on the 도형 and 그림 탭.
    var groupChoices: [Choice?] {
        let context = document?.context ?? EditingContext()
        return [Choice(title: "개체 묶기", key: "g", modifiers: [], enabled: context.objects > 1 && !context.locked) { self.groupObjects() },
                Choice(title: "개체 풀기", key: "u", modifiers: [], enabled: document?.object?.group == true && !context.locked) {
                    self.change { .ungroup($0) }
                }]
    }
}

/// 개체 속성 (or 표/셀 속성), laid out like Hancom's: 기본 (size, position), 여백/캡션,
/// and 그림, or 표 and 셀. Only changed properties apply.
struct ObjectSheet: View {
    let state: ObjectSheetState
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var props: ObjectProps
    @State private var cell: CellProps
    @State private var tab: String

    init(state: ObjectSheetState, viewer: Viewer, tab: String = "기본") {
        (self.state, self.viewer) = (state, viewer)
        _tab = State(initialValue: tab)
        _props = State(initialValue: state.props)
        _cell = State(initialValue: state.cell?.props ?? CellProps())
    }

    private var kind: ObjectKind { state.object.kind }

    var body: some View {
        DialogFrame(state.cell == nil ? "개체 속성" : "표/셀 속성", confirmTitle: "설정") {
            DialogTabs(selection: $tab, titles: ["기본", "여백/캡션"] + (kind == .picture ? ["선", "그림"] : [])
                       + (kind == .table ? ["테두리", "배경"] : [])
                       + (kind == .table ? ["표", "셀"] : []) + (kind == .shape ? ["선", "채우기"] : [])
                       + (state.textBox ? ["글상자"] : []) + (kind == .shape ? ["그림자"] : [])) { tab in
                switch tab {
                case "글상자": textBoxTab
                case "그림자": shadow
                case "테두리": tableBorder
                case "배경": tableBackground
                case "선": line
                case "채우기": fill
                case "여백/캡션": margins
                case "그림": picture
                case "표": table
                case "셀": cellTab
                default: basic
                }
            }
            .dialogTabs()
            .frame(height: 420)
        } confirm: {
            viewer.setObject(state.object, props.changes(from: state.props))
            if let original = state.cell { viewer.setCell(original.target, cell.changes(from: original.props)) }
            dismiss()
        }
    }

    // MARK: Tabs

    private var basic: some View {
        VStack(alignment: .leading, spacing: 14) {
            if kind == .picture || kind == .shape {
                GroupTitle("크기")
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow { length("너비", \.width, range: 1...10_000) }
                        GridRow { length("높이", \.height, range: 1...10_000) }
                    }
                    Toggle("크기 고정", isOn: flag(\.sizeProtect))
                }
                .padding(.leading, 12)
            }
            GroupTitle("위치")
            VStack(alignment: .leading, spacing: 10) {
                Toggle("글자처럼 취급", isOn: flag(\.treatAsChar))
                Group {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("본문과의 배치")
                        IconTiles(selection: text(\.textWrap, "Square"), options: [
                            ("Square", "어울림"), ("TopAndBottom", "자리 차지"), ("BehindText", "글 뒤로"), ("InFrontOfText", "글 앞으로"),
                        ]) { Pictogram.wrap($0, on: $1) }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("가로")
                            choice(\.horzRelTo, "Para", [("Paper", "종이"), ("Page", "쪽"), ("Column", "단"), ("Para", "문단")])
                            choice(\.horzAlign, "Left", [("Left", "왼쪽"), ("Center", "가운데"), ("Right", "오른쪽")])
                            Text("기준")
                            SpinField(value: millimeters(\.horzOffset), unit: "mm", range: -1000...1000)
                        }
                        GridRow {
                            FieldLabel("세로")
                            choice(\.vertRelTo, "Para", [("Paper", "종이"), ("Page", "쪽"), ("Para", "문단")])
                            choice(\.vertAlign, "Top", [("Top", "위쪽"), ("Center", "가운데"), ("Bottom", "아래쪽")])
                            Text("기준")
                            SpinField(value: millimeters(\.vertOffset), unit: "mm", range: -1000...1000)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("쪽 영역 안으로 제한", isOn: flag(\.restrictInPage))
                        Toggle("서로 겹침 허용", isOn: flag(\.allowOverlap))
                    }
                }
                // Kept in place while disabled, so the sheet never jumps.
                .disabled(props.treatAsChar == true)
            }
            .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var margins: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("바깥 여백")
            sides(\.outerMarginLeft, \.outerMarginRight, \.outerMarginTop, \.outerMarginBottom)
            if kind == .picture || kind == .table {
                GroupTitle("캡션")
                HStack(alignment: .top, spacing: 24) {
                    CaptionGrid(selection: text(\.caption, "None"))
                    VStack(alignment: .leading, spacing: 8) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                            GridRow { length("크기", \.captionWidth) }
                            GridRow { length("개체와의 간격", \.captionSpacing) }
                        }
                        if kind == .picture {
                            Toggle("여백 부분까지 너비 확대", isOn: flag(\.captionIncludeMargin))
                        }
                    }
                    .disabled((props.caption ?? "None") == "None")
                }
                .padding(.leading, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var picture: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("그림 자르기")
            sides(\.cropLeft, \.cropRight, \.cropTop, \.cropBottom)
            GroupTitle("그림 여백")
            sides(\.paddingLeft, \.paddingRight, \.paddingTop, \.paddingBottom)
            GroupTitle("그림 효과")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("색조 조정")
                    ChoiceField(text(\.effect, "RealPic"), [("RealPic", "효과 없음"), ("GrayScale", "회색조"), ("BlackWhite", "흑백")])
                        .gridCellColumns(3)
                }
                GridRow {
                    FieldLabel("밝기")
                    SpinField(value: number(\.brightness), unit: "%", range: -100...100)
                    FieldLabel("대비")
                    SpinField(value: number(\.contrast), unit: "%", range: -100...100)
                }
            }
            .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("여러 쪽 지원")
            VStack(alignment: .leading, spacing: 8) {
                Text("쪽 경계에서")
                IconTiles(selection: Binding { props.pageBreak ?? 0 } set: { props.pageBreak = $0 },
                          options: [(UInt8(2), "셀 단위로 나눔"), (1, "나눔"), (0, "나누지 않음")]) { Pictogram.pageBreak($0, on: $1) }
                Toggle("제목 줄 자동 반복", isOn: flag(\.repeatHeader))
            }
            .padding(.leading, 12)
            GroupTitle("모든 셀의 안 여백")
            sides(\.paddingLeft, \.paddingRight, \.paddingTop, \.paddingBottom)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var tableBorder: some View { TableBorderTab(props: $props) }
    private var tableBackground: some View { TableBackgroundTab(props: $props) }

    private var line: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("선")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("색")
                    ColorWell(hex: color(\.borderColor))
                    FieldLabel("종류")
                    ChoiceField(index(\.lineType), Swatches.lineKinds.indices.prefix(12).map { ($0, "") },
                                images: Array(Swatches.lineKinds.prefix(12)), minWidth: 100)
                }
                GridRow {
                    if kind == .shape {
                        FieldLabel("끝 모양")
                        ChoiceField(index(\.lineEndShape), Swatches.lineEnds.indices.map { ($0, "") }, images: Swatches.lineEnds, minWidth: 100)
                    }
                    FieldLabel("굵기")
                    SpinField(value: Binding { (Double(props.borderWidth ?? 0) / Units.perMillimeter * 100).rounded() / 100 }
                                  set: { props.borderWidth = Units.units($0) },
                              unit: "mm", range: 0...20, step: 0.1, digits: 2)
                }
            }
            .padding(.leading, 12)
            if kind == .shape {
                GroupTitle("화살표")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { arrow("시작 모양", \.arrowStart, start: true); arrow("끝 모양", \.arrowEnd, start: false) }
                    GridRow { arrowSize("시작 크기", \.arrowStartSize, start: true); arrowSize("끝 크기", \.arrowEndSize, start: false) }
                }
                .padding(.leading, 12)
                .disabled(!state.line)
            }
            if props.roundRate != nil {
                GroupTitle("사각형 모서리 곡률")
                HStack(spacing: 4) {
                    ForEach([(UInt32(0), "직각"), (20, "둥근 모양"), (50, "반원")], id: \.0) { rate, title in
                        Button { props.roundRate = rate } label: { Pictogram.corner(rate) }
                            .buttonStyle(ToolButtonStyle(on: props.roundRate == rate))
                            .help(title)
                            .accessibilityLabel(title)
                    }
                    LabeledField("곡률 지정") {
                        SpinField(value: Binding { Double(props.roundRate ?? 0) } set: { props.roundRate = UInt32($0) },
                                  unit: "%", range: 0...50)
                    }
                    .padding(.leading, 12)
                }
                .padding(.leading, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// 글상자: 안쪽 여백 (with 모두) and 세로 정렬.
    private var textBoxTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("안쪽 여백")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { length("왼쪽", \.tbMarginLeft); length("위쪽", \.tbMarginTop) }
                GridRow { length("오른쪽", \.tbMarginRight); length("아래쪽", \.tbMarginBottom) }
                GridRow {
                    FieldLabel("모두")
                    SpinField(value: Binding { Units.millimeters(props.tbMarginLeft ?? 0) } set: { value in
                        let units: Int32 = Units.units(value)
                        (props.tbMarginLeft, props.tbMarginRight, props.tbMarginTop, props.tbMarginBottom) = (units, units, units, units)
                    }, unit: "mm", range: 0...1000)
                }
            }
            .padding(.leading, 12)
            GroupTitle("속성")
            LabeledField("세로 정렬") {
                Picker("", selection: text(\.tbVerticalAlign, "Top")) {
                    Text("위").tag("Top")
                    Text("가운데").tag("Center")
                    Text("아래").tag("Bottom")
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// 그림자 종류 in the dialog's order, with where each puts the shadow (in 2 mm steps).
    private static let shadows: [(type: UInt32, title: String, x: Int32, y: Int32)] = [
        (0, "그림자 없음", 0, 0), (9, "작게", -1, -1), (10, "크게", -1, -1),
        (1, "왼쪽 위", -1, -1), (3, "왼쪽 아래", -1, 1), (2, "오른쪽 위", 1, -1), (4, "오른쪽 아래", 1, 1),
        (5, "왼쪽 뒤", -1, 1), (7, "왼쪽 앞", -1, 1), (6, "오른쪽 뒤", 1, 1), (8, "오른쪽 앞", 1, 1),
    ]
    /// 그림자: 종류, 그림자 색, 가로·세로 방향 이동 (위로 양수) with the 1 mm steps, and 투명도.
    private var shadow: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("종류")
            HStack(spacing: 4) {
                ForEach(Self.shadows, id: \.type) { kind in
                    Button {
                        props.shadowType = kind.type
                        props.shadowOffsetX = kind.x * 567
                        props.shadowOffsetY = kind.y * 567
                        if kind.type != 0, props.shadowColor == nil { props.shadowColor = 0xb2b2b2 }
                    } label: { Pictogram.shadow(kind.type) }
                        .buttonStyle(ToolButtonStyle(on: (props.shadowType ?? 0) == kind.type))
                        .help(kind.title)
                        .accessibilityLabel(kind.title)
                }
            }
            .padding(.leading, 12)
            GroupTitle("그림자")
            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("그림자 색")
                        ColorWell(hex: color(\.shadowColor, "#b2b2b2"))
                    }
                    GridRow {
                        FieldLabel("가로 방향 이동")
                        SpinField(value: millimeters(\.shadowOffsetX), unit: "mm", range: -100...100)
                    }
                    GridRow {
                        FieldLabel("세로 방향 이동")
                        SpinField(value: Binding { -Units.millimeters(props.shadowOffsetY ?? 0) } set: { props.shadowOffsetY = Units.units(-$0) },
                                  unit: "mm", range: -100...100)
                    }
                    GridRow {
                        FieldLabel("투명도")
                        SpinField(value: Binding { (Double(props.shadowAlpha ?? 0) / 2.55).rounded() } set: { props.shadowAlpha = UInt32(($0 * 2.55).rounded()) },
                                  unit: "%", range: 0...100)
                    }
                }
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach([[(-1, -1, "왼쪽 위"), (0, -1, "위"), (1, -1, "오른쪽 위")],
                             [(-1, 0, "왼쪽"), (0, 0, "기본 값으로 설정"), (1, 0, "오른쪽")],
                             [(-1, 1, "왼쪽 아래"), (0, 1, "아래"), (1, 1, "오른쪽 아래")]], id: \.first!.2) { row in
                        GridRow {
                            ForEach(row, id: \.2) { dx, dy, title in
                                ToolIcon(title, symbol: dx == 0 && dy == 0 ? "arrow.counterclockwise" : Self.arrow(dx, dy)) {
                                    if dx == 0 && dy == 0 {
                                        let kind = Self.shadows.first { $0.type == (props.shadowType ?? 0) }
                                        (props.shadowOffsetX, props.shadowOffsetY) = ((kind?.x ?? 0) * 567, (kind?.y ?? 0) * 567)
                                    } else {
                                        props.shadowOffsetX = (props.shadowOffsetX ?? 0) + Int32(dx) * 283
                                        props.shadowOffsetY = (props.shadowOffsetY ?? 0) + Int32(dy) * 283
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.leading, 12)
            .disabled((props.shadowType ?? 0) == 0)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
    private static func arrow(_ dx: Int, _ dy: Int) -> String {
        switch (dx, dy) {
        case (-1, -1): "arrow.up.left"
        case (0, -1): "arrow.up"
        case (1, -1): "arrow.up.right"
        case (-1, 0): "arrow.left"
        case (1, 0): "arrow.right"
        case (-1, 1): "arrow.down.left"
        case (0, 1): "arrow.down"
        default: "arrow.down.right"
        }
    }

    private var fill: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("채우기")
            VStack(alignment: .leading, spacing: 8) {
                Picker("채우기", selection: Binding { props.fillType == "solid" ? "solid" : "none" } set: { kind in
                    props.fillType = kind
                    if kind == "solid", props.fillBgColor == nil { props.fillBgColor = 0xffffff }
                }) {
                    Text("색 채우기 없음").tag("none")
                    Text("색").tag("solid")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("면 색")
                        ColorWell(hex: color(\.fillBgColor, "#ffffff"))
                    }
                    GridRow {
                        FieldLabel("무늬 색")
                        ColorWell(hex: color(\.fillPatColor))
                        FieldLabel("무늬 모양")
                        ChoiceField(Binding { max(0, Int(props.fillPatType ?? 0)) } set: { props.fillPatType = Int32($0) },
                                    Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns, minWidth: 100)
                    }
                }
                .padding(.leading, 20)
                .disabled(props.fillType != "solid")
            }
            .padding(.leading, 12)
            GroupTitle("투명도 설정")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("투명도")
                    SpinField(value: Binding { (Double(props.fillAlpha ?? 0) * 100 / 255).rounded() }
                                  set: { props.fillAlpha = UInt32(($0 * 255 / 100).rounded()) },
                              unit: "%", range: 0...100)
                }
            }
            .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var cellTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("셀 크기")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    cellLength("너비", \.width)
                    cellLength("높이", \.height)
                }
            }
            .padding(.leading, 12)
            GroupTitle("안 여백")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("안 여백 지정", isOn: Binding { cell.applyInnerMargin ?? false } set: { cell.applyInnerMargin = $0 })
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { cellLength("왼쪽", \.paddingLeft); cellLength("오른쪽", \.paddingRight) }
                    GridRow { cellLength("위쪽", \.paddingTop); cellLength("아래쪽", \.paddingBottom) }
                }
                .disabled(cell.applyInnerMargin != true)
            }
            .padding(.leading, 12)
            GroupTitle("속성")
            VStack(alignment: .leading, spacing: 8) {
                LabeledField("세로 정렬") {
                    Picker("세로 정렬", selection: Binding { cell.verticalAlign ?? 0 } set: { cell.verticalAlign = $0 }) {
                        Image(systemName: "arrow.up.to.line").help("위").tag(UInt8(0))
                        Image(systemName: "arrow.up.and.down").help("가운데").tag(UInt8(1))
                        Image(systemName: "arrow.down.to.line").help("아래").tag(UInt8(2))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("제목 셀", isOn: Binding { cell.isHeader ?? false } set: { cell.isHeader = $0 })
                Toggle("셀 보호", isOn: Binding { cell.cellProtect ?? false } set: { cell.cellProtect = $0 })
            }
            .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: Fields

    private func flag(_ key: WritableKeyPath<ObjectProps, Bool?>) -> Binding<Bool> {
        Binding { props[keyPath: key] ?? false } set: { props[keyPath: key] = $0 }
    }
    private func index(_ key: WritableKeyPath<ObjectProps, UInt32?>) -> Binding<Int> {
        Binding { Int(props[keyPath: key] ?? 0) } set: { props[keyPath: key] = UInt32($0) }
    }
    private func color(_ key: WritableKeyPath<ObjectProps, UInt32?>, _ fallback: String = "#000000") -> Binding<String> {
        Binding { props[keyPath: key].map { HexColor.hex(bgr: $0) } ?? fallback } set: { props[keyPath: key] = HexColor.bgr($0) }
    }
    @ViewBuilder private func arrow(_ title: String, _ key: WritableKeyPath<ObjectProps, UInt32?>, start: Bool) -> some View {
        let images = start ? Swatches.arrowStarts : Swatches.arrowEnds
        FieldLabel(title)
        ChoiceField(index(key), images.indices.map { ($0, "") }, images: images, minWidth: 100)
    }
    @ViewBuilder private func arrowSize(_ title: String, _ key: WritableKeyPath<ObjectProps, UInt32?>, start: Bool) -> some View {
        let images = start ? Swatches.arrowStartSizes : Swatches.arrowEndSizes
        FieldLabel(title)
        ChoiceField(index(key), images.indices.map { ($0, "") }, images: images, minWidth: 100)
    }
    private func text(_ key: WritableKeyPath<ObjectProps, String?>, _ fallback: String) -> Binding<String> {
        Binding { props[keyPath: key] ?? fallback } set: { props[keyPath: key] = $0 }
    }
    private func number<T: BinaryInteger>(_ key: WritableKeyPath<ObjectProps, T?>) -> Binding<Double> {
        Binding { Double(props[keyPath: key] ?? 0) } set: { props[keyPath: key] = T(clamping: Int($0.rounded())) }
    }
    private func millimeters<T: BinaryInteger>(_ key: WritableKeyPath<ObjectProps, T?>) -> Binding<Double> {
        Binding { Units.millimeters(props[keyPath: key] ?? 0) } set: { props[keyPath: key] = Units.units($0) }
    }
    private func choice(_ key: WritableKeyPath<ObjectProps, String?>, _ fallback: String,
                        _ options: [(value: String, title: String)]) -> some View {
        ChoiceField(text(key, fallback), options, minWidth: 40)
    }
    @ViewBuilder private func length<T: BinaryInteger>(_ title: String, _ key: WritableKeyPath<ObjectProps, T?>,
                                                       range: ClosedRange<Double> = 0...1000) -> some View {
        FieldLabel(title)
        SpinField(value: millimeters(key), unit: "mm", range: range)
    }
    @ViewBuilder private func cellLength<T: BinaryInteger>(_ title: String, _ key: WritableKeyPath<CellProps, T?>) -> some View {
        FieldLabel(title)
        SpinField(value: Binding { Units.millimeters(cell[keyPath: key] ?? 0) } set: { cell[keyPath: key] = Units.units($0) },
                  unit: "mm", range: 0...1000)
    }
    /// 왼쪽·오른쪽 down the first column and 위쪽·아래쪽 down the second, as the web dialogs.
    private func sides(_ left: WritableKeyPath<ObjectProps, Int32?>, _ right: WritableKeyPath<ObjectProps, Int32?>,
                       _ top: WritableKeyPath<ObjectProps, Int32?>, _ bottom: WritableKeyPath<ObjectProps, Int32?>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow { length("왼쪽", left); length("위쪽", top) }
            GridRow { length("오른쪽", right); length("아래쪽", bottom) }
        }
        .padding(.leading, 12)
    }
}

/// 캡션: the nine places around the object, drawn as the web dialog draws them; the
/// middle is no caption.
private struct CaptionGrid: View {
    @Binding var selection: String
    private static let places = [["LeftTop", "Top", "RightTop"], ["LeftCenter", "None", "RightCenter"],
                                 ["LeftBottom", "Bottom", "RightBottom"]]
    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Self.places, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { place in
                        Button { selection = place } label: { Pictogram.caption(place, on: selection == place).frame(width: 40, height: 34).padding(3) }
                            .buttonStyle(ToolButtonStyle(on: selection == place))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                            .help(Captions.all.first { $0.value == place }?.title ?? "")
                    }
                }
            }
        }
    }
}

/// Small drawings for the picture choices: text as gray lines and the object as a box,
/// in the accent color only when chosen.
private enum Pictogram {
    static func ink(_ on: Bool) -> Color { on ? .accentColor : .secondary }
    /// 사각형 모서리 곡률: a rectangle with corners `rate` % round.
    static func corner(_ rate: UInt32) -> some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 5)
            let radius = min(box.width, box.height) * CGFloat(rate) / 100
            context.stroke(Path(roundedRect: box, cornerRadius: radius), with: .color(.primary), lineWidth: 1.5)
        }
        .frame(width: 26, height: 22)
        .padding(2)
    }
    /// 그림자 종류 `type`: a box with its shadow, none for 0.
    static func shadow(_ type: UInt32) -> some View {
        Canvas { context, size in
            let box = CGRect(x: size.width * 0.25, y: size.height * 0.25, width: size.width * 0.5, height: size.height * 0.5)
            let step: CGFloat = 3
            var shade: Path?
            switch type {
            case 1: shade = Path(box.offsetBy(dx: -step, dy: -step))
            case 2: shade = Path(box.offsetBy(dx: step, dy: -step))
            case 3: shade = Path(box.offsetBy(dx: -step, dy: step))
            case 4: shade = Path(box.offsetBy(dx: step, dy: step))
            case 9: shade = Path(box.insetBy(dx: box.width / 6, dy: box.height / 6).offsetBy(dx: -box.width / 4, dy: -box.height / 4))
            case 10: shade = Path(box.insetBy(dx: -box.width / 6, dy: -box.height / 6).offsetBy(dx: -step, dy: -step))
            case 5...8:
                // 뒤 rises behind the box, 앞 falls in front of it; to the 왼쪽 or 오른쪽.
                let left = type == 5 || type == 7, back = type == 5 || type == 6
                let lean = (left ? -1 : 1) * box.width / 2
                let edge = back ? box.minY + box.height / 2 : box.maxY
                shade = Path { p in
                    p.move(to: CGPoint(x: box.minX, y: box.maxY))
                    p.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                    p.addLine(to: CGPoint(x: box.maxX + lean, y: edge + (back ? 0 : box.height / 2)))
                    p.addLine(to: CGPoint(x: box.minX + lean, y: edge + (back ? 0 : box.height / 2)))
                    p.closeSubpath()
                }
            default: break
            }
            if let shade { context.fill(shade, with: .color(.secondary.opacity(0.6))) }
            context.fill(Path(box), with: .color(Color(nsColor: .controlBackgroundColor)))
            context.stroke(Path(box), with: .color(.primary), lineWidth: 1)
        }
        .frame(width: 26, height: 22)
        .padding(2)
    }
    static func wrap(_ value: String, on: Bool) -> some View {
        Canvas { context, size in
            let c = context, ink = ink(on)
            let box = CGRect(x: size.width * 0.3, y: size.height * 0.3, width: size.width * 0.4, height: size.height * 0.4)
            let lines = stride(from: 3.0, to: size.height, by: 5).map { CGRect(x: 1, y: $0, width: size.width - 2, height: 1.2) }
            let text = { (rects: [CGRect]) in for r in rects { c.fill(Path(r), with: .color(.secondary.opacity(0.6))) } }
            let object = { (opacity: Double) in
                c.fill(Path(box), with: .color(ink.opacity(opacity)))
                c.stroke(Path(box), with: .color(ink), lineWidth: 1)
            }
            switch value {
            case "Square":
                text(lines.flatMap { r in
                    r.intersects(box) ? [CGRect(x: r.minX, y: r.minY, width: box.minX - 2 - r.minX, height: r.height),
                                         CGRect(x: box.maxX + 2, y: r.minY, width: r.maxX - box.maxX - 2, height: r.height)] : [r]
                })
                object(0.35)
            case "TopAndBottom":
                text(lines.filter { !$0.insetBy(dx: 0, dy: -2).intersects(box) })
                object(0.35)
            case "BehindText":
                object(0.2)
                text(lines)
            default:
                text(lines)
                object(0.6)
            }
        }
    }
    /// 셀 단위로 나눔 (2), 나눔 (1), 나누지 않음 (0): a table across a page boundary.
    static func pageBreak(_ value: UInt8, on: Bool) -> some View {
        Canvas { context, size in
            let c = context, ink = ink(on)
            let cut = size.height / 2
            c.stroke(Path { $0.move(to: CGPoint(x: 0, y: cut)); $0.addLine(to: CGPoint(x: size.width, y: cut)) },
                     with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let row = { (y: CGFloat, h: CGFloat) in
                let r = CGRect(x: 4, y: y, width: size.width - 8, height: h)
                c.stroke(Path(r), with: .color(ink), lineWidth: 1)
                c.stroke(Path { $0.move(to: CGPoint(x: r.midX, y: r.minY)); $0.addLine(to: CGPoint(x: r.midX, y: r.maxY)) },
                         with: .color(ink), lineWidth: 1)
            }
            switch value {
            case 2:
                row(3, cut - 6); row(cut + 3, cut - 6)
            case 1:
                row(6, cut - 6); row(cut, cut - 9)
            default:
                row(cut + 3, cut - 6)
            }
        }
    }
    static func caption(_ place: String, on: Bool) -> some View {
        Canvas { context, size in
            let c = context, ink = ink(on)
            guard place != "None" else {
                let box = CGRect(x: size.width / 2 - 8, y: size.height / 2 - 8, width: 16, height: 16)
                c.fill(Path(box), with: .color(ink.opacity(0.35)))
                c.stroke(Path(box), with: .color(ink), lineWidth: 1)
                return
            }
            let box = CGRect(x: size.width / 2 - 7, y: size.height / 2 - 7, width: 14, height: 14)
            var label = CGPoint(x: size.width / 2, y: size.height / 2)
            if place.hasPrefix("Left") { label.x = box.minX - 8 } else if place.hasPrefix("Right") { label.x = box.maxX + 8 }
            if place == "Top" { label.y = box.minY - 6 } else if place == "Bottom" { label.y = box.maxY + 6 }
            if place.hasSuffix("Top") && place != "Top" { label.y = box.minY + 4 }
            if place.hasSuffix("Bottom") && place != "Bottom" { label.y = box.maxY - 4 }
            c.fill(Path(box), with: .color(ink.opacity(0.3)))
            c.stroke(Path(box), with: .color(ink), lineWidth: 1)
            c.draw(Text("#1").font(.system(size: 8)).foregroundStyle(ink), at: label)
        }
    }
}

/// [표 테두리/배경], from 셀 테두리/배경: the table's 테두리 and 배경 tabs alone.
struct TableBorderSheet: View {
    let state: ObjectSheetState
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var props: ObjectProps
    @State private var tab = "테두리"

    init(state: ObjectSheetState, viewer: Viewer) {
        (self.state, self.viewer) = (state, viewer)
        _props = State(initialValue: state.props)
    }
    var body: some View {
        DialogFrame("표 테두리/배경", confirmTitle: "설정") {
            DialogTabs(selection: $tab, titles: ["테두리", "배경"]) { tab in
                if tab == "배경" { TableBackgroundTab(props: $props) } else { TableBorderTab(props: $props) }
            }
            .dialogTabs()
            .frame(width: 520, height: 330)
        } confirm: {
            viewer.setObject(state.object, props.changes(from: state.props))
            dismiss()
        }
    }
}

/// 표 테두리: 셀 간격 (without which the table's own sides do not show), and the sides.
struct TableBorderTab: View {
    @Binding var props: ObjectProps
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField("셀 간격") {
                SpinField(value: Binding { Units.millimeters(props.cellSpacing ?? 0) } set: { props.cellSpacing = Units.units($0) },
                          unit: "mm", range: 0...100)
            }
            TableSides(border: Binding { props.tableBorder ?? CellBorder() } set: { props.tableBorder = $0 })
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// 표 배경: one fill over the whole table.
struct TableBackgroundTab: View {
    @Binding var props: ObjectProps
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("채우기")
            FillFields(fill: Binding { props.tableBorder?.fill } set: { props.tableBorder?.fill = $0 }, extended: true)
                .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// A table's 테두리: 종류, 굵기 and 색, 선 종류 바로 적용, and the side buttons around a
/// 미리 보기 (왼쪽, 오른쪽, 위, 아래 and 모두).
private struct TableSides: View {
    @Binding var border: CellBorder
    @State private var line = BorderSide(line: 1, width: 1, color: "#000000")
    @State private var instant = true
    @State private var pressed: Set<Int> = []
    @State private var previous = Array(repeating: BorderSide(line: 0, width: 0, color: "#000000"), count: 4)

    private func side(_ i: Int) -> BorderSide { border.sides[i] ?? BorderSide(line: 0, width: 0, color: "#000000") }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("테두리")
                LineFields(line: $line).padding(.leading, 12)
                Toggle("선 종류 바로 적용", isOn: $instant).padding(.leading, 12)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    HStack(spacing: 4) { button("위", [2]); button("아래", [3]) }
                }
                GridRow {
                    VStack(spacing: 4) { button("왼쪽", [0]); button("오른쪽", [1]) }
                    Canvas { context, size in
                        let box = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                        if let fill = border.fill, fill.color != "none" {
                            context.fill(Path(box), with: .color(HexColor.color(fill.color)))
                        }
                        for x in [box.minX + box.width / 3, box.minX + box.width * 2 / 3] {
                            context.stroke(Path { $0.move(to: CGPoint(x: x, y: box.minY)); $0.addLine(to: CGPoint(x: x, y: box.maxY)) },
                                           with: .color(.gray.opacity(0.5)), lineWidth: 0.5)
                        }
                        LineFields.stroke(context, side(0), CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.maxY))
                        LineFields.stroke(context, side(1), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY))
                        LineFields.stroke(context, side(2), CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY))
                        LineFields.stroke(context, side(3), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY))
                    }
                    .frame(width: 140, height: 110)
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    button("모두", [0, 1, 2, 3])
                }
            }
        }
        .onChange(of: line) { _, line in
            guard instant else { return }
            for i in pressed { border.sides[i] = line }
        }
    }
    /// Puts the line on `which`, or takes it back off.
    private func button(_ title: String, _ which: [Int]) -> some View {
        let down = which.allSatisfy(pressed.contains)
        return Button {
            for i in which {
                if down {
                    border.sides[i] = previous[i]
                    pressed.remove(i)
                } else if !pressed.contains(i) {
                    previous[i] = side(i)
                    border.sides[i] = line
                    pressed.insert(i)
                }
            }
        } label: { SideIcon(sides: which) }
            .buttonStyle(ToolButtonStyle(on: down))
            .help(title)
            .accessibilityLabel(title)
    }
}

/// 차트 데이터 편집 as opened: the chart's number and its data.
struct ChartEditing: Identifiable {
    let id = UUID()
    let chart: UInt32
    let data: ChartData
}

/// [차트 데이터 편집]: the 줄 names down the side, the 칸 names across the top and the values;
/// a cell's quick menu adds or removes 줄 and 칸.
struct ChartDataSheet: View {
    let editing: ChartEditing
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var data: ChartData
    @State private var editingCell: Cell?
    @FocusState private var focused: Bool

    init(editing: ChartEditing, viewer: Viewer) {
        (self.editing, self.viewer) = (editing, viewer)
        _data = State(initialValue: editing.data)
    }
    private var valid: Bool {
        !data.labels.isEmpty && !data.series.isEmpty
            && data.series.allSatisfy { $0.values.allSatisfy { Double($0)?.isFinite == true } }
    }
    var body: some View {
        DialogFrame("차트 데이터 편집", confirmTitle: "설정", canConfirm: valid && data != editing.data) {
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        ForEach(data.series.indices, id: \.self) { c in
                            cell(Binding { data.series[c].name } set: { data.series[c].name = $0 }, row: nil, column: c)
                                .fontWeight(.semibold)
                        }
                    }
                    ForEach(data.labels.indices, id: \.self) { r in
                        GridRow {
                            cell(Binding { data.labels[r] } set: { data.labels[r] = $0 }, row: r, column: nil)
                                .fontWeight(.semibold)
                            ForEach(data.series.indices, id: \.self) { c in
                                cell(Binding { data.series[c].values[r] } set: { data.series[c].values[r] = $0 }, row: r, column: c)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                .padding(2)
            }
            .frame(width: 520, height: 260)
        } confirm: {
            viewer.setChartData(data, chart: editing.chart)
            dismiss()
        }
    }
    /// A cell: double-clicked it is edited (Return or leaving it sets it); its quick menu
    /// adds and removes 줄 and 칸.
    private func cell(_ text: Binding<String>, row: Int?, column: Int?) -> some View {
        let key = Cell(row: row, column: column)
        return Group {
            if editingCell == key {
                TextField("", text: text)
                    .focused($focused)
                    .onSubmit { editingCell = nil }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, now in if !now { editingCell = nil } }
            } else {
                Text(text.wrappedValue)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: column != nil && row != nil ? .trailing : .leading)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editingCell = key }
            }
        }
        .frame(width: 90)
        .contextMenu {
            if let column {
                Button("왼쪽에 열 추가하기") { addColumn(at: column) }
            }
            if let row {
                Button("위에 행 추가하기") { addRow(at: row) }.disabled(row == 0)
                if row == data.labels.count - 1 { Button("아래에 행 추가하기") { addRow(at: row + 1) } }
            }
            Divider()
            if let column {
                Button("열 지우기") { data.series.remove(at: column) }.disabled(data.series.count == 1)
            }
            if let row {
                Button("행 지우기") { removeRow(row) }.disabled(data.labels.count == 1)
            }
        }
    }
    /// A cell of the table: a 줄 name (no column), a 칸 name (no row) or a value.
    private struct Cell: Equatable {
        let row: Int?
        let column: Int?
    }
    private func addColumn(at c: Int) {
        data.series.insert(ChartSeries(name: "계열 \(data.series.count + 1)", values: Array(repeating: "0", count: data.labels.count)), at: c)
    }
    private func addRow(at r: Int) {
        data.labels.insert("항목 \(data.labels.count + 1)", at: r)
        for c in data.series.indices { data.series[c].values.insert("0", at: r) }
    }
    private func removeRow(_ r: Int) {
        data.labels.remove(at: r)
        for c in data.series.indices { data.series[c].values.remove(at: r) }
    }
}
