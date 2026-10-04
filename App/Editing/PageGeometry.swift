import CoreGraphics

/// Converts between PDF page space (points, bottom-left origin within `box`) and engine
/// page space (96 dpi pixels, top-left origin). Rotated pages are not editable.
enum PageGeometry {
    static let pointsPerPixel = 72.0 / 96.0

    static func enginePoint(_ point: CGPoint, in box: CGRect) -> CGPoint {
        CGPoint(x: (point.x - box.minX) / pointsPerPixel, y: (box.maxY - point.y) / pointsPerPixel)
    }
    static func pageRect(_ rect: PageRect, in box: CGRect) -> CGRect {
        CGRect(x: box.minX + rect.x * pointsPerPixel,
               y: box.maxY - (rect.y + rect.height) * pointsPerPixel,
               width: rect.width * pointsPerPixel,
               height: rect.height * pointsPerPixel)
    }
}

extension String {
    /// Unicode scalar offsets of every grapheme boundary, including 0 and the end.
    var graphemeBoundaries: [UInt32] {
        var offsets: [UInt32] = [0]
        var offset: UInt32 = 0
        for character in self {
            offset += UInt32(character.unicodeScalars.count)
            offsets.append(offset)
        }
        return offsets
    }
    /// The text between two Unicode scalar offsets.
    func scalars(_ range: Range<UInt32>) -> String {
        let scalars = Array(unicodeScalars)
        let lower = min(Int(range.lowerBound), scalars.count), upper = min(Int(range.upperBound), scalars.count)
        return String(String.UnicodeScalarView(scalars[lower..<upper]))
    }
}
