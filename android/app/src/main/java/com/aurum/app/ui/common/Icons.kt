package com.aurum.app.ui.common

import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/**
 * AURUM's line icons, drawn in-house on a 24 unit grid (1.5 unit strokes) so
 * the app needs no icon font. Tinted by the Icon composable.
 */
object AurumIcons {
    private fun icon(name: String, vararg paths: String, filled: Boolean = false): ImageVector {
        val b = ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f)
        for (d in paths) {
            if (filled) {
                b.addPath(addPathNodes(d), fill = SolidColor(androidx.compose.ui.graphics.Color.Black))
            } else {
                b.addPath(
                    addPathNodes(d),
                    stroke = SolidColor(androidx.compose.ui.graphics.Color.Black),
                    strokeLineWidth = 1.5f,
                    strokeLineCap = StrokeCap.Round,
                    strokeLineJoin = StrokeJoin.Round,
                )
            }
        }
        return b.build()
    }

    val close = icon("close", "M6,6 L18,18 M18,6 L6,18")
    val back = icon("back", "M15,5 L8,12 L15,19")
    val undo = icon("undo", "M9,7 L5,11 L9,15 M5,11 H14 a5,5 0 0,1 0,10 H11")
    val redo = icon("redo", "M15,7 L19,11 L15,15 M19,11 H10 a5,5 0 0,0 0,10 H13")
    val share = icon("share", "M12,3 V15 M8,7 L12,3 L16,7 M6,11 H5 V21 H19 V11 H18")
    val download = icon("download", "M12,3 V15 M8,11 L12,15 L16,11 M5,19 H19")
    val search = icon("search", "M10.5,4 a6.5,6.5 0 1,0 0.01,0 Z M15.5,15.5 L20,20")
    val plus = icon("plus", "M12,5 V19 M5,12 H19")
    val trash = icon("trash", "M5,7 H19 M10,7 V4 H14 V7 M7,7 L8,20 H16 L17,7")
    val rotate = icon("rotate", "M4,12 a8,8 0 1,0 2.5,-5.8 M4,4 V9 H9")
    val flip = icon("flip", "M12,3 V21 M9,6 L4,18 H9 Z M15,6 L20,18 H15 Z")
    val compare = icon("compare", "M12,3 V21 M5,5 H19 V19 H5 Z")
    val check = icon("check", "M5,12 L10,17 L19,7")
    val bookmark = icon("bookmark", "M7,4 H17 V20 L12,16 L7,20 Z")
    val bookmarkFilled = icon("bookmarkFilled", "M7,4 H17 V20 L12,16 L7,20 Z", filled = true)
    val sparkle = icon("sparkle", "M12,3 C12.8,8.5 15.5,11.2 21,12 C15.5,12.8 12.8,15.5 12,21 C11.2,15.5 8.5,12.8 3,12 C8.5,11.2 11.2,8.5 12,3 Z")
    val camera = icon("camera", "M4,8 H8 L10,5 H14 L16,8 H20 V19 H4 Z M12,10 a3.5,3.5 0 1,0 0.01,0 Z")
    val layers = icon("layers", "M12,4 L21,9 L12,14 L3,9 Z M3,14 L12,19 L21,14")
    val photo = icon("photo", "M4,5 H20 V19 H4 Z M4,16 L9,11 L13,15 L16,12 L20,16 M15,8.5 a1,1 0 1,0 0.01,0")
    val more = icon("more", "M6,12 h0.01 M12,12 h0.01 M18,12 h0.01")
    /** The membership mark: a small three-point crown. */
    val crown = icon("crown", "M4,17 L5.5,8 L9.5,12 L12,6 L14.5,12 L18.5,8 L20,17 Z", filled = true)
}
