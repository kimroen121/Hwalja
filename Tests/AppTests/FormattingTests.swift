import Testing
import Foundation
import AppKit
import SwiftUI
@testable import HwaljaKit

/// 글자 모양, 문단 모양, 스타일 and lists, as the inspector and menus apply them.
@MainActor
struct FormattingTests {
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

    @Test func boldFormattingChangesTheRenderedFontFace() async throws {
        let document = HwpDocument()
        let start = EditPosition(target: body, scalar: 0)
        document.selection = .caret(start)
        document.type("안녕하세요", nil)
        await document.settle()

        func textFaces(_ page: RenderedPage) -> Set<PageDisplay.Face> {
            guard case .display(let display) = page else { return [] }
            return Set(display.ops.compactMap { op in
                guard case .text(let text) = op,
                      text.runs.contains(where: { $0.text.contains("안") }),
                      let run = text.runs.first(where: { $0.text.contains("안") })
                else { return nil }
                return display.fonts[run.font]
            })
        }

        let regular = textFaces(try #require(document.pages.first))
        document.selection = EditSelection(
            anchor: start,
            focus: EditPosition(target: body, scalar: 5)
        )
        document.formatText(CharStyle(bold: true), nil)
        await document.settle()
        let bold = textFaces(try #require(document.pages.first))

        #expect(!regular.isEmpty)
        #expect(!bold.isEmpty)
        #expect(bold != regular)
    }

    @Test func styleChosenAtTheCaretAppliesToTheNextText() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let undo = UndoManager()
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.formatText(CharStyle(bold: true), undo)
        await document.settle()
        #expect(document.format?.text.bold == true)
        document.type("굵", undo)
        await document.settle()
        let typed = try await document.session(formatAt: EditPosition(target: body, scalar: 1))
        #expect(typed.text.bold == true)
        #expect(document.selection == .caret(EditPosition(target: body, scalar: 1)))
        // Composition keeps the pending style through every update.
        document.formatText(CharStyle(italic: true), undo)
        for (text, commit) in [("ㄱ", false), ("기", false), ("기", true)] { document.compose(text, commit: commit, undo) }
        await document.settle()
        let composed = try await document.session(formatAt: EditPosition(target: body, scalar: 2))
        #expect(composed.text.italic == true)
        undo.undo()
        await document.settle()
        undo.undo()
        await document.settle()
        #expect(try await document.paragraph(body).text.hasPrefix("굵") == false)
    }

    @Test func stylesListAndApply() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        document.select { $0.selection }
        await document.settle()
        let style = try #require(document.styles.last)
        #expect(document.format?.style != style.id)
        document.applyStyle(style.id, UndoManager())
        await document.settle()
        #expect(document.format?.style == style.id)
    }

    /// Pages's * and 업데이트: text set apart from its style shows it, and 업데이트 takes it into the style.
    @Test func updateTakesTheCaretsShapesIntoItsStyle() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        let style = try #require(document.format?.style)
        #expect(!TextTab.changed(document.format, from: try await document.styleFormat(style)))
        viewer.canvas.editor.format(ParaStyle(alignment: .center))
        await document.settle()
        #expect(TextTab.changed(document.format, from: try await document.styleFormat(style)))
        viewer.restyleFromCaret(style)
        await document.settle()
        #expect(!TextTab.changed(document.format, from: try await document.styleFormat(style)))
        #expect(try await document.styleFormat(style).paragraph.alignment == .center)
    }

    /// 문단 번호 매기기 and 한 수준 증가 from the editor, as the format row runs them.
    @Test func listsNumberAndStepLevels() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        viewer.canvas.editor.format(ParaStyle(head: "Number", numbering: 1))
        await document.settle()
        #expect(document.format?.paragraph.head == "Number" && document.format?.paragraph.level == 0)
        viewer.canvas.editor.stepLevel(by: 1)
        await document.settle()
        #expect(document.format?.paragraph.level == 1)
        viewer.canvas.editor.format(ParaStyle(head: "None"))
        await document.settle()
        #expect(document.format?.paragraph.head == "None")
    }
}
