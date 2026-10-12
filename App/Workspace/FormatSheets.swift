import AppKit
import SwiftUI

// 글자 모양 and 문단 모양.

extension Viewer {
    /// 글자 모양 (0) or 문단 모양 (1): the inspector's 텍스트 at 스타일 or 레이아웃, where all of them are.
    func revealText(layout: Int) {
        textLayout = layout
        reveal(.format, tab: "텍스트")
    }
}

/// Line shapes for underline and strikethrough, in Hancom's order and numbering.
enum LineShapes {
    static let names = ["실선", "파선", "점선", "일점쇄선", "이점쇄선", "긴 파선", "원형 점선", "이중 실선",
                        "얇고 굵은 이중선", "굵고 얇은 이중선", "얇고 굵고 얇은 삼중선", "물결선", "이중 물결선"]

    /// A sample of each shape, as the web editor's menus show them.
    static let images = images(width: 64)
    static func images(width: CGFloat) -> [NSImage] { names.indices.map { shape in
        let image = NSImage(size: NSSize(width: width, height: 10), flipped: true) { rect in
            NSColor.labelColor.set()
            func line(_ y: CGFloat, _ width: CGFloat, dash: [CGFloat] = [], round: Bool = false) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 1, y: y))
                path.line(to: NSPoint(x: rect.maxX - 1, y: y))
                path.lineWidth = width
                if round { path.lineCapStyle = .round }
                if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
                path.stroke()
            }
            func wave(_ y: CGFloat) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 1, y: y))
                for x in stride(from: CGFloat(1), to: rect.maxX - 1, by: 6) {
                    path.curve(to: NSPoint(x: x + 6, y: y), controlPoint1: NSPoint(x: x + 2, y: y - 3),
                               controlPoint2: NSPoint(x: x + 4, y: y + 3))
                }
                path.lineWidth = 1
                path.stroke()
            }
            switch shape {
            case 1: line(5, 1.5, dash: [5, 3])
            case 2: line(5, 1.5, dash: [1.5, 2])
            case 3: line(5, 1.5, dash: [7, 2, 1.5, 2])
            case 4: line(5, 1.5, dash: [7, 2, 1.5, 2, 1.5, 2])
            case 5: line(5, 1.5, dash: [12, 5])
            case 6: line(5, 2.5, dash: [0, 5], round: true)
            case 7: line(3.5, 1); line(6.5, 1)
            case 8: line(3, 0.75); line(6.5, 2)
            case 9: line(3.5, 2); line(7, 0.75)
            case 10: line(1.5, 0.75); line(5, 2); line(8.5, 0.75)
            case 11: wave(5)
            case 12: wave(3); wave(7)
            default: line(5, 1.5)
            }
            return true
        }
        image.isTemplate = true
        return image
    } }
}

/// Formats with 테두리 and 배경, which the engine takes all together.
protocol BorderFillStyle: PartialFormat {
    var borderLine: Int? { get set }
    var borderWidth: Int? { get set }
    var borderColor: String? { get set }
    var fillColor: String? { get set }
    var patternColor: String? { get set }
    var pattern: Int? { get set }
}
extension CharStyle: BorderFillStyle {}
extension ParaStyle: BorderFillStyle {}

extension BorderFillStyle {
    /// The changes from `old`, with all of 테두리 and 배경 when any of them changed.
    func changesWithBorderFill(from old: Self) -> Self {
        var change = changes(from: old)
        let keys: [WritableKeyPath<Self, Int?>] = [\.borderLine, \.borderWidth, \.pattern]
        let colors: [WritableKeyPath<Self, String?>] = [\.borderColor, \.fillColor, \.patternColor]
        guard keys.contains(where: { change[keyPath: $0] != nil }) || colors.contains(where: { change[keyPath: $0] != nil })
        else { return change }
        change.borderLine = borderLine ?? 0
        change.borderWidth = borderWidth ?? 0
        change.borderColor = borderColor ?? "#000000"
        change.fillColor = fillColor ?? "none"
        change.patternColor = patternColor ?? "#000000"
        change.pattern = pattern ?? 0
        return change
    }
}
