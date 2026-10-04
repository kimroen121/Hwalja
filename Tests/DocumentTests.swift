import Testing
import Foundation
import AppKit
@testable import HwpStudio

@MainActor
struct DocumentTests {
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
        let pages = document.pages
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(undo) { $0.map { .replace($0, text: String(repeating: "줄\n", count: 120)) } }
        await document.settle()
        #expect(document.pages === pages && document.reply.pageCount > 1)
        #expect(pages.pageCount == Int(document.reply.pageCount))
        undo.undo()
        await document.settle()
        #expect(pages.pageCount == 1 && document.reply.pageCount == 1)
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

    /// Opt-in: `HWP_BENCH=<file> swift test -c release --filter benchKeystroke`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HWP_BENCH"] != nil))
    func benchKeystroke() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HWP_BENCH"]!)
        let document = try HwpDocument(data: Data(contentsOf: url))
        let undo = UndoManager()
        let target = try await document.hitTest(page: 0, x: 300, y: 300)
        document.selection = .caret(target)
        for _ in 0..<5 {
            let start = ContinuousClock.now
            document.type("가", undo)
            await document.settle()
            print("BENCH keystroke", ContinuousClock.now - start)
        }
        let page = try #require(document.pages.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let context = try #require(CGContext(data: nil, width: Int(box.width * 2), height: Int(box.height * 2), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        let start = ContinuousClock.now
        page.draw(with: .mediaBox, to: context)
        print("BENCH draw of the new page", ContinuousClock.now - start)
    }
}
