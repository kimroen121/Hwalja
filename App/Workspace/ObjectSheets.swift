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
        let object: ObjectRef
        if let placed = document.object {
            object = placed.object
        } else if let target = document.selection?.focus.target, let cell = target.cell {
            object = ObjectRef(kind: .table, section: target.section, paragraph: target.paragraph, control: cell.control)
        } else {
            return
        }
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
        DialogFrame(state.cell == nil ? "개체 속성" : "표/셀 속성") {
            DialogTabs(selection: $tab, titles: ["기본", "여백/캡션"] + (kind == .picture ? ["그림"] : [])
                       + (kind == .table ? ["표", "셀"] : [])) { tab in
                switch tab {
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

/// Choices shown as pictures in a row, as the web dialogs show 본문과의 배치 and 쪽 경계에서.
private struct IconTiles<Value: Hashable, Picture: View>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @ViewBuilder let picture: (Value, Bool) -> Picture
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    picture(option.value, selection == option.value).frame(width: 30, height: 30).padding(4)
                }
                .buttonStyle(ToolButtonStyle(on: selection == option.value))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                .help(option.title)
                .accessibilityLabel(option.title)
            }
        }
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
