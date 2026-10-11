import Testing
import Foundation
import AppKit
import SwiftUI
@testable import HwaljaKit

/// Pictures, equations, shapes and 글상자: put in, chosen, dragged and changed.
@MainActor
struct ObjectTests {
    /// Pictures and equations go in the body and in table cells; 캡션 넣기 is off in a 배포용 문서.
    @Test func insertionTargets() {
        #expect(EditingContext(inTable: true).canPicture)
        #expect(!EditingContext(inNote: true).canPicture)
        #expect(!EditingContext(object: .picture, locked: true).canCaption)
    }

    @Test func insertsPictureSavesAndUndoes() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        let position = EditPosition(target: body, scalar: 0)
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

    /// Changing an object leaves the text caret where it was.
    @Test func objectChangesKeepTheCaret() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { _ in .insertPicture(EditPosition(target: body, scalar: 0), data: png, width: 7_500, height: 7_500,
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

    /// 그림 바꾸기 puts another image in the selected picture; 삽입 그림 저장하기 gives it back.
    @Test func picturesAreReplacedAndSavedOut() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { _ in .insertPicture(EditPosition(target: body, scalar: 0), data: png, width: 7_500, height: 7_500,
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
        document.replacePicture(redPNG, object: listed[0].object, nil)
        await document.settle()
        let file = try await document.pictureFile(listed[0].object)
        #expect(file.data == redPNG && file.extension == "png")
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
        // 개체 선택: every object on the page at once, the last as the 기준 개체.
        let all = try await document.objects(page: 0)
        #expect(all.map(\.object).contains(first.object) && all.map(\.object).contains(second.object))
        document.choose(all: all)
        #expect(document.object == all.last && document.others.count == all.count - 1)
        document.object = first
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
        // A click on it, once let go, chooses it again.
        document.deselectObject()
        await document.settle()
        await drag(NSPoint(x: moved.midX, y: moved.midY), NSPoint(x: moved.midX, y: moved.midY))
        #expect(document.object != nil)

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
        let end = try await document.paragraph(body).text.unicodeScalars.count
        document.edit(undo) { _ in .insertPicture(EditPosition(target: body, scalar: UInt32(end)), data: png, width: 7_500,
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
}
