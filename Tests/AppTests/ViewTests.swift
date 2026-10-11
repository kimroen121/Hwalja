import Testing
import Foundation
import AppKit
import SwiftUI
@testable import HwaljaKit

/// The window's view of the pages: zoom, spreads, 쪽 윤곽, rulers, marks, 찾기 and status.
@MainActor
struct ViewTests {
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

    @Test func pageGeometryRoundTrips() {
        let frame = CGRect(x: 24, y: 900, width: 595, height: 842)
        let rect = PageRect(page: 0, x: 120, y: 200, width: 40, height: 16)
        let view = PageGeometry.viewRect(rect, in: frame)
        let back = PageGeometry.enginePoint(view.origin, in: frame)
        #expect(abs(back.x - 120) < 0.001 && abs(back.y - 200) < 0.001)
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
        let edits = document.reply.revision
        viewer.insertClickHere(guide: "이곳을 마우스로 누르고 내용을 입력하세요.", memo: "", name: "이름", formEditable: true)
        await document.settle()
        #expect(document.reply.revision > edits)
        let caret = try #require(document.selection?.focus)
        #expect(try await document.clickHere(at: caret)?.name == "이름")
        viewer.editClickHere(guide: "성명", memo: "", name: "이름", formEditable: false)
        await document.settle()
        #expect(try await document.clickHere(at: caret)?.guide == "성명")
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

    /// The sidebar menu: one 작업 창 at a time, or the document alone; 글자 수 and 눈금자 beside them.
    @Test func sidebarMenuChoosesOnePaneAndTheRulers() {
        let viewer = Viewer()
        viewer.toggle(.outline)
        #expect(viewer.shows(.outline) && !viewer.shows(.pages) && viewer.showsSidebar)
        viewer.toggle(.bookmarks)
        #expect(viewer.shows(.bookmarks) && !viewer.shows(.outline))
        viewer.toggle(.bookmarks)
        #expect(!viewer.showsSidebar && TaskPane.allCases.allSatisfy { !viewer.shows($0) })
        viewer.showsHorizontalRuler = true
        #expect(viewer.showsRuler && viewer.canvas.showsHorizontalRuler)
        viewer.showsHorizontalRuler = false
        #expect(!viewer.canvas.showsHorizontalRuler)
    }

    /// The toolbar's 확대/축소 shows the canvas's zoom as it changes.
    @Test func zoomMenuFollowsTheCanvas() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = viewer.canvas
        viewer.canvas.bind(document)
        viewer.canvas.setZoom(1.5)
        #expect(viewer.position.zoomPercent == 150)
        viewer.canvas.setZoom(0.5)
        #expect(viewer.position.zoomPercent == 50)
    }

    /// 모양 복사 takes the caret's 글자 모양, and puts it on the next selection.
    @Test func paintFormatCopiesThenPastes() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.type("굵은 보통", nil)
        await document.settle()
        document.selection = EditSelection(anchor: EditPosition(target: body, scalar: 0), focus: EditPosition(target: body, scalar: 2))
        document.formatText(CharStyle(bold: true), nil)
        await document.settle()
        document.select { _ in .caret(EditPosition(target: body, scalar: 1)) }
        await document.settle()
        viewer.paintFormat()
        document.select { _ in EditSelection(anchor: EditPosition(target: body, scalar: 3), focus: EditPosition(target: body, scalar: 5)) }
        await document.settle()
        viewer.paintFormat()
        await document.settle()
        #expect(try await document.session(formatAt: EditPosition(target: body, scalar: 4)).text.bold == true)
    }

    /// 수식 편집기's 한글 and LaTeX: a script goes to LaTeX and back to the same equation.
    @Test func equationScriptsGoToLatexAndBack() async throws {
        let document = HwpDocument()
        let latex = try await document.convertEquation("{a} over {b} + sqrt {x}", fromLatex: false)
        #expect(latex.contains("frac") && latex.contains("sqrt"))
        let back = try await document.convertEquation(latex, fromLatex: true)
        #expect(back.contains("over") && back.contains("sqrt"))
    }
}
