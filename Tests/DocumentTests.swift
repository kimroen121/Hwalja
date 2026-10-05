import Testing
import Foundation
import AppKit
import PDFKit
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
        let page = document.pages[0]
        let context = try #require(bitmap(page.size, scale: 2))
        page.draw(in: context, rect: CGRect(origin: .zero, size: page.size))  // loads the fonts
        document.type("가", undo)
        await document.settle()
        let next = document.pages[0]
        let start = ContinuousClock.now
        next.draw(in: context, rect: CGRect(origin: .zero, size: page.size))
        print("BENCH draw of the new page", ContinuousClock.now - start)
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
