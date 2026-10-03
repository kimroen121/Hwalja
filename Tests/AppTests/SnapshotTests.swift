import XCTest
import PDFKit
import CoreGraphics
@testable import HwpStudio

final class SnapshotTests: XCTestCase {
    func testGeneratedHWPAndHWPXOpenAsValidImmutablePDF() throws {
        for ext in ["hwp", "hwpx"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "generated", withExtension: ext))
            let original = try Data(contentsOf: url)
            let snapshot = try DocumentSnapshot.open(url)
            XCTAssertEqual(snapshot.original, original)
            XCTAssertEqual(PDFDocument(data: snapshot.pdf)?.pageCount, Int(snapshot.pageCount))
            XCTAssertGreaterThan(snapshot.pageCount, 0)
        }
    }
    func testExportWritesExactSnapshotAndPreservesSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.hwp")
        let original = Data("immutable original".utf8)
        try original.write(to: source)
        let buffer = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: buffer))
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        let pdf = buffer as Data
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 1)
        let snapshot = DocumentSnapshot(sourceURL: source, original: original, pdf: pdf, pageCount: 1)
        let target = folder.appendingPathComponent("export.pdf")
        try snapshot.export(to: target)
        XCTAssertEqual(try Data(contentsOf: target), pdf)
        let directoryTarget = folder.appendingPathComponent("protected-directory")
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        let sentinel = directoryTarget.appendingPathComponent("keep.txt")
        try original.write(to: sentinel)
        XCTAssertThrowsError(try snapshot.export(to: directoryTarget))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let absentFolder = folder.appendingPathComponent("missing/export.pdf")
        XCTAssertThrowsError(try snapshot.export(to: absentFolder))
        XCTAssertEqual(try Data(contentsOf: target), pdf)
        XCTAssertThrowsError(try snapshot.export(to: source))
        let alias = folder.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try snapshot.export(to: alias))
        let hardlink = folder.appendingPathComponent("hardlink.pdf")
        try FileManager.default.linkItem(at: source, to: hardlink)
        XCTAssertThrowsError(try snapshot.export(to: hardlink))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testInvalidDocumentCannotCreateExportableSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".hwp")
        try Data("invalid".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DocumentSnapshot.open(url))
    }
}
