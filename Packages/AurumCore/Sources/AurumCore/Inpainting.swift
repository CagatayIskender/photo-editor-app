import Foundation

/// A small RGBA image in floats (0...1), interleaved, row 0 at the top.
/// Used for the CPU part of Object Remove, on a downscaled region.
public struct RGBAImageBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// r, g, b, a for each pixel, row by row.
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height * 4, "pixel count must be width × height × 4")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A buffer filled with one colour.
    public init(width: Int, height: Int, red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.width = width
        self.height = height
        var p = [Float](repeating: 0, count: width * height * 4)
        var i = 0
        while i < p.count {
            p[i] = red
            p[i + 1] = green
            p[i + 2] = blue
            p[i + 3] = alpha
            i += 4
        }
        self.pixels = p
    }

    /// From 8-bit RGBA bytes.
    public init(rgba8 bytes: [UInt8], width: Int, height: Int) {
        precondition(bytes.count == width * height * 4, "byte count must be width × height × 4")
        self.width = width
        self.height = height
        self.pixels = bytes.map { Float($0) / 255 }
    }

    /// 8-bit RGBA bytes, rounded and clamped.
    public var rgba8: [UInt8] {
        pixels.map { v in
            let c = min(max(v, 0), 1) * 255
            return UInt8(c.rounded())
        }
    }

    public func value(x: Int, y: Int, channel: Int) -> Float {
        pixels[(y * width + x) * 4 + channel]
    }

    public mutating func setValue(_ value: Float, x: Int, y: Int, channel: Int) {
        pixels[(y * width + x) * 4 + channel] = value
    }
}

/// Classic, non-generative inpainting for Object Remove.
///
/// 1. **Push-pull fill.** The hole is filled from its surroundings with a
///    multi-scale pyramid: known pixels are averaged down level by level
///    (pull) until every coarse pixel has a value, then coarse values are
///    blended back up into the unknown pixels (push). The result is a smooth
///    membrane that matches the border colour.
/// 2. **Texture from a nearby patch.** Smooth fills look plastic, so several
///    offsets around the hole's bounding box are tested; the one whose shifted
///    copy matches the hole's border best is copied in, and the remaining
///    border difference is spread across the hole with another push-pull pass
///    so the patch blends in seamlessly (a simple seamless-cloning scheme).
///
/// Pixels outside the hole are never changed.
public enum Inpainter {
    /// Width, in pixels, of the known ring around the hole used to judge patches.
    public static let ringWidth = 3
    /// Patches whose border mismatch is above this are not used; the smooth fill stays.
    public static let maximumPatchCost: Float = 0.03

    /// Fills every pixel where `mask` ≥ 0.5. `mask` has one value per pixel.
    public static func fill(_ image: RGBAImageBuffer, mask: [Float], useTexture: Bool = true) -> RGBAImageBuffer {
        let n = image.width * image.height
        guard n > 0, mask.count == n else { return image }
        var known = [Float](repeating: 1, count: n)
        var holeCount = 0
        for i in 0..<n where mask[i] >= 0.5 {
            known[i] = 0
            holeCount += 1
        }
        guard holeCount > 0 else { return image }
        guard holeCount < n else { return image }

        var result = image
        if useTexture, let offset = bestPatchOffset(image, known: known) {
            let correction = borderCorrection(image, known: known, offset: offset)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let i = y * image.width + x
                    guard known[i] == 0 else { continue }
                    let si = (y + offset.dy) * image.width + (x + offset.dx)
                    for k in 0..<3 {
                        let v = image.pixels[si * 4 + k] + correction[i * 4 + k]
                        result.pixels[i * 4 + k] = min(max(v, 0), 1)
                    }
                    result.pixels[i * 4 + 3] = image.pixels[si * 4 + 3]
                }
            }
            return result
        }

        let smooth = pushPull(image.pixels, weights: known, width: image.width, height: image.height, channels: 4)
        for i in 0..<n where known[i] == 0 {
            for k in 0..<4 {
                result.pixels[i * 4 + k] = min(max(smooth[i * 4 + k], 0), 1)
            }
        }
        return result
    }

    // MARK: Push-pull

    /// Fills values where `weights` is below 1 from the weighted values
    /// around them. `values` holds `channels` floats per pixel; pixels with
    /// weight 1 come back unchanged. A pixel's weight says how much its own
    /// value is trusted (0 unknown, 1 known).
    public static func pushPull(_ values: [Float], weights: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        let n = width * height
        guard n > 0, weights.count == n, values.count == n * channels else { return values }

        // Level 0, premultiplied by weight.
        var premultiplied = [Float](repeating: 0, count: n * channels)
        for i in 0..<n {
            let w = weights[i]
            for k in 0..<channels {
                premultiplied[i * channels + k] = values[i * channels + k] * w
            }
        }
        var colourLevels: [[Float]] = [premultiplied]
        var weightLevels: [[Float]] = [weights]
        var sizes: [(w: Int, h: Int)] = [(width, height)]

        // Pull: average known values down until one pixel remains.
        while sizes[sizes.count - 1].w > 1 || sizes[sizes.count - 1].h > 1 {
            let fine = sizes[sizes.count - 1]
            let fineColour = colourLevels[colourLevels.count - 1]
            let fineWeight = weightLevels[weightLevels.count - 1]
            let cw = (fine.w + 1) / 2
            let ch = (fine.h + 1) / 2
            var colour = [Float](repeating: 0, count: cw * ch * channels)
            var weight = [Float](repeating: 0, count: cw * ch)
            for y in 0..<ch {
                for x in 0..<cw {
                    let o = y * cw + x
                    var sum: Float = 0
                    for dy in 0..<2 {
                        let sy = 2 * y + dy
                        if sy >= fine.h { continue }
                        for dx in 0..<2 {
                            let sx = 2 * x + dx
                            if sx >= fine.w { continue }
                            let si = sy * fine.w + sx
                            sum += fineWeight[si]
                            for k in 0..<channels {
                                colour[o * channels + k] += fineColour[si * channels + k]
                            }
                        }
                    }
                    if sum > 0 {
                        let w = min(1, sum)
                        let scale = w / sum
                        for k in 0..<channels {
                            colour[o * channels + k] *= scale
                        }
                        weight[o] = w
                    }
                }
            }
            colourLevels.append(colour)
            weightLevels.append(weight)
            sizes.append((cw, ch))
        }

        // The coarsest level as plain (un-premultiplied) values.
        let top = colourLevels.count - 1
        var filled = colourLevels[top]
        let topWeights = weightLevels[top]
        for i in 0..<topWeights.count {
            let w = topWeights[i]
            for k in 0..<channels {
                filled[i * channels + k] = w > 0 ? filled[i * channels + k] / w : 0
            }
        }

        // Push: blend the coarser, complete level into what each finer level lacks.
        var level = top - 1
        while level >= 0 {
            let fine = sizes[level]
            let coarse = sizes[level + 1]
            let fineColour = colourLevels[level]
            let fineWeight = weightLevels[level]
            var out = [Float](repeating: 0, count: fine.w * fine.h * channels)
            for y in 0..<fine.h {
                // Bilinear sample position in the coarse level.
                let fy = max(0, min(Float(coarse.h - 1), (Float(y) + 0.5) / 2 - 0.5))
                let y0 = Int(fy)
                let y1 = min(y0 + 1, coarse.h - 1)
                let ty = fy - Float(y0)
                for x in 0..<fine.w {
                    let i = y * fine.w + x
                    let w = fineWeight[i]
                    if w >= 1 {
                        for k in 0..<channels {
                            out[i * channels + k] = fineColour[i * channels + k]
                        }
                        continue
                    }
                    let fx = max(0, min(Float(coarse.w - 1), (Float(x) + 0.5) / 2 - 0.5))
                    let x0 = Int(fx)
                    let x1 = min(x0 + 1, coarse.w - 1)
                    let tx = fx - Float(x0)
                    let i00 = (y0 * coarse.w + x0) * channels
                    let i10 = (y0 * coarse.w + x1) * channels
                    let i01 = (y1 * coarse.w + x0) * channels
                    let i11 = (y1 * coarse.w + x1) * channels
                    let missing = 1 - w
                    for k in 0..<channels {
                        let upper = filled[i00 + k] + (filled[i10 + k] - filled[i00 + k]) * tx
                        let lower = filled[i01 + k] + (filled[i11 + k] - filled[i01 + k]) * tx
                        let sample = upper + (lower - upper) * ty
                        out[i * channels + k] = fineColour[i * channels + k] + missing * sample
                    }
                }
            }
            filled = out
            level -= 1
        }
        return filled
    }

    // MARK: Patch search

    /// A shift, in pixels, from a hole pixel to the pixel copied into it.
    public struct Offset: Equatable, Hashable, Sendable {
        public var dx: Int
        public var dy: Int
        public init(dx: Int, dy: Int) {
            self.dx = dx
            self.dy = dy
        }
    }

    /// The hole's bounding box, inclusive, or nil when there is no hole.
    static func holeBounds(known: [Float], width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where known[y * width + x] == 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// Known pixels within `ringWidth` of the hole (by chessboard distance).
    static func ring(known: [Float], width: Int, height: Int) -> [Int] {
        var inRing = [Bool](repeating: false, count: width * height)
        let r = ringWidth
        for y in 0..<height {
            for x in 0..<width where known[y * width + x] == 0 {
                // Only the hole's edge pixels can reach the ring.
                let left = x > 0 && known[y * width + x - 1] != 0
                let right = x < width - 1 && known[y * width + x + 1] != 0
                let up = y > 0 && known[(y - 1) * width + x] != 0
                let down = y < height - 1 && known[(y + 1) * width + x] != 0
                guard left || right || up || down else { continue }
                for ny in max(0, y - r)...min(height - 1, y + r) {
                    for nx in max(0, x - r)...min(width - 1, x + r) where known[ny * width + nx] != 0 {
                        inRing[ny * width + nx] = true
                    }
                }
            }
        }
        var out: [Int] = []
        for i in 0..<inRing.count where inRing[i] { out.append(i) }
        return out
    }

    /// Offsets to try: in eight directions around the hole's bounding box,
    /// at several distances, plus a finer sweep straight left, right, up and
    /// down (which finds the period of stripes and tiles).
    public static func candidateOffsets(holeWidth: Int, holeHeight: Int) -> [Offset] {
        let gap = ringWidth + 1
        let baseX = holeWidth + gap
        let baseY = holeHeight + gap
        var seen = Set<Offset>()
        var out: [Offset] = []
        func add(_ o: Offset) {
            guard o.dx != 0 || o.dy != 0, seen.insert(o).inserted else { return }
            out.append(o)
        }
        let directions: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)]
        let multipliers: [Double] = [1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
        for (sx, sy) in directions {
            for m in multipliers {
                let dx = Int((Double(baseX) * m).rounded()) * sx
                let dy = Int((Double(baseY) * m).rounded()) * sy
                add(Offset(dx: dx, dy: dy))
            }
        }
        let stepX = max(1, baseX / 16)
        let stepY = max(1, baseY / 16)
        var d = baseX
        while d <= baseX * 2 {
            add(Offset(dx: d, dy: 0))
            add(Offset(dx: -d, dy: 0))
            d += stepX
        }
        d = baseY
        while d <= baseY * 2 {
            add(Offset(dx: 0, dy: d))
            add(Offset(dx: 0, dy: -d))
            d += stepY
        }
        return out
    }

    /// How badly the copy shifted by `offset` fits the hole's border: the
    /// spread of the colour difference around the ring, plus a smaller
    /// penalty for its average (which the border correction removes anyway).
    /// Nil when the copy would leave the image or read from the hole.
    public static func patchCost(_ image: RGBAImageBuffer, known: [Float], ring: [Int], offset: Offset) -> Float? {
        let w = image.width
        let h = image.height
        var count: Float = 0
        var sum: [Float] = [0, 0, 0]
        var sumSquares: [Float] = [0, 0, 0]
        for i in ring {
            let x = i % w + offset.dx
            let y = i / w + offset.dy
            guard x >= 0, y >= 0, x < w, y < h else { continue }
            let si = y * w + x
            guard known[si] != 0 else { continue }
            for k in 0..<3 {
                let diff = image.pixels[i * 4 + k] - image.pixels[si * 4 + k]
                sum[k] += diff
                sumSquares[k] += diff * diff
            }
            count += 1
        }
        guard count > 0, count >= Float(ring.count) / 2 else { return nil }
        var cost: Float = 0
        for k in 0..<3 {
            let mean = sum[k] / count
            let variance = max(0, sumSquares[k] / count - mean * mean)
            cost += variance + 0.25 * mean * mean
        }
        return cost / 3
    }

    /// The offset whose copy fits the hole best, or nil when none fits
    /// within `maximumPatchCost` (the smooth fill is used instead).
    public static func bestPatchOffset(_ image: RGBAImageBuffer, known: [Float]) -> Offset? {
        let w = image.width
        let h = image.height
        guard let box = holeBounds(known: known, width: w, height: h) else { return nil }
        let ringPixels = ring(known: known, width: w, height: h)
        guard !ringPixels.isEmpty else { return nil }
        let holeWidth = box.maxX - box.minX + 1
        let holeHeight = box.maxY - box.minY + 1
        var holePixels: [Int] = []
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX where known[y * w + x] == 0 {
                holePixels.append(y * w + x)
            }
        }

        var best: Offset?
        var bestCost = maximumPatchCost
        for offset in candidateOffsets(holeWidth: holeWidth, holeHeight: holeHeight) {
            // The whole hole must copy from known pixels inside the image.
            let minX = box.minX + offset.dx
            let maxX = box.maxX + offset.dx
            let minY = box.minY + offset.dy
            let maxY = box.maxY + offset.dy
            guard minX >= 0, minY >= 0, maxX < w, maxY < h else { continue }
            var readsHole = false
            for i in holePixels {
                let si = i + offset.dy * w + offset.dx
                if known[si] == 0 {
                    readsHole = true
                    break
                }
            }
            if readsHole { continue }
            guard let cost = patchCost(image, known: known, ring: ringPixels, offset: offset) else { continue }
            if cost < bestCost || (cost == bestCost && best == nil) {
                bestCost = cost
                best = offset
            }
        }
        return best
    }

    /// The colour difference between the border and the shifted copy's
    /// border, spread smoothly across the hole (4 values per pixel).
    static func borderCorrection(_ image: RGBAImageBuffer, known: [Float], offset: Offset) -> [Float] {
        let w = image.width
        let h = image.height
        let n = w * h
        var values = [Float](repeating: 0, count: n * 4)
        var weights = [Float](repeating: 0, count: n)
        for i in ring(known: known, width: w, height: h) {
            let x = i % w + offset.dx
            let y = i / w + offset.dy
            guard x >= 0, y >= 0, x < w, y < h else { continue }
            let si = y * w + x
            guard known[si] != 0 else { continue }
            for k in 0..<3 {
                values[i * 4 + k] = image.pixels[i * 4 + k] - image.pixels[si * 4 + k]
            }
            weights[i] = 1
        }
        return pushPull(values, weights: weights, width: w, height: h, channels: 4)
    }
}
