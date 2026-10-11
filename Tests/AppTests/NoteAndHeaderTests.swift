import Testing
import Foundation
import AppKit
import SwiftUI
@testable import HwaljaKit

/// 각주·미주 and 머리말·꼬리말: typed in, gone through, closed and deleted.
@MainActor
struct NoteAndHeaderTests {
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

    /// The 주석 탭: 이전/다음 주석으로, 닫기 back after the number, and 주석 지우기.
    @Test func notesAreGoneThroughClosedAndDeleted() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.selection = .caret(EditPosition(target: body, scalar: 1))
        viewer.insertNote(endnote: false)
        await document.settle()
        let first = try #require(document.selection?.focus.target)
        document.selection = .caret(EditPosition(target: body, scalar: 3))
        viewer.insertNote(endnote: true)
        await document.settle()
        let second = try #require(document.selection?.focus.target)
        #expect(document.context.inNote)

        viewer.goTo(.previousNote)
        await document.settle()
        #expect(document.selection?.focus.target == first)
        viewer.goTo(.nextNote)
        await document.settle()
        #expect(document.selection?.focus.target == second)

        document.closeNote()
        await document.settle()
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 4)))
        let text = try await document.paragraph(body).text

        document.selection = .caret(EditPosition(target: first, scalar: 0))
        document.deleteNote(nil)
        await document.settle()
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 1)))
        #expect(try await document.paragraph(body).text.unicodeScalars.count == text.unicodeScalars.count - 1)
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
}
