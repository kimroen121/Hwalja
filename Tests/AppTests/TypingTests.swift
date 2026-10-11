import Testing
import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import HwaljaKit

/// Typing, 한글 composition, moving, selecting, copying and pasting.
@MainActor
struct TypingTests {
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

    @Test func selectedTextSpansParagraphs() async throws {
        let document = HwpDocument()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { $0.map { .replace($0, text: "첫째\n둘째") } }
        await document.settle()
        let second = EditTarget(section: 0, paragraph: 1, cell: nil)
        let selection = EditSelection(anchor: EditPosition(target: second, scalar: 1), focus: EditPosition(target: body, scalar: 1))
        #expect(try await document.text(of: selection) == "째\n둘")
    }

    /// A fast drag out of a table cell reaches the nearest edge of that cell instead of
    /// leaving the selection at its starting character or crossing document containers.
    @Test func draggingAcrossAContainerClampsToItsEdge() async throws {
        let document = HwpDocument()
        let canvas = DocumentCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.bind(document)
        canvas.setZoom(1)
        canvas.tile()
        let editor = canvas.editor
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.edit(nil) { $0.map { .insertTable($0.focus, rows: 1, columns: 1) } }
        await document.settle()
        document.type("셀 내용", nil)
        await document.settle()
        var start = try #require(document.selection?.focus)
        start.scalar = 0
        document.select { _ in .caret(start) }
        await document.settle()

        let page = try #require(editor.frame(ofPage: 0))
        let caret = PageGeometry.viewRect(try await document.caret(at: start), in: page)
        let from = NSPoint(x: caret.midX + 2, y: caret.midY)
        let to = NSPoint(x: caret.midX + 2, y: page.maxY - 80)
        let outside = PageGeometry.enginePoint(to, in: page)
        #expect(try await document.hitTest(page: 0, x: outside.x, y: outside.y).target.cell == nil)
        let event = { (type: NSEvent.EventType, point: NSPoint) in
            NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        editor.mouseDown(with: event(.leftMouseDown, from))
        editor.mouseDragged(with: event(.leftMouseDragged, to))
        editor.mouseUp(with: event(.leftMouseUp, to))
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(20))
            await document.settle()
        }
        let selection = try #require(document.selection)
        #expect(selection.anchor.target.cell != nil && selection.focus.target.cell != nil)
        #expect(selection.focus.scalar > selection.anchor.scalar)
    }

    @Test func selectionReachStaysInOneHeaderFooterDefinition() {
        let header = EditTarget(section: 0, paragraph: 0, cell: nil, note: nil,
                                headerFooter: HeaderFooterTarget(footer: false, applyTo: 0, page: 0))
        let sameHeaderOnAnotherPage = EditTarget(section: 0, paragraph: 0, cell: nil, note: nil,
                                                 headerFooter: HeaderFooterTarget(footer: false, applyTo: 0, page: 2))
        let otherHeader = EditTarget(section: 0, paragraph: 0, cell: nil, note: nil,
                                     headerFooter: HeaderFooterTarget(footer: false, applyTo: 1, page: 0))
        let selection = EditSelection.caret(EditPosition(target: header, scalar: 0))
        #expect(selection.reaches(EditPosition(target: sameHeaderOnAnotherPage, scalar: 0)))
        #expect(!selection.reaches(EditPosition(target: otherHeader, scalar: 0)))
        #expect(!selection.reaches(EditPosition(target: body, scalar: 0)))
    }

    @Test func scalarRangesKeepClustersWhole() {
        #expect("가👨‍👩‍👧‍👦e\u{301}".scalars(1..<8) == "👨‍👩‍👧‍👦")
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

    /// 웹 주소 자동 연결: a web address ended by a space or Enter becomes a link, which one
    /// undo takes off.
    @Test func typedWebAddressesBecomeLinks() async throws {
        #expect(Hyperlink.typedAddress("보기 https://example.com/a. ")! == (3, 24, "https://example.com/a"))
        #expect(Hyperlink.typedAddress("www.hancom.com\n")!.uri == "http://www.hancom.com")
        #expect(Hyperlink.typedAddress("example.com ") == nil && Hyperlink.typedAddress("https:// ") == nil)
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.type("보기 https://example.com ", undo)
        await document.settle()
        let link = try await document.hyperlink(at: EditPosition(target: body, scalar: 5))
        #expect(link?.uri == "https://example.com" && link?.text == "https://example.com")
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 23)))
        undo.undo()
        await document.settle()
        #expect(try await document.hyperlink(at: EditPosition(target: body, scalar: 5)) == nil)
        #expect(try await document.paragraph(body).text.hasPrefix("보기 https://example.com "))
        document.type("www.hancom.com\n", undo)
        await document.settle()
        #expect(try await document.hyperlink(at: EditPosition(target: body, scalar: 25))?.uri == "http://www.hancom.com")
    }

    /// 자동 번호 매기기 and 자동 글머리 기호 넣기, which one undo takes back; <Backspace>
    /// at the paragraph's start takes the head off.
    @Test func typedSignsBecomeListHeads() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        let start = EditPosition(target: body, scalar: 0)
        document.selection = .caret(start)
        document.type("1. ", undo)
        await document.settle()
        #expect(document.format?.paragraph.head == "Number" && document.selection == .caret(start))
        undo.undo()
        await document.settle()
        #expect(document.format?.paragraph.head == "None")
        #expect(try await document.paragraph(body).text.hasPrefix("1. "))
        document.selection = .caret(start)
        document.delete(.right, undo)
        document.delete(.right, undo)
        document.delete(.right, undo)
        document.type(">> ", undo)
        await document.settle()
        #expect(document.format?.paragraph.head == "Bullet" && document.format?.paragraph.bullet == "√")
        let text = try await document.paragraph(body).text
        document.delete(.left, undo)
        await document.settle()
        #expect(document.format?.paragraph.head == "None")
        #expect(try await document.paragraph(body).text == text)
    }

    /// The system's text services see the caret's paragraph, and replace a range of it.
    @Test func textServicesReadAndReplace() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let editor = viewer.canvas.editor
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.type("abc ", nil)
        await document.settle()
        let text = try await document.paragraph(body).text
        let first = NSRange(location: 0, length: 3)
        for _ in 0..<100 where editor.attributedSubstring(forProposedRange: first, actualRange: nil) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(editor.attributedSubstring(forProposedRange: first, actualRange: nil)?.string == "abc")
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
        #expect(editor.accessibilityRole() == .textArea && editor.accessibilityValue() as? String == text)
        editor.insertText("xyz", replacementRange: first)
        await document.settle()
        #expect(try await document.paragraph(body).text == "xyz" + text.dropFirst(3))
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
}
