import AppKit
import SwiftUI

/// The inspector at the window's right, as Pages' 포맷: 글자, 문단 and 스타일 for the text at
/// the caret, and the 개체 탭 and 상황 탭 of 한/글 (그림, 도형, 표 …) while they apply. What it
/// changes applies at once, and the full dialogs open from it.
struct Inspector: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var chosen = "글자"

    static let textTabs = ["글자", "문단", "스타일"]
    /// The 개체 탭 and 상황 탭 for what is selected.
    static func contextTabs(_ context: EditingContext) -> [String] {
        switch context.object {
        case .picture: ["그림"]
        case .shape: context.chart ? ["차트 디자인"] : ["도형"]
        case .equation: []
        case .table, nil:
            context.inHeaderFooter ? ["머리말/꼬리말"] : context.inNote ? ["주석"]
                : context.inTable ? ["표 디자인", "표 레이아웃"] : []
        }
    }
    /// A selected object has only its own tabs; text has 글자, 문단 and 스타일 before them.
    static func tabs(_ context: EditingContext) -> [String] {
        let extra = contextTabs(context)
        return [.picture, .shape].contains(context.object) ? extra : textTabs + extra
    }

    var body: some View {
        let context = document.context, tabs = Self.tabs(context)
        let tab = tabs.contains(chosen) ? chosen : tabs[0]
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab }, set: { chosen = $0 })) {
                ForEach(tabs, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            if tab == "스타일" {
                StylePane(document: document, viewer: viewer)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content(tab, context) }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .controlSize(.small)
        .onChange(of: Self.contextTabs(context)) { old, new in
            // A selected object, 머리말/꼬리말 or 주석 brings its tab up; a table's do not, so typing in cells keeps the tab.
            if let first = new.first, !old.contains(first), !first.hasPrefix("표") { chosen = first }
        }
    }

    @ViewBuilder private func content(_ tab: String, _ context: EditingContext) -> some View {
        switch tab {
        case "글자": CharacterTab(document: document, viewer: viewer)
        case "문단": ParagraphTab(document: document, viewer: viewer)
        case "그림": picture(context)
        case "도형": shape(context)
        case "차트 디자인": chart(context)
        case "표 디자인": tableDesign(context)
        case "표 레이아웃": tableLayout(context)
        case "머리말/꼬리말": headerFooter(context)
        case "주석": annotations(context)
        default: EmptyView()
        }
    }

    // MARK: 개체 탭과 상황 탭

    @ViewBuilder private func picture(_ context: EditingContext) -> some View {
        InspectorSection {
            InspectorCommand("그림 속성…", Icon.objectProps) { viewer.showObjectProperties() }
            InspectorCommand("바꾸기/저장", Icon.replacePicture, choices: {
                [Choice(title: "그림 바꾸기…") { viewer.replacePicture() },
                 Choice(title: "삽입 그림 저장하기…") { viewer.savePicture() }]
            })
            InspectorCommand("원본 그림으로", Icon.originalPicture) { MenuItems.restorePicture(viewer) }
            InspectorCommand("개체 선택", Icon.selectObjects) { viewer.draw("select") }
        }
        .disabled(context.locked)
        InspectorSection("효과") {
            InspectorCommand("색조 조정", Icon.pictureEffect, choices: { MenuItems.pictureEffects(viewer) })
            InspectorCommand("밝기", Icon.brightness, choices: { MenuItems.brightness(viewer) })
            InspectorCommand("대비", Icon.contrast, choices: { MenuItems.contrast(viewer) })
        }
        .disabled(context.locked)
        arrangement(context, order: false)
    }
    @ViewBuilder private func shape(_ context: EditingContext) -> some View {
        InspectorSection {
            InspectorCommand("도형 속성…", Icon.objectProps) { viewer.showObjectProperties() }
            if let textBox = document.object?.textBox {
                InspectorCommand("글자 넣기", Icon.textIn, on: textBox) { viewer.change { .setTextBox($0, attach: !textBox) } }
            }
            InspectorCommand("개체 선택", Icon.selectObjects) { viewer.draw("select") }
        }
        .disabled(context.locked)
        arrangement(context, order: true)
    }
    @ViewBuilder private func chart(_ context: EditingContext) -> some View {
        InspectorSection {
            InspectorCommand("차트 데이터 편집…", Icon.chartData) { viewer.editChartData() }
        }
        .disabled(context.locked)
        InspectorSection("배치") {
            Arrangement(document: document, viewer: viewer).disabled(context.locked)
            captions(context)
        }
    }
    /// 배치, 회전, 개체 보호, 순서, 그룹 and 캡션 of a selected picture or shape.
    @ViewBuilder private func arrangement(_ context: EditingContext, order: Bool) -> some View {
        InspectorSection("배치") {
            Arrangement(document: document, viewer: viewer)
            InspectorCommand("회전", Icon.rotate, choices: { viewer.rotationChoices })
            InspectorCommand("개체 보호", Icon.protect, choices: { viewer.protectionChoices })
            if order {
                InspectorCommand("앞으로", Icon.front, choices: {
                    [Choice(title: "맨 앞으로") { viewer.change { .order($0, .front) } },
                     Choice(title: "앞으로") { viewer.change { .order($0, .forward) } }]
                })
                InspectorCommand("뒤로", Icon.back, choices: {
                    [Choice(title: "맨 뒤로") { viewer.change { .order($0, .back) } },
                     Choice(title: "뒤로") { viewer.change { .order($0, .backward) } }]
                })
            }
            InspectorCommand("그룹", Icon.group, choices: { viewer.groupChoices })
        }
        .disabled(context.locked)
        InspectorSection { captions(context) }
    }
    private func captions(_ context: EditingContext) -> some View {
        InspectorCommand("캡션", Icon.caption, choices: {
            Captions.all.map { caption in Choice(title: caption.title) { viewer.insertCaption(caption.value) } }
        })
        .disabled(!context.canCaption)
    }

    @ViewBuilder private func tableDesign(_ context: EditingContext) -> some View {
        InspectorSection {
            InspectorCommand("표 속성…", Icon.objectProps) { viewer.showObjectProperties() }
            InspectorCommand("셀 테두리/배경", Icon.cellBorder, choices: {
                [Choice(title: "각 셀마다 적용…") { viewer.showCellBorder(one: false) },
                 Choice(title: "하나의 셀처럼 적용…") { viewer.showCellBorder(one: true) }]
            })
        }
        .disabled(context.locked)
        InspectorSection("배치") {
            Arrangement(document: document, viewer: viewer).disabled(context.locked)
            captions(context)
        }
    }
    @ViewBuilder private func tableLayout(_ context: EditingContext) -> some View {
        InspectorSection("줄/칸") {
            InspectorCommand("줄/칸 추가하기", Icon.insertRow, choices: {
                [Choice(title: "위쪽에 줄 추가하기") { viewer.editTable(.insertRowAbove) },
                 Choice(title: "아래쪽에 줄 추가하기") { viewer.editTable(.insertRowBelow) }, nil,
                 Choice(title: "왼쪽에 칸 추가하기") { viewer.editTable(.insertColumnLeft) },
                 Choice(title: "오른쪽에 칸 추가하기") { viewer.editTable(.insertColumnRight) }]
            })
            InspectorCommand("줄/칸 지우기", Icon.deleteRow, choices: {
                [Choice(title: "줄 지우기") { viewer.editTable(.deleteRow) }, nil,
                 Choice(title: "칸 지우기") { viewer.editTable(.deleteColumn) }]
            })
        }
        .disabled(context.locked)
        InspectorSection("셀") {
            InspectorCommand("셀 나누기…", Icon.splitCells) { viewer.splittingCells = true }
                .disabled(context.locked)
            Group {
                InspectorCommand("셀 합치기", Icon.mergeCells) { viewer.editCells { .mergeCells($0) } }
                InspectorCommand("셀 너비를 같게", Icon.equalWidth) { viewer.editCells { .equalizeCells($0, height: false) } }
                InspectorCommand("셀 높이를 같게", Icon.equalHeight) { viewer.editCells { .equalizeCells($0, height: true) } }
            }
            .disabled(!context.cellBlock || context.locked)
        }
        InspectorSection("표") {
            InspectorCommand("표 뒤집기…", Icon.flipTable) { viewer.flippingTable = true }
            InspectorCommand("표 나누기", Icon.splitTable) { viewer.editTable(.split) }
            InspectorCommand("표 붙이기", Icon.attachTable) { viewer.editTable(.attach) }
            TransparentLinesCommand(viewer: viewer)
        }
        .disabled(context.locked)
        InspectorSection("계산식") {
            InspectorCommand("블록 계산식", Icon.blockCalculation, choices: {
                MenuItems.blockFunctions.map { function in
                    Choice(title: function.title) { viewer.editCells { .calculateBlock($0, function.function) } }
                }
            })
            .disabled(!context.cellBlock || context.locked)
            InspectorCommand("계산식…", Icon.calculation) { viewer.calculating = true }
                .disabled(context.cellBlock || context.locked)
        }
    }

    @ViewBuilder private func headerFooter(_ context: EditingContext) -> some View {
        InspectorSection {
            InspectorCommand("머리말", Icon.header, choices: { MenuItems.headerChoices(viewer, footer: false) })
            InspectorCommand("꼬리말", Icon.footer, choices: { MenuItems.headerChoices(viewer, footer: true) })
            InspectorCommand("상용구", Icon.autoText, choices: {
                [("전체 쪽수", PageCode.total), ("현재 쪽 번호", .page), ("현재 쪽/전체 쪽수", .pageOfTotal)].map { title, code in
                    Choice(title: title) { viewer.insertPageCode(code) }
                }
            })
            InspectorCommand("편집 용지…", Icon.pageSetup) { viewer.showPageSetup() }
        }
        .disabled(context.locked)
        InspectorSection {
            InspectorCommand("이전", Icon.previous) { viewer.goTo(.previousHeaderFooter) }
            InspectorCommand("다음", Icon.next) { viewer.goTo(.nextHeaderFooter) }
            InspectorCommand("지우기", Icon.eraseCodes) { document.deleteHeaderFooter(viewer.undoManager) }
                .disabled(context.locked)
            InspectorCommand("닫기", Icon.close) { document.closeHeaderFooter() }
        }
    }
    @ViewBuilder private func annotations(_ context: EditingContext) -> some View {
        InspectorSection {
            InspectorCommand("각주/미주 모양…", Icon.noteShape) { viewer.showNoteShapes() }
                .disabled(context.locked)
            InspectorCommand("주석 지우기", Icon.eraseCodes) { document.deleteNote(viewer.undoManager) }
                .disabled(context.locked)
        }
        InspectorSection {
            InspectorCommand("이전 주석으로", Icon.previous) { viewer.goTo(.previousNote) }
            InspectorCommand("다음 주석으로", Icon.next) { viewer.goTo(.nextNote) }
            InspectorCommand("닫기", Icon.close) { document.closeNote() }
        }
    }
}

/// 글자: font, size and character styles, and 글자 모양 for the rest.
private struct CharacterTab: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var language: Int?
    var body: some View {
        let editor = viewer.canvas.editor
        Group {
            InspectorSection("글꼴") {
                FontField(document: document, editor: editor, language: language)
                HStack(spacing: 4) {
                    LanguageField(language: $language)
                    SizeField(size: document.format?.text.size, editor: editor)
                }
                HStack(spacing: 1) { CharacterButtons(document: document, editor: editor) }
            }
            Button("글자 모양…") { viewer.editingCharShape = true }
        }
        .disabled(!document.context.canFormat)
    }
}

/// 문단: alignment, line spacing and lists, and 문단 모양 for the rest.
private struct ParagraphTab: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    var body: some View {
        let editor = viewer.canvas.editor, context = document.context
        Group {
            InspectorSection("정렬") {
                HStack(spacing: 1) { AlignmentButtons(document: document, editor: editor) }
                SpacingField(paragraph: document.format?.paragraph, editor: editor)
            }
            InspectorSection("글머리표 및 문단 번호") {
                HStack(spacing: 1) {
                    ListButtons(document: document, editor: editor)
                    Group {
                        ToolIcon("한 수준 증가", symbol: Icon.levelUp) { editor.stepLevel(by: 1) }
                        ToolIcon("한 수준 감소", symbol: Icon.levelDown) { editor.stepLevel(by: -1) }
                    }
                    .disabled(!context.inList)
                }
                Button("문단 번호 모양…") { viewer.editingList = "문단 번호" }
            }
            Button("문단 모양…") { viewer.editingParaShape = true }
        }
        .disabled(!context.canFormat)
    }
}

/// A group of the inspector under its name, if it has one.
struct InspectorSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        (self.title, self.content) = (title, content())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            content
        }
    }
}

/// A command of the inspector, its icon before its name; with `choices`, a menu opens under it.
struct InspectorCommand: View {
    let title: String, symbol: String
    var on = false
    var action: (() -> Void)?
    var choices: (() -> [Choice?])?
    @State private var anchor = Anchor()

    init(_ title: String, _ symbol: String, on: Bool = false, action: @escaping () -> Void) {
        (self.title, self.symbol, self.on, self.action) = (title, symbol, on, action)
    }
    init(_ title: String, _ symbol: String, choices: @escaping () -> [Choice?]) {
        (self.title, self.symbol, self.choices) = (title, symbol, choices)
    }

    var body: some View {
        Button {
            if let choices { DropDown.show(choices(), below: anchor.view) } else { action?() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
                if choices != nil { Chevron() }
            }
            .padding(.horizontal, 4)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(ToolButtonStyle(on: on))
        .background(AnchorView(anchor: anchor))
    }
}

/// 표 레이아웃's 투명 선, lit while shown.
private struct TransparentLinesCommand: View {
    @ObservedObject var viewer: Viewer
    var body: some View {
        InspectorCommand("투명 선", Icon.transparentLines, on: viewer.showsTransparentLines) { viewer.showsTransparentLines.toggle() }
    }
}

/// 배치: 글자처럼 취급, and 어울림, 자리 차지, 글 앞으로 or 글 뒤로 for an object out of the line.
private struct Arrangement: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var props: ObjectProps?
    private static let wraps: [(wrap: String, title: String, symbol: String)] = [
        ("Square", "어울림", Icon.wrapSquare), ("TopAndBottom", "자리 차지", Icon.wrapTopAndBottom),
        ("InFrontOfText", "글 앞으로", Icon.inFrontOfText), ("BehindText", "글 뒤로", Icon.behindText),
    ]
    var body: some View {
        let inLine = props?.treatAsChar == true
        VStack(alignment: .leading, spacing: 4) {
            Toggle("글자처럼 취급", isOn: Binding(get: { inLine }, set: { viewer.arrange(ObjectProps(treatAsChar: $0)) }))
                .toggleStyle(.checkbox)
            HStack(spacing: 1) {
                ForEach(Self.wraps, id: \.wrap) { item in
                    ToolIcon(item.title, symbol: item.symbol, on: !inLine && props?.textWrap == item.wrap) {
                        viewer.arrange(ObjectProps(treatAsChar: false, textWrap: item.wrap))
                    }
                }
            }
            .disabled(inLine)
        }
        .disabled(props == nil)
        // Read again after every edit, so the checks follow undo and 개체 속성.
        .task(id: "\(document.revision) \(String(describing: viewer.arrangedObject))") {
            guard let object = viewer.arrangedObject else { return props = nil }
            props = try? await document.objectProps(object)
        }
    }
}
