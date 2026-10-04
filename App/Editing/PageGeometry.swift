import CoreGraphics

/// Converts between a page's frame in the flipped page view (points, top-left origin) and
/// engine page space (96 dpi pixels, top-left origin).
enum PageGeometry {
    static let pointsPerPixel = 72.0 / 96.0

    static func enginePoint(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / pointsPerPixel, y: (point.y - frame.minY) / pointsPerPixel)
    }
    static func viewRect(_ rect: PageRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.x * pointsPerPixel, y: frame.minY + rect.y * pointsPerPixel,
               width: rect.width * pointsPerPixel, height: rect.height * pointsPerPixel)
    }
}

extension String {
    /// The text between two Unicode scalar offsets.
    func scalars(_ range: Range<UInt32>) -> String {
        let scalars = Array(unicodeScalars)
        let lower = min(Int(range.lowerBound), scalars.count), upper = min(Int(range.upperBound), scalars.count)
        return String(String.UnicodeScalarView(scalars[lower..<upper]))
    }
}
