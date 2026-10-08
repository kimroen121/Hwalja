import Testing
import Foundation
import AppKit
import CoreText
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
@testable import HwpStudio

@MainActor
struct DocumentTests {
    @Test func blankFailureIsRecoverableAndCannotSave() throws {
        let document = HwpDocument(blankUsing: { _ in throw EditError.renderFailed })
        #expect(document.creationFailed)
        #expect(document.pages.isEmpty)
        #expect(!document.context.hasSelection)
        #expect(throws: EditError.self) { try document.snapshot(contentType: .hwpx) }
    }

    @Test func blankEngineMismatchReportsCreationError() {
        let document = HwpDocument(blankUsing: { _ in throw EditError.incompatibleEngine })
        #expect(document.creationFailed)
        #expect(document.pages.isEmpty)
    }

    @Test func corruptExistingDocumentStillThrows() {
        #expect(throws: EditError.self) { try HwpDocument(data: Data([0, 1, 2])) }
    }

    @Test func newBlankDocumentRendersAndSaves() throws {
        let document = HwpDocument()
        #expect(document.creationFailed == false)
        #expect(!document.pages.isEmpty)
        let saved = try document.snapshot(contentType: .hwpx)
        let reopened = try HwpDocument(data: saved)
        #expect(reopened.creationFailed == false)
        #expect(!reopened.pages.isEmpty)
    }

    /// A save that starts after an edit was accepted must not overtake that edit.
    @Test(arguments: ["hwp", "hwpx"])
    func immediateSaveIncludesQueuedTyping(ext: String) async throws {
        let document = try HwpDocument(data: fixture(ext))
        let original = try await document.paragraph(body).text
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.select { document in
            try await Task.sleep(for: .milliseconds(100))
            return document.selection
        }
        document.type("저장 직전 입력", nil)

        let contentType: UTType = ext == "hwp" ? .hwp : .hwpx
        let saved = try await Task.detached { try document.snapshot(contentType: contentType) }.value
        let reopened = try HwpDocument(data: saved)
        #expect(try await reopened.paragraph(body).text == "저장 직전 입력" + original)
    }

    /// Object changes already accepted by the document are part of the same save boundary.
    @Test(arguments: ["hwp", "hwpx"])
    func immediateSaveIncludesQueuedObjectEdit(ext: String) async throws {
        let document = try HwpDocument(data: fixture(ext))
        let position = EditPosition(target: body, scalar: 0)
        document.selection = .caret(position)
        document.edit(nil) { _ in .insertEquation(position, script: "x", fontSize: 1_000, color: 0) }
        await document.settle()
        var equation: ObjectRef?
        for control in UInt32(0)..<16 {
            let candidate = ObjectRef(kind: .equation, section: 0, paragraph: 0, control: control)
            if (try? await document.objectProps(candidate)) != nil { equation = candidate }
        }
        let object = try #require(equation)
        document.select { document in
            try await Task.sleep(for: .milliseconds(100))
            return document.selection
        }
        let changed = ObjectProps(width: 14_000, height: 9_000, treatAsChar: false,
                                  horzOffset: 1_200, vertOffset: 1_800, script: "a over b")
        document.edit(nil) { _ in .setObject(object, changed) }

        let contentType: UTType = ext == "hwp" ? .hwp : .hwpx
        let saved = try await Task.detached { try document.snapshot(contentType: contentType) }.value
        let reopened = try HwpDocument(data: saved)
        let props = try await reopened.objectProps(object)
        #expect(props.script == "a over b")
        #expect(props.width == 14_000 && props.height == 9_000)
        #expect(props.treatAsChar == false)
        #expect(props.horzOffset == 1_200 && props.vertOffset == 1_800)
    }

    @Test(arguments: ["hwp", "hwpx"])
    func immediateSaveIncludesQueuedFormatting(ext: String) async throws {
        let document = try HwpDocument(data: fixture(ext))
        let start = EditPosition(target: body, scalar: 0)
        let end = EditPosition(target: body, scalar: 1)
        document.selection = EditSelection(anchor: start, focus: end)
        document.select { document in
            try await Task.sleep(for: .milliseconds(100))
            return document.selection
        }
        document.formatText(CharStyle(bold: true), nil)

        let contentType: UTType = ext == "hwp" ? .hwp : .hwpx
        let saved = try await Task.detached { try document.snapshot(contentType: contentType) }.value
        let reopened = try HwpDocument(data: saved)
        #expect(try await reopened.session(formatAt: start).text.bold == true)
    }

    @Test func failedQueuedWorkReleasesSaveBarrier() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        document.select { _ in throw EditError.unsupportedTarget }
        let saved = try await Task.detached { try document.snapshot(contentType: .hwpx) }.value
        #expect(!saved.isEmpty)
        #expect(try HwpDocument(data: saved).creationFailed == false)
    }

    @Test func mainThreadSnapshotRefusesPendingWorkWithoutDeadlock() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        document.select { document in
            try await Task.sleep(for: .milliseconds(100))
            return document.selection
        }
        #expect(throws: EditError.saveFailed) { try document.snapshot(contentType: .hwpx) }
        await document.settle()
    }

    /// A pending token holds saves, and finishing it twice cannot corrupt the count.
    @Test func documentWorkBarrierWaitsAndTokenFinishesOnce() {
        let barrier = DocumentWorkBarrier()
        let token = barrier.begin()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            barrier.waitUntilIdle()
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 0.02) == .timedOut)
        token.finish()
        token.finish()
        #expect(finished.wait(timeout: .now() + 1) == .success)
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

    /// Pictures and equations go in the body and in table cells; 캡션 넣기 is off in a 배포용 문서.
    @Test func insertionTargets() {
        #expect(EditingContext(inTable: true).canPicture)
        #expect(!EditingContext(inNote: true).canPicture)
        #expect(!EditingContext(object: .picture, locked: true).canCaption)
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
        #expect(text.starts(with: ["오려두기", "복사하기", "붙여넣기", "삭제"]) && text.contains("글자 모양…") && text.contains("문자표…"))
        #expect(!text.contains("개체 속성…"))
        let picture = titles(EditingContext(hasSelection: true, object: .picture))
        #expect(picture.contains("원본 그림으로") && picture.last == "개체 속성…" && !picture.contains("글자 모양…"))
        #expect(titles(EditingContext(hasSelection: true, inTable: true)).contains("표/셀 속성…"))
    }

    @Test func quickMenuOffersDeletionForObjects() {
        let titles = MenuItems.quickMenu(Viewer(), EditingContext(hasSelection: true, object: .shape)).compactMap { $0?.title }
        #expect(titles.contains("삭제"))
    }

    @Test func quickMenuKeepsCopyButDisablesMutationsInLockedDocuments() throws {
        // A 배포용 문서 has no body or table to edit, so its context has neither.
        let context = EditingContext(hasSelection: true, hasRange: true, locked: true)
        let items = MenuItems.quickMenu(Viewer(), context).compactMap { $0 }
        let enabled = { (title: String) in items.first { $0.title == title }?.enabled }
        #expect(enabled("복사하기") == true)
        #expect(enabled("오려두기") == false)
        #expect(enabled("붙여넣기") == false)
        #expect(enabled("삭제") == false)
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

    /// A 직선's end is dragged by its handle; the other end stays.
    @Test func lineEndsAreDragged() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        canvas.setZoom(1)
        canvas.tile()
        let editor = canvas.editor
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.insertShape("line", page: 0, from: CGPoint(x: 200, y: 300), to: CGPoint(x: 320, y: 300), nil)
        await document.settle()
        let page = try #require(editor.frame(ofPage: 0))
        let ends = try #require(document.object?.ends)
        let end = NSPoint(x: page.minX + ends[2] * PageGeometry.pointsPerPixel, y: page.minY + ends[3] * PageGeometry.pointsPerPixel)
        let event = { (type: NSEvent.EventType, point: NSPoint) in
            NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let to = NSPoint(x: end.x, y: end.y + 30)
        editor.mouseDown(with: event(.leftMouseDown, end))
        editor.mouseDragged(with: event(.leftMouseDragged, to))
        editor.mouseUp(with: event(.leftMouseUp, to))
        await document.settle()
        let moved = try #require(document.object?.ends)
        #expect(abs(moved[0] - ends[0]) < 1 && abs(moved[1] - ends[1]) < 1)
        #expect(abs(moved[3] - ends[3] - 40) < 2)
    }

    /// <Shift> and a click choose more objects; 개체 묶기 makes them one.
    @Test func chosenObjectsAreGrouped() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.insertShape("rectangle", page: 0, from: CGPoint(x: 100, y: 300), to: CGPoint(x: 200, y: 380), nil)
        await document.settle()
        let first = try #require(document.object)
        document.insertShape("ellipse", page: 0, from: CGPoint(x: 260, y: 300), to: CGPoint(x: 360, y: 380), nil)
        await document.settle()
        let second = try #require(document.object)
        document.choose(first)
        #expect(document.object == first && document.others == [second])
        document.choose(second)
        #expect(document.object == first && document.others.isEmpty)
        // As a <Shift> click does: chosen in the queue, so the bars follow.
        document.select { $0.choose(second); return nil }
        await document.settle()
        #expect(document.context.objects == 2)
        #expect(MenuItems.quickMenu(viewer, document.context).contains { $0?.title == "개체 묶기" })
        viewer.groupObjects()
        await document.settle()
        let group = try #require(try await document.objectAt(page: 0, x: 150, y: 340))
        let other = try await document.objectAt(page: 0, x: 310, y: 340)
        #expect(group.group && group == other)
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

        // A picture set in the text: clicked, sized; dragging it neither moves it nor floats it.
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
        // Dropped on the start of the text, it moves there, still in the line.
        let start = PageGeometry.viewRect(try await document.caret(at: EditPosition(target: body, scalar: 0)), in: page)
        await drag(NSPoint(x: grown.midX, y: grown.midY), NSPoint(x: start.minX + 1, y: start.midY))
        #expect(try await document.paragraph(body).text.unicodeScalars.first == "\u{FFFC}")
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 1)))
        picture = nil
        for y in stride(from: 0.0, to: 1000, by: 5) where picture == nil {
            for x in stride(from: 0.0, to: 800, by: 10) where picture == nil {
                if let found = try await document.objectAt(page: 0, x: x, y: y), found.object.kind == .picture { picture = found }
            }
        }
        #expect(try await document.objectProps(try #require(picture).object).treatAsChar == true)
    }

    /// 그림 바꾸기 puts another image in the selected picture; 삽입 그림 저장하기 gives it back.
    @Test func picturesAreReplacedAndSavedOut() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let red = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="))
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { _ in .insertPicture(EditPosition(target: self.body, scalar: 0), data: png, width: 7_500, height: 7_500,
                                                  naturalWidth: 1, naturalHeight: 1, extension: "png", description: "p.png") }
        await document.settle()
        var found: PlacedObject?
        for y in stride(from: 0.0, to: 1000, by: 5) where found == nil {
            for x in stride(from: 0.0, to: 800, by: 10) where found == nil {
                found = try await document.objectAt(page: 0, x: x, y: y)
            }
        }
        let listed = try await document.pictures()
        #expect(listed.map(\.object) == [try #require(found).object] && listed[0].page == 1 && !listed[0].linked)
        document.replacePicture(red, object: listed[0].object, nil)
        await document.settle()
        let file = try await document.pictureFile(listed[0].object)
        #expect(file.data == red && file.extension == "png")
    }

    /// Changing an object leaves the text caret where it was.
    @Test func objectChangesKeepTheCaret() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { _ in .insertPicture(EditPosition(target: self.body, scalar: 0), data: png, width: 7_500, height: 7_500,
                                                  naturalWidth: 1, naturalHeight: 1, extension: "png", description: "p.png") }
        await document.settle()
        var found: PlacedObject?
        for y in stride(from: 0.0, to: 1000, by: 5) where found == nil {
            for x in stride(from: 0.0, to: 800, by: 10) where found == nil {
                found = try await document.objectAt(page: 0, x: x, y: y)
            }
        }
        let object = try #require(found).object
        document.selection = .caret(EditPosition(target: body, scalar: 3))
        document.edit(nil) { _ in .setObject(object, ObjectProps(width: 3_000, height: 3_000)) }
        await document.settle()
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 3)))
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
        #expect(!document.context.inTable && !document.context.inBody && document.format?.textBox == true)
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

    /// Selecting all while the last Korean syllable is marked replaces the whole document,
    /// not the stale marked syllable.
    @Test func compositionSelectAllReplacesTheWholeSelection() async throws {
        let document = HwpDocument()
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        let editor = canvas.editor
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        editor.insertText("안녕하세", replacementRange: NSRange(location: NSNotFound, length: 0))
        await document.settle()
        editor.setMarkedText("요", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))

        editor.selectAll(nil)
        editor.insertText("반갑습니다", replacementRange: NSRange(location: NSNotFound, length: 0))
        await document.settle()
        #expect(try await document.paragraph(body).text == "반갑습니다")
        #expect(document.marked == nil)

        window.undoManager?.undo()
        await document.settle()
        #expect(try await document.paragraph(body).text == "안녕하세요")
    }

    @Test func compositionThenArrowMovesFromCommittedText() async throws {
        let (document, editor, _) = await editorComposingGreeting()
        editor.doCommand(by: NSSelectorFromString("moveLeft:"))
        editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        await document.settle()
        #expect(try await document.paragraph(body).text == "안녕하세!요")
        #expect(document.marked == nil)
    }

    @Test func compositionThenDeleteRemovesTheCommittedSyllable() async throws {
        let (document, editor, window) = await editorComposingGreeting()
        editor.doCommand(by: NSSelectorFromString("deleteBackward:"))
        await document.settle()
        #expect(try await document.paragraph(body).text == "안녕하세")
        #expect(document.marked == nil)
        window.undoManager?.undo()
        await document.settle()
        #expect(try await document.paragraph(body).text == "안녕하세요")
    }

    @Test func compositionThenPasteAppendsAfterCommittedText() async throws {
        let (document, editor, _) = await editorComposingGreeting()
        let pasteboard = NSPasteboard.withUniqueName()
        editor.pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("!", forType: .string)
        editor.paste(nil)
        await document.settle()
        #expect(try await document.paragraph(body).text == "안녕하세요!")
        #expect(document.marked == nil)
    }

    @Test func copiesPasteWithTheirFormats() async throws {
        let document = HwpDocument()
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        canvas.bind(document)
        let editor = canvas.editor
        let pasteboard = NSPasteboard.withUniqueName()
        editor.pasteboard = pasteboard
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.type("굵은 글", nil)
        await document.settle()
        document.selection = EditSelection(anchor: EditPosition(target: body, scalar: 0), focus: EditPosition(target: body, scalar: 2))
        document.formatText(CharStyle(bold: true), nil)
        await document.settle()
        editor.copy(nil)
        for _ in 0..<200 where pasteboard.string(forType: PageEditor.copyType) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pasteboard.string(forType: .html)?.contains("굵은") == true)
        // Other apps read it as UTF-8.
        let data = try #require(pasteboard.data(forType: .html))
        #expect(NSAttributedString(html: data, documentAttributes: nil)?.string.hasPrefix("굵은") == true)
        document.selection = .caret(EditPosition(target: body, scalar: 4))
        editor.paste(nil)
        await document.settle()
        #expect(try await document.paragraph(body).text == "굵은 글굵은")
        #expect(try await document.session(formatAt: EditPosition(target: body, scalar: 6)).text.bold == true)
    }

    /// Rich text from Pages or TextEdit (RTF, no HTML) keeps its bold and italic.
    @Test func pastesRichTextFromOtherApps() async throws {
        let document = HwpDocument()
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        canvas.bind(document)
        let pasteboard = NSPasteboard.withUniqueName()
        canvas.editor.pasteboard = pasteboard
        let font = NSFont.systemFont(ofSize: 12)
        let rich = NSMutableAttributedString(string: "굵게", attributes: [.font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)])
        rich.append(NSAttributedString(string: " <기울>", attributes: [.font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)]))
        pasteboard.clearContents()
        pasteboard.writeObjects([rich])
        #expect(pasteboard.string(forType: .html) == nil)
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        canvas.editor.paste(nil)
        await document.settle()
        #expect(try await document.paragraph(body).text == "굵게 <기울>")
        let bold = try await document.session(formatAt: EditPosition(target: body, scalar: 1)).text
        let italic = try await document.session(formatAt: EditPosition(target: body, scalar: 5)).text
        #expect(bold.bold == true && bold.italic != true)
        #expect(italic.italic == true && italic.bold != true)
    }

    @Test func compositionThenNewlineSplitsAfterCommittedText() async throws {
        let (document, editor, _) = await editorComposingGreeting()
        editor.doCommand(by: NSSelectorFromString("insertNewline:"))
        await document.settle()
        #expect(try await document.paragraph(body).text == "안녕하세요")
        #expect(document.selection?.focus.target.paragraph == 1)
        #expect(document.marked == nil)
    }

    @Test func compositionThenTabAppendsAfterCommittedText() async throws {
        let (document, editor, _) = await editorComposingGreeting()
        editor.doCommand(by: NSSelectorFromString("insertTab:"))
        await document.settle()
        #expect(try await document.paragraph(body).text == "안녕하세요\t")
        #expect(document.marked == nil)
    }

    private func editorComposingGreeting() async -> (HwpDocument, PageEditor, NSWindow) {
        let document = HwpDocument()
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        let editor = canvas.editor
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        editor.insertText("안녕하세", replacementRange: NSRange(location: NSNotFound, length: 0))
        await document.settle()
        editor.setMarkedText("요", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        await document.settle()
        return (document, editor, window)
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

    /// End and Shift+End stop at the end of the wrapped line, as in 한글; Home goes back.
    @Test func homeAndEndKeysGoToTheLineEnds() async throws {
        let document = HwpDocument()
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        canvas.bind(document)
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.type(String(repeating: "가나다라마바사 아자차카 ", count: 12), nil)
        await document.settle()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        await document.settle()
        func key(_ key: Int, _ flags: NSEvent.ModifierFlags = []) async {
            let characters = String(UnicodeScalar(UInt16(key))!)
            canvas.editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.function),
                                                         timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!)
            await document.settle()
        }
        await key(NSEndFunctionKey)
        let end = try #require(document.selection?.focus)
        #expect(end.upstream && end.scalar > 10 && end.scalar < 100)
        await key(NSHomeFunctionKey)
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 0)))
        await key(NSEndFunctionKey, .shift)
        #expect(document.selection == EditSelection(anchor: EditPosition(target: body, scalar: 0), focus: end))
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

    @Test func boldFormattingChangesTheRenderedFontFace() async throws {
        let document = HwpDocument()
        let start = EditPosition(target: body, scalar: 0)
        document.selection = .caret(start)
        document.type("안녕하세요", nil)
        await document.settle()

        func textFaces(_ page: RenderedPage) -> Set<PageDisplay.Face> {
            guard case .display(let display) = page else { return [] }
            return Set(display.ops.compactMap { op in
                guard case .text(let text) = op,
                      text.runs.contains(where: { $0.text.contains("안") }),
                      let run = text.runs.first(where: { $0.text.contains("안") })
                else { return nil }
                return display.fonts[run.font]
            })
        }

        let regular = textFaces(try #require(document.pages.first))
        document.selection = EditSelection(
            anchor: start,
            focus: EditPosition(target: body, scalar: 5)
        )
        document.formatText(CharStyle(bold: true), nil)
        await document.settle()
        let bold = textFaces(try #require(document.pages.first))

        #expect(!regular.isEmpty)
        #expect(!bold.isEmpty)
        #expect(bold != regular)
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

    @Test func emojiSurvivesTypingRenderingAndBothSaveFormats() async throws {
        let document = HwpDocument()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.type("앞😀뒤", nil)
        await document.settle()
        #expect(try await document.paragraph(body).text == "앞😀뒤")
        document.selection = EditSelection(anchor: EditPosition(target: body, scalar: 0),
                                           focus: EditPosition(target: body, scalar: 3))
        document.formatText(CharStyle(size: 72), nil)
        await document.settle()
        document.selection = .caret(EditPosition(target: body, scalar: 3))
        document.move(.right, extend: false)
        await document.settle()
        let rendered = document.pages.compactMap { page -> String? in
            guard case .display(let display) = page else { return nil }
            return display.ops.compactMap { op in
                guard case .text(let text) = op else { return nil }
                return text.runs.map(\.text).joined()
            }.joined()
        }.joined()
        #expect(rendered.contains("😀"))
        let emojiFaces = document.pages.flatMap { page -> [String] in
            guard case .display(let display) = page else { return [] }
            return display.ops.flatMap { op -> [String] in
                guard case .text(let text) = op else { return [] }
                return text.runs.compactMap { run in
                    run.text.contains("😀") ? display.fonts[run.font].path : nil
                }
            }
        }
        #expect(emojiFaces.contains { $0.localizedCaseInsensitiveContains("emoji") })
        let hasColoredEmoji = document.pages.contains { page in
            guard case .display = page,
                  let context = colorBitmap(page.size),
                  let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
            else { return false }
            page.draw(in: context, rect: CGRect(origin: .zero, size: page.size))
            var emojiColoredPixels = 0
            for y in 0..<context.height {
                for x in 0..<context.width {
                    let pixel = bytes + y * context.bytesPerRow + x * 4
                    if pixel[0] > 180, pixel[1] > 70, pixel[1] < 230, pixel[2] < 100 {
                        emojiColoredPixels += 1
                    }
                }
            }
            return emojiColoredPixels > 300
        }
        #expect(hasColoredEmoji, "the page must draw the emoji glyph, not LastResort's question-mark box")

        for contentType in [UTType.hwpx, .hwp] {
            let reopened = try HwpDocument(data: document.snapshot(contentType: contentType))
            #expect(try await reopened.paragraph(body).text == "앞😀뒤")
        }
    }

    @Test func consecutiveColorEmojiStayWithinTheirLayoutAdvances() async throws {
        let document = HwpDocument()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.type("📣😄📖", nil)
        await document.settle()
        document.selection = EditSelection(anchor: EditPosition(target: body, scalar: 0),
                                           focus: EditPosition(target: body, scalar: 3))
        document.formatText(CharStyle(size: 72), nil)
        await document.settle()

        let page = try #require(document.pages.first)
        guard case .display(let display) = page else {
            Issue.record("emoji page must use the native display list")
            return
        }
        let emoji = display.ops.compactMap { op -> PageDisplay.Op.Text? in
            guard case .text(let text) = op,
                  text.runs.map(\.text).joined().unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
            else { return nil }
            return text
        }
        #expect(emoji.count == 3)
        let caret = try #require(document.presentation.caret)
        for (index, text) in emoji.enumerated() {
            let run = try #require(text.runs.first)
            let descriptor = try #require(FontFiles.shared.descriptor(display.fonts[run.font]))
            let font = FontFiles.shared.font(descriptor, size: text.size)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: run.text, attributes: [.font: font])
            )
            let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
            let target = text.length ?? advance
            let ink = CTLineGetImageBounds(line, nil).applying(CGAffineTransform(scaleX: target / advance, y: 1))
            let boundary = index + 1 < emoji.count ? emoji[index + 1].origin.x : caret.x
            let paintedMaxX = text.origin.x + ink.maxX
            #expect(paintedMaxX <= boundary - 0.5,
                    "\(run.text) paints \(paintedMaxX - boundary) px into the next emoji/caret slot")
        }
    }

    @Test(.enabled(if: NSFontManager.shared.availableFontFamilies.contains("Pretendard Variable")))
    func variableFontKeepsWeightAndItalicRequest() async throws {
        let document = HwpDocument()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.formatText(CharStyle(font: "Pretendard Variable", size: 32, bold: true, italic: true), nil)
        document.type(String(repeating: "가변글꼴 굵기와 기울임 ", count: 18), nil)
        await document.settle()

        guard case .display(let display) = try #require(document.pages.first) else {
            Issue.record("variable-font page must use the native display list")
            return
        }
        let run = try #require(display.ops.compactMap { op -> PageDisplay.Op.Text? in
            guard case .text(let text) = op,
                  text.runs.map(\.text).joined().unicodeScalars.contains(where: { "가변".unicodeScalars.contains($0) })
            else { return nil }
            return text
        }.first)
        let face = display.fonts[try #require(run.runs.first).font]
        #expect(face.path.contains("PretendardVariable"))
        #expect(face.weight == 700)
        #expect(face.italic)

        let descriptor = try #require(FontFiles.shared.descriptor(face))
        let font = FontFiles.shared.font(descriptor, size: run.size)
        let variations = CTFontCopyVariation(font) as NSDictionary?
        let weight = variations?[NSNumber(value: UInt32(0x7767_6874))] as? NSNumber // `wght`
        #expect((weight?.doubleValue ?? 0) >= 650,
                "Core Text must instantiate the variable face near the requested weight")
        #expect(FontFiles.shared.needsSyntheticItalic(face, font: font),
                "a variable face without an italic axis must synthesize the requested slant")

        let pdf = try #require(PDFDocument(data: try await document.pdf()))
        let exported = try #require(pdf.page(at: 0))
        let screenPixels = try #require(raster(.display(display)))
        let pdfPixels = try #require(raster(.pdf(exported)))
        let differing = zip(screenPixels, pdfPixels).filter { abs(Int($0) - Int($1)) > 96 }.count
        let painted = zip(screenPixels, pdfPixels).filter { min($0, $1) < 224 }.count
        let ratio = Double(differing) / Double(max(1, painted))
        #expect(ratio < 0.08,
                "PDF export must use the same variable-font instance as the canvas")
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
        #expect(canvas.fit == .page && canvas.zoom.isFinite && canvas.zoom > 0)
        #expect(editor.visibleRect.insetBy(dx: -1, dy: -1).contains(page))
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

    @Test func pageCodesAndBookmarksRunFromTheViewer() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        document.type("책갈피 이름", nil)
        await document.settle()
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        #expect(await viewer.wordAtCaret() == "책갈피")
        viewer.addBookmark("처음")
        viewer.newNumber(.page, from: 7)
        viewer.setPageHide(PageHide(header: true, footer: true))
        await document.settle()
        let marks = try await document.bookmarks()
        #expect(marks.map(\.name) == ["처음"])
        #expect(try await document.pageHide(body) == PageHide(header: true, footer: true))
        viewer.eraseCodes([.pageHide, .newNumber(.page)])
        await document.settle()
        #expect(try await document.pageHide(body) == PageHide())
        let statistics = try await document.statistics()
        #expect(statistics.characters == 6 && statistics.charactersWithoutSpaces == 5 && statistics.words == 2)
        #expect(try await document.outline().isEmpty)
        #expect(await viewer.setPassword(current: nil, new: "12345") && document.hasPassword)
        #expect(await !viewer.setPassword(current: "틀림", new: nil) && document.hasPassword)
        #expect(await viewer.setPassword(current: "12345", new: nil) && !document.hasPassword)
        let fonts = try await document.fonts()
        let from = try #require(fonts[1].first).name
        viewer.replaceFont(language: 0, from: from, to: "Apple SD Gothic Neo")
        await document.settle()
        #expect(try await document.fonts()[1].contains(UsedFont(name: "Apple SD Gothic Neo", installed: true)))
        let item = { (level: UInt8) in
            OutlineItem(level: level, number: "", title: "", position: EditPosition(target: body, scalar: 0))
        }
        let tree = OutlineNode.tree([1, 2, 3, 2, 1, 3].map(item))
        #expect(tree.map(\.id) == [0, 4] && tree[0].children?.map(\.id) == [1, 3])
        #expect(tree[0].children?[0].children?.map(\.id) == [2] && tree[1].children?.map(\.id) == [5])
    }

    /// The 상황 선 follows the caret: 줄, 칸 and 글자 수 once typing pauses, and a cell's address.
    @Test func statusBarFollowsTheCaret() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        document.type("가나다", nil)
        await document.settle()
        func caret() async throws -> CaretStatus {
            for _ in 0..<100 where viewer.status.caret?.characters != 3 { try await Task.sleep(for: .milliseconds(10)) }
            return try #require(viewer.status.caret)
        }
        let typed = try await caret()
        #expect((typed.page, typed.column, typed.character, typed.characters, typed.cell) == (1, 1, 4, 3, nil))
        viewer.insertTable(rows: 1, columns: 2)
        await document.settle()
        for _ in 0..<100 where viewer.status.caret?.cell == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(viewer.status.caret?.cell == "A1")
    }

    /// 표 뒤집기 turns the table with the caret's cell: 시계 방향 90도 takes A1 of a 2×3 table to B1.
    @Test func tablesTurn() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        viewer.insertTable(rows: 2, columns: 3)
        await document.settle()
        viewer.flipTable(.right, margins: false)
        await document.settle()
        let caret = try #require(document.selection?.focus)
        #expect(try await document.status(at: caret).cell == "B1")
    }

    /// 개체 탭 and 상황 탭 follow the selection, as in 한/글 2024.
    @Test func objectAndStateTabsFollowTheSelection() {
        #expect(ToolRow.contextTabs(EditingContext()) == [])
        #expect(ToolRow.contextTabs(EditingContext(inTable: true)) == ["표 디자인", "표 레이아웃"])
        #expect(ToolRow.contextTabs(EditingContext(inTable: true, object: .picture)) == ["그림"])
        #expect(ToolRow.contextTabs(EditingContext(object: .shape)) == ["도형"])
        #expect(ToolRow.contextTabs(EditingContext(object: .equation)) == [])
        #expect(ToolRow.contextTabs(EditingContext(inHeaderFooter: true)) == ["머리말/꼬리말"])
    }

    /// 한글's table keys: Ctrl+Enter (⌘↩) in a cell adds a row, P on a cell block opens 표/셀 속성.
    @Test func tableKeysAddRowsAndOpenProperties() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        viewer.insertTable(rows: 2, columns: 2)
        await document.settle()
        var cell = try #require(document.selection?.focus)
        cell.target.cell?.cell = 0
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) async {
            viewer.canvas.editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                                windowNumber: 0, context: nil, characters: characters,
                                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
            await document.settle()
        }
        await key("\r", .command, code: 36)
        var far = cell
        far.target.cell?.cell = 5
        document.select { _ in EditSelection(anchor: cell, focus: far) }
        await document.settle()
        #expect(document.context.cellBlock && document.presentation.highlight.count == 6)
        // P while typing 한글.
        await key("ㅔ", code: 35)
        for _ in 0..<100 where viewer.objectSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(viewer.objectSheet?.cell != nil)
    }

    @Test func structureCommandsRunFromTheViewer() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        #expect(document.context.inBody && !document.context.inTable)
        viewer.insertTable(rows: 2, columns: 2)
        await document.settle()
        #expect(document.context.inTable)
        viewer.editTable(.insertRowBelow)
        await document.settle()
        #expect(document.context.inTable)
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
        #expect(document.context.inTable && !document.context.cellBlock)
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
        var border = try await document.pageBorder(section: 0)
        border.sides = Array(repeating: BorderSide(line: 1, width: 3, color: "#336699"), count: 4)
        border.fill = PageFill(color: "#ffeecc", patternColor: "#000000", pattern: 0)
        border.borderPages = .exceptFirst
        viewer.setPageBorder(border, section: 0, whole: true)
        await document.settle()
        #expect(try await document.pageBorder(section: 0) == border)
        let count = document.styles.count
        var editor = try #require(viewer.newStyle())
        editor.spec.name = "큰 제목"
        editor.spec.text = [CharStyle(size: 20)]
        viewer.finishStyle(editor, editor.spec)
        await document.settle()
        #expect(document.styles.count == count + 1 && document.styles.last?.name == "큰 제목")
        document.applyStyle(UInt32(count), viewer.undoManager)
        await document.settle()
        #expect(document.format?.style == UInt32(count) && document.format?.text.size == 20)
        // Commands that leave the text alone keep the caret where the user put it.
        let caret = EditSelection.caret(EditPosition(target: EditTarget(section: 0, paragraph: 0, cell: nil), scalar: 1))
        document.selection = caret
        viewer.moveStyle(UInt32(count), up: true)
        await document.settle()
        #expect(document.styles[count - 1].name == "큰 제목" && document.selection == caret)
        viewer.deleteStyle(UInt32(count - 1), replacement: 0)
        await document.settle()
        #expect(document.styles.count == count && document.format?.style == 0)
        var note = try await document.noteShape(section: 0, footnote: false)
        note.numberFormat = "upperRoman"
        note.numbering = "restartSection"
        viewer.setNoteShape(note, footnote: false, section: 0, whole: false)
        await document.settle()
        #expect(try await document.noteShape(section: 0, footnote: false) == note)
        var setup = try await document.sectionSetup(section: 0)
        setup.pageNum = 3
        setup.hideEmptyLine.toggle()
        viewer.setSection(setup, section: 0, whole: false)
        await document.settle()
        #expect(try await document.sectionSetup(section: 0) == setup)
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
        #expect(caret.target.note != nil && !document.context.inBody && document.context.canFormat)
        document.type("각주 내용", nil)
        await document.settle()
        #expect(document.selection?.focus.scalar == caret.scalar + 5)
        #expect(document.presentation.caret != nil)
    }

    @Test func headerFooterTargetSupportsTypingSelectionAndPlainTextCopy() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        viewer.headerFooter(footer: false, pageNumber: .center)
        await document.settle()
        let target = EditTarget(
            section: 0,
            paragraph: 0,
            cell: nil,
            note: nil,
            headerFooter: HeaderFooterTarget(footer: false, applyTo: 0, page: 0)
        )
        #expect(target.isHeaderFooter)
        #expect(target.offset(by: 1).paragraph == 1)
        document.selection = .caret(EditPosition(target: target, scalar: 0))
        document.type("학교 ", nil)
        await document.settle()
        #expect(!document.context.inBody)
        #expect(!document.context.canPicture)
        #expect(document.context.canFormat)
        #expect(document.context.inHeaderFooter)
        #expect(!document.context.canApplyStyle)
        let paragraph = try await document.paragraph(target)
        #expect(paragraph.text.hasPrefix("학교 "))
        let selection = EditSelection(
            anchor: EditPosition(target: target, scalar: 0),
            focus: EditPosition(target: target, scalar: UInt32(paragraph.text.unicodeScalars.count))
        )
        let copied = try await document.text(of: selection)
        #expect(copied.hasPrefix("학교 "))
        #expect(!copied.unicodeScalars.contains { (0x15...0x17).contains($0.value) })
    }

    @Test func headerFooterClosesAndIsDeletedBackToTheBodyCaret() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        viewer.headerFooter(footer: false, pageNumber: .center)
        await document.settle()
        let target = EditTarget(
            section: 0, paragraph: 0, cell: nil, note: nil,
            headerFooter: HeaderFooterTarget(footer: false, applyTo: 0, page: 0)
        )
        let caret = EditSelection.caret(EditPosition(target: body, scalar: 0))
        document.selection = caret
        document.selection = .caret(EditPosition(target: target, scalar: 0))
        document.type("머리", nil)
        document.closeHeaderFooter()
        await document.settle()
        #expect(document.selection == caret)
        document.selection = .caret(EditPosition(target: target, scalar: 0))
        document.deleteHeaderFooter(nil)
        await document.settle()
        #expect(document.selection == caret)
        await #expect(throws: (any Error).self) { try await document.paragraph(target) }
    }

    @Test func headerFooterEditingRequiresDoubleClickThenSupportsClickAndBodyExit() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        let canvas = viewer.canvas
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        viewer.headerFooter(footer: false, pageNumber: .center)
        await document.settle()
        let target = EditTarget(
            section: 0, paragraph: 0, cell: nil, note: nil,
            headerFooter: HeaderFooterTarget(footer: false, applyTo: 0, page: 0)
        )
        document.selection = .caret(EditPosition(target: target, scalar: 0))
        document.type("학교 머리말 ", nil)
        await document.settle()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        let editor = canvas.editor
        editor.layoutSubtreeIfNeeded()
        let page = try #require(editor.frame(ofPage: 0))
        let header = PageGeometry.viewRect(
            try await document.caret(at: EditPosition(target: target, scalar: 2)), in: page
        )
        func event(at point: NSPoint, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(point, to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        editor.mouseDown(with: event(at: NSPoint(x: header.midX, y: header.midY), clicks: 1))
        await document.settle()
        #expect(document.selection?.focus.target.headerFooter == nil)
        editor.mouseDown(with: event(at: NSPoint(x: header.midX, y: header.midY), clicks: 2))
        await document.settle()
        #expect(document.selection?.focus.target.headerFooter == target.headerFooter)
        editor.mouseDown(with: event(at: NSPoint(x: header.maxX, y: header.midY), clicks: 1))
        await document.settle()
        #expect(document.selection?.focus.target.headerFooter == target.headerFooter)
        editor.mouseDown(with: event(at: NSPoint(x: page.midX, y: page.midY), clicks: 1))
        await document.settle()
        #expect(document.selection?.focus.target.headerFooter == nil)
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

    @Test func rulerMarksTheBodyAndIndentsAndDraggingThemChangesThem() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        canvas.tile()
        await document.settle()
        canvas.showsRuler = true
        var marks: [NSRulerMarker] = []
        for _ in 0..<50 where marks.count < 5 {
            try await Task.sleep(for: .milliseconds(20))
            marks = canvas.horizontalRulerView?.markers ?? []
        }
        let page = try #require(canvas.editor.frame(ofPage: 0))
        let left = try #require(marks.first { $0.representedObject as? String == "indentLeft" })
        #expect(marks.count == 5 && marks.allSatisfy { page.minX < $0.markerLocation && $0.markerLocation < page.maxX })
        let before = document.pages[0].id
        // The first line stays where it was.
        left.markerLocation += 20
        canvas.editor.rulerView(canvas.horizontalRulerView!, didMove: left)
        await document.settle()
        #expect(document.format?.paragraph.marginLeft == 20 && document.format?.paragraph.indent == -20)
        #expect(document.pages[0].id != before)
    }

    @Test func withoutPageOutlineOnlyBodiesShowOneAfterAnother() async throws {
        let document = HwpDocument()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { $0.map { .replace($0, text: String(repeating: "줄\n", count: 120)) } }
        await document.settle()
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        canvas.bind(document)
        let page = try #require(canvas.editor.frame(ofPage: 0))
        canvas.editor.showsOutline = false
        let first = try #require(canvas.editor.clip(ofPage: 0)), second = try #require(canvas.editor.clip(ofPage: 1))
        let moved = try #require(canvas.editor.frame(ofPage: 0))
        #expect(first.width < page.width && first.height < page.height)
        #expect(moved.size == page.size && moved.contains(first))
        #expect(second.minY == first.maxY + PageEditor.draftGap)
        #expect(canvas.editor.page(near: NSPoint(x: second.midX, y: second.minY + 2)) == 1)
        canvas.editor.showsOutline = true
        #expect(canvas.editor.clip(ofPage: 0) == page)
    }

    @Test func pageOutlineTurnsOnForSeveralPagesAndIsRemembered() {
        let viewer = Viewer()
        viewer.showsOutline = false
        #expect(Viewer().showsOutline == false && !viewer.canvas.editor.showsOutline)
        viewer.columns = 2
        #expect(viewer.showsOutline && viewer.canvas.editor.showsOutline && Viewer().showsOutline)
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
            ("char", AnyView(CharShapeSheet(style: format.text, languages: format.languages, viewer: viewer))),
            ("para", AnyView(ParaShapeSheet(style: format.paragraph, viewer: viewer))),
            ("charExtended", AnyView(CharShapeSheet(style: format.text, languages: format.languages, viewer: viewer, tab: "확장"))),
            ("list", AnyView(ListSheet(style: format.paragraph, body: true, tab: "문단 번호", viewer: viewer))),
            ("paraBorder", AnyView(ParaShapeSheet(style: format.paragraph, viewer: viewer, tab: "테두리/배경"))),
            ("page", AnyView(PageSetupSheet(section: 0, page: try await document.pageSetup(section: 0), viewer: viewer))),
            ("pageBorder", AnyView(PageBorderSheet(section: 0, border: try await document.pageBorder(section: 0), viewer: viewer))),
            ("styles", AnyView(StyleSheet(document: document, viewer: viewer))),
            ("styleEdit", AnyView(StyleEditSheet(editor: try #require(viewer.newStyle()), styles: document.styles, viewer: viewer))),
            ("notes", AnyView(NoteShapeSheet(section: 0, footnote: try await document.noteShape(section: 0, footnote: true),
                                             endnote: try await document.noteShape(section: 0, footnote: false), viewer: viewer))),
            ("section", AnyView(SectionSheet(section: 0, setup: try await document.sectionSetup(section: 0), viewer: viewer))),
            ("pageBackground", AnyView(PageBorderSheet(section: 0, border: try await document.pageBorder(section: 0), viewer: viewer,
                                                       tab: "배경"))),
            ("equation", AnyView(EquationEditor(edit: EquationEdit(script: "x = {-b PLUSMINUS sqrt {b^2 - 4ac}} over {2a}",
                                                                   fontSize: 10, color: 0), viewer: viewer, document: document))),
            ("symbols", AnyView(VStack(alignment: .leading) {
                ForEach(EquationPalette.symbols.indices, id: \.self) { index in
                    PaletteGrid(items: EquationPalette.symbols[index].items, renderer: EquationRenderer(document: document),
                                symbols: true) { _ in }
                    Divider()
                }
            })),
            ("templates", AnyView(VStack(alignment: .leading) {
                ForEach(EquationPalette.templates.indices, id: \.self) { index in
                    PaletteGrid(items: EquationPalette.templates[index].items,
                                renderer: EquationRenderer(document: document), symbols: false) { _ in }
                    Divider()
                }
            })),
            ("object", AnyView(ObjectSheet(state: ObjectSheetState(object: ObjectRef(kind: .picture, section: 0, paragraph: 0, control: 0),
                                                                   props: ObjectProps(width: 14_000, height: 9_000, treatAsChar: false,
                                                                                      textWrap: "Square", caption: "None")),
                                           viewer: viewer))),
            ("margins", AnyView(ObjectSheet(state: ObjectSheetState(object: ObjectRef(kind: .picture, section: 0, paragraph: 0, control: 0),
                                                                    props: ObjectProps(caption: "Bottom")),
                                            viewer: viewer, tab: "여백/캡션"))),
            ("newNumber", AnyView(NewNumberSheet(viewer: viewer))),
            ("pageHide", AnyView(PageHideSheet(viewer: viewer, hide: PageHide(header: true)))),
            ("bookmark", AnyView(BookmarkSheet(viewer: viewer))),
            ("eraseCodes", AnyView(EraseCodesSheet(viewer: viewer))),
            ("documentInfo", AnyView(DocumentInfoSheet(info: DocumentInfo(url: nil, statistics: try await document.statistics()),
                                                       document: document, viewer: viewer))),
            ("password", AnyView(PasswordSheet(viewer: viewer))),
            ("passwordChange", AnyView(PasswordChangeSheet(viewer: viewer))),
            ("fontInfo", AnyView(DocumentInfoSheet(info: DocumentInfo(url: nil, statistics: try await document.statistics()),
                                                   document: document, viewer: viewer, tab: "글꼴 정보"))),
            ("pictureInfo", AnyView(DocumentInfoSheet(info: DocumentInfo(url: nil, statistics: try await document.statistics()),
                                                      document: document, viewer: viewer, tab: "그림 정보"))),
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
        // HWP_SNAPSHOT_DOC=<file>: its pages too, as the canvas draws them.
        if let path = ProcessInfo.processInfo.environment["HWP_SNAPSHOT_DOC"] {
            let other = try HwpDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
            viewer.canvas.bind(other)
            viewer.showsControlCodes = false
            viewer.showsGrid = false
            editor.layoutPages(force: true)
            for index in other.pages.indices {
                let page = try #require(editor.frame(ofPage: index))
                let rep = try #require(editor.bitmapImageRepForCachingDisplay(in: page))
                editor.cacheDisplay(in: page, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "page-\(index + 1).png"))
            }
            viewer.showsOutline = false
            if let first = editor.clip(ofPage: 0), let last = editor.clip(ofPage: min(1, other.pages.count - 1)) {
                let area = first.union(last).insetBy(dx: -8, dy: -8)
                let rep = try #require(editor.bitmapImageRepForCachingDisplay(in: area))
                editor.cacheDisplay(in: area, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "draft.png"))
            }
            viewer.showsOutline = true
        }
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

    /// Korean fonts commonly have no italic face. The canvas synthesizes the slant,
    /// so PDF export must do the same without changing glyph advances or pagination.
    @Test func synthesizedKoreanItalicMatchesPDFExport() async throws {
        let document = HwpDocument()
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.formatText(CharStyle(size: 32, italic: true), undo)
        document.type("기울임 한글", undo)
        await document.settle()

        let pdf = try #require(PDFDocument(data: try await document.pdf()))
        let page = try #require(document.pages.first)
        let reference = try #require(pdf.page(at: 0))
        let native = try #require(raster(page))
        let exported = try #require(raster(.pdf(reference)))
        let differing = zip(native, exported).filter { abs(Int($0) - Int($1)) > 96 }.count
        let ratio = Double(differing) / Double(native.count)

        #expect(ratio < 0.002)
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

private func colorBitmap(_ size: CGSize) -> CGContext? {
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setFillColor(NSColor.white.cgColor)
    context?.fill(CGRect(origin: .zero, size: size))
    context?.translateBy(x: 0, y: size.height)
    context?.scaleBy(x: 1, y: -1)
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
