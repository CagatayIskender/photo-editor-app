import Foundation

/// Estimates tempo and the first beat from mono audio samples.
///
/// Method: an onset-strength envelope (positive change in short-window
/// energy), then autocorrelation over 60–180 BPM to pick the tempo, then the
/// phase with the most onset energy on the beat. It is simple and robust for
/// the steady-tempo music used in templates. It runs on device in a fraction
/// of a second for a three-minute track at 11 kHz.
public enum BeatDetector {
    /// Envelope frames per second.
    static let frameRate = 100.0

    public static func detect(samples: [Float], sampleRate: Double) -> BeatGrid? {
        let envelope = onsetEnvelope(samples: samples, sampleRate: sampleRate)
        guard envelope.count > Int(frameRate * 4) else { return nil }

        // Tempo: autocorrelation peak between 60 and 180 BPM, with a mild
        // preference for the 90–130 BPM range where most pop music sits.
        let minLag = Int(frameRate * 60 / 180)
        let maxLag = Int(frameRate * 60 / 60)
        var bestLag = 0
        var bestScore = -Double.infinity
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in lag..<envelope.count { sum += envelope[i] * envelope[i - lag] }
            let bpm = 60 * frameRate / Double(lag)
            let preference = exp(-pow(log2(bpm / 110), 2) / 0.5)
            let score = sum / Double(envelope.count - lag) * (0.6 + 0.4 * preference)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestLag > 0, bestScore > 0 else { return nil }

        // Refine to sub-frame precision with a parabola through the peak.
        let lag = refinedLag(bestLag, envelope: envelope, minLag: minLag, maxLag: maxLag)
        let bpm = 60 * frameRate / lag

        // Phase: the offset whose beat positions collect the most onset energy.
        var bestPhase = 0
        var bestPhaseScore = -Double.infinity
        for phase in 0..<bestLag {
            var sum = 0.0
            var t = Double(phase)
            while Int(t) < envelope.count {
                sum += envelope[Int(t)]
                t += lag
            }
            if sum > bestPhaseScore {
                bestPhaseScore = sum
                bestPhase = phase
            }
        }
        return BeatGrid(bpm: bpm, offset: Double(bestPhase) / frameRate)
    }

    /// Positive energy change per 10 ms frame, normalised to 0...1.
    static func onsetEnvelope(samples: [Float], sampleRate: Double) -> [Double] {
        let hop = max(1, Int(sampleRate / frameRate))
        let window = hop * 2
        guard samples.count > window else { return [] }
        var energies: [Double] = []
        energies.reserveCapacity(samples.count / hop)
        var start = 0
        while start + window <= samples.count {
            var e = 0.0
            for i in start..<(start + window) {
                let s = Double(samples[i])
                e += s * s
            }
            energies.append(log(1 + 1000 * e / Double(window)))
            start += hop
        }
        var onset = [Double](repeating: 0, count: energies.count)
        for i in 1..<energies.count { onset[i] = max(0, energies[i] - energies[i - 1]) }
        let peak = onset.max() ?? 0
        return peak > 0 ? onset.map { $0 / peak } : onset
    }

    static func refinedLag(_ lag: Int, envelope: [Double], minLag: Int, maxLag: Int) -> Double {
        func score(_ l: Int) -> Double {
            var sum = 0.0
            for i in l..<envelope.count { sum += envelope[i] * envelope[i - l] }
            return sum / Double(envelope.count - l)
        }
        guard lag > minLag, lag < maxLag else { return Double(lag) }
        let a = score(lag - 1), b = score(lag), c = score(lag + 1)
        let denom = a - 2 * b + c
        guard denom != 0 else { return Double(lag) }
        let shift = 0.5 * (a - c) / denom
        return Double(lag) + max(-0.5, min(0.5, shift))
    }
}
