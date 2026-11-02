import Foundation

/// Bakes per-colour HSL shifts, tone curves and split toning into a 3D colour
/// lookup table. One LUT lookup on the GPU then applies all three at once.
///
/// This lives in AurumCore (not the renderer) because it is pure maths: it is
/// unit-tested on Linux, and Android can port it line for line.
public enum ColorCube {
    /// Returns RGBA float data in the layout `CIColorCube` expects
    /// (red varies fastest, then green, then blue), or nil when the
    /// adjustments are neutral and no cube is needed.
    public static func make(for adjustments: AdjustmentSet, dimension: Int = 32) -> [Float]? {
        let hsl = adjustments.hsl
        let curves = adjustments.curves
        let split = adjustments.splitToning
        let hasSplit = split.shadowSaturation > 0 || split.highlightSaturation > 0
        guard !hsl.shifts.isEmpty || !curves.isIdentity || hasSplit else { return nil }

        let master = ToneCurveSampler(curves.master)
        let red = ToneCurveSampler(curves.red)
        let green = ToneCurveSampler(curves.green)
        let blue = ToneCurveSampler(curves.blue)
        let shadowRGB = rgb(hue: split.shadowHue, saturation: 1, lightness: 0.5)
        let highlightRGB = rgb(hue: split.highlightHue, saturation: 1, lightness: 0.5)

        var data = [Float]()
        data.reserveCapacity(dimension * dimension * dimension * 4)
        let maxIndex = Double(dimension - 1)
        for bi in 0..<dimension {
            for gi in 0..<dimension {
                for ri in 0..<dimension {
                    var r = Double(ri) / maxIndex
                    var g = Double(gi) / maxIndex
                    var b = Double(bi) / maxIndex

                    if !hsl.shifts.isEmpty {
                        (r, g, b) = applyHSL(r, g, b, hsl)
                    }
                    if !curves.isIdentity {
                        r = red.value(master.value(r))
                        g = green.value(master.value(g))
                        b = blue.value(master.value(b))
                    }
                    if hasSplit {
                        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        // Shadows weight falls from 1 at black; highlights rise to 1 at white.
                        // Balance moves the crossover point.
                        let pivot = 0.5 + split.balance * 0.25
                        let sw = max(0, 1 - luma / max(pivot, 0.01)) * split.shadowSaturation * 0.5
                        let hw = max(0, (luma - pivot) / max(1 - pivot, 0.01)) * split.highlightSaturation * 0.5
                        r = r + (shadowRGB.0 - 0.5) * sw + (highlightRGB.0 - 0.5) * hw
                        g = g + (shadowRGB.1 - 0.5) * sw + (highlightRGB.1 - 0.5) * hw
                        b = b + (shadowRGB.2 - 0.5) * sw + (highlightRGB.2 - 0.5) * hw
                    }
                    data.append(Float(clamp01(r)))
                    data.append(Float(clamp01(g)))
                    data.append(Float(clamp01(b)))
                    data.append(1)
                }
            }
        }
        return data
    }

    // MARK: HSL

    /// Centre hue (degrees) of each band.
    static let bandCentres: [(HSLAdjustments.Band, Double)] = [
        (.red, 0), (.orange, 30), (.yellow, 60), (.green, 120),
        (.aqua, 180), (.blue, 225), (.purple, 270), (.magenta, 315)
    ]

    /// How much a hue belongs to a band: 1 at the centre, falling to 0 at
    /// 45° away, so neighbouring bands blend smoothly.
    static func weight(hue: Double, centre: Double) -> Double {
        var d = abs(hue - centre).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return max(0, 1 - d / 45)
    }

    static func applyHSL(_ r: Double, _ g: Double, _ b: Double, _ hsl: HSLAdjustments) -> (Double, Double, Double) {
        var (h, s, l) = hslFrom(r, g, b)
        guard s > 0.0001 else { return (r, g, b) } // greys have no hue to shift
        var dh = 0.0, ds = 0.0, dl = 0.0
        for (band, centre) in bandCentres {
            let w = weight(hue: h, centre: centre)
            guard w > 0 else { continue }
            let shift = hsl[band]
            dh += shift.hue * w * 30          // up to ±30°
            ds += shift.saturation * w
            dl += shift.luminance * w * 0.3   // gentle: ±30% lightness
        }
        h = (h + dh).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        s = clamp01(s * (1 + ds))
        // Weight the lightness change by saturation so near-greys barely move.
        l = clamp01(l + dl * s)
        return rgb(hue: h, saturation: s, lightness: l)
    }

    static func hslFrom(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxV == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }

    static func rgb(hue: Double, saturation s: Double, lightness l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let h = hue / 360
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// Evaluates a tone curve by monotone piecewise-linear interpolation through
/// its points, with implicit end points at (0, 0) and (1, 1).
struct ToneCurveSampler {
    let points: [CurvePoint]

    init(_ points: [CurvePoint]) {
        var pts = points.map { CurvePoint(x: ColorCube.clamp01($0.x), y: ColorCube.clamp01($0.y)) }
        if !pts.contains(where: { $0.x == 0 }) { pts.append(CurvePoint(x: 0, y: 0)) }
        if !pts.contains(where: { $0.x == 1 }) { pts.append(CurvePoint(x: 1, y: 1)) }
        self.points = pts.sorted { $0.x < $1.x }
    }

    func value(_ x: Double) -> Double {
        guard points.count > 2 || points.first?.y != 0 || points.last?.y != 1 else { return x }
        guard let upperIndex = points.firstIndex(where: { $0.x >= x }) else { return points.last?.y ?? x }
        if upperIndex == 0 { return points[0].y }
        let a = points[upperIndex - 1], b = points[upperIndex]
        let t = b.x == a.x ? 0 : (x - a.x) / (b.x - a.x)
        return a.y + (b.y - a.y) * t
    }
}
