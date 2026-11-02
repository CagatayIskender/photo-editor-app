import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

/// Camera moves for 3D photo motion: the renderer splits the photo into depth
/// layers and moves a virtual camera through them.
public enum DepthMotionPreset: String, Codable, CaseIterable, Sendable {
    /// The camera circles the subject.
    case orbit
    /// Moves in and back out, with the focus following.
    case dolly
    /// Sways side to side.
    case swing
    /// A slow figure of eight, like a drifting balloon.
    case float
}

/// A looping 3D photo move. Samples are deterministic and the loop is
/// seamless: the sample at t = 0 equals the sample at t = duration.
public struct DepthMotion: Codable, Equatable, Sendable {
    /// Largest camera offset at intensity 1, as a fraction of the frame.
    public static let maxOffset = 0.03
    /// Largest zoom above 1 at intensity 1.
    public static let maxZoom = 0.12
    /// Largest change of the focus depth at intensity 1.
    public static let maxFocusShift = 0.15
    public static let defaultDuration: Seconds = 4

    /// The camera at one instant.
    public struct Sample: Equatable, Sendable {
        /// Camera offset, normalised to the frame.
        public var dx: Double
        public var dy: Double
        /// Scale, always at least 1 and large enough to hide the frame edges
        /// for the current offset.
        public var zoom: Double
        /// 0 is nearest, 1 farthest.
        public var focusDepth: Double

        public init(dx: Double, dy: Double, zoom: Double, focusDepth: Double) {
            self.dx = dx
            self.dy = dy
            self.zoom = zoom
            self.focusDepth = focusDepth
        }
    }

    public var preset: DepthMotionPreset
    /// 0...1 scales every amplitude.
    public var intensity: Double
    /// Depth the focus rests at, 0...1.
    public var focusDepth: Double

    public init(preset: DepthMotionPreset, intensity: Double = 0.6, focusDepth: Double = 0.4) {
        self.preset = preset
        self.intensity = (0.0...1.0).clamp(intensity)
        self.focusDepth = (0.0...1.0).clamp(focusDepth)
    }

    /// The camera at time `t` of a loop lasting `duration`. Times outside
    /// 0...duration wrap around.
    public func sample(at t: Seconds, duration: Seconds = DepthMotion.defaultDuration) -> Sample {
        let a = (0.0...1.0).clamp(intensity)
        let base = (0.0...1.0).clamp(focusDepth)
        var phase = 0.0
        if duration > 0, t.isFinite {
            let cycles = t / duration
            phase = cycles - cycles.rounded(.down)
        }
        let theta = 2 * Double.pi * phase
        let m = Self.maxOffset * a
        // Zoom needed so an offset of m never shows the frame edge.
        let cover = 2 * m
        // 0 at the loop start, 1 halfway, back to 0 at the end.
        let wave = (1 - cos(theta)) / 2

        var dx = 0.0, dy = 0.0, zoom = 1 + cover, focus = base
        switch preset {
        case .orbit:
            dx = m * sin(theta)
            dy = m * (cos(theta) - 1) / 2
            focus = base
        case .dolly:
            zoom = 1 + cover + (Self.maxZoom - 2 * Self.maxOffset) * a * wave
            focus = base + Self.maxFocusShift * a * wave
        case .swing:
            dx = m * sin(theta)
            focus = base - Self.maxFocusShift * a * 0.5 * wave
        case .float:
            dx = 0.6 * m * sin(theta)
            dy = 0.5 * m * sin(2 * theta)
            zoom = 1 + cover + 0.02 * a * wave
        }
        return Sample(dx: dx, dy: dy, zoom: zoom, focusDepth: (0.0...1.0).clamp(focus))
    }
}
