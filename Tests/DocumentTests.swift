import Testing
import Foundation
import AppKit
import PDFKit
import SwiftUI
@testable import HwpStudio

@MainActor
struct DocumentTests {
    @Test func blankFailureIsRecoverableAndCannotSave() throws {
        let document = HwpDocument(blankUsing: { _ in throw EditError.renderFailed })
        #expect(document.creationError != nil)
        #expect(document.pages.isEmpty)
        #expect(!document.context.hasSelection)
        #expect(throws: EditError.self) { try document.snapshot(contentType: .hwpx) }
    }

    @Test func corruptExistingDocumentStillThrows() {
        #expect(throws: EditError.self) { try HwpDocument(data: Data([0, 1, 2])) }
    }

    @Test func newBlankDocumentRendersAndSaves() throws {
        let document = HwpDocument()
        #expect(document.creationError == nil)
        #expect(!document.pages.isEmpty)
        let saved = try document.snapshot(contentType: .hwpx)
        let reopened = try HwpDocument(data: saved)
        #expect(reopened.creationError == nil)
        #expect(!reopened.pages.isEmpty)
    }

    @Test func insertsPictureSavesAndUndoes() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        let position = EditPosition(target: body, scalar: 0)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        document.selection = .caret(position)
        document.edit(undo) { _ in .insertPicture(position, data: png, width: 7_500, height: 7_500,
                                                   naturalWidth: 1, naturalHeight: 1,
                                                   extension: "png", description: "test.png") }
        await document.settle()
        #expect(document.revision == 1)
        #expect(document.pages.contains { page in
            if case .display(let display) = page { return display.ops.contains { if case .image = $0 { true } else { false } } }
            return false
        })
        let reopened = try HwpDocument(data: document.snapshot(contentType: .hwpx))
        #expect(!reopened.pages.isEmpty)
        undo.undo()
        await document.settle()
        #expect(document.revision == 2 && !document.reply.dirty)
    }

    @Test func insertsEquationSavesAndUndoes() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        let position = EditPosition(target: body, scalar: 0)
        let beforeOps = document.pages.reduce(0) { count, page in
            if case .display(let display) = page { return count + display.ops.count }
            return count
        }
        document.selection = .caret(position)
        document.edit(undo) { _ in
            .insertEquation(position, script: "1 over 2", fontSize: 1_000, color: 0)
        }
        await document.settle()
        let afterOps = document.pages.reduce(0) { count, page in
            if case .display(let display) = page { return count + display.ops.count }
            return count
        }
        #expect(document.revision == 1)
        #expect(afterOps > beforeOps)
        let reopened = try HwpDocument(data: document.snapshot(contentType: .hwpx))
        #expect(!reopened.pages.isEmpty)
        undo.undo()
        await document.settle()
        #expect(document.revision == 2 && !document.reply.dirty)
    }

    /// The equation inserted at `body`, found the way the canvas finds what was clicked.
    @Test func objectsAreSelectedChangedAndDeleted() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        let position = EditPosition(target: body, scalar: 0)
        document.selection = .caret(position)
        document.edit(undo) { _ in .insertEquation(position, script: "x^2", fontSize: 1_000, color: 0) }
        await document.settle()
        var object: ObjectRef?
        for control in UInt32(0)..<16 {
            let candidate = ObjectRef(kind: .equation, section: 0, paragraph: 0, control: control)
            if (try? await document.objectProps(candidate)) != nil { object = candidate }
        }
        let equation = try #require(object)
        document.edit(undo) { _ in .setObject(equation, ObjectProps(script: "a over b", fontSize: 1_400)) }
        await document.settle()
        let props = try await document.objectProps(equation)
        #expect(props.script == "a over b" && props.fontSize == 1_400)
        let preview = try await document.equationPreview("sqrt {x}", fontSize: 1_000, color: 0)
        #expect(preview.width > 0 && !preview.ops.isEmpty)
        document.edit(undo) { _ in .deleteObject(equation) }
        await document.settle()
        #expect((try? await document.objectProps(equation)) == nil)
        undo.undo()
        await document.settle()
        #expect(try await document.objectProps(equation).script == "a over b")
    }

    /// The 빠른 메뉴 offers what fits the selection.
    @Test func quickMenuFollowsTheSelection() {
        let titles = { (context: EditingContext) in MenuItems.quickMenu(Viewer(), context).compactMap { $0?.title } }
        let text = titles(EditingContext(hasSelection: true, hasRange: true))
        #expect(text.starts(with: ["오려 두기", "복사하기", "붙이기", "지우기"]) && text.contains("글자 모양…"))
        #expect(!text.contains("개체 속성…"))
        let picture = titles(EditingContext(hasSelection: true, object: .picture))
        #expect(picture.contains("원래 그림으로") && picture.last == "개체 속성…" && !picture.contains("글자 모양…"))
        #expect(titles(EditingContext(hasSelection: true, inTable: true)).contains("표/셀 속성…"))
    }

    /// 문단 부호 and 조판 부호 redraw the pages without touching the document or undo.
    @Test func marksRedrawPagesOnly() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let before = document.pages.map(\.id)
        viewer.showsParagraphMarks = true
        await document.settle()
        #expect(document.pages.map(\.id) != before)
        #expect(document.pages.allSatisfy { if case .display = $0 { true } else { false } })
        #expect(!document.reply.dirty && !document.reply.canUndo)
    }

    @Test func stylesListAndApply() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.select { $0.selection }
        await document.settle()
        let style = try #require(document.styles.last)
        #expect(document.format?.style != style.id)
        document.applyStyle(style.id, UndoManager())
        await document.settle()
        #expect(document.format?.style == style.id)
    }

    /// 문단 번호 매기기 and 한 수준 증가 from the editor, as the format row runs them.
    @Test func listsNumberAndStepLevels() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        viewer.canvas.editor.format(ParaStyle(head: "Number", numbering: 1))
        await document.settle()
        #expect(document.format?.paragraph.head == "Number" && document.format?.paragraph.level == 0)
        viewer.canvas.editor.stepLevel(by: 1)
        await document.settle()
        #expect(document.format?.paragraph.level == 1)
        viewer.canvas.editor.format(ParaStyle(head: "None"))
        await document.settle()
        #expect(document.format?.paragraph.head == "None")
    }

    /// A drag in 도형 drawing draws the shape and leaves it selected.
    @Test func drawnShapesAreInsertedAndSelected() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.insertShape("ellipse", page: 0, from: CGPoint(x: 200, y: 300), to: CGPoint(x: 320, y: 380), undo)
        await document.settle()
        let object = try #require(document.object)
        #expect(object.object.kind == .shape && document.context.object == .shape)
        #expect(abs(object.rect.x - 200) < 2 && abs(object.rect.width - 120) < 2)
        undo.undo()
        await document.settle()
        #expect(document.object == nil)
    }

    /// Dragging with the mouse sizes and moves the selected shape, and moves a table border.
    @Test func objectsAndTableBordersAreDragged() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        canvas.setZoom(1)
        canvas.tile()
        let editor = canvas.editor
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.insertShape("rectangle", page: 0, from: CGPoint(x: 200, y: 300), to: CGPoint(x: 320, y: 380), undo)
        await document.settle()
        let page = try #require(editor.frame(ofPage: 0))
        func drag(_ from: NSPoint, _ to: NSPoint) async {
            let event = { (type: NSEvent.EventType, point: NSPoint) in
                NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            editor.mouseDown(with: event(.leftMouseDown, from))
            editor.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)))
            editor.mouseDragged(with: event(.leftMouseDragged, to))
            editor.mouseUp(with: event(.leftMouseUp, to))
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(20))
                await document.settle()
            }
        }
        var rect = PageGeometry.viewRect(try #require(document.object).rect, in: page)
        await drag(NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.maxX + 30, y: rect.maxY + 15))
        let sized = PageGeometry.viewRect(try #require(document.object).rect, in: page)
        #expect(abs(sized.width - (rect.width + 30)) < 2 && abs(sized.height - (rect.height + 15)) < 2)
        #expect(abs(sized.minX - rect.minX) < 2)
        rect = sized
        await drag(NSPoint(x: rect.midX, y: rect.midY), NSPoint(x: rect.midX + 40, y: rect.midY + 20))
        let moved = PageGeometry.viewRect(try #require(document.object).rect, in: page)
        #expect(abs(moved.minX - (rect.minX + 40)) < 2 && abs(moved.minY - (rect.minY + 20)) < 2)
        #expect(abs(moved.width - rect.width) < 2)

        document.deselectObject()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(undo) { $0.map { .insertTable($0.focus, rows: 2, columns: 3) } }
        await document.settle()
        let line = try #require(try await document.tableLines(page: 0).first { !$0.row && $0.line == 0 })
        let y = page.minY + (line.from + line.to) / 2 * PageGeometry.pointsPerPixel
        let x = page.minX + line.at * PageGeometry.pointsPerPixel
        _ = editor.frame(ofPage: 0)
        editor.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: editor.convert(NSPoint(x: x, y: y), to: nil),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        try await Task.sleep(for: .milliseconds(100))
        await drag(NSPoint(x: x, y: y), NSPoint(x: x + 30, y: y))
        let after = try #require(try await document.tableLines(page: 0).first { !$0.row && $0.line == 0 && $0.table == line.table })
        #expect(abs((after.at - line.at) * PageGeometry.pointsPerPixel - 30) < 2)

        // A picture set in the text: clicked, sized, then dragged off its line.
        document.deselectObject()
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let end = try await document.paragraph(body).text.unicodeScalars.count
        document.edit(undo) { _ in .insertPicture(EditPosition(target: self.body, scalar: UInt32(end)), data: png, width: 7_500,
                                                   height: 7_500, naturalWidth: 1, naturalHeight: 1, extension: "png",
                                                   description: "p.png") }
        await document.settle()
        var picture: PlacedObject?
        for y in stride(from: 0.0, to: 1000, by: 5) where picture == nil {
            for x in stride(from: 0.0, to: 800, by: 10) where picture == nil {
                if let found = try await document.objectAt(page: 0, x: x, y: y), found.object.kind == .picture { picture = found }
            }
        }
        let inline = try #require(picture)
        rect = PageGeometry.viewRect(inline.rect, in: page)
        await drag(NSPoint(x: rect.midX, y: rect.midY), NSPoint(x: rect.midX, y: rect.midY))
        #expect(document.object?.object == inline.object)
        await drag(NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.maxX + 20, y: rect.maxY + 20))
        let grown = PageGeometry.viewRect(try #require(document.object).rect, in: page)
        #expect(abs(grown.width - (rect.width + 20)) < 2)
        await drag(NSPoint(x: grown.midX, y: grown.midY), NSPoint(x: grown.midX + 100, y: grown.midY + 120))
        let dropped = PageGeometry.viewRect(try #require(document.object).rect, in: page)
        #expect(abs(dropped.minX - (grown.minX + 100)) < 2 && abs(dropped.minY - (grown.minY + 120)) < 2)
        #expect(try await document.objectProps(inline.object).treatAsChar == false)
    }

    /// Text typed after a click inside a 글상자 lands in the box; table commands stay off.
    @Test func textBoxesTakeTypedText() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.insertShape("textbox", page: 0, from: CGPoint(x: 200, y: 300), to: CGPoint(x: 400, y: 380), nil)
        await document.settle()
        let box = try #require(document.object)
        let inside = try await document.hitTest(page: 0, x: box.rect.x + 20, y: box.rect.y + 20)
        #expect(inside.target.cell?.control == box.object.control)
        document.select { _ in .caret(inside) }
        document.type("상자 글", nil)
        await document.settle()
        #expect(try await document.paragraph(inside.target).text == "상자 글")
        #expect(!document.context.inTable && document.format?.textBox == true)
    }

    private let body = EditTarget(section: 0, paragraph: 0, cell: nil)

    @Test(arguments: ["hwp", "hwpx"])
    func editsUndoThroughUndoManagerAndSave(ext: String) async throws {
        let document = try HwpDocument(data: fixture(ext))
        let original = try await document.paragraph(body).text
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(undo) { $0.map { .replace($0, text: "가") } }
        document.edit(undo) { $0.map { .replace($0, text: "나") } }
        await document.settle()
        #expect(try await document.paragraph(body).text == "가나" + original)
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 2)))

        undo.undo()
        await document.settle()
        #expect(try await document.paragraph(body).text == "가" + original)
        undo.redo()
        await document.settle()
        #expect(try await document.paragraph(body).text == "가나" + original)

        let saved = try document.snapshot(contentType: ext == "hwp" ? .hwp : .hwpx)
        #expect(try await HwpDocument(data: saved).paragraph(body).text == "가나" + original)
    }

    @Test func typingWhileBusyIsOneEdit() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let original = try await document.paragraph(body).text
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        for text in ["가", "나", "다"] { document.type(text, undo) }
        await document.settle()
        #expect(try await document.paragraph(body).text == "가나다" + original)
        undo.undo()
        await document.settle()
        #expect(try await document.paragraph(body).text == original)
    }

    @Test func compositionIsInlineAndOneUndoStep() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let original = try await document.paragraph(body).text
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.compose("ㅎ", commit: false, undo)
        await document.settle()
        #expect(try await document.paragraph(body).text == "ㅎ" + original)
        #expect(document.marked == EditSelection(anchor: EditPosition(target: body, scalar: 0), focus: EditPosition(target: body, scalar: 1)))
        #expect(document.presentation.caret?.x ?? 0 > 0)
        document.compose("하", commit: false, undo)
        await document.settle()
        document.compose("한", commit: true, undo)
        await document.settle()
        #expect(try await document.paragraph(body).text == "한" + original)
        #expect(document.marked == nil && document.selection == .caret(EditPosition(target: body, scalar: 1)))
        undo.undo()
        await document.settle()
        #expect(try await document.paragraph(body).text == original)
        #expect(!undo.canUndo)
    }

    /// The Korean input method commits a syllable and starts the next one back to back;
    /// the commit must not be overtaken by the next composition.
    @Test func backToBackSyllablesBothLand() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let original = try await document.paragraph(body).text
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        for (text, commit) in [("ㅎ", false), ("하", false), ("한", true), ("ㄱ", false), ("그", false), ("글", true)] {
            document.compose(text, commit: commit, undo)
        }
        await document.settle()
        #expect(try await document.paragraph(body).text == "한글" + original)
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 2)))
        #expect(document.presentation.caret != nil)
    }

    @Test func movesAndDeletesFollowTheLayout() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let original = try await document.paragraph(body).text
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.move(.right, extend: false)
        document.move(.right, extend: true)
        await document.settle()
        #expect(document.selection == EditSelection(anchor: EditPosition(target: body, scalar: 1), focus: EditPosition(target: body, scalar: 2)))
        #expect(!document.presentation.highlight.isEmpty)
        document.move(.left, extend: false)
        document.delete(.left, undo)
        await document.settle()
        #expect(try await document.paragraph(body).text == String(original.dropFirst()))
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 0)))
    }

    @Test func formattingUpdatesTheCaretFormat() async throws {
        let document = try HwpDocument(data: fixture("hwp"))
        let undo = UndoManager()
        document.selection = EditSelection(anchor: EditPosition(target: body, scalar: 0), focus: EditPosition(target: body, scalar: 2))
        document.formatText(CharStyle(size: 18, bold: true), undo)
        document.formatParagraphs(ParaStyle(alignment: .center), undo)
        await document.settle()
        #expect(document.format?.text.bold == true && document.format?.text.size == 18)
        #expect(document.format?.paragraph.alignment == .center)
        undo.undo()
        undo.undo()
        await document.settle()
        #expect(document.format?.text.bold == false)
    }

    @Test func pagesArePatchedInPlace() async throws {
        let document = HwpDocument()
        let first = document.pages[0].id
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(undo) { $0.map { .replace($0, text: String(repeating: "줄\n", count: 120)) } }
        await document.settle()
        #expect(document.reply.pageCount > 1 && document.pages.count == Int(document.reply.pageCount))
        #expect(document.pages[0].id != first)
        undo.undo()
        await document.settle()
        #expect(document.pages.count == 1 && document.reply.pageCount == 1)
    }

    @Test func selectedTextSpansParagraphs() async throws {
        let document = HwpDocument()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { $0.map { .replace($0, text: "첫째\n둘째") } }
        await document.settle()
        let second = EditTarget(section: 0, paragraph: 1, cell: nil)
        let selection = EditSelection(anchor: EditPosition(target: second, scalar: 1), focus: EditPosition(target: body, scalar: 1))
        #expect(try await document.text(of: selection) == "째\n둘")
    }

    @Test func pageGeometryRoundTrips() {
        let frame = CGRect(x: 24, y: 900, width: 595, height: 842)
        let rect = PageRect(page: 0, x: 120, y: 200, width: 40, height: 16)
        let view = PageGeometry.viewRect(rect, in: frame)
        let back = PageGeometry.enginePoint(view.origin, in: frame)
        #expect(abs(back.x - 120) < 0.001 && abs(back.y - 200) < 0.001)
    }

    @Test func scalarRangesKeepClustersWhole() {
        #expect("가👨‍👩‍👧‍👦e\u{301}".scalars(1..<8) == "👨‍👩‍👧‍👦")
    }

    /// Renders the canvas offscreen: the page is drawn and the caret sits on it.
    /// `HWP_SNAPSHOT=<png>` keeps the image for a look.
    @Test func canvasDrawsPagesAndCaret() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        canvas.tile()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.move(.wordRight, extend: true)
        await document.settle()
        try await Task.sleep(for: .milliseconds(100))
        let editor = canvas.editor
        let area = editor.visibleRect
        let image = try #require(editor.bitmapImageRepForCachingDisplay(in: area))
        editor.cacheDisplay(in: area, to: image)
        if let path = ProcessInfo.processInfo.environment["HWP_SNAPSHOT"] {
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let page = try #require(editor.frame(ofPage: 0))
        let center = image.colorAt(x: Int((page.midX - area.minX) / area.width * CGFloat(image.pixelsWide)),
                                   y: Int((page.minY + 4 - area.minY) / area.height * CGFloat(image.pixelsHigh)))
        #expect(center?.brightnessComponent ?? 0 > 0.95)
        #expect(!document.presentation.highlight.isEmpty)
        #expect(canvas.zoom < 1)
    }

    /// Layout no longer depends on the viewport, so zooming and pasting across pages cannot
    /// feed back into scrolling (this recursed until the stack overflowed).
    @Test func findsAndReplacesAllAsOneUndoStep() async throws {
        let document = HwpDocument()
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(undo) { $0.map { .replace($0, text: "사과 배 사과\n사과") } }
        await document.settle()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        viewer.query = "사과"
        document.selection = .caret(EditPosition(target: body, scalar: 1))
        viewer.findNext()
        await document.settle()
        #expect(viewer.matches.count == 3)
        #expect(document.selection == viewer.matches[1])
        viewer.findNext(backward: true)
        await document.settle()
        #expect(document.selection == viewer.matches[0])
        document.replaceAll("사과", with: "감", undo)
        await document.settle()
        #expect(try await document.paragraph(body).text == "감 배 감")
        #expect(try await document.find("사과").isEmpty)
        undo.undo()
        await document.settle()
        #expect(try await document.find("사과").count == 3)
    }

    @Test func structureCommandsRunFromTheViewer() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        #expect(viewer.inBody && !viewer.inTable)
        viewer.insertTable(rows: 2, columns: 2)
        await document.settle()
        #expect(viewer.inTable)
        viewer.editTable(.insertRowBelow)
        await document.settle()
        #expect(viewer.inTable)
        var corner = try #require(document.selection?.focus)
        corner.target.cell?.cell = 0
        var far = corner
        far.target.cell?.cell = 3
        document.select { _ in EditSelection(anchor: corner, focus: far) }
        await document.settle()
        #expect(document.context.cellBlock && !document.context.hasRange)
        #expect(document.presentation.highlight.count == 4 && document.presentation.caret != nil)
        viewer.editCells { .mergeCells($0) }
        await document.settle()
        #expect(viewer.inTable && !document.context.cellBlock)
        document.selection = .caret(EditPosition(target: EditTarget(section: 0, paragraph: 1, cell: nil), scalar: 0))
        viewer.insertBreak(column: false)
        await document.settle()
        #expect(document.reply.pageCount == 2 && document.pages.count == 2)
        var page = try await document.pageSetup(section: 0)
        page.landscape.toggle()
        viewer.setPage(page, section: 0)
        await document.settle()
        #expect(try await document.pageSetup(section: 0) == page)
        #expect(document.pages[0].size.width > document.pages[0].size.height)
        let revision = document.reply.revision
        viewer.headerFooter(footer: false, pageNumber: .center)
        viewer.headerFooter(footer: true, pageNumber: nil)
        await document.settle()
        #expect(document.reply.revision == revision + 2)
    }

    @Test func notesTakeTypedText() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.selection = .caret(EditPosition(target: body, scalar: 1))
        viewer.insertNote(endnote: false)
        await document.settle()
        let caret = try #require(document.selection?.focus)
        #expect(caret.target.note != nil && document.context.inNote && !document.context.canFormat)
        document.type("각주 내용", nil)
        await document.settle()
        #expect(document.selection?.focus.scalar == caret.scalar + 5)
        #expect(document.presentation.caret != nil)
    }

    @Test func styleChosenAtTheCaretAppliesToTheNextText() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.formatText(CharStyle(bold: true), undo)
        await document.settle()
        #expect(document.format?.text.bold == true)
        document.type("굵", undo)
        await document.settle()
        let typed = try await document.session(formatAt: EditPosition(target: body, scalar: 1))
        #expect(typed.text.bold == true)
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 1)))
        // Composition keeps the pending style through every update.
        document.formatText(CharStyle(italic: true), undo)
        for (text, commit) in [("ㄱ", false), ("기", false), ("기", true)] { document.compose(text, commit: commit, undo) }
        await document.settle()
        let composed = try await document.session(formatAt: EditPosition(target: body, scalar: 2))
        #expect(composed.text.italic == true)
        undo.undo()
        await document.settle()
        undo.undo()
        await document.settle()
        #expect(try await document.paragraph(body).text.hasPrefix("굵") == false)
    }

    @Test func spreadsLayPagesSideBySide() async throws {
        let document = HwpDocument()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { $0.map { .replace($0, text: String(repeating: "줄\n", count: 120)) } }
        await document.settle()
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        canvas.bind(document)
        canvas.columns = 2
        let first = try #require(canvas.editor.frame(ofPage: 0)), second = try #require(canvas.editor.frame(ofPage: 1))
        #expect(first.minY == second.minY && second.minX > first.maxX)
        #expect(canvas.editor.page(near: NSPoint(x: second.midX, y: second.midY)) == 1)
    }

    @Test func zoomingAndReflowingSettle() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        canvas.tile()
        for zoom in [4.0, 0.25, 1.7, 3.3] { canvas.setZoom(zoom) }
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        let undo = UndoManager()
        for _ in 0..<4 { document.edit(undo) { $0.map { .replace($0, text: String(repeating: "붙여넣기 문단\n", count: 40)) } } }
        await document.settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.reply.pageCount > 1)
        #expect(canvas.editor.frame(ofPage: Int(document.reply.pageCount) - 1) != nil)
        window.setContentSize(NSSize(width: 400, height: 300))
        canvas.zoomToFit(nil)
        #expect(canvas.zoom < 1)
    }
    /// Opt-in: types fast into a real window and reports how far the screen falls behind.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HWP_BENCH"] != nil))
    func benchHostedTyping() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HWP_BENCH"]!)
        for hosted in [false, true] {
            let document = try HwpDocument(data: Data(contentsOf: url))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            let canvas: DocumentCanvas
            if hosted {
                window.contentView = NSHostingView(rootView: DocumentWindow(document: document))
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                canvas = try #require(Self.findCanvas(window))
            } else {
                canvas = DocumentCanvas(frame: window.contentLayoutRect)
                window.contentView = canvas
                canvas.bind(document)
            }
            let editor = canvas.editor
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            document.selection = .caret(try await document.hitTest(page: 0, x: 300, y: 300))
            await document.settle()
            let start = ContinuousClock.now
            // Two-set Korean typing at about 12 keys a second.
            for _ in 0..<10 {
                for (text, commit) in [("ㄱ", false), ("가", false), ("각", false), ("각", true)] {
                    if commit {
                        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                    } else {
                        editor.setMarkedText(text, selectedRange: NSRange(location: 1, length: 0),
                                             replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(Int(ProcessInfo.processInfo.environment["HWP_KEY_MS"] ?? "80")!))
                }
            }
            let typed = ContinuousClock.now
            await document.settle()
            window.displayIfNeeded()
            print("BENCH hosted \(hosted): typing \(typed - start), behind by \(ContinuousClock.now - typed)")
            window.orderOut(nil)
        }
    }
    /// Opt-in: `HWP_ROWS_PNG=<file> swift test --filter snapshotRows` renders the tool and
    /// format rows (pop-up menus draw as placeholders).
    /// Renders the tool rows and dialogs to PNGs in HWP_SNAPSHOT_DIR, drawn by AppKit
    /// like the window (native controls included), for a look without screen recording.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HWP_SNAPSHOT_DIR"] != nil))
    func snapshots() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HWP_SNAPSHOT_DIR"]!)
        let document = try HwpDocument(data: fixture("hwpx"))
        document.selection = .caret(try await document.hitTest(page: 0, x: 200, y: 200))
        document.type("가", nil)
        await document.settle()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let format = try #require(document.format)
        let views: [(String, AnyView)] = [
            ("rows", AnyView(VStack(spacing: 0) {
                ToolRow(document: document, viewer: viewer)
                Divider()
                FormatRow(document: document, editor: viewer.canvas.editor)
            }.frame(width: 1400))),
            ("table", AnyView(TableSheet(viewer: viewer))),
            ("split", AnyView(SplitCellSheet(viewer: viewer))),
            ("char", AnyView(CharShapeSheet(style: format.text, viewer: viewer))),
            ("para", AnyView(ParaShapeSheet(style: format.paragraph, viewer: viewer))),
            ("page", AnyView(PageSetupSheet(section: 0, page: try await document.pageSetup(section: 0), viewer: viewer))),
            ("equation", AnyView(EquationEditor(edit: EquationEdit(script: "x = {-b PLUSMINUS sqrt {b^2 - 4ac}} over {2a}",
                                                                   fontSize: 10, color: 0), viewer: viewer, document: document))),
            ("symbols", AnyView(PaletteGrid(items: EquationPalette.symbols[4], renderer: EquationRenderer(document: document),
                                            symbols: true) { _ in })),
            ("templates", AnyView(PaletteGrid(items: EquationPalette.templates[1].items,
                                              renderer: EquationRenderer(document: document), symbols: false) { _ in })),
            ("object", AnyView(ObjectSheet(state: ObjectSheetState(object: ObjectRef(kind: .picture, section: 0, paragraph: 0, control: 0),
                                                                   props: ObjectProps(width: 14_000, height: 9_000, treatAsChar: false,
                                                                                      textWrap: "Square", caption: "None")),
                                           viewer: viewer))),
            ("margins", AnyView(ObjectSheet(state: ObjectSheetState(object: ObjectRef(kind: .picture, section: 0, paragraph: 0, control: 0),
                                                                    props: ObjectProps(caption: "Bottom")),
                                            viewer: viewer, tab: "여백/캡션"))),
            ("tableTab", AnyView(ObjectSheet(state: ObjectSheetState(object: ObjectRef(kind: .table, section: 0, paragraph: 0, control: 0),
                                                                     props: ObjectProps(pageBreak: 2, repeatHeader: true)),
                                             viewer: viewer, tab: "표"))),
        ]
        for (name, view) in views {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
        }
        for (index, shape) in ["textbox", "rectangle", "ellipse", "line", "arc"].enumerated() {
            let y = 320 + Double(index) * 90
            document.insertShape(shape, page: 0, from: CGPoint(x: 160, y: y), to: CGPoint(x: 360, y: y + 70), nil)
        }
        viewer.showsControlCodes = true
        viewer.showsGrid = true
        await document.settle()
        let editor = viewer.canvas.editor
        editor.layoutPages(force: true)
        let page = try #require(editor.frame(ofPage: 0))
        let rep = try #require(editor.bitmapImageRepForCachingDisplay(in: page))
        editor.cacheDisplay(in: page, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "marks.png"))
    }

    private static func findCanvas(_ window: NSWindow) -> DocumentCanvas? {
        func search(_ view: NSView) -> DocumentCanvas? {
            if let canvas = view as? DocumentCanvas { return canvas }
            return view.subviews.lazy.compactMap(search).first
        }
        return window.contentView.flatMap(search)
    }

    /// Native pages draw what the exported PDF shows: the same faces at the same places.
    @Test func nativePagesMatchThePDF() async throws {
        let paths = ProcessInfo.processInfo.environment["HWP_BENCH"].map { [URL(fileURLWithPath: $0)] } ?? []
        for data in try [fixture("hwpx"), fixture("hwp")] + paths.map({ try Data(contentsOf: $0) }) {
            let document = try HwpDocument(data: data)
            let pdf = try #require(PDFDocument(data: try await document.pdf()))
            for (index, page) in document.pages.enumerated() {
                guard case .display = page, let reference = pdf.page(at: index) else { continue }
                let native = try #require(raster(page)), exported = try #require(raster(.pdf(reference)))
                let differing = zip(native, exported).filter { abs(Int($0) - Int($1)) > 96 }.count
                let ratio = Double(differing) / Double(native.count)
                print("page \(index): \(String(format: "%.4f", ratio * 100))% of pixels differ, \(native.filter { $0 < 128 }.count) dark")
                if let folder = ProcessInfo.processInfo.environment["HWP_SNAPSHOT_DIR"] {
                    for (name, pixels) in [("native", native), ("pdf", exported)] {
                        let size = page.size
                        let provider = CGDataProvider(data: Data(pixels) as CFData)!
                        let image = CGImage(width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bitsPerPixel: 8,
                                            bytesPerRow: Int(size.width), space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                        let rep = NSBitmapImageRep(cgImage: image)
                        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(index)-\(name).png"))
                    }
                }
                #expect(ratio < 0.002)
            }
        }
    }
}

/// White page bitmap whose y axis points down, `scale` pixels per point.
private func bitmap(_ size: CGSize, scale: CGFloat) -> CGContext? {
    let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: Int(size.width * scale), space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
    context?.setFillColor(gray: 1, alpha: 1)
    context?.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
    context?.translateBy(x: 0, y: size.height * scale)
    context?.scaleBy(x: scale, y: -scale)
    return context
}
/// Gray pixels of a page drawn at 2× and blurred by downsampling to 1×, so sub-pixel
/// antialiasing differences between Core Text and PDF glyphs do not count.
private func raster(_ page: RenderedPage) -> [UInt8]? {
    guard let context = bitmap(page.size, scale: 2) else { return nil }
    page.draw(in: context, rect: CGRect(origin: .zero, size: page.size))
    guard let image = context.makeImage(), let small = bitmap(page.size, scale: 1) else { return nil }
    small.interpolationQuality = .high
    small.draw(image, in: CGRect(origin: .zero, size: page.size))
    guard let bytes = small.data else { return nil }
    return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: small.bytesPerRow * small.height))
}
