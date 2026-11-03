package com.aurum.core

import kotlin.math.max
import kotlin.math.min

/**
 * Where a photo sits inside a collage cell. Shared by the on-screen editor and
 * the renderer, so what the user frames is what exports. Port of iOS
 * `CollageCellGeometry`. All sizes are in the same unit (points or pixels).
 */
object CollageCellGeometry {
    /** An image frame in cell coordinates, top-left origin. */
    data class Frame(val x: Double, val y: Double, val width: Double, val height: Double) {
        val maxX: Double get() = x + width
        val maxY: Double get() = y + height
        val midX: Double get() = x + width / 2
        val midY: Double get() = y + height / 2
    }

    /** Scale from image pixels to cell units (aspect fill, times zoom). */
    fun scale(cellW: Double, cellH: Double, imageW: Double, imageH: Double, zoom: Double): Double {
        if (imageW <= 0 || imageH <= 0) return 1.0
        return max(cellW / imageW, cellH / imageH) * max(1.0, zoom)
    }

    /** The centre clamped so the image always covers the cell. */
    fun clampedCenter(center: NormalizedPoint, cellW: Double, cellH: Double, imageW: Double, imageH: Double, zoom: Double): NormalizedPoint {
        val s = scale(cellW, cellH, imageW, imageH, zoom)
        if (imageW <= 0 || imageH <= 0 || s <= 0) return center
        val hx = cellW / s / imageW / 2
        val hy = cellH / s / imageH / 2
        return NormalizedPoint(min(max(center.x, hx), 1 - hx), min(max(center.y, hy), 1 - hy))
    }

    /** The image's frame in cell coordinates (top-left origin). */
    fun imageFrame(cellW: Double, cellH: Double, imageW: Double, imageH: Double, zoom: Double, center: NormalizedPoint): Frame {
        val s = scale(cellW, cellH, imageW, imageH, zoom)
        val c = clampedCenter(center, cellW, cellH, imageW, imageH, zoom)
        val w = imageW * s
        val h = imageH * s
        return Frame(cellW / 2 - c.x * w, cellH / 2 - c.y * h, w, h)
    }

    /** The centre after dragging the photo by (dx, dy) cell units. */
    fun panned(center: NormalizedPoint, dx: Double, dy: Double, cellW: Double, cellH: Double, imageW: Double, imageH: Double, zoom: Double): NormalizedPoint {
        val s = scale(cellW, cellH, imageW, imageH, zoom)
        if (imageW <= 0 || imageH <= 0 || s <= 0) return center
        val moved = NormalizedPoint(center.x - dx / (imageW * s), center.y - dy / (imageH * s))
        return clampedCenter(moved, cellW, cellH, imageW, imageH, zoom)
    }
}
