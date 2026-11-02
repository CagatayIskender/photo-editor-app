package com.aurum.core

import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Estimates tempo and the first beat from mono samples: onset envelope,
 * autocorrelation over 60–180 BPM, then the best phase. Same method as iOS.
 */
object BeatDetector {
    private const val FRAME_RATE = 100.0

    fun detect(samples: FloatArray, sampleRate: Double): BeatGrid? {
        val envelope = onsetEnvelope(samples, sampleRate)
        if (envelope.size <= (FRAME_RATE * 4).toInt()) return null

        val minLag = (FRAME_RATE * 60 / 180).toInt()
        val maxLag = (FRAME_RATE * 60 / 60).toInt()
        var bestLag = 0
        var bestScore = Double.NEGATIVE_INFINITY
        for (lag in minLag..maxLag) {
            var sum = 0.0
            for (i in lag until envelope.size) sum += envelope[i] * envelope[i - lag]
            val bpm = 60 * FRAME_RATE / lag
            val preference = exp(-(log2(bpm / 110)).pow(2) / 0.5)
            val score = sum / (envelope.size - lag) * (0.6 + 0.4 * preference)
            if (score > bestScore) {
                bestScore = score
                bestLag = lag
            }
        }
        if (bestLag <= 0 || bestScore <= 0) return null

        val lag = refinedLag(bestLag, envelope, minLag, maxLag)
        val bpm = 60 * FRAME_RATE / lag

        var bestPhase = 0
        var bestPhaseScore = Double.NEGATIVE_INFINITY
        for (phase in 0 until bestLag) {
            var sum = 0.0
            var t = phase.toDouble()
            while (t.toInt() < envelope.size) {
                sum += envelope[t.toInt()]
                t += lag
            }
            if (sum > bestPhaseScore) {
                bestPhaseScore = sum
                bestPhase = phase
            }
        }
        return BeatGrid.of(bpm, bestPhase / FRAME_RATE)
    }

    private fun log2(x: Double) = ln(x) / ln(2.0)

    internal fun onsetEnvelope(samples: FloatArray, sampleRate: Double): DoubleArray {
        val hop = max(1, (sampleRate / FRAME_RATE).toInt())
        val window = hop * 2
        if (samples.size <= window) return DoubleArray(0)
        val energies = ArrayList<Double>(samples.size / hop)
        var start = 0
        while (start + window <= samples.size) {
            var e = 0.0
            for (i in start until start + window) {
                val s = samples[i].toDouble()
                e += s * s
            }
            energies.add(ln(1 + 1000 * e / window))
            start += hop
        }
        val onset = DoubleArray(energies.size)
        for (i in 1 until energies.size) onset[i] = max(0.0, energies[i] - energies[i - 1])
        val peak = onset.maxOrNull() ?: 0.0
        if (peak > 0) for (i in onset.indices) onset[i] /= peak
        return onset
    }

    private fun refinedLag(lag: Int, envelope: DoubleArray, minLag: Int, maxLag: Int): Double {
        fun score(l: Int): Double {
            var sum = 0.0
            for (i in l until envelope.size) sum += envelope[i] * envelope[i - l]
            return sum / (envelope.size - l)
        }
        if (lag <= minLag || lag >= maxLag) return lag.toDouble()
        val a = score(lag - 1)
        val b = score(lag)
        val c = score(lag + 1)
        val denom = a - 2 * b + c
        if (denom == 0.0) return lag.toDouble()
        val shift = 0.5 * (a - c) / denom
        return lag + max(-0.5, min(0.5, shift))
    }
}
