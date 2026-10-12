import Testing
import Foundation
import AppKit
import SwiftUI
@testable import HwaljaKit

/// Tables: made, changed, turned, and their cells.
@MainActor
struct TableTests {
    @Test func structureCommandsRunFromTheViewer() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        #expect(document.context.inBody && !document.context.inTable)
        viewer.insertTable(rows: 2, columns: 2)
        await document.settle()
        #expect(document.context.inTable)
        viewer.editTable(.insertRowBelow)
        await document.settle()
        #expect(document.context.inTable)
        var corner = try #require(document.selection?.focus)
        corner.target.cell?.cell = 0
        var far = corner
        far.target.cell?.cell = 3
        document.select { _ in EditSelection(anchor: corner, focus: far) }
        await document.settle()
        #expect(document.context.cellBlock && !document.context.hasRange)
        #expect(document.presentation.highlight.count == 4 && document.presentation.caret != nil)
        let red = BorderSide(line: 1, width: 5, color: "#ff0000")
        var cellBorder = CellBorder(fill: PageFill(color: "#ccddee", patternColor: "#000000", pattern: 0))
        cellBorder.sides[0] = red
        viewer.setCellBorder(cellBorder, all: false, one: false)
        await document.settle()
        let drawn = try await document.cellBorder(corner.target)
        #expect(drawn.sides[0] == red && drawn.fill == cellBorder.fill && document.context.cellBlock)
        // 표 배경 as the inspector's 표 sets it: the fill alone.
        let table = try #require(viewer.arrangedObject)
        let gray = PageFill(color: "#eeeeee", patternColor: "#000000", pattern: 0)
        viewer.arrange(ObjectProps(tableBorder: CellBorder(fill: gray)))
        await document.settle()
        #expect(try await document.objectProps(table).tableBorder?.fill == gray)
        viewer.editCells { .mergeCells($0) }
        await document.settle()
        #expect(document.context.inTable && !document.context.cellBlock)
        document.selection = .caret(EditPosition(target: EditTarget(section: 0, paragraph: 1, cell: nil), scalar: 0))
        viewer.insertBreak(column: false)
        await document.settle()
        #expect(document.reply.pageCount == 2 && document.pages.count == 2)
        var page = try await document.pageSetup(section: 0)
        page.landscape.toggle()
        viewer.setPage(page, section: 0)
        await document.settle()
        #expect(try await document.pageSetup(section: 0) == page)
        #expect(document.pages[0].size.width > document.pages[0].size.height)
        var border = try await document.pageBorder(section: 0)
        border.sides = Array(repeating: BorderSide(line: 1, width: 3, color: "#336699"), count: 4)
        border.fill = PageFill(color: "#ffeecc", patternColor: "#000000", pattern: 0)
        border.borderPages = .exceptFirst
        viewer.setPageBorder(border, section: 0, whole: true)
        await document.settle()
        #expect(try await document.pageBorder(section: 0) == border)
        // A style as Pages's +: from the caret's shapes, applied there, then named.
        let count = document.styles.count
        viewer.canvas.editor.format(ParaStyle(alignment: .center))
        await document.settle()
        #expect(viewer.addStyle(paragraphStyle: true) == UInt32(count))
        await document.settle()
        #expect(document.styles.count == count + 1 && document.format?.style == UInt32(count))
        #expect(try await document.styleFormat(UInt32(count)).paragraph.alignment == .center)
        viewer.editStyle(try #require(document.styles.last)) { $0.name = "큰 제목" }
        await document.settle()
        #expect(document.styles.last?.name == "큰 제목")
        // Commands that leave the text alone keep the caret where the user put it.
        let caret = EditSelection.caret(EditPosition(target: EditTarget(section: 0, paragraph: 0, cell: nil), scalar: 1))
        document.selection = caret
        viewer.moveStyle(UInt32(count), up: true)
        await document.settle()
        #expect(document.styles[count - 1].name == "큰 제목" && document.selection == caret)
        viewer.deleteStyle(UInt32(count - 1), replacement: 0)
        await document.settle()
        #expect(document.styles.count == count && document.format?.style == 0)
        var note = try await document.noteShape(section: 0, footnote: false)
        note.numberFormat = "upperRoman"
        note.numbering = "restartSection"
        viewer.setNoteShape(note, footnote: false, section: 0, whole: false)
        await document.settle()
        #expect(try await document.noteShape(section: 0, footnote: false) == note)
        var setup = try await document.sectionSetup(section: 0)
        setup.pageNum = 3
        setup.hideEmptyLine.toggle()
        viewer.setSection(setup, section: 0, whole: false)
        await document.settle()
        #expect(try await document.sectionSetup(section: 0) == setup)
        let revision = document.reply.revision
        viewer.headerFooter(footer: false, pageNumber: .center)
        viewer.headerFooter(footer: true, pageNumber: nil)
        await document.settle()
        #expect(document.reply.revision == revision + 2)
    }

    /// 표 뒤집기 turns the table with the caret's cell: 시계 방향 90도 takes A1 of a 2×3 table to B1.
    @Test func tablesTurn() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        viewer.insertTable(rows: 2, columns: 3)
        await document.settle()
        viewer.flipTable(.right, margins: false)
        await document.settle()
        let caret = try #require(document.selection?.focus)
        #expect(try await document.status(at: caret).cell == "B1")
    }

    /// 한글's table keys: Ctrl+Enter (⌘↩) in a cell adds a row, P on a cell block opens 표/셀 속성.
    @Test func tableKeysAddRowsAndOpenProperties() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        viewer.insertTable(rows: 2, columns: 2)
        await document.settle()
        var cell = try #require(document.selection?.focus)
        cell.target.cell?.cell = 0
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) async {
            viewer.canvas.editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                                windowNumber: 0, context: nil, characters: characters,
                                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
            await document.settle()
        }
        await key("\r", .command, code: 36)
        var far = cell
        far.target.cell?.cell = 5
        document.select { _ in EditSelection(anchor: cell, focus: far) }
        await document.settle()
        #expect(document.context.cellBlock && document.presentation.highlight.count == 6)
        // P while typing 한글.
        await key("ㅔ", code: 35)
        #expect(viewer.showsInspector && viewer.inspectorPane == .format
                 && viewer.inspectorTabs[Inspector.tabs(document.context).joined(separator: " ")] == "표")
    }
}
