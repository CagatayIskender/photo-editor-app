package com.aurum.app.video

import android.content.Context
import android.graphics.BitmapFactory
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import com.aurum.core.AnimatedEffect
import com.aurum.core.Clip
import com.aurum.core.StillMotion
import com.aurum.core.Transition
import com.aurum.core.VideoProject
import com.aurum.core.VideoRenderPlan
import com.aurum.core.render.VideoGrade
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.pow

/**
 * Everything the iOS `AurumVideoCompositor` draws before layers, for one
 * frame, in a single GPU pass: the still's push-in, the transition from the
 * outgoing clip (its last frame, prepared on the CPU), the look grade (a baked
 * lookup table plus vignette, light leak, grain and a bloom approximation),
 * then the animated effects (flicker, light leak, glitter, tape tracking,
 * handheld and pulse). Intro and outro cards pass through untouched.
 *
 * Applied as a composition effect, so frame timestamps are timeline time.
 */
@UnstableApi
class AurumFrameEffect(
    private val project: VideoProject,
    private val grade: VideoGrade,
    /** Prepared last frames of outgoing clips, by incoming clip index, at the render size. */
    private val outgoingFrames: Map<Int, File>,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        AurumFrameShaderProgram(project, grade, outgoingFrames, useHdr)
}

@UnstableApi
internal class AurumFrameShaderProgram(
    private val project: VideoProject,
    private val grade: VideoGrade,
    private val outgoingFrames: Map<Int, File>,
    useHdr: Boolean,
) : BaseGlShaderProgram(useHdr, 1) {

    private val program: GlProgram
    private val windows = VideoRenderPlan.transitions(project)
    private var width = 1
    private var height = 1
    private var lutTexture = 0
    private var outgoingTexture = 0
    private var outgoingIndex = -1

    init {
        try {
            program = GlProgram(VERTEX, FRAGMENT)
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e)
        }
        program.setBufferAttribute("aFramePosition", GlUtil.getNormalizedCoordinateBounds(), GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE)
    }

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        width = inputWidth
        height = inputHeight
        return Size(inputWidth, inputHeight)
    }

    private fun f(name: String, vararg v: Float) = program.setFloatsUniformIfPresent(name, v)

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            val t = presentationTimeUs / 1_000_000.0
            program.use()
            program.setSamplerTexIdUniform("uTex", inputTexId, 0)
            f("uSize", width.toFloat(), height.toFloat())
            val scale = max(width, height) / 1080f
            f("uScale", scale)

            if (VideoRenderPlan.isBookend(project, t)) {
                f("uBypass", 1f)
                program.setSamplerTexIdUniform("uOutgoing", inputTexId, 1)
                program.setSamplerTexIdUniform("uLut", inputTexId, 2)
                program.bindAttributesAndUniforms()
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                return
            }
            f("uBypass", 0f)

            // Still motion and transition.
            var motion = 1f
            var transition = 0f
            var progress = 0f
            var outMotion = 1f
            var outgoingTex = inputTexId
            project.clipAt(t)?.let { (index, local) ->
                val clip = project.clips[index]
                if (clip.kind == Clip.Kind.photo) motion = pushIn(local, clip).toFloat()
                val w = windows.firstOrNull { it.clipIndex == index && local < it.duration }
                val tex = w?.let { outgoing(index) }
                if (w != null && tex != null) {
                    outgoingTex = tex
                    progress = (local / w.duration).coerceIn(0.0, 1.0).toFloat()
                    transition = when (w.transition) {
                        is Transition.Dissolve -> 1f
                        is Transition.DipToBlack -> 2f
                        is Transition.Slide -> 3f
                        is Transition.Zoom -> 4f
                        Transition.Cut -> 0f
                    }
                    val previous = project.clips[index - 1]
                    if (previous.kind == Clip.Kind.photo) {
                        outMotion = (pushIn(w.outgoingLocal + local, previous) / pushIn(w.outgoingLocal, previous)).toFloat()
                    }
                }
            }
            f("uMotion", motion)
            f("uTransition", transition)
            f("uProgress", progress)
            f("uOutMotion", outMotion)
            program.setSamplerTexIdUniform("uOutgoing", outgoingTex, 1)

            // Grade.
            val lut = lutTexture()
            program.setSamplerTexIdUniform("uLut", if (lut != 0) lut else inputTexId, 2)
            f("uHasLut", if (lut != 0) 1f else 0f)
            f("uLutSize", grade.lutSize.toFloat())
            f("uBloom", grade.bloom.toFloat())
            f("uLeak", grade.lightLeak.coerceAtMost(1.0).toFloat())
            f("uVignette", grade.vignette.toFloat())
            f("uGrain", (grade.grain.coerceAtMost(1.0) * 0.35).toFloat())
            f("uGrainCell", (scale * grade.grainSize.coerceIn(0.5, 2.0)).toFloat().coerceAtLeast(1f))
            val seed = seedOf(project)
            f("uGrainOffset", (seed % 4096).toFloat(), ((seed shr 12) % 4096).toFloat())

            setEffects(t, scale)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e, presentationTimeUs)
        }
    }

    private fun pushIn(local: Double, clip: Clip): Double =
        StillMotion.pushIn.transform(local / max(clip.duration, 0.01)).first

    /** Samples every active effect at [t] and sets the shader's effect uniforms. */
    private fun setEffects(t: Double, scale: Float) {
        var exposure = 1.0
        var leak = 0.0
        var leakPos = 0.5
        var glitter = 0.0
        var glitterSeed = 1uL
        var tracking = 0.0
        var trackingSeed = 1uL
        var offX = 0.0
        var offY = 0.0
        var zoom = 1.0
        for (effect in project.effects) {
            if (!effect.isActive(t) || effect.intensity <= 0) continue
            val s = effect.sample(t)
            exposure *= s.exposure
            if (s.leak > leak) { leak = s.leak; leakPos = s.leakPosition }
            if (s.glitter > glitter) { glitter = s.glitter; glitterSeed = effect.seed }
            if (s.tracking > tracking) { tracking = s.tracking; trackingSeed = effect.seed }
            offX += s.offsetX
            offY += s.offsetY
            zoom *= s.zoom
        }
        f("uExposure", exposure.toFloat())
        f("uFxLeak", (leak.coerceAtMost(1.0) * 0.6).toFloat())
        f("uFxLeakPos", leakPos.coerceIn(0.0, 1.0).toFloat())

        f("uGlitter", (glitter.coerceAtMost(1.0) * 0.8).toFloat())
        val frame12 = floor(t * 12).toLong()
        val gh = hash(frame12, glitterSeed)
        f("uGlitterSeed", (gh % 4096uL).toFloat(), ((gh shr 16) % 4096uL).toFloat(), ((gh shr 32) % 997uL).toFloat())

        // Tape tracking: two or three bands slip sideways; red and blue split.
        val a = tracking.coerceAtMost(1.0)
        val bands = Array(3) { floatArrayOf(0f, 0f, 0f) }
        if (a > 0) {
            val frame = floor(t * 24).toLong()
            val count = 2 + (hash(frame, trackingSeed + 3uL) % 2uL).toInt()
            for (i in 0 until count) {
                val salt = trackingSeed + i.toULong() * 0x632BE59BD9B4E019uL
                val u1 = unit(hash(frame, salt + 11uL))
                val u2 = unit(hash(frame, salt + 23uL))
                val u3 = unit(hash(frame, salt + 37uL))
                val bandHeight = 0.02 + 0.07 * u2
                val y = u1 * (1 - bandHeight)
                val direction = if (i % 2 == 0) 1 else -1
                val dx = a * (0.015 + 0.035 * u3) * direction
                bands[i] = floatArrayOf(y.toFloat(), (y + bandHeight).toFloat(), dx.toFloat())
            }
        }
        f("uTracking", a.toFloat())
        f("uBand0", *bands[0])
        f("uBand1", *bands[1])
        f("uBand2", *bands[2])
        f("uChroma", (a * 4 * scale / width).toFloat())

        val minimumZoom = 1 + max(abs(offX), abs(offY)) * 2
        f("uCamera", offX.toFloat(), offY.toFloat(), maxOf(zoom, minimumZoom, 1.0).toFloat())
    }

    private fun lutTexture(): Int {
        val data = grade.lut ?: return 0
        if (lutTexture != 0) return lutTexture
        val n = grade.lutSize
        val bytes = ByteBuffer.allocateDirect(n * n * n * 4).order(ByteOrder.nativeOrder())
        // Row g holds every blue slice side by side: texel (b * n + r, g).
        for (g in 0 until n) for (b in 0 until n) for (r in 0 until n) {
            val i = ((b * n + g) * n + r) * 3
            bytes.put((data[i] * 255f + 0.5f).toInt().coerceIn(0, 255).toByte())
            bytes.put((data[i + 1] * 255f + 0.5f).toInt().coerceIn(0, 255).toByte())
            bytes.put((data[i + 2] * 255f + 0.5f).toInt().coerceIn(0, 255).toByte())
            bytes.put(255.toByte())
        }
        bytes.position(0)
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ids[0])
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, n * n, n, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, bytes)
        GlUtil.checkGlError()
        lutTexture = ids[0]
        return lutTexture
    }

    /** The outgoing frame for the transition into [index], uploaded once per transition. */
    private fun outgoing(index: Int): Int? {
        if (outgoingIndex == index && outgoingTexture != 0) return outgoingTexture
        val file = outgoingFrames[index] ?: return null
        val bitmap = BitmapFactory.decodeFile(file.absolutePath) ?: return null
        if (outgoingTexture != 0) GlUtil.deleteTexture(outgoingTexture)
        outgoingTexture = GlUtil.createTexture(bitmap)
        outgoingIndex = index
        bitmap.recycle()
        return outgoingTexture
    }

    override fun release() {
        super.release()
        try {
            program.delete()
            if (lutTexture != 0) GlUtil.deleteTexture(lutTexture)
            if (outgoingTexture != 0) GlUtil.deleteTexture(outgoingTexture)
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e)
        }
    }

    companion object {
        /** SplitMix64-style hash of a frame number and seed (iOS `EffectRenderer.hash`). */
        fun hash(n: Long, seed: ULong): ULong {
            var h = (n.toULong() * 0x9E3779B97F4A7C15uL) xor seed
            h = h xor (h shr 31)
            h *= 0xBF58476D1CE4E5B9uL
            h = h xor (h shr 29)
            h *= 0x94D049BB133111EBuL
            h = h xor (h shr 32)
            return h
        }

        fun unit(h: ULong): Double = (h shr 11).toDouble() / (1uL shl 53).toDouble()

        private fun seedOf(project: VideoProject): Long =
            com.aurum.core.render.PixelRenderer.seed(project.id).let { if (it < 0) -it else it }.coerceAtLeast(0)

        private const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTexCoord;
void main() {
  gl_Position = aFramePosition;
  vTexCoord = aFramePosition.xy * 0.5 + 0.5;
}
"""

        // GL texture space: origin bottom left. Bitmaps uploaded from Android
        // (the outgoing frame) are top-down, so they are sampled flipped.
        private const val FRAGMENT = """
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 vTexCoord;
uniform sampler2D uTex;
uniform sampler2D uOutgoing;
uniform sampler2D uLut;
uniform vec2 uSize;
uniform float uScale;
uniform float uBypass;
uniform float uMotion;
uniform float uTransition;
uniform float uProgress;
uniform float uOutMotion;
uniform float uHasLut;
uniform float uLutSize;
uniform float uBloom;
uniform float uLeak;
uniform float uVignette;
uniform float uGrain;
uniform float uGrainCell;
uniform vec2 uGrainOffset;
uniform float uExposure;
uniform float uFxLeak;
uniform float uFxLeakPos;
uniform float uGlitter;
uniform vec3 uGlitterSeed;
uniform float uTracking;
uniform vec3 uBand0;
uniform vec3 uBand1;
uniform vec3 uBand2;
uniform float uChroma;
uniform vec3 uCamera;

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

vec3 incoming(vec2 uv) {
  vec2 q = 0.5 + (uv - 0.5) / uMotion;
  return texture2D(uTex, clamp(q, 0.0, 1.0)).rgb;
}

vec3 outgoing(vec2 uv) {
  vec2 q = clamp(0.5 + (uv - 0.5) / uOutMotion, 0.0, 1.0);
  return texture2D(uOutgoing, vec2(q.x, 1.0 - q.y)).rgb;
}

vec3 picture(vec2 uv) {
  float p = uProgress;
  if (uTransition < 0.5) return incoming(uv);
  if (uTransition < 1.5) return mix(outgoing(uv), incoming(uv), p);
  if (uTransition < 2.5) {
    if (p < 0.5) return mix(outgoing(uv), vec3(0.0), p * 2.0);
    return mix(vec3(0.0), incoming(uv), (p - 0.5) * 2.0);
  }
  if (uTransition < 3.5) {
    float e = p * p * (3.0 - 2.0 * p);
    if (uv.x >= 1.0 - e) return incoming(vec2(uv.x - (1.0 - e), uv.y));
    return outgoing(vec2(uv.x + e, uv.y));
  }
  float s = 1.0 + 0.25 * p;
  return mix(outgoing(0.5 + (uv - 0.5) / s), incoming(uv), p);
}

vec3 lut(vec3 c) {
  float n = uLutSize;
  vec3 s = clamp(c, 0.0, 1.0) * (n - 1.0);
  float b0 = floor(s.b);
  float b1 = min(b0 + 1.0, n - 1.0);
  vec2 rg = s.rg + 0.5;
  vec3 c0 = texture2D(uLut, vec2((b0 * n + rg.x) / (n * n), rg.y / n)).rgb;
  vec3 c1 = texture2D(uLut, vec2((b1 * n + rg.x) / (n * n), rg.y / n)).rgb;
  return mix(c0, c1, s.b - b0);
}

vec3 screen(vec3 a, vec3 b) { return 1.0 - (1.0 - a) * (1.0 - b); }

float softLight(float b, float s) {
  if (s <= 0.5) return b - (1.0 - 2.0 * s) * b * (1.0 - b);
  float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
  return b + (2.0 * s - 1.0) * (d - b);
}

vec3 graded(vec2 uv) {
  vec3 c = picture(uv);
  if (uHasLut > 0.5) c = lut(c);
  vec2 px = vec2(uv.x, 1.0 - uv.y) * uSize;
  if (uBloom > 0.0) {
    float l = dot(c, vec3(0.2125, 0.7154, 0.0721));
    c = screen(c, vec3(clamp(max(0.0, (l - 0.55) / 0.45) * uBloom * 0.5, 0.0, 1.0)));
  }
  if (uLeak > 0.0) {
    float radius = max(uSize.x, uSize.y) * 0.75;
    float t = clamp(length(vec2(uSize.x - px.x, px.y)) / radius, 0.0, 1.0);
    float a = uLeak * 0.75 * (1.0 - t);
    c = screen(c, vec3(1.0, 0.55 - 0.15 * t, 0.25 - 0.05 * t) * a);
  }
  if (uVignette != 0.0) {
    float radius = length(uSize) * 0.42;
    float e = smoothstep(radius * 0.4, radius * 1.6, length(px - uSize * 0.5));
    if (uVignette > 0.0) c *= max(0.0, 1.0 - uVignette * e);
    else c += (1.0 - c) * (-uVignette * e);
  }
  if (uGrain > 0.0) {
    vec2 cell = floor(px / uGrainCell) + uGrainOffset;
    float m = 0.5 - uGrain / 2.0 + uGrain * hash12(cell);
    c = vec3(softLight(c.r, m), softLight(c.g, m), softLight(c.b, m));
  }
  return clamp(c, 0.0, 1.0);
}

float slip(vec3 band, float y, float x) {
  if (band.z != 0.0 && y >= band.x && y < band.y) return x - band.z;
  return x;
}

vec3 sparkle(vec2 px) {
  float g = 12.0 * uScale;
  vec2 cell = floor(px / g);
  float density = 0.08 + 0.10 * uGlitter;
  float total = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 c = cell + vec2(float(i), float(j));
      vec2 k = c + uGlitterSeed.xy;
      if (hash12(k) < 1.0 - density) continue;
      vec2 pos = (c + vec2(hash12(k + 17.1), hash12(k + 31.7))) * g;
      float v = hash12(k + uGlitterSeed.z + 5.3);
      vec2 d = px - pos;
      float r2 = dot(d, d);
      float s = uScale;
      float core = exp(-r2 / (2.0 * 0.64 * s * s));
      float glow = 0.6 * exp(-r2 / (8.0 * s * s));
      float sx = exp(-d.y * d.y / (0.72 * s * s)) * max(0.0, 1.0 - abs(d.x) / (5.0 * s));
      float sy = exp(-d.x * d.x / (0.72 * s * s)) * max(0.0, 1.0 - abs(d.y) / (5.0 * s));
      total += v * (core + glow + 0.5 * (sx + sy));
    }
  }
  return vec3(0.957, 0.890, 0.749) * min(total, 1.0);
}

void main() {
  vec2 uv = vTexCoord;
  if (uBypass > 0.5) {
    gl_FragColor = texture2D(uTex, uv);
    return;
  }
  // Handheld and pulse: zoom about the centre, then shift (offsets are y down).
  vec2 down = vec2(uv.x, 1.0 - uv.y);
  down = 0.5 + (down - 0.5 - uCamera.xy) / uCamera.z;
  vec2 p = vec2(down.x, 1.0 - down.y);

  vec3 c;
  if (uTracking > 0.0) {
    float x = p.x;
    x = slip(uBand2, p.y, x);
    x = slip(uBand1, p.y, x);
    x = slip(uBand0, p.y, x);
    vec2 q = vec2(x, p.y);
    float r = graded(clamp(q - vec2(uChroma, 0.0), 0.0, 1.0)).r;
    vec3 mid = graded(clamp(q, 0.0, 1.0));
    float b = graded(clamp(q + vec2(uChroma, 0.0), 0.0, 1.0)).b;
    c = vec3(max(r, 0.0), mid.g, max(b, 0.0));
  } else {
    c = graded(clamp(p, 0.0, 1.0));
  }

  vec2 px = vec2(uv.x, 1.0 - uv.y) * uSize;
  if (uExposure != 1.0) c = pow(pow(c, vec3(2.2)) * uExposure, vec3(1.0 / 2.2));
  if (uFxLeak > 0.0) {
    vec2 centre = vec2(uFxLeakPos * uSize.x, uSize.y * 0.04);
    float radius = uSize.x * 0.8;
    float d = length(px - centre);
    float tr = clamp((d - 0.15 * radius) / (0.85 * radius), 0.0, 1.0);
    float roseA = uFxLeak * 0.7 * (1.0 - tr);
    float ta = clamp(d / (0.55 * radius), 0.0, 1.0);
    float amberA = uFxLeak * (1.0 - ta);
    vec3 amber = mix(vec3(1.0, 0.66, 0.3), vec3(1.0, 0.55, 0.35), ta) * amberA;
    vec3 leak = amber + vec3(1.0, 0.42, 0.5) * roseA * (1.0 - amberA);
    c = screen(c, clamp(leak, 0.0, 1.0));
  }
  if (uGlitter > 0.0) c = screen(c, sparkle(px) * uGlitter);
  gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
"""
    }
}
