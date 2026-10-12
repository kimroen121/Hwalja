import Testing
import Foundation
import AppKit
import SwiftUI
import CoreText
import PDFKit
@testable import HwaljaKit

/// Pages drawn natively match the exported PDF; fonts, emoji and snapshots.
@MainActor
struct RenderingTests {
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
        // 텍스트 with its 레이아웃 showing.
        let layoutViewer = Viewer()
        layoutViewer.canvas.bind(document)
        layoutViewer.textLayout = 1
        // A document with the caret in a 각주, for the 주석 탭.
        let noted = try HwpDocument(data: fixture("hwpx"))
        let notedViewer = Viewer()
        notedViewer.canvas.bind(noted)
        noted.selection = .caret(EditPosition(target: body, scalar: 1))
        notedViewer.insertNote(endnote: false)
        await noted.settle()
        // A picture chosen, a table with the caret in it, and an equation chosen, for their tabs.
        let pictured = try HwpDocument(data: fixture("hwpx"))
        let picturedViewer = Viewer()
        picturedViewer.canvas.bind(pictured)
        _ = try await insertedPicture(pictured)
        let tabled = HwpDocument()
        let tabledViewer = Viewer()
        tabledViewer.canvas.bind(tabled)
        tabled.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await tabled.settle()
        tabledViewer.insertTable(rows: 3, columns: 3)
        await tabled.settle()
        let equated = try HwpDocument(data: fixture("hwpx"))
        let equatedViewer = Viewer()
        equatedViewer.canvas.bind(equated)
        equated.selection = .caret(EditPosition(target: body, scalar: 0))
        equated.edit(nil) { _ in .insertEquation(EditPosition(target: body, scalar: 0), script: "x^2", fontSize: 1_000, color: 0) }
        await equated.settle()
        choose(try await placedObject(equated, .equation), in: equated)
        await equated.settle()
        // A 글상자 and a 직선 chosen, for 도형.
        var shaped: [(HwpDocument, Viewer)] = []
        for shape in ["textbox", "line"] {
            let document = try HwpDocument(data: fixture("hwpx"))
            let viewer = Viewer()
            viewer.canvas.bind(document)
            document.insertShape(shape, page: 0, from: CGPoint(x: 160, y: 320), to: CGPoint(x: 360, y: 390), nil)
            await document.settle()
            choose(try await placedObject(document, .shape), in: document)
            await document.settle()
            shaped.append((document, viewer))
        }
        // 문서's 구역 showing.
        let sectionViewer = Viewer()
        sectionViewer.canvas.bind(document)
        sectionViewer.documentTab = 1
        let inspector = { (document: HwpDocument, viewer: Viewer, tab: String) in
            AnyView(Inspector(document: document, viewer: viewer, tab: tab).frame(width: 280, height: 1600))
        }
        let views: [(String, AnyView)] = [
            ("quickMenu", AnyView(QuickMenu(document: document, viewer: viewer).padding(20))),
            ("pictureStyle", inspector(pictured, picturedViewer, "스타일")),
            ("pictureImage", inspector(pictured, picturedViewer, "이미지")),
            ("object", inspector(pictured, picturedViewer, "개체")),
            ("tableTable", inspector(tabled, tabledViewer, "표")),
            ("tableCell", inspector(tabled, tabledViewer, "셀")),
            ("equationTab", inspector(equated, equatedViewer, "수식")),
            ("textBoxShape", inspector(shaped[0].0, shaped[0].1, "도형")),
            ("lineShape", inspector(shaped[1].0, shaped[1].1, "도형")),
            ("inspector", AnyView(Inspector(document: document, viewer: viewer).frame(width: 270, height: 900))),
            ("textLayout", AnyView(Inspector(document: document, viewer: layoutViewer).frame(width: 270, height: 900))),
            ("annotations", AnyView(Inspector(document: noted, viewer: notedViewer, tab: "주석").frame(width: 270, height: 400))),
            ("documentInspector", AnyView(DocumentInspector(document: document, viewer: viewer).frame(width: 270, height: 1400))),
            ("sectionInspector", AnyView(DocumentInspector(document: document, viewer: sectionViewer).frame(width: 270, height: 1400))),
            ("shapes", AnyView(ShapeTiles(viewer: viewer))),
            ("table", AnyView(TableSheet(viewer: viewer))),
            ("split", AnyView(SplitCellSheet(viewer: viewer))),
            ("calculation", AnyView(CalculationSheet(viewer: viewer))),
            ("privateInfo", AnyView(PrivateInfoSheet(viewer: viewer))),
            ("char", AnyView(CharShapeSheet(style: format.text, languages: format.languages) { _ in })),
            ("para", AnyView(ParaShapeSheet(style: format.paragraph) { _ in })),
            ("charExtended", AnyView(CharShapeSheet(style: format.text, languages: format.languages, tab: "확장") { _ in })),
            ("paraBorder", AnyView(ParaShapeSheet(style: format.paragraph, tab: "테두리/배경") { _ in })),
            ("styles", AnyView(StyleSheet(document: document, viewer: viewer))),
            ("styleEdit", AnyView(StyleEditSheet(editor: try #require(viewer.newStyle()), styles: document.styles, viewer: viewer))),
            ("equation", AnyView(EquationEditor(edit: EquationEdit(script: "x = {-b PLUSMINUS sqrt {b^2 - 4ac}} over {2a}",
                                                                   fontSize: 10, color: 0), viewer: viewer, document: document))),
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
            ("goTo", AnyView(GoToSheet(viewer: viewer, pageCount: 7))),
            ("hyperlink", AnyView(HyperlinkSheet(viewer: viewer, editing: HyperlinkEditing(
                existing: nil, text: "한컴 홈페이지", uri: "https://www.hancom.com")))),
            ("chartData", AnyView(ChartDataSheet(editing: ChartEditing(chart: 0, data: ChartData(
                labels: ["항목 1", "항목 2", "항목 3"],
                series: [ChartSeries(name: "계열 1", values: ["4.3", "2.5", "3.5"]), ChartSeries(name: "계열 2", values: ["2.4", "4.4", "1.8"])])),
                viewer: viewer))),
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
}
