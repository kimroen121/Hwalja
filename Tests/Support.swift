import Testing
import Foundation
import AppKit
@testable import HwaljaKit

/// The generated public fixture, `generated.hwp` or `generated.hwpx`.
func fixture(_ ext: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "generated", withExtension: ext, subdirectory: "Fixtures")))
}

/// The body's first paragraph.
let body = EditTarget(section: 0, paragraph: 0, cell: nil)

/// A white 1×1 PNG, and a red 2×2 one.
let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
let redPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==")!

/// White page bitmap whose y axis points down, `scale` pixels per point.
func bitmap(_ size: CGSize, scale: CGFloat) -> CGContext? {
    let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: Int(size.width * scale), space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
    context?.setFillColor(gray: 1, alpha: 1)
    context?.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
    context?.translateBy(x: 0, y: size.height * scale)
    context?.scaleBy(x: scale, y: -scale)
    return context
}

func colorBitmap(_ size: CGSize) -> CGContext? {
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setFillColor(NSColor.white.cgColor)
    context?.fill(CGRect(origin: .zero, size: size))
    context?.translateBy(x: 0, y: size.height)
    context?.scaleBy(x: 1, y: -1)
    return context
}
/// Gray pixels of a page drawn at 2× and blurred by downsampling to 1×, so sub-pixel
/// antialiasing differences between Core Text and PDF glyphs do not count.
func raster(_ page: RenderedPage) -> [UInt8]? {
    guard let context = bitmap(page.size, scale: 2) else { return nil }
    page.draw(in: context, rect: CGRect(origin: .zero, size: page.size))
    guard let image = context.makeImage(), let small = bitmap(page.size, scale: 1) else { return nil }
    small.interpolationQuality = .high
    small.draw(image, in: CGRect(origin: .zero, size: page.size))
    guard let bytes = small.data else { return nil }
    return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: small.bytesPerRow * small.height))
}

/// The first object of `kind` the hit test finds on page 1, scanning it as clicks would.
@MainActor func placedObject(_ document: HwpDocument, _ kind: ObjectKind? = nil) async throws -> PlacedObject? {
    for y in stride(from: 0.0, to: 1100, by: 5) {
        for x in stride(from: 0.0, to: 800, by: 10) {
            if let found = try await document.objectAt(page: 0, x: x, y: y), kind == nil || found.object.kind == kind { return found }
        }
    }
    return nil
}

/// A picture put at the start of the body, and chosen as a click chooses it.
@MainActor func insertedPicture(_ document: HwpDocument, _ undo: UndoManager? = nil) async throws -> PlacedObject {
    let start = EditPosition(target: body, scalar: 0)
    document.selection = .caret(start)
    document.edit(undo) { _ in .insertPicture(start, data: png, width: 7_500, height: 7_500, naturalWidth: 1, naturalHeight: 1,
                                               extension: "png", description: "p.png") }
    await document.settle()
    let placed = try #require(try await placedObject(document, .picture))
    choose(placed, in: document)
    await document.settle()
    return placed
}

/// A mouse event at `point` in `view`, in its window.
@MainActor func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                       windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}

/// Chooses an object as a click does: in the document's queue, so the context and the
/// inspector's tabs follow.
@MainActor func choose(_ placed: PlacedObject?, in document: HwpDocument) {
    document.select { document in
        document.object = placed
        return nil
    }
}
