package com.aurum.core.render

import com.aurum.core.EditOperation
import com.aurum.core.LookCatalog
import com.aurum.core.OperationKind
import kotlin.math.max

/**
 * A video's look stack, flattened for a GPU shader: every colour step of
 * every enabled operation baked into one RGB lookup table (intensity mixed in
 * per operation, as [PixelRenderer] does), plus the summed spatial amounts
 * (bloom, light leak, vignette, grain) that the shader draws analytically.
 *
 * The iOS compositor runs the photo `FilterGraph` on every frame; this is the
 * same colour maths, with the spatial steps moved after the colour steps.
 */
class VideoGrade(
    /** Edge length of the cube. */
    val lutSize: Int,
    /** RGB triples, red fastest: index ((b * n + g) * n + r) * 3. Null when no colour step applies. */
    val lut: FloatArray?,
    val bloom: Double,
    val lightLeak: Double,
    val vignette: Double,
    val grain: Double,
    val grainSize: Double,
) {
    val isIdentity: Boolean get() = lut == null && bloom <= 0 && lightLeak <= 0 && vignette == 0.0 && grain <= 0

    companion object {
        val identity = VideoGrade(0, null, 0.0, 0.0, 0.0, 0.0, 1.0)

        fun of(operations: List<EditOperation>, catalog: LookCatalog, size: Int = 33): VideoGrade {
            val renderer = PixelRenderer(catalog)
            val steps = mutableListOf<Pair<Double, (Double, Double, Double) -> DoubleArray>>()
            var bloom = 0.0
            var leak = 0.0
            var vignette = 0.0
            var grain = 0.0
            var grainSize = 1.0
            for (op in operations) {
                if (!op.isEnabled) continue
                when (val k = op.kind) {
                    is OperationKind.Look -> {
                        val application = k.look
                        if (application.intensity <= 0) continue
                        val recipe = catalog.look(application.lookID) ?: continue
                        val p = recipe.params.applying(application.refine)
                        val amount = application.intensity.coerceIn(0.0, 1.0)
                        steps.add(amount to { r, g, b -> renderer.lookColour(p, r, g, b) })
                        bloom += p.bloom * amount
                        leak += p.lightLeak * amount
                        vignette += p.vignette * amount
                        if (p.grain * amount > grain) {
                            grain = p.grain * amount
                            grainSize = p.grainSize
                        }
                    }
                    is OperationKind.Adjust -> {
                        val a = k.adjust
                        if (a.isNeutral) continue
                        steps.add(1.0 to { r, g, b -> renderer.adjustColour(a, r, g, b) })
                        vignette += a.vignette
                        if (a.grain > grain) {
                            grain = a.grain
                            grainSize = 1.0
                        }
                    }
                    is OperationKind.Retouch -> Unit
                }
            }
            val lut = if (steps.isEmpty()) null else bake(size, steps)
            return VideoGrade(if (lut == null) 0 else size, lut, bloom, leak, vignette.coerceIn(-1.0, 1.0), grain, max(0.5, grainSize))
        }

        private fun bake(n: Int, steps: List<Pair<Double, (Double, Double, Double) -> DoubleArray>>): FloatArray {
            val out = FloatArray(n * n * n * 3)
            val d = (n - 1).toDouble()
            var i = 0
            for (b in 0 until n) for (g in 0 until n) for (r in 0 until n) {
                var c = doubleArrayOf(r / d, g / d, b / d)
                for ((k, f) in steps) {
                    val graded = f(c[0], c[1], c[2])
                    c = doubleArrayOf(
                        c[0] + (graded[0] - c[0]) * k,
                        c[1] + (graded[1] - c[1]) * k,
                        c[2] + (graded[2] - c[2]) * k,
                    )
                }
                out[i++] = c[0].coerceIn(0.0, 1.0).toFloat()
                out[i++] = c[1].coerceIn(0.0, 1.0).toFloat()
                out[i++] = c[2].coerceIn(0.0, 1.0).toFloat()
            }
            return out
        }
    }
}
