import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import HwpStudio

struct SnapshotTests {
    @Test @MainActor func workspaceNavigationClampsPagesAndResetsForNewDocument() throws {
        let state = PDFWorkspaceState()
        let document = PDFDocument()
        for _ in 0..<3 { document.insert(PDFPage(), at: document.pageCount) }
        state.load(try #require(document.dataRepresentation()))
        #expect(state.pageCount == 3)
        state.go(to: 2)
        #expect(state.pageNumber == 3)
        state.go(to: 99)
        #expect(state.pageNumber == 3)
        state.go(to: -1)
        #expect(state.pageNumber == 1)
        state.zoom(by: 100)
        #expect(state.view.scaleFactor <= 4)
        let replacement = PDFDocument()
        replacement.insert(PDFPage(), at: 0)
        state.load(try #require(replacement.dataRepresentation()))
        #expect(state.pageNumber == 1)
        #expect(state.pageCount == 1)
        #expect(state.view.autoScales)
    }
    @Test func detectedLayoutProblemRequiresExplicitExportAcknowledgement() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.hwp")
        let target = folder.appendingPathComponent("export.pdf")
        let original = Data("unchanged source".utf8)
        let priorExport = Data("existing export must survive".utf8)
        try original.write(to: source)
        try priorExport.write(to: target)
        let snapshot = DocumentSnapshot(sourceURL: source, original: original, pdf: Data("diagnostic PDF".utf8), pageCount: 1, layoutWarnings: "겹침 감지")
        #expect(throws: (any Error).self) { try snapshot.export(to: target) }
        #expect(try Data(contentsOf: target) == priorExport)
        #expect(throws: (any Error).self) { try snapshot.export(to: source, acknowledgingLayoutWarnings: true) }
        #expect(try Data(contentsOf: source) == original)
        try snapshot.export(to: target, acknowledgingLayoutWarnings: true)
        #expect(try Data(contentsOf: target) == snapshot.pdf)
    }
    @Test func generatedHWPAndHWPXOpenAsValidImmutablePDF() throws {
        for ext in ["hwp", "hwpx"] {
            let url = try #require(Bundle.module.url(forResource: "generated", withExtension: ext, subdirectory: "Fixtures"))
            let original = try Data(contentsOf: url)
            let snapshot = try DocumentSnapshot.open(url)
            #expect(snapshot.original == original)
            #expect(PDFDocument(data: snapshot.pdf)?.pageCount == Int(snapshot.pageCount))
            #expect(snapshot.pageCount > 0)
        }
    }
    @Test func exportWritesExactSnapshotAndPreservesSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.hwp")
        let original = Data("immutable original".utf8)
        try original.write(to: source)
        let buffer = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: buffer))
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        let pdf = buffer as Data
        #expect(PDFDocument(data: pdf)?.pageCount == 1)
        let snapshot = DocumentSnapshot(sourceURL: source, original: original, pdf: pdf, pageCount: 1)
        let target = folder.appendingPathComponent("export.pdf")
        try snapshot.export(to: target)
        #expect(try Data(contentsOf: target) == pdf)
        let directoryTarget = folder.appendingPathComponent("protected-directory")
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        let sentinel = directoryTarget.appendingPathComponent("keep.txt")
        try original.write(to: sentinel)
        #expect(throws: (any Error).self) { try snapshot.export(to: directoryTarget) }
        #expect(try Data(contentsOf: sentinel) == original)
        #expect(try Data(contentsOf: source) == original)
        let absentFolder = folder.appendingPathComponent("missing/export.pdf")
        #expect(throws: (any Error).self) { try snapshot.export(to: absentFolder) }
        #expect(try Data(contentsOf: target) == pdf)
        #expect(throws: (any Error).self) { try snapshot.export(to: source) }
        let alias = folder.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        #expect(throws: (any Error).self) { try snapshot.export(to: alias) }
        let hardlink = folder.appendingPathComponent("hardlink.pdf")
        try FileManager.default.linkItem(at: source, to: hardlink)
        #expect(throws: (any Error).self) { try snapshot.export(to: hardlink) }
        #expect(try Data(contentsOf: source) == original)
    }
    @Test func invalidDocumentCannotCreateExportableSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".hwp")
        try Data("invalid".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try DocumentSnapshot.open(url) }
    }
}
