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

extension Viewer {

    /// 개체 속성 of the selected object, or 표/셀 속성 of the table holding the caret: the inspector's
    /// 개체 or 표.
    func showObjectProperties() {
        guard let document else { return }
        if document.object != nil {
            reveal(.format, tab: "개체")
        } else if document.selection?.focus.target.cell != nil {
            reveal(.format, tab: "표")
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
    /// 개체 보호 for the selected object, and 모든 보호 개체 해제.
    var protectionChoices: [Choice?] {
        [Choice(title: "개체 보호", enabled: document?.object?.object.cell == nil) {
            self.change { .setObject($0, ObjectProps(protect: true)) }
         },
         Choice(title: "모든 보호 개체 해제") { self.document?.edit(self.undoManager) { _ in .unprotectAll } }]
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
        // The object stays selected; the caption is written when it is clicked.
        guard let object = arrangedObject else { return }
        setObject(object, ObjectProps(caption: position))
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

/// Small drawings for the picture choices: text as gray lines and the object as a box,
/// in the accent color only when chosen.
enum Pictogram {
    static func ink(_ on: Bool) -> Color { on ? .white : .secondary }
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
}

/// 차트 데이터 편집 as opened: the chart's number and its data.
struct ChartEditing: Identifiable {
    let id = UUID()
    let chart: UInt32
    let data: ChartData
}

/// [차트 데이터 편집]: a table of the 줄 names down the side, the 칸 names across the top and
/// the values, each cell typed in; the bar below and a cell's quick menu add and remove 행 and 열.
struct ChartDataSheet: View {
    let editing: ChartEditing
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var data: ChartData
    @FocusState private var focused: Cell?

    init(editing: ChartEditing, viewer: Viewer) {
        (self.editing, self.viewer) = (editing, viewer)
        _data = State(initialValue: editing.data)
    }
    private var valid: Bool {
        !data.labels.isEmpty && !data.series.isEmpty
            && data.series.allSatisfy { $0.values.allSatisfy(Self.number) }
    }
    private static func number(_ text: String) -> Bool { Double(text)?.isFinite == true }

    var body: some View {
        DialogFrame("차트 데이터 편집", confirmTitle: "설정", canConfirm: valid && data != editing.data) {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                        GridRow {
                            Self.fill(header: true).frame(width: Self.width, height: Self.height)
                            ForEach(data.series.indices, id: \.self) { c in
                                cell(Binding { data.series[c].name } set: { data.series[c].name = $0 }, Cell(row: nil, column: c))
                            }
                        }
                        ForEach(data.labels.indices, id: \.self) { r in
                            GridRow {
                                cell(Binding { data.labels[r] } set: { data.labels[r] = $0 }, Cell(row: r, column: nil))
                                ForEach(data.series.indices, id: \.self) { c in
                                    cell(Binding { data.series[c].values[r] } set: { data.series[c].values[r] = $0 }, Cell(row: r, column: c))
                                }
                            }
                        }
                    }
                    .padding(1)
                    .background(Color(nsColor: .separatorColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: 520, height: 240)
                HStack(spacing: 14) {
                    tools("행", add: { addRow(at: (focused?.row).map { $0 + 1 } ?? data.labels.count) },
                          remove: focused?.row.flatMap { data.labels.count > 1 ? $0 : nil }.map { r in { removeRow(r) } })
                    tools("열", add: { addColumn(at: (focused?.column).map { $0 + 1 } ?? data.series.count) },
                          remove: focused?.column.flatMap { data.series.count > 1 ? $0 : nil }.map { c in { removeColumn(c) } })
                }
            }
        } confirm: {
            viewer.setChartData(data, chart: editing.chart)
            dismiss()
        }
    }

    private static let (width, height): (CGFloat, CGFloat) = (88, 24)
    /// A cell's ground: the names' row and column shaded.
    private static func fill(header: Bool) -> some View {
        Color(nsColor: .textBackgroundColor).overlay(Color.primary.opacity(header ? 0.05 : 0))
    }
    /// A cell typed in place; a value that is not a number shows red.
    private func cell(_ text: Binding<String>, _ key: Cell) -> some View {
        let header = key.row == nil || key.column == nil
        return TextField("", text: text)
            .textFieldStyle(.plain)
            .focused($focused, equals: key)
            .fontWeight(header ? .semibold : .regular)
            .monospacedDigit()
            .multilineTextAlignment(header ? .leading : .trailing)
            .foregroundStyle(header || Self.number(text.wrappedValue) ? Color.primary : Color.red)
            .padding(.horizontal, 6)
            .frame(width: Self.width, height: Self.height)
            .background(Self.fill(header: header))
            .overlay {
                // A click enters the cell with its text selected, as Tab does; a second click places the caret.
                if focused == key {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                } else {
                    Color.clear.contentShape(Rectangle()).onTapGesture { focused = key }
                }
            }
            .contextMenu {
                if let row = key.row {
                    Button("위에 행 추가하기") { addRow(at: row) }
                    Button("아래에 행 추가하기") { addRow(at: row + 1) }
                }
                if let column = key.column {
                    Button("왼쪽에 열 추가하기") { addColumn(at: column) }
                    Button("오른쪽에 열 추가하기") { addColumn(at: column + 1) }
                }
                Divider()
                if let row = key.row {
                    Button("행 지우기") { removeRow(row) }.disabled(data.labels.count == 1)
                }
                if let column = key.column {
                    Button("열 지우기") { removeColumn(column) }.disabled(data.series.count == 1)
                }
            }
    }
    /// 행 or 열 with its + and −: added after the focused cell's, or at the end; the focused one removed.
    private func tools(_ title: String, add: @escaping () -> Void, remove: (() -> Void)?) -> some View {
        HStack(spacing: 2) {
            Text(title).foregroundStyle(.secondary).padding(.trailing, 4)
            Button(action: add) { Image(systemName: "plus").frame(width: 22, height: 20) }
                .buttonStyle(.borderless)
                .help("\(title) 추가하기")
                .accessibilityLabel("\(title) 추가하기")
            Button { remove?() } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                .buttonStyle(.borderless)
                .disabled(remove == nil)
                .help("\(title) 지우기")
                .accessibilityLabel("\(title) 지우기")
        }
    }
    /// A cell of the table: a 줄 name (no column), a 칸 name (no row) or a value.
    private struct Cell: Hashable {
        let row: Int?
        let column: Int?
    }
    private func addColumn(at c: Int) {
        data.series.insert(ChartSeries(name: "계열 \(data.series.count + 1)", values: Array(repeating: "0", count: data.labels.count)), at: c)
        focused = Cell(row: nil, column: c)
    }
    private func addRow(at r: Int) {
        data.labels.insert("항목 \(data.labels.count + 1)", at: r)
        for c in data.series.indices { data.series[c].values.insert("0", at: r) }
        focused = Cell(row: r, column: nil)
    }
    private func removeColumn(_ c: Int) {
        focused = nil
        data.series.remove(at: c)
    }
    private func removeRow(_ r: Int) {
        focused = nil
        data.labels.remove(at: r)
        for c in data.series.indices { data.series[c].values.remove(at: r) }
    }
}
