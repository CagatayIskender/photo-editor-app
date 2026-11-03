package com.aurum.app.ui.video

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/** Line icons for the video tools, drawn on the same 24 unit grid as [com.aurum.app.ui.common.AurumIcons]. */
object VideoIcons {
    private fun icon(name: String, vararg paths: String, filled: Boolean = false): ImageVector {
        val b = ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f)
        for (d in paths) {
            if (filled) {
                b.addPath(addPathNodes(d), fill = SolidColor(Color.Black))
            } else {
                b.addPath(addPathNodes(d), stroke = SolidColor(Color.Black), strokeLineWidth = 1.5f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
            }
        }
        return b.build()
    }

    val play = icon("play", "M8,5 L19,12 L8,19 Z", filled = true)
    val pause = icon("pause", "M7,5 H10 V19 H7 Z M14,5 H17 V19 H14 Z", filled = true)
    val trim = icon("trim", "M6,3 V18 H21 M3,6 H18 V21")
    val split = icon("split", "M12,3 V21 M4,7 H9 V17 H4 Z M15,7 H20 V17 H15 Z")
    val speed = icon("speed", "M4,16 a8,8 0 1,1 16,0 M12,16 L16,9")
    val reverse = icon("reverse", "M9,6 L5,10 L9,14 M5,10 H15 a4,4 0 0,1 0,8 H12")
    val volume = icon("volume", "M4,9 H8 L13,5 V19 L8,15 H4 Z M16,9 a4,4 0 0,1 0,6 M18.5,6.5 a7.5,7.5 0 0,1 0,11")
    val muted = icon("muted", "M4,9 H8 L13,5 V19 L8,15 H4 Z M16,9 L21,15 M21,9 L16,15")
    val transition = icon("transition", "M3,6 H11 V18 H3 Z M13,6 H21 V18 H13 Z M9,12 H15")
    val music = icon("music", "M9,18 V5 L20,3 V16 M9,18 a2.5,2.5 0 1,1 -5,0 a2.5,2.5 0 1,1 5,0 M20,16 a2.5,2.5 0 1,1 -5,0 a2.5,2.5 0 1,1 5,0")
    val text = icon("text", "M5,6 V4 H19 V6 M12,4 V20 M9,20 H15")
    val effects = icon("effects", "M5,19 L15,9 M14,4 V6 M19,9 H21 M17.5,5.5 L19,4 M10,4 L11,6 M18,13 L20,14")
    val look = icon("look", "M12,3 a9,9 0 1,0 0.01,0 Z M12,3 V21 M12,8 C15,8 17,10 17,12")
    val bookends = icon("bookends", "M4,5 V19 M20,5 V19 M8,9 H16 M8,12 H14 M8,15 H16")
    val aspect = icon("aspect", "M7,3 H17 V21 H7 Z M3,8 V16 M21,8 V16")
}
