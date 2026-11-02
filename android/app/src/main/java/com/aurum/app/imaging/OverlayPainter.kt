package com.aurum.app.imaging

import android.content.Context
import android.graphics.BlendMode as AndroidBlendMode
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.os.Build
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import androidx.core.content.res.ResourcesCompat
import com.aurum.app.R
import com.aurum.core.BlendMode
import com.aurum.core.Overlay
import com.aurum.core.OverlayContent
import com.aurum.core.OverlayFont
import com.aurum.core.StickerOverlay
import com.aurum.core.TextAlignment
import com.aurum.core.TextOverlay
import com.aurum.core.TextStyle
import kotlin.math.ceil

/**
 * Draws text, stickers and the free-tier watermark with the same normalised
 * layout as iOS `OverlayRasterizer`: sizes are authored on a 1080 px wide
 * canvas, positions are fractions of the cropped photo.
 */
class OverlayPainter(private val context: Context) {

    private val typefaces = HashMap<String, Typeface>()
    private val stickers = HashMap<String, Drawable?>()

    fun typefaceFor(fontID: String): Typeface = typefaces.getOrPut(fontID) {
        val def = OverlayFont.font(fontID)
        val res = FONT_RESOURCES[def.resourceName]
        val loaded = res?.let { runCatching { ResourcesCompat.getFont(context, it) }.getOrNull() }
        loaded ?: Typeface.create(
            if (def.fallbackDesign == "serif") Typeface.SERIF else Typeface.SANS_SERIF,
            if (def.isItalic) Typeface.ITALIC else Typeface.NORMAL,
        )
    }

    /** Draws [overlays] (and the watermark, when given) onto a canvas [width] × [height]. */
    fun draw(canvas: Canvas, overlays: List<Overlay>, width: Float, height: Float, watermark: String?) {
        val unit = width / REFERENCE_WIDTH
        for (overlay in overlays) {
            if (overlay.isHidden) continue
            val paint = Paint().apply {
                alpha = (overlay.opacity.coerceIn(0.0, 1.0) * 255).toInt()
                applyBlend(this, overlay.blendMode)
            }
            val save = canvas.saveLayer(null, paint)
            canvas.translate((overlay.center.x * width).toFloat(), (overlay.center.y * height).toFloat())
            canvas.rotate(overlay.rotationDegrees.toFloat())
            val s = overlay.scale.toFloat() * unit
            canvas.scale(s, s)
            when (val c = overlay.content) {
                is OverlayContent.Text -> drawText(canvas, c.text)
                is OverlayContent.Sticker -> drawSticker(canvas, c.sticker)
            }
            canvas.restoreToCount(save)
        }
        if (watermark != null) drawWatermark(canvas, watermark, width, height)
    }

    /** The overlay's untransformed bounds, centred on the origin, in reference units (for hit testing). */
    fun bounds(overlay: Overlay): RectF = when (val c = overlay.content) {
        is OverlayContent.Text -> {
            val layout = layout(c.text, textPaint(c.text))
            RectF(-layout.width / 2f, -layout.height / 2f, layout.width / 2f, layout.height / 2f)
        }
        is OverlayContent.Sticker -> {
            val (w, h) = stickerSize(c.sticker)
            RectF(-w / 2, -h / 2, w / 2, h / 2)
        }
    }

    // ---------------------------------------------------------------- text

    private fun textPaint(text: TextOverlay) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = typefaceFor(text.fontID)
        textSize = text.size.toFloat()
        color = parseColor(text.colorHex)
    }

    private fun layout(text: TextOverlay, paint: TextPaint): StaticLayout {
        val maxWidth = (REFERENCE_WIDTH * 0.9f).toInt()
        val measured = text.text.split('\n').maxOfOrNull { paint.measureText(it) } ?: 0f
        val width = ceil(measured).toInt().coerceIn(1, maxWidth)
        val align = when (text.alignment) {
            TextAlignment.leading -> Layout.Alignment.ALIGN_NORMAL
            TextAlignment.center -> Layout.Alignment.ALIGN_CENTER
            TextAlignment.trailing -> Layout.Alignment.ALIGN_OPPOSITE
        }
        return StaticLayout.Builder.obtain(text.text, 0, text.text.length, paint, width)
            .setAlignment(align)
            .setIncludePad(false)
            .build()
    }

    private fun drawText(canvas: Canvas, text: TextOverlay) {
        val paint = textPaint(text)
        val layout = layout(text, paint)
        val w = layout.width.toFloat()
        val h = layout.height.toFloat()
        val left = -w / 2
        val top = -h / 2
        when (text.style) {
            TextStyle.box -> {
                val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(178, 10, 10, 13) }
                canvas.drawRoundRect(RectF(left - 16, top - 6, left + w + 16, top + h + 6), 6f, 6f, bg)
            }
            TextStyle.shadow -> paint.setShadowLayer(12f, 0f, 2f, Color.argb(140, 0, 0, 0))
            TextStyle.glow -> paint.setShadowLayer(16f, 0f, 0f, Color.argb(230, 245, 227, 191))
            TextStyle.gradient -> paint.shader = LinearGradient(
                left, 0f, left + w, 0f, parseColor("#F4EFE6"), parseColor("#C9A86A"), Shader.TileMode.CLAMP,
            )
            TextStyle.plain, TextStyle.outline -> Unit
        }
        canvas.save()
        canvas.translate(left, top)
        if (text.style == TextStyle.outline) {
            // NSAttributedString stroke width -3 means 3 % of the point size, stroked and filled.
            val fill = paint.color
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = text.size.toFloat() * 0.03f
            paint.strokeJoin = Paint.Join.ROUND
            paint.color = Color.BLACK
            layout.draw(canvas)
            paint.style = Paint.Style.FILL
            paint.color = fill
        }
        layout.draw(canvas)
        canvas.restore()
    }

    // ---------------------------------------------------------------- stickers

    private fun drawable(id: String): Drawable? = stickers.getOrPut(id) {
        STICKER_RESOURCES[id]?.let { ResourcesCompat.getDrawable(context.resources, it, null) }
    }

    private fun stickerSize(sticker: StickerOverlay): Pair<Float, Float> {
        val d = drawable(sticker.stickerID) ?: return STICKER_BASE_WIDTH to STICKER_BASE_WIDTH
        val aspect = d.intrinsicHeight.toFloat() / maxOf(d.intrinsicWidth, 1)
        return STICKER_BASE_WIDTH to STICKER_BASE_WIDTH * aspect
    }

    private fun drawSticker(canvas: Canvas, sticker: StickerOverlay) {
        val base = drawable(sticker.stickerID) ?: return
        val d = base.constantState?.newDrawable(context.resources)?.mutate() ?: base.mutate()
        val (w, h) = stickerSize(sticker)
        if (sticker.tintHex != null) {
            d.setTint(parseColor(sticker.tintHex!!))
            d.setTintMode(PorterDuff.Mode.SRC_IN)
        }
        d.setBounds((-w / 2).toInt(), (-h / 2).toInt(), (w / 2).toInt(), (h / 2).toInt())
        d.draw(canvas)
    }

    // ---------------------------------------------------------------- watermark

    fun drawWatermark(canvas: Canvas, text: String, width: Float, height: Float) {
        val unit = width / REFERENCE_WIDTH
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = typefaceFor("playfair")
            textSize = 26 * unit
            color = parseColor("#F4EFE6")
            alpha = (0.8f * 255).toInt()
            letterSpacing = 6f / 26f // 6 units of kerning, in ems
        }
        val margin = 32 * unit
        val textWidth = paint.measureText(text)
        val fm = paint.fontMetrics
        canvas.drawText(text, width - textWidth - margin, height - margin - fm.descent, paint)
    }

    private fun applyBlend(paint: Paint, mode: BlendMode) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            paint.blendMode = when (mode) {
                BlendMode.normal -> AndroidBlendMode.SRC_OVER
                BlendMode.screen -> AndroidBlendMode.SCREEN
                BlendMode.multiply -> AndroidBlendMode.MULTIPLY
                BlendMode.overlay -> AndroidBlendMode.OVERLAY
                BlendMode.softLight -> AndroidBlendMode.SOFT_LIGHT
                BlendMode.lighten -> AndroidBlendMode.LIGHTEN
                BlendMode.darken -> AndroidBlendMode.DARKEN
            }
        } else {
            val pd = when (mode) {
                BlendMode.normal -> null
                BlendMode.screen -> PorterDuff.Mode.SCREEN
                BlendMode.multiply -> PorterDuff.Mode.MULTIPLY
                // Soft light is not available before Android 10; overlay is the closest.
                BlendMode.overlay, BlendMode.softLight -> PorterDuff.Mode.OVERLAY
                BlendMode.lighten -> PorterDuff.Mode.LIGHTEN
                BlendMode.darken -> PorterDuff.Mode.DARKEN
            }
            paint.xfermode = pd?.let { PorterDuffXfermode(it) }
        }
    }

    companion object {
        const val REFERENCE_WIDTH = 1080f
        const val STICKER_BASE_WIDTH = 360f

        fun parseColor(hex: String): Int {
            val s = hex.trim().removePrefix("#")
            val v = if (s.length == 6) s.toLongOrNull(16) else null
            return if (v == null) Color.MAGENTA else (0xFF000000 or v).toInt()
        }

        /** res/font files copied unmodified from App/Fonts by tools/sync_android_assets.py. */
        val FONT_RESOURCES: Map<String, Int> = mapOf(
            "playfair_display_italic" to R.font.playfair_display_italic,
            "playfair_display_medium" to R.font.playfair_display_medium,
            "cormorant_garamond_medium_italic" to R.font.cormorant_garamond_medium_italic,
            "italiana_regular" to R.font.italiana_regular,
            "bodoni_moda_medium" to R.font.bodoni_moda_medium,
            "inter_medium" to R.font.inter_medium,
        )

        /** VectorDrawables converted from the iOS sticker SVGs. */
        val STICKER_RESOURCES: Map<String, Int> = mapOf(
            "sparkle" to R.drawable.sticker_sparkle,
            "laurel" to R.drawable.sticker_laurel,
            "bow" to R.drawable.sticker_bow,
            "heart-line" to R.drawable.sticker_heart_line,
            "pearls" to R.drawable.sticker_pearls,
            "monogram" to R.drawable.sticker_monogram,
            "oval-frame" to R.drawable.sticker_oval_frame,
            "gallery-frame" to R.drawable.sticker_gallery_frame,
            "crescent" to R.drawable.sticker_crescent,
            "sunburst" to R.drawable.sticker_sunburst,
            "constellation" to R.drawable.sticker_constellation,
            "envelope" to R.drawable.sticker_envelope,
            "wax-seal" to R.drawable.sticker_wax_seal,
            "snowflake" to R.drawable.sticker_snowflake,
            "holly" to R.drawable.sticker_holly,
        )
    }
}
