import Foundation

/// A collage layout: photo cells as normalised rectangles of the canvas.
/// Cells tile the canvas without gaps; spacing is added when rendering.
public struct CollageLayout: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var aspect: AspectPreset
    public var cells: [NormalizedRect]
    public var tier: Tier

    public init(id: String, name: String, aspect: AspectPreset, cells: [NormalizedRect], tier: Tier = .free) {
        self.id = id
        self.name = name
        self.aspect = aspect
        self.cells = cells
        self.tier = tier
    }

    public var photoCount: Int { cells.count }

    /// Canvas width over height; free and original aspects render square.
    public var canvasRatio: Double { aspect.ratio ?? 1 }

    /// The cells after applying spacing, so that the outer border and the
    /// gaps between cells are all `spacing` of the canvas's shorter side.
    public func frames(spacing: Double) -> [NormalizedRect] {
        let g = CollageProject.spacingRange.clamp(spacing)
        guard g > 0 else { return cells }
        let r = canvasRatio
        // Spacing in each axis, normalised to that axis.
        let gx = r >= 1 ? g / r : g
        let gy = r >= 1 ? g : g * r
        return cells.map { c in
            // Map into the canvas inset by half a gap, then inset each cell by half a gap.
            let x = gx / 2 + c.x * (1 - gx)
            let y = gy / 2 + c.y * (1 - gy)
            let w = c.width * (1 - gx)
            let h = c.height * (1 - gy)
            return NormalizedRect(x: x + gx / 2, y: y + gy / 2, width: max(0, w - gx), height: max(0, h - gy))
        }
    }

    public static func layouts(forPhotoCount count: Int, in library: [CollageLayout] = CollageLayout.library) -> [CollageLayout] {
        library.filter { $0.photoCount == count }
    }

    public static func layout(id: String) -> CollageLayout? {
        library.first { $0.id == id }
    }

    private static func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    /// AURUM's built-in layouts for 2 to 6 photos.
    public static let library: [CollageLayout] = [
        // Two
        CollageLayout(id: "collage.duet", name: "Duet", aspect: .square,
                      cells: [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 1)]),
        CollageLayout(id: "collage.horizon", name: "Horizon", aspect: .story,
                      cells: [r(0, 0, 1, 0.5), r(0, 0.5, 1, 0.5)]),
        // Three
        CollageLayout(id: "collage.salon", name: "Salon", aspect: .portrait,
                      cells: [r(0, 0, 0.6, 1), r(0.6, 0, 0.4, 0.5), r(0.6, 0.5, 0.4, 0.5)]),
        CollageLayout(id: "collage.triptych", name: "Triptych", aspect: .story,
                      cells: [r(0, 0, 1, 1.0 / 3), r(0, 1.0 / 3, 1, 1.0 / 3), r(0, 2.0 / 3, 1, 1.0 / 3)]),
        CollageLayout(id: "collage.marquee", name: "Marquee", aspect: .square,
                      cells: [r(0, 0, 1, 0.6), r(0, 0.6, 0.5, 0.4), r(0.5, 0.6, 0.5, 0.4)], tier: .member),
        // Four
        CollageLayout(id: "collage.quartet", name: "Quartet", aspect: .square,
                      cells: [r(0, 0, 0.5, 0.5), r(0.5, 0, 0.5, 0.5), r(0, 0.5, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]),
        CollageLayout(id: "collage.gallery", name: "Gallery", aspect: .portrait,
                      cells: [r(0, 0, 1, 0.625), r(0, 0.625, 1.0 / 3, 0.375), r(1.0 / 3, 0.625, 1.0 / 3, 0.375), r(2.0 / 3, 0.625, 1.0 / 3, 0.375)]),
        CollageLayout(id: "collage.cascade", name: "Cascade", aspect: .story,
                      cells: [r(0, 0, 0.5, 0.625), r(0.5, 0, 0.5, 0.375), r(0, 0.625, 0.5, 0.375), r(0.5, 0.375, 0.5, 0.625)], tier: .member),
        // Five
        CollageLayout(id: "collage.mosaic", name: "Mosaic", aspect: .square,
                      cells: [r(0, 0, 0.5, 0.5), r(0.5, 0, 0.5, 0.5), r(0, 0.5, 1.0 / 3, 0.5), r(1.0 / 3, 0.5, 1.0 / 3, 0.5), r(2.0 / 3, 0.5, 1.0 / 3, 0.5)]),
        CollageLayout(id: "collage.atelier", name: "Atelier", aspect: .portrait,
                      cells: [r(0, 0, 0.625, 1), r(0.625, 0, 0.375, 0.25), r(0.625, 0.25, 0.375, 0.25), r(0.625, 0.5, 0.375, 0.25), r(0.625, 0.75, 0.375, 0.25)], tier: .member),
        // Six
        CollageLayout(id: "collage.contact", name: "Contact Sheet", aspect: .portrait,
                      cells: [r(0, 0, 0.5, 1.0 / 3), r(0.5, 0, 0.5, 1.0 / 3),
                              r(0, 1.0 / 3, 0.5, 1.0 / 3), r(0.5, 1.0 / 3, 0.5, 1.0 / 3),
                              r(0, 2.0 / 3, 0.5, 1.0 / 3), r(0.5, 2.0 / 3, 0.5, 1.0 / 3)]),
        CollageLayout(id: "collage.vitrine", name: "Vitrine", aspect: .story,
                      cells: [r(0, 0, 0.625, 0.25), r(0.625, 0, 0.375, 0.25),
                              r(0, 0.25, 1, 0.5),
                              r(0, 0.75, 0.375, 0.25), r(0.375, 0.75, 0.3125, 0.25), r(0.6875, 0.75, 0.3125, 0.25)], tier: .member)
    ]
}

/// A collage the user is building.
public struct CollageProject: Codable, Equatable, Identifiable, Sendable {
    public static let spacingRange = 0.0...0.05
    public static let cornerRadiusRange = 0.0...0.1

    /// A photo in a cell, with the user's pan and zoom.
    public struct Cell: Codable, Equatable, Sendable {
        public var source: SourceAsset
        /// 1 fills the cell (aspect fill); up to 4.
        public var zoom: Double
        /// Centre of the visible area in normalised image coordinates.
        public var center: NormalizedPoint

        public init(source: SourceAsset, zoom: Double = 1, center: NormalizedPoint = .center) {
            self.source = source
            self.zoom = (1.0...4.0).clamp(zoom)
            self.center = NormalizedPoint(x: (0.0...1.0).clamp(center.x), y: (0.0...1.0).clamp(center.y))
        }
    }

    public var id: UUID
    public private(set) var layout: CollageLayout
    /// One entry per layout cell; nil means empty.
    public private(set) var cells: [Cell?]
    /// Fraction of the canvas's shorter side, 0...0.05.
    public var spacing: Double
    /// Fraction of the canvas's shorter side, 0...0.1.
    public var cornerRadius: Double
    /// "#RRGGBB".
    public var backgroundHex: String

    public init(id: UUID = UUID(), layout: CollageLayout, cells: [Cell?] = [], spacing: Double = 0.01, cornerRadius: Double = 0, backgroundHex: String = "#000000") {
        self.id = id
        self.layout = layout
        self.cells = Self.fit(cells, to: layout.photoCount)
        self.spacing = Self.spacingRange.clamp(spacing)
        self.cornerRadius = Self.cornerRadiusRange.clamp(cornerRadius)
        self.backgroundHex = Self.normalizedHex(backgroundHex) ?? "#000000"
    }

    private static func fit(_ cells: [Cell?], to count: Int) -> [Cell?] {
        var out = Array(cells.prefix(count))
        while out.count < count { out.append(nil) }
        return out
    }

    /// "#rgb", "rrggbb" or "#RRGGBB" as "#RRGGBB", or nil if not a colour.
    public static func normalizedHex(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        let hexDigits = Set("0123456789ABCDEF")
        guard s.allSatisfy({ hexDigits.contains($0) }) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 else { return nil }
        return "#" + s
    }

    public var isComplete: Bool { cells.allSatisfy { $0 != nil } }
    public var filledCount: Int { cells.filter { $0 != nil }.count }

    /// Cell frames with the current spacing.
    public var frames: [NormalizedRect] { layout.frames(spacing: spacing) }

    public mutating func assign(_ cell: Cell?, at index: Int) {
        guard cells.indices.contains(index) else { return }
        cells[index] = cell
    }

    /// Puts a photo in the first empty cell. Returns its index, or nil if full.
    @discardableResult
    public mutating func add(_ source: SourceAsset) -> Int? {
        guard let i = cells.firstIndex(where: { $0 == nil }) else { return nil }
        cells[i] = Cell(source: source)
        return i
    }

    public mutating func swapCells(_ a: Int, _ b: Int) {
        guard cells.indices.contains(a), cells.indices.contains(b), a != b else { return }
        cells.swapAt(a, b)
    }

    /// Changes layout, keeping the photos in order. Photos beyond the new
    /// layout's cells are dropped.
    public mutating func setLayout(_ newLayout: CollageLayout) {
        let photos = cells.compactMap { $0 }
        layout = newLayout
        cells = Self.fit(photos.map { Optional($0) }, to: newLayout.photoCount)
    }
}

/// Splits one wide photo into panels for a swipeable carousel post.
public enum Carousel {
    public static let maxPanels = 20

    /// `count` panels of `panelAspect` (width / height) cut from the largest
    /// centred strip that fits an image of `imageAspect`. Rects are normalised
    /// to the image. Adjacent panels touch exactly, so the carousel is seamless.
    public static func panels(for imageAspect: Double, count: Int, panelAspect: Double) -> [NormalizedRect] {
        guard imageAspect > 0, panelAspect > 0, imageAspect.isFinite, panelAspect.isFinite, count >= 1 else { return [] }
        let n = min(count, maxPanels)
        let stripAspect = Double(n) * panelAspect
        var x0 = 0.0, y0 = 0.0, width = 1.0, height = 1.0
        if stripAspect <= imageAspect {
            width = stripAspect / imageAspect
            x0 = (1 - width) / 2
        } else {
            height = imageAspect / stripAspect
            y0 = (1 - height) / 2
        }
        // Panels share boundaries; each width is the difference of two
        // neighbouring boundaries so x + width lands exactly on the next x.
        var edges = (0...n).map { x0 + width * Double($0) / Double(n) }
        if x0 == 0 { edges[n] = 1 }
        return (0..<n).map { i in
            NormalizedRect(x: edges[i], y: y0, width: edges[i + 1] - edges[i], height: height)
        }
    }
}
