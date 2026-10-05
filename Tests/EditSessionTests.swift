import Testing
import Foundation
@testable import HwpStudio

func fixture(_ ext: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "generated", withExtension: ext, subdirectory: "Fixtures")))
}

struct EditSessionTests {
    @Test func protocolVersionMismatchIsRejectedBeforeRendering() {
        let json = Data(#"{"version":999,"revision":0,"pageCount":1,"changedPages":[0],"canUndo":false,"canRedo":false,"dirty":false}"#.utf8)
        #expect(throws: EditError.incompatibleEngine) { try EditSession.Output((json, Data([2]))) }
    }

    @Test func rejectsMalformedRenderingPayloads() {
        let json = Data(#"{"version":2,"revision":0,"pageCount":1,"changedPages":[0],"canUndo":false,"canRedo":false,"dirty":false}"#.utf8)
        // Old raw PDF payload, unknown discriminator and a truncated display.
        for data in [Data("%PDF-1.7".utf8), Data([2]), Data([1])] {
            #expect(throws: EditError.renderFailed) { try EditSession.Output((json, data)) }
        }
    }

    @Test(arguments: ["hwp", "hwpx"])
    func editGeometryAndUndoRoundTrip(ext: String) async throws {
        let (session, opened) = try EditSession.open(fixture(ext))
        #expect(opened.reply.revision == 0 && !opened.reply.dirty)
        #expect(opened.pages.count == 1 && opened.reply.changedPages == [0])
        guard case .display(let display) = opened.pages[0] else { Issue.record("page 0 is not drawn natively"); return }
        #expect(display.ops.contains { if case .text = $0 { true } else { false } })

        let body = EditTarget(section: 0, paragraph: 0, cell: nil)
        let original = try await session.paragraph(body).text
        let edited = try await session.apply(.replace(.caret(EditPosition(target: body, scalar: 0)), text: "편집 "), at: 0)
        #expect(edited.reply.dirty && edited.reply.canUndo && edited.reply.changedPages == [0])
        #expect(try await session.paragraph(body).text == "편집 " + original)

        let caret = try await session.caret(revision: 1, at: EditPosition(target: body, scalar: 1))
        let hit = try await session.hitTest(revision: 1, page: caret.page, x: caret.x + 0.5, y: caret.y + caret.height / 2)
        #expect(hit == EditPosition(target: body, scalar: 1))
        let selection = EditSelection(anchor: EditPosition(target: body, scalar: 0), focus: EditPosition(target: body, scalar: 2))
        #expect(try await session.selectionRects(revision: 1, for: selection).count == 1)

        let undone = try await session.apply(.undo, at: 1)
        #expect(!undone.reply.dirty && undone.reply.canRedo)
        #expect(try await session.paragraph(body).text == original)
    }

    @Test func failuresAreTypedErrors() async throws {
        let (session, _) = try EditSession.open(fixture("hwp"))
        await #expect(throws: EditError.staleRevision) { try await session.apply(.undo, at: 7) }
        #expect(throws: EditError.invalidInput) { try EditSession.open(Data()) }
        #expect(throws: EditError.unsupportedFormat) { try EditSession.open(Data("PK\u{3}\u{4}broken".utf8)) }
    }
}
