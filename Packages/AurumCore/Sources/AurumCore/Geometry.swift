import Foundation

/// A point in normalised coordinates, where (0, 0) is the top-left and (1, 1)
/// the bottom-right of the reference rectangle (usually the crop rect).
public struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = NormalizedPoint(x: 0.5, y: 0.5)
}

/// A rectangle in normalised coordinates of the source image.
public struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// Returns the rectangle clamped so it lies inside the unit square and has
    /// a minimum size, which keeps a crop usable after a bad gesture.
    public func clamped(minimumSize: Double = 0.05) -> NormalizedRect {
        let w = min(max(width, minimumSize), 1)
        let h = min(max(height, minimumSize), 1)
        let cx = min(max(x, 0), 1 - w)
        let cy = min(max(y, 0), 1 - h)
        return NormalizedRect(x: cx, y: cy, width: w, height: h)
    }
}

/// A pixel size of an image.
public struct PixelSize: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double {
        height == 0 ? 1 : Double(width) / Double(height)
    }

    /// Scales the size down, keeping its aspect ratio, so its longest side is
    /// at most `maxPixelSize`. Sizes already within the limit are returned unchanged.
    public func fitting(maxPixelSize: Int) -> PixelSize {
        let longest = max(width, height)
        guard longest > maxPixelSize, longest > 0 else { return self }
        let scale = Double(maxPixelSize) / Double(longest)
        return PixelSize(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }
}
