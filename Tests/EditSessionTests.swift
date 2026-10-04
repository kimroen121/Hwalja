import Testing
import Foundation
@testable import HwpStudio

struct EditSessionTests {
    private func fixture(_ ext: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: "generated", withExtension: ext, subdirectory: "Fixtures")))
    }

    @Test(arguments: ["hwp", "hwpx"])
    func editUndoRedoRoundTrip(ext: String) async throws {
        let (session, opened) = try await EditSession.open(fixture(ext))
        #expect(opened.reply.revision == 0 && !opened.reply.dirty)
        #expect(opened.pdf.starts(with: Data("%PDF-".utf8)))

        let body = EditTarget(section: 0, paragraph: 0, cell: nil)
        let original = try await session.paragraph(body).text
        let start = EditPosition(target: body, scalar: 0)
        let edited = try await session.apply(.replace(.caret(start), text: "편집 "), at: 0)
        #expect(edited.reply.dirty && edited.reply.canUndo)
        #expect(try await session.paragraph(body).text == "편집 " + original)

        let caret = try await session.caret(revision: 1, at: EditPosition(target: body, scalar: 1))
        let hit = try await session.hitTest(revision: 1, page: caret.page, x: caret.x + 0.5, y: caret.y + caret.height / 2)
        #expect(hit == EditPosition(target: body, scalar: 1))

        let undone = try await session.apply(.undo, at: 1)
        #expect(!undone.reply.dirty && undone.reply.canRedo)
        #expect(try await session.paragraph(body).text == original)
        _ = try await session.apply(.redo, at: 2)
        #expect(try await session.paragraph(body).text == "편집 " + original)
    }

    @Test func staleRevisionAndInvalidOpenAreTypedErrors() async throws {
        let (session, _) = try await EditSession.open(fixture("hwp"))
        await #expect(throws: EditError.staleRevision) { try await session.apply(.undo, at: 7) }
        await #expect(throws: EditError.invalidInput) { try await EditSession.open(Data("junk".utf8)) }
    }
}
