package com.aurum.core

import kotlinx.serialization.Serializable
import java.util.Locale
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/** A collage layout: photo cells as normalised rectangles that tile the canvas. */
@Serializable
data class CollageLayout(
    val id: String,
    val name: String,
    val aspect: AspectPreset,
    val cells: List<NormalizedRect>,
    val tier: Tier = Tier.free,
) {
    val photoCount: Int get() = cells.size

    /** Free and original aspects render square. */
    val canvasRatio: Double get() = aspect.ratio ?: 1.0

    /** Cells with spacing: outer border and gaps are `spacing` of the shorter side. */
    fun frames(spacing: Double): List<NormalizedRect> {
        val g = CollageProject.SPACING_RANGE.clamp(spacing)
        if (g <= 0) return cells
        val r = canvasRatio
        val gx = if (r >= 1) g / r else g
        val gy = if (r >= 1) g else g * r
        return cells.map { c ->
            val x = gx / 2 + c.x * (1 - gx)
            val y = gy / 2 + c.y * (1 - gy)
            val w = c.width * (1 - gx)
            val h = c.height * (1 - gy)
            NormalizedRect(x + gx / 2, y + gy / 2, max(0.0, w - gx), max(0.0, h - gy))
        }
    }

    companion object {
        private fun r(x: Double, y: Double, w: Double, h: Double) = NormalizedRect(x, y, w, h)

        val library: List<CollageLayout> = listOf(
            CollageLayout("collage.duet", "Duet", AspectPreset.square, listOf(r(0.0, 0.0, 0.5, 1.0), r(0.5, 0.0, 0.5, 1.0))),
            CollageLayout("collage.horizon", "Horizon", AspectPreset.story, listOf(r(0.0, 0.0, 1.0, 0.5), r(0.0, 0.5, 1.0, 0.5))),
            CollageLayout("collage.salon", "Salon", AspectPreset.portrait, listOf(r(0.0, 0.0, 0.6, 1.0), r(0.6, 0.0, 0.4, 0.5), r(0.6, 0.5, 0.4, 0.5))),
            CollageLayout("collage.triptych", "Triptych", AspectPreset.story, listOf(r(0.0, 0.0, 1.0, 1.0 / 3), r(0.0, 1.0 / 3, 1.0, 1.0 / 3), r(0.0, 2.0 / 3, 1.0, 1.0 / 3))),
            CollageLayout("collage.marquee", "Marquee", AspectPreset.square, listOf(r(0.0, 0.0, 1.0, 0.6), r(0.0, 0.6, 0.5, 0.4), r(0.5, 0.6, 0.5, 0.4)), Tier.member),
            CollageLayout("collage.quartet", "Quartet", AspectPreset.square, listOf(r(0.0, 0.0, 0.5, 0.5), r(0.5, 0.0, 0.5, 0.5), r(0.0, 0.5, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5))),
            CollageLayout("collage.gallery", "Gallery", AspectPreset.portrait, listOf(r(0.0, 0.0, 1.0, 0.625), r(0.0, 0.625, 1.0 / 3, 0.375), r(1.0 / 3, 0.625, 1.0 / 3, 0.375), r(2.0 / 3, 0.625, 1.0 / 3, 0.375))),
            CollageLayout("collage.cascade", "Cascade", AspectPreset.story, listOf(r(0.0, 0.0, 0.5, 0.625), r(0.5, 0.0, 0.5, 0.375), r(0.0, 0.625, 0.5, 0.375), r(0.5, 0.375, 0.5, 0.625)), Tier.member),
            CollageLayout("collage.mosaic", "Mosaic", AspectPreset.square, listOf(r(0.0, 0.0, 0.5, 0.5), r(0.5, 0.0, 0.5, 0.5), r(0.0, 0.5, 1.0 / 3, 0.5), r(1.0 / 3, 0.5, 1.0 / 3, 0.5), r(2.0 / 3, 0.5, 1.0 / 3, 0.5))),
            CollageLayout("collage.atelier", "Atelier", AspectPreset.portrait, listOf(r(0.0, 0.0, 0.625, 1.0), r(0.625, 0.0, 0.375, 0.25), r(0.625, 0.25, 0.375, 0.25), r(0.625, 0.5, 0.375, 0.25), r(0.625, 0.75, 0.375, 0.25)), Tier.member),
            CollageLayout(
                "collage.contact", "Contact Sheet", AspectPreset.portrait,
                listOf(
                    r(0.0, 0.0, 0.5, 1.0 / 3), r(0.5, 0.0, 0.5, 1.0 / 3),
                    r(0.0, 1.0 / 3, 0.5, 1.0 / 3), r(0.5, 1.0 / 3, 0.5, 1.0 / 3),
                    r(0.0, 2.0 / 3, 0.5, 1.0 / 3), r(0.5, 2.0 / 3, 0.5, 1.0 / 3),
                ),
            ),
            CollageLayout(
                "collage.vitrine", "Vitrine", AspectPreset.story,
                listOf(
                    r(0.0, 0.0, 0.625, 0.25), r(0.625, 0.0, 0.375, 0.25),
                    r(0.0, 0.25, 1.0, 0.5),
                    r(0.0, 0.75, 0.375, 0.25), r(0.375, 0.75, 0.3125, 0.25), r(0.6875, 0.75, 0.3125, 0.25),
                ),
                Tier.member,
            ),
        )

        fun layouts(photoCount: Int, library: List<CollageLayout> = this.library) = library.filter { it.photoCount == photoCount }
        fun layout(id: String) = library.firstOrNull { it.id == id }
    }
}

/** A collage being built. Immutable; edits return a new project. */
@Serializable
data class CollageProject(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val layout: CollageLayout,
    /** One entry per layout cell; null is empty. */
    val cells: List<Cell?> = emptyList(),
    val spacing: Double = 0.01,
    val cornerRadius: Double = 0.0,
    val backgroundHex: String = "#000000",
) {
    @Serializable
    data class Cell(val source: SourceAsset, val zoom: Double = 1.0, val center: NormalizedPoint = NormalizedPoint.center) {
        companion object {
            fun of(source: SourceAsset, zoom: Double = 1.0, center: NormalizedPoint = NormalizedPoint.center) =
                Cell(source, (1.0..4.0).clamp(zoom), NormalizedPoint((0.0..1.0).clamp(center.x), (0.0..1.0).clamp(center.y)))
        }
    }

    val isComplete: Boolean get() = cells.all { it != null }
    val filledCount: Int get() = cells.count { it != null }
    val frames: List<NormalizedRect> get() = layout.frames(spacing)

    fun assign(cell: Cell?, index: Int): CollageProject =
        if (index !in cells.indices) this else copy(cells = cells.toMutableList().also { it[index] = cell })

    /** Puts a photo in the first empty cell; returns the new project and its index, or null if full. */
    fun add(source: SourceAsset): Pair<CollageProject, Int>? {
        val i = cells.indexOfFirst { it == null }
        if (i < 0) return null
        return assign(Cell.of(source), i) to i
    }

    fun swapCells(a: Int, b: Int): CollageProject {
        if (a !in cells.indices || b !in cells.indices || a == b) return this
        val list = cells.toMutableList()
        val t = list[a]; list[a] = list[b]; list[b] = t
        return copy(cells = list)
    }

    /** Changes layout, keeping photos in order; extra photos are dropped. */
    fun withLayout(newLayout: CollageLayout): CollageProject =
        copy(layout = newLayout, cells = fit(cells.filterNotNull(), newLayout.photoCount))

    companion object {
        val SPACING_RANGE = 0.0..0.05
        val CORNER_RADIUS_RANGE = 0.0..0.1

        fun of(layout: CollageLayout, cells: List<Cell?> = emptyList(), spacing: Double = 0.01, cornerRadius: Double = 0.0, backgroundHex: String = "#000000", id: UUID = UUID.randomUUID()) =
            CollageProject(id, layout, fit(cells, layout.photoCount), SPACING_RANGE.clamp(spacing), CORNER_RADIUS_RANGE.clamp(cornerRadius), normalizedHex(backgroundHex) ?: "#000000")

        private fun fit(cells: List<Cell?>, count: Int): List<Cell?> {
            val out = cells.take(count).toMutableList()
            while (out.size < count) out.add(null)
            return out
        }

        /** "#rgb", "rrggbb" or "#RRGGBB" as "#RRGGBB", or null. */
        fun normalizedHex(text: String): String? {
            var s = text.trim().uppercase(Locale.ROOT)
            if (s.startsWith("#")) s = s.substring(1)
            if (!s.all { it in "0123456789ABCDEF" }) return null
            if (s.length == 3) s = s.map { "$it$it" }.joinToString("")
            if (s.length != 6) return null
            return "#$s"
        }
    }
}

/** Splits one wide photo into seamless carousel panels. */
object Carousel {
    const val MAX_PANELS = 20

    fun panels(imageAspect: Double, count: Int, panelAspect: Double): List<NormalizedRect> {
        if (imageAspect <= 0 || panelAspect <= 0 || !imageAspect.isFinite() || !panelAspect.isFinite() || count < 1) return emptyList()
        val n = min(count, MAX_PANELS)
        val stripAspect = n * panelAspect
        var x0 = 0.0
        var y0 = 0.0
        var width = 1.0
        var height = 1.0
        if (stripAspect <= imageAspect) {
            width = stripAspect / imageAspect
            x0 = (1 - width) / 2
        } else {
            height = imageAspect / stripAspect
            y0 = (1 - height) / 2
        }
        val edges = DoubleArray(n + 1) { x0 + width * it / n }
        if (x0 == 0.0) edges[n] = 1.0
        return (0 until n).map { i -> NormalizedRect(edges[i], y0, edges[i + 1] - edges[i], height) }
    }
}
