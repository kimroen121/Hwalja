import Testing
import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import HwaljaKit

/// Opening, saving and undo: what reaches the file, and when.
@MainActor
struct SavingTests {
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
}
