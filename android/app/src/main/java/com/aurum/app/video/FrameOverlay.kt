package com.aurum.app.video

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import com.aurum.app.imaging.OverlayPainter
import com.aurum.core.BookendEffect
import com.aurum.core.LayerAnimator
import com.aurum.core.NormalizedPoint
import com.aurum.core.Overlay
import com.aurum.core.OverlayContent
import com.aurum.core.TextOverlay
import com.aurum.core.TextStyle
import com.aurum.core.VideoProject
import kotlin.math.max
import kotlin.math.min

/**
 * Intro and outro cards (iOS `BookendRenderer`): an onyx card with the
 * title, or the brand name on an outro, and a champagne rule that draws
 * across, fading in at the start of an outro and out at the end of an intro.
 */
class BookendPainter(private val painter: OverlayPainter, private val brandName: String) {
    fun draw(canvas: Canvas, bookend: BookendEffect, isIntro: Boolean, progress: Double, width: Float, height: Float) {
        val p = progress.coerceIn(0.0, 1.0)
        val alpha = if (isIntro) min(1.0, (1 - p) * 4) else min(1.0, p * 4)
        val save = canvas.saveLayerAlpha(0f, 0f, width, height, (alpha * 255).toInt().coerceIn(0, 255))
        canvas.drawColor(Color.rgb(11, 11, 12))
        val title = bookend.title ?: if (isIntro) "" else brandName
        if (title.isNotEmpty()) {
            var text = TextOverlay(text = title, fontID = "playfair.italic", size = 88.0, colorHex = "#F4EFE6", style = TextStyle.plain)
            if (bookend.presetID == "spotlight" || bookend.presetID == "fireworks") text = text.copy(style = TextStyle.glow)
            val rise = (1 - min(1.0, p * 2)) * 0.02
            painter.draw(canvas, listOf(Overlay(content = OverlayContent.Text(text), center = NormalizedPoint(0.5, 0.5 + rise))), width, height, null)
        }
        val ruleProgress = if (isIntro) p else 1 - p
        val ruleWidth = width * 0.4f * min(1.0, ruleProgress * 1.5).toFloat()
        if (ruleWidth > 1) {
            val h = max(1f, width / 540f)
            val top = height * 0.56f - h
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(201, 168, 106) }
            canvas.drawRect((width - ruleWidth) / 2, top, (width + ruleWidth) / 2, top + h, paint)
        }
        canvas.restoreToCount(save)
    }

    companion object {
        /** The card on screen at [t], with its progress, or null. */
        fun at(project: VideoProject, t: Double): Triple<BookendEffect, Boolean, Double>? {
            val intro = project.intro
            if (intro != null && t < intro.duration) return Triple(intro, true, t / max(intro.duration, 0.01))
            val outro = project.outro ?: return null
            val start = project.duration - outro.duration
            return if (t >= start) Triple(outro, false, (t - start) / max(outro.duration, 0.01)) else null
        }
    }
}

/**
 * Everything drawn above the graded picture: intro and outro cards, timed
 * text and sticker layers with their animation, and the free-tier mark.
 * One full-frame bitmap, redrawn only when what it shows changes (the iOS
 * compositor caches its layer image the same way).
 */
@UnstableApi
class FrameOverlay(
    private val project: VideoProject,
    private val width: Int,
    private val height: Int,
    private val painter: OverlayPainter,
    private val bookends: BookendPainter,
    private val watermark: String?,
    private val drawBookends: Boolean = true,
) : BitmapOverlay() {
    private val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    private val canvas = Canvas(bitmap)
    private var lastKey: String? = null

    override fun getBitmap(presentationTimeUs: Long): Bitmap {
        val t = presentationTimeUs / 1_000_000.0
        val card = if (drawBookends) BookendPainter.at(project, t) else null
        val layers = LayerAnimator.overlays(project, t)
        val key = buildString {
            if (card != null) append(if (card.second) "i" else "o").append((card.third * 240).toInt()).append('|')
            for (o in layers) {
                append(o.id).append(':').append((o.opacity * 100).toInt()).append(':')
                append((o.center.y * 1000).toInt()).append(':').append((o.scale * 100).toInt()).append(':')
                append(o.content.hashCode()).append('|')
            }
        }
        if (key != lastKey) {
            lastKey = key
            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
            val w = width.toFloat()
            val h = height.toFloat()
            card?.let { bookends.draw(canvas, it.first, it.second, it.third, w, h) }
            painter.draw(canvas, layers, w, h, watermark)
        }
        return bitmap
    }

    companion object {
        fun isNeeded(project: VideoProject, watermark: String?, drawBookends: Boolean) =
            watermark != null || project.layers.isNotEmpty() || (drawBookends && (project.intro != null || project.outro != null))
    }
}
