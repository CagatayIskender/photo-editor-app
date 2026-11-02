import SwiftUI

/// AURUM's custom thin-line icon set, drawn on a 24 pt grid with a 1.25 pt
/// stroke. Icons are paths rather than SF Symbols so the set stays original
/// and consistent.
public enum AurumIcon: String, CaseIterable, Sendable {
    case salon, vault, plus, close, back, undo, redo, search, settings
    case looks, effects, threeD, wand, retouch, adjust, text, stickers, music, layers, crop
    case crown, compare, sparkle, check, camera, rotate, flip, share, download

    /// Accessibility name used when the icon stands alone.
    public var accessibilityName: String {
        switch self {
        case .threeD: return "3D"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    func path(in r: CGRect) -> Path {
        let s = r.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: r.minX + (cx - radius) * s, y: r.minY + (cy - radius) * s, width: 2 * radius * s, height: 2 * radius * s))
        }
        var path = Path()
        switch self {
        case .salon:
            path.move(to: p(4, 20)); path.addLine(to: p(4, 9)); path.addLine(to: p(12, 4)); path.addLine(to: p(20, 9)); path.addLine(to: p(20, 20))
            path.move(to: p(9, 20)); path.addLine(to: p(9, 14)); path.addLine(to: p(15, 14)); path.addLine(to: p(15, 20))
        case .vault:
            path.addRoundedRect(in: CGRect(x: r.minX + 4 * s, y: r.minY + 5 * s, width: 16 * s, height: 15 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s))
            path.addPath(circle(12, 12.5, 3))
        case .plus:
            path.move(to: p(12, 5)); path.addLine(to: p(12, 19)); path.move(to: p(5, 12)); path.addLine(to: p(19, 12))
        case .close:
            path.move(to: p(6, 6)); path.addLine(to: p(18, 18)); path.move(to: p(18, 6)); path.addLine(to: p(6, 18))
        case .back:
            path.move(to: p(15, 5)); path.addLine(to: p(8, 12)); path.addLine(to: p(15, 19))
        case .undo:
            path.move(to: p(9, 7)); path.addLine(to: p(5, 11)); path.addLine(to: p(9, 15))
            path.move(to: p(5, 11)); path.addLine(to: p(15, 11))
            path.addArc(center: p(15, 15), radius: 4 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: p(12, 19))
        case .redo:
            path.move(to: p(15, 7)); path.addLine(to: p(19, 11)); path.addLine(to: p(15, 15))
            path.move(to: p(19, 11)); path.addLine(to: p(9, 11))
            path.addArc(center: p(9, 15), radius: 4 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: p(12, 19))
        case .search:
            path.addPath(circle(11, 11, 6)); path.move(to: p(15.5, 15.5)); path.addLine(to: p(20, 20))
        case .settings:
            path.addPath(circle(12, 12, 3))
            for (a, b) in [((12, 3), (12, 6)), ((12, 18), (12, 21)), ((3, 12), (6, 12)), ((18, 12), (21, 12))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
                path.move(to: p(a.0, a.1)); path.addLine(to: p(b.0, b.1))
            }
        case .looks:
            path.addPath(circle(9, 10, 5)); path.addPath(circle(15, 14, 5))
        case .effects, .sparkle:
            path.move(to: p(12, 3)); path.addLine(to: p(13.8, 8.2)); path.addLine(to: p(19, 10)); path.addLine(to: p(13.8, 11.8))
            path.addLine(to: p(12, 17)); path.addLine(to: p(10.2, 11.8)); path.addLine(to: p(5, 10)); path.addLine(to: p(10.2, 8.2)); path.closeSubpath()
        case .threeD:
            path.move(to: p(12, 3)); path.addLine(to: p(20, 7.5)); path.addLine(to: p(20, 16.5)); path.addLine(to: p(12, 21)); path.addLine(to: p(4, 16.5)); path.addLine(to: p(4, 7.5)); path.closeSubpath()
            path.move(to: p(12, 12)); path.addLine(to: p(20, 7.5)); path.move(to: p(12, 12)); path.addLine(to: p(12, 21)); path.move(to: p(12, 12)); path.addLine(to: p(4, 7.5))
        case .wand:
            path.move(to: p(4, 20)); path.addLine(to: p(14, 10))
            path.move(to: p(17, 3)); path.addLine(to: p(18, 6)); path.addLine(to: p(21, 7)); path.addLine(to: p(18, 8))
            path.addLine(to: p(17, 11)); path.addLine(to: p(16, 8)); path.addLine(to: p(13, 7)); path.addLine(to: p(16, 6)); path.closeSubpath()
            path.move(to: p(6, 5)); path.addLine(to: p(6, 8)); path.move(to: p(4.5, 6.5)); path.addLine(to: p(7.5, 6.5))
        case .retouch:
            path.move(to: p(5, 19)); path.addLine(to: p(14, 10)); path.addLine(to: p(17, 7)); path.addLine(to: p(19, 9)); path.addLine(to: p(16, 12)); path.addLine(to: p(14, 10))
        case .adjust:
            path.move(to: p(4, 7)); path.addLine(to: p(14, 7)); path.move(to: p(18, 7)); path.addLine(to: p(20, 7)); path.addPath(circle(16, 7, 2))
            path.move(to: p(4, 17)); path.addLine(to: p(8, 17)); path.move(to: p(12, 17)); path.addLine(to: p(20, 17)); path.addPath(circle(10, 17, 2))
        case .text:
            path.move(to: p(5, 6)); path.addLine(to: p(19, 6)); path.move(to: p(12, 6)); path.addLine(to: p(12, 19)); path.move(to: p(9, 19)); path.addLine(to: p(15, 19))
        case .stickers:
            path.move(to: p(5, 5)); path.addLine(to: p(19, 5)); path.addLine(to: p(19, 13)); path.addLine(to: p(13, 19)); path.addLine(to: p(5, 19)); path.closeSubpath()
            path.move(to: p(13, 19)); path.addLine(to: p(13, 13)); path.addLine(to: p(19, 13))
        case .music:
            path.move(to: p(9, 18)); path.addLine(to: p(9, 6)); path.addLine(to: p(19, 4)); path.addLine(to: p(19, 16))
            path.addPath(circle(7, 18, 2)); path.addPath(circle(17, 16, 2))
        case .layers:
            path.move(to: p(12, 4)); path.addLine(to: p(20, 8)); path.addLine(to: p(12, 12)); path.addLine(to: p(4, 8)); path.closeSubpath()
            path.move(to: p(4, 12)); path.addLine(to: p(12, 16)); path.addLine(to: p(20, 12))
            path.move(to: p(4, 16)); path.addLine(to: p(12, 20)); path.addLine(to: p(20, 16))
        case .crop:
            path.move(to: p(7, 3)); path.addLine(to: p(7, 17)); path.addLine(to: p(21, 17))
            path.move(to: p(3, 7)); path.addLine(to: p(17, 7)); path.addLine(to: p(17, 21))
        case .crown:
            path.move(to: p(3, 18)); path.addLine(to: p(21, 18))
            path.move(to: p(4, 8)); path.addLine(to: p(8.5, 12)); path.addLine(to: p(12, 5)); path.addLine(to: p(15.5, 12)); path.addLine(to: p(20, 8))
            path.addLine(to: p(18.5, 16)); path.addLine(to: p(5.5, 16)); path.closeSubpath()
        case .compare:
            path.addRoundedRect(in: CGRect(x: r.minX + 4 * s, y: r.minY + 5 * s, width: 16 * s, height: 14 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s))
            path.move(to: p(12, 3)); path.addLine(to: p(12, 21))
        case .check:
            path.move(to: p(5, 12)); path.addLine(to: p(10, 17)); path.addLine(to: p(19, 7))
        case .camera:
            path.move(to: p(4, 8)); path.addLine(to: p(7, 8)); path.addLine(to: p(9, 5)); path.addLine(to: p(15, 5)); path.addLine(to: p(17, 8)); path.addLine(to: p(20, 8)); path.addLine(to: p(20, 19)); path.addLine(to: p(4, 19)); path.closeSubpath()
            path.addPath(circle(12, 13, 3.5))
        case .rotate:
            path.addArc(center: p(12, 12), radius: 7 * s, startAngle: .degrees(180), endAngle: .degrees(-120), clockwise: true)
            path.move(to: p(5, 3)); path.addLine(to: p(5, 7)); path.addLine(to: p(9, 7))
        case .flip:
            path.move(to: p(12, 3)); path.addLine(to: p(12, 21))
            path.move(to: p(9, 7)); path.addLine(to: p(4, 17)); path.addLine(to: p(9, 17)); path.closeSubpath()
            path.move(to: p(15, 7)); path.addLine(to: p(20, 17)); path.addLine(to: p(15, 17)); path.closeSubpath()
        case .share:
            path.move(to: p(12, 3)); path.addLine(to: p(12, 15)); path.move(to: p(8, 7)); path.addLine(to: p(12, 3)); path.addLine(to: p(16, 7))
            path.move(to: p(7, 11)); path.addLine(to: p(5, 11)); path.addLine(to: p(5, 21)); path.addLine(to: p(19, 21)); path.addLine(to: p(19, 11)); path.addLine(to: p(17, 11))
        case .download:
            path.move(to: p(12, 3)); path.addLine(to: p(12, 15)); path.move(to: p(8, 11)); path.addLine(to: p(12, 15)); path.addLine(to: p(16, 11))
            path.move(to: p(5, 19)); path.addLine(to: p(19, 19))
        }
        return path
    }
}

/// A shape that draws an `AurumIcon`.
public struct AurumIconShape: Shape {
    public let icon: AurumIcon
    public init(_ icon: AurumIcon) { self.icon = icon }
    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return icon.path(in: square)
    }
}

/// Renders an icon at a given size in the current foreground colour.
public struct IconView: View {
    let icon: AurumIcon
    let size: CGFloat
    let lineWidth: CGFloat

    public init(_ icon: AurumIcon, size: CGFloat = 24, lineWidth: CGFloat = Size.iconStroke) {
        self.icon = icon
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        AurumIconShape(icon)
            .stroke(style: StrokeStyle(lineWidth: lineWidth * size / 24 * 1.0, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
