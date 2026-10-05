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
}

extension Viewer {

    /// 개체 속성 of the selected object, or 표/셀 속성 of the table holding the caret.
    func showObjectProperties() {
        guard let document else { return }
        Task {
            if let placed = document.object {
                guard let props = try? await document.objectProps(placed.object) else { return NSSound.beep() }
                objectSheet = ObjectSheetState(object: placed.object, props: props)
            } else if let target = document.selection?.focus.target, let cell = target.cell {
                let table = ObjectRef(kind: .table, section: target.section, paragraph: target.paragraph, control: cell.control)
                guard let props = try? await document.objectProps(table),
                      let cellProps = try? await document.cellProps(target)
                else { return NSSound.beep() }
                objectSheet = ObjectSheetState(object: table, props: props, cell: (target, cellProps))
            }
        }
    }
    /// What double-click and Return open: 수식 편집기 for an equation, else 개체 속성.
    func open(_ placed: PlacedObject) {
        guard placed.object.kind == .equation, let document else { return showObjectProperties() }
        Task {
            guard let props = try? await document.objectProps(placed.object) else { return NSSound.beep() }
            equation = EquationEdit(object: placed.object, script: props.script ?? "",
                                    fontSize: Double(props.fontSize ?? 1000) / 100, color: props.color ?? 0)
        }
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
    /// 캡션 넣기: for the selected object, or the table holding the caret.
    func insertCaption(_ position: String) {
        guard let document else { return }
        if let placed = document.object {
            setObject(placed.object, ObjectProps(caption: position))
        } else if let target = document.selection?.focus.target, let cell = target.cell {
            let table = ObjectRef(kind: .table, section: target.section, paragraph: target.paragraph, control: cell.control)
            setObject(table, ObjectProps(caption: position))
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
}

/// 개체 속성 (or 표/셀 속성), laid out like Hancom's: 기본 (size, position), 여백/캡션,
/// and 그림, or 표 and 셀. Only changed properties apply.
struct ObjectSheet: View {
    let state: ObjectSheetState
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var props: ObjectProps
    @State private var cell: CellProps

    init(state: ObjectSheetState, viewer: Viewer) {
        (self.state, self.viewer) = (state, viewer)
        _props = State(initialValue: state.props)
        _cell = State(initialValue: state.cell?.props ?? CellProps())
    }

    private var kind: ObjectKind { state.object.kind }

    var body: some View {
        DialogFrame(state.cell == nil ? "개체 속성" : "표/셀 속성") {
            TabView {
                basic.tab("기본")
                margins.tab("여백/캡션")
                if kind == .picture { picture.tab("그림") }
                if kind == .table {
                    table.tab("표")
                    cellTab.tab("셀")
                }
            }
            .dialogTabs()
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
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        length("너비", \.width, range: 1...10_000)
                        length("높이", \.height, range: 1...10_000)
                    }
                }
                .padding(.leading, 12)
            }
            GroupTitle("위치")
            VStack(alignment: .leading, spacing: 10) {
                Toggle("글자처럼 취급", isOn: flag(\.treatAsChar))
                if props.treatAsChar != true {
                    LabeledField("본문과의 배치") {
                        Picker("본문과의 배치", selection: text(\.textWrap, "Square")) {
                            Text("어울림").tag("Square")
                            Text("자리 차지").tag("TopAndBottom")
                            Text("글 뒤로").tag("BehindText")
                            Text("글 앞으로").tag("InFrontOfText")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("가로")
                            choice(\.horzRelTo, "Para", [("Paper", "종이"), ("Page", "쪽"), ("Column", "단"), ("Para", "문단")])
                            Text("의")
                            choice(\.horzAlign, "Left", [("Left", "왼쪽"), ("Center", "가운데"), ("Right", "오른쪽")])
                            Text("기준")
                            SpinField(value: millimeters(\.horzOffset), unit: "mm", range: -1000...1000)
                        }
                        GridRow {
                            FieldLabel("세로")
                            choice(\.vertRelTo, "Para", [("Paper", "종이"), ("Page", "쪽"), ("Para", "문단")])
                            Text("의")
                            choice(\.vertAlign, "Top", [("Top", "위"), ("Center", "가운데"), ("Bottom", "아래")])
                            Text("기준")
                            SpinField(value: millimeters(\.vertOffset), unit: "mm", range: -1000...1000)
                        }
                    }
                    Toggle("쪽 영역 안으로 제한", isOn: flag(\.restrictInPage))
                    Toggle("서로 겹침 허용", isOn: flag(\.allowOverlap))
                }
                if kind != .table { Toggle("크기 고정", isOn: flag(\.sizeProtect)) }
            }
            .padding(.leading, 12)
            if kind == .picture || kind == .shape {
                GroupTitle("개체 회전")
                LabeledField("회전각") {
                    SpinField(value: number(\.rotationAngle), unit: "°", range: -360...360)
                }
                .padding(.leading, 12)
            }
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
                Picker("캡션", selection: text(\.caption, "None")) {
                    ForEach(Captions.all, id: \.value) { Text($0.title).tag($0.value) }
                }
                .labelsHidden()
                .fixedSize()
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
                    Picker("색조", selection: text(\.effect, "RealPic")) {
                        Text("효과 없음").tag("RealPic")
                        Text("회색조").tag("GrayScale")
                        Text("흑백").tag("BlackWhite")
                    }
                    .labelsHidden()
                    .fixedSize()
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
                LabeledField("쪽 경계에서") {
                    Picker("쪽 경계에서", selection: Binding { props.pageBreak ?? 0 } set: { props.pageBreak = $0 }) {
                        Text("나눔").tag(UInt8(1))
                        Text("셀 단위로 나눔").tag(UInt8(2))
                        Text("나누지 않음").tag(UInt8(0))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("제목 줄 자동 반복", isOn: flag(\.repeatHeader))
            }
            .padding(.leading, 12)
            GroupTitle("모든 셀의 안 여백")
            sides(\.paddingLeft, \.paddingRight, \.paddingTop, \.paddingBottom)
            GroupTitle("테두리")
            LabeledField("셀 간격") {
                SpinField(value: millimeters(\.cellSpacing), unit: "mm", range: 0...100)
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
        Picker("", selection: text(key, fallback)) {
            ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
        }
        .labelsHidden()
        .fixedSize()
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
    /// 왼쪽·오른쪽·위쪽·아래쪽 lengths, as Hancom's dialogs order them.
    private func sides(_ left: WritableKeyPath<ObjectProps, Int32?>, _ right: WritableKeyPath<ObjectProps, Int32?>,
                       _ top: WritableKeyPath<ObjectProps, Int32?>, _ bottom: WritableKeyPath<ObjectProps, Int32?>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow { length("왼쪽", left); length("오른쪽", right) }
            GridRow { length("위쪽", top); length("아래쪽", bottom) }
        }
        .padding(.leading, 12)
    }
}

private extension View {
    func tab(_ title: String) -> some View {
        frame(maxWidth: .infinity, alignment: .topLeading).tabItem { Text(title) }
    }
}
