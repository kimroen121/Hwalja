import CoreText
import Foundation
import ImageIO
import PDFKit

/// One page as drawn: the engine's display list, or a PDF page for the rare page it cannot
/// express. Sizes are in points; drawing maps the page onto any rect.
enum RenderedPage: @unchecked Sendable {
    case display(PageDisplay)
    case pdf(PDFPage)

    /// Changes whenever the page is re-rendered.
    var id: ObjectIdentifier {
        switch self {
        case .display(let display): ObjectIdentifier(display)
        case .pdf(let page): ObjectIdentifier(page)
        }
    }

    var size: CGSize {
        switch self {
        case .display(let display):
            CGSize(width: display.width * PageGeometry.pointsPerPixel, height: display.height * PageGeometry.pointsPerPixel)
        case .pdf(let page): page.bounds(for: .mediaBox).size
        }
    }

    /// Draws the page into `rect` of a context whose y axis points down.
    func draw(in context: CGContext, rect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        switch self {
        case .display(let display):
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / display.width, y: rect.height / display.height)
            display.draw(in: context)
        case .pdf(let page):
            let box = page.bounds(for: .mediaBox)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: rect.width / box.width, y: -rect.height / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
        }
    }
}

/// How the engine draws one page, in its pixel space (96 dpi, y down). Text uses the exact
/// font files the PDF would embed, so it looks the same.
final class PageDisplay: @unchecked Sendable {
    let width: Double
    let height: Double
    let fonts: [Face]
    let ops: [Op]

    struct Face: Hashable {
        let path: String
        let index: Int
    }

    /// Reads the engine's encoding (`Display::encode`).
    init(_ reader: inout ByteReader) throws {
        width = Double(try reader.f32())
        height = Double(try reader.f32())
        fonts = try (0..<reader.count()).map { _ in Face(path: try reader.string(), index: Int(try reader.u32())) }
        ops = try (0..<reader.count()).map { _ in try Op(&reader) }
    }

    enum Op {
        case save, restore
        case transform(CGAffineTransform)
        case clip([CGRect])
        case rect(CGRect, fill: CGColor?, stroke: CGColor?, width: Double)
        case ellipse(CGRect, fill: CGColor?, stroke: CGColor?, width: Double)
        case line(CGPoint, CGPoint, color: CGColor, width: Double, dash: [Double])
        case path(CGPath, fill: CGColor?, stroke: CGColor?, width: Double, round: Bool)
        case image(CGRect, CGImage?)
        case text(Text)

        struct Text {
            let origin: CGPoint
            let size: Double
            let color: CGColor
            let runs: [(font: Int, text: String)]
            let length: Double?
            let center: Bool
        }

        init(_ r: inout ByteReader) throws {
            func number() throws -> Double { Double(try r.f32()) }
            func numbers(_ n: Int) throws -> [Double] { try (0..<n).map { _ in try number() } }
            func rect() throws -> CGRect {
                let v = try numbers(4)
                return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
            }
            func color() throws -> CGColor? {
                let rgb = try r.u32()
                return rgb == .max ? nil : Self.color(rgb)
            }
            switch try r.u8() {
            case 0: self = .save
            case 1: self = .restore
            case 2:
                let m = try numbers(6)
                self = .transform(CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]))
            case 3: self = .clip(try (0..<r.count()).map { _ in try rect() })
            case 4: self = .rect(try rect(), fill: try color(), stroke: try color(), width: try number())
            case 5: self = .ellipse(try rect(), fill: try color(), stroke: try color(), width: try number())
            case 6:
                let p = try numbers(4)
                self = .line(CGPoint(x: p[0], y: p[1]), CGPoint(x: p[2], y: p[3]), color: Self.color(try r.u32()),
                             width: try number(), dash: try numbers(r.count()))
            case 7:
                self = .path(try Self.path(numbers(r.count())), fill: try color(), stroke: try color(),
                             width: try number(), round: try r.u8() != 0)
            case 8:
                let rect = try rect()
                let data = Data(base64Encoded: try r.string()) ?? Data()
                self = .image(rect, CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            case 9:
                let v = try numbers(4)
                let color = Self.color(try r.u32())
                let center = try r.u8() != 0
                let runs = try (0..<r.count()).map { _ in (font: Int(try r.u16()), text: try r.string()) }
                self = .text(Text(origin: CGPoint(x: v[0], y: v[1]), size: v[2], color: color, runs: runs,
                                  length: v[3] < 0 ? nil : v[3], center: center))
            default: throw EditError.renderFailed
            }
        }

        private static func color(_ rgb: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                    blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        }
        private static func path(_ d: [Double]) -> CGPath {
            let path = CGMutablePath()
            var i = 0
            func p(_ k: Int) -> CGPoint { CGPoint(x: d[i + k], y: d[i + k + 1]) }
            let sizes: [Double: Int] = [0: 3, 1: 3, 2: 7, 3: 5, 4: 1]
            while i < d.count, let size = sizes[d[i]], i + size <= d.count {
                switch d[i] {
                case 0: path.move(to: p(1))
                case 1: path.addLine(to: p(1))
                case 2: path.addCurve(to: p(5), control1: p(1), control2: p(3))
                case 3: path.addQuadCurve(to: p(3), control: p(1))
                default: path.closeSubpath()
                }
                i += size
            }
            return path
        }
    }

    func draw(in context: CGContext) {
        let fonts = fonts.map(FontFiles.shared.descriptor)
        for op in ops {
            switch op {
            case .save: context.saveGState()
            case .restore: context.restoreGState()
            case .transform(let m): context.concatenate(m)
            case .clip(let rects): context.clip(to: rects)
            case let .rect(rect, fill, stroke, width):
                if let fill { context.setFillColor(fill); context.fill(rect) }
                if let stroke { context.setStrokeColor(stroke); context.setLineWidth(width); context.stroke(rect) }
            case let .ellipse(rect, fill, stroke, width):
                if let fill { context.setFillColor(fill); context.fillEllipse(in: rect) }
                if let stroke { context.setStrokeColor(stroke); context.setLineWidth(width); context.strokeEllipse(in: rect) }
            case let .line(from, to, color, width, dash):
                context.saveGState()
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
                context.strokeLineSegments(between: [from, to])
                context.restoreGState()
            case let .path(path, fill, stroke, width, round):
                if let fill { context.addPath(path); context.setFillColor(fill); context.fillPath() }
                if let stroke {
                    context.saveGState()
                    context.addPath(path)
                    context.setStrokeColor(stroke)
                    context.setLineWidth(width)
                    context.setLineCap(round ? .round : .butt)
                    context.strokePath()
                    context.restoreGState()
                }
            case let .image(rect, image):
                guard let image else { continue }
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
                context.restoreGState()
            case .text(let text): Self.draw(text, fonts: fonts, in: context)
            }
        }
    }

    /// Combining marks, joiners, Hangul jamo and Arabic script take their glyphs from context.
    private static func needsShaping(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x08FF, 0x1100...0x11FF, 0xA960...0xA97F, 0xD7B0...0xD7FF: return true
        default:
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format: return true
            default: return false
            }
        }
    }

    /// One SVG `<text>`: glyphs at their natural advances from the origin, stretched to
    /// `length` when given, the way usvg lays out a single text chunk.
    private static func draw(_ text: Op.Text, fonts: [CTFontDescriptor?], in context: CGContext) {
        var glyphs: [CGGlyph] = [], positions: [CGPoint] = [], runs: [(font: CTFont, range: Range<Int>)] = []
        var lines: [(CTLine, x: CGFloat)] = []
        var x: CGFloat = 0
        for run in text.runs {
            guard let descriptor = fonts[run.font] else { continue }
            let font = FontFiles.shared.font(descriptor, size: text.size)
            let units = Array(run.text.utf16)
            var found = [CGGlyph](repeating: 0, count: units.count)
            if run.text.unicodeScalars.count == units.count, !run.text.unicodeScalars.contains(where: Self.needsShaping),
               CTFontGetGlyphsForCharacters(font, units, &found, units.count) {
                var advances = [CGSize](repeating: .zero, count: found.count)
                CTFontGetAdvancesForGlyphs(font, .horizontal, found, &advances, found.count)
                let start = glyphs.count
                for (glyph, advance) in zip(found, advances) {
                    glyphs.append(glyph)
                    positions.append(CGPoint(x: x, y: 0))
                    x += advance.width
                }
                runs.append((font, start..<glyphs.count))
            } else {
                // Clusters that need shaping (old Hangul jamo, surrogate pairs) go through Core Text.
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: run.text, attributes: [.font: font]))
                lines.append((line, x))
                x += CTLineGetTypographicBounds(line, nil, nil, nil)
            }
        }
        guard x > 0 else { return }
        let scale = text.length.map { $0 / x } ?? 1
        context.saveGState()
        context.translateBy(x: text.origin.x - (text.center ? x * scale / 2 : 0), y: text.origin.y)
        context.scaleBy(x: scale, y: 1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setFillColor(text.color)
        for run in runs {
            glyphs[run.range].withUnsafeBufferPointer { g in
                positions[run.range].withUnsafeBufferPointer { p in
                    CTFontDrawGlyphs(run.font, g.baseAddress!, p.baseAddress!, g.count, context)
                }
            }
        }
        for (line, x) in lines {
            context.textPosition = CGPoint(x: x, y: 0)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

/// Font files the engine names, loaded once, and fonts by size.
final class FontFiles: @unchecked Sendable {
    static let shared = FontFiles()
    private let lock = NSLock()
    private var descriptors: [PageDisplay.Face: CTFontDescriptor?] = [:]
    private var fonts: [FontKey: CTFont] = [:]
    private struct FontKey: Hashable {
        let descriptor: ObjectIdentifier
        let size: Double
    }

    func descriptor(_ face: PageDisplay.Face) -> CTFontDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        if let known = descriptors[face] { return known }
        let all = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: face.path) as CFURL) as? [CTFontDescriptor]
        let descriptor = all.flatMap { $0.indices.contains(face.index) ? $0[face.index] : nil }
        descriptors[face] = descriptor
        return descriptor
    }

    func font(_ descriptor: CTFontDescriptor, size: Double) -> CTFont {
        let key = FontKey(descriptor: ObjectIdentifier(descriptor), size: size)
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[key] { return font }
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        fonts[key] = font
        return font
    }
}

/// Reads little-endian values from engine output, throwing past the end.
struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Data { Data(bytes[offset...]) }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard bytes.count - offset >= size else { throw EditError.renderFailed }
        var value = T.zero
        for i in (0..<size).reversed() { value = value << 8 | T(bytes[offset + i]) }
        offset += size
        return value
    }
    mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    mutating func u16() throws -> UInt16 { try integer(UInt16.self) }
    mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    /// A count of following items; bounded by the bytes left, so bad input cannot allocate wildly.
    mutating func count() throws -> Int {
        let count = Int(try u32())
        guard count <= bytes.count - offset else { throw EditError.renderFailed }
        return count
    }
    mutating func string() throws -> String {
        let length = try count()
        defer { offset += length }
        return String(decoding: bytes[offset..<offset + length], as: UTF8.self)
    }
}
