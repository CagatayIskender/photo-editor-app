package com.aurum.app.ui.studio

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.common.Chip
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.LabeledSlider
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.FaceRetouch
import com.aurum.core.RetouchControl
import com.aurum.core.RetouchSettings
import kotlin.math.roundToInt

/**
 * Face retouching, one control at a time, like Adjust (the iOS RetouchSheet).
 * "Natural" sets a subtle starting point in one tap. Settings apply to every
 * face. Retouch is for members: it can be tried freely, and membership is
 * asked for only at export.
 */
@Composable
fun RetouchPanel(session: StudioSession) {
    val p = LocalPalette.current
    var control by rememberSaveable { mutableStateOf(RetouchControl.smoothing) }
    val retouch = session.document.retouch
    fun value(c: RetouchControl) = retouch.global[c]
    fun set(settings: RetouchSettings, live: Boolean) {
        val doc = session.document.withRetouch(settings)
        if (live) session.update(doc) else session.commit(doc)
    }

    val groups = listOf(
        tr("Skin") to listOf(RetouchControl.smoothing, RetouchControl.blemishRemoval, RetouchControl.underEye),
        tr("Features") to listOf(RetouchControl.teethWhitening, RetouchControl.eyeBrightening),
        tr("Shape") to listOf(RetouchControl.jaw, RetouchControl.cheeks, RetouchControl.nose, RetouchControl.eyes, RetouchControl.lips, RetouchControl.forehead),
    )

    Column(Modifier.fillMaxWidth().padding(vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Row(Modifier.fillMaxWidth().padding(start = Spacing.m, end = Spacing.xs), verticalAlignment = Alignment.CenterVertically) {
            Text(trDynamic(control.displayName), style = AurumType.headline, color = p.textPrimary)
            Spacer(Modifier.width(Spacing.xs))
            Text(format(value(control), control), style = AurumType.caption, color = p.textSecondary)
            Spacer(Modifier.weight(1f))
            TextAction(tr("Natural"), { set(RetouchSettings(FaceRetouch.natural), live = false) })
            TextAction(tr("Reset"), { set(RetouchSettings(), live = false) }, enabled = !retouch.isNeutral, color = p.textSecondary)
        }

        Column(Modifier.padding(horizontal = Spacing.m)) {
            val range = control.range
            LabeledSlider(
                trDynamic(control.displayName),
                value(control).toFloat(),
                range.start.toFloat()..range.endInclusive.toFloat(),
                onChange = { v ->
                    val current = session.document.retouch
                    set(current.copy(global = current.global.with(control, v.toDouble())), live = true)
                },
                onFinished = session::end,
                format = { format(it.toDouble(), control) },
            )
        }

        LazyRow(
            contentPadding = PaddingValues(horizontal = Spacing.m),
            horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            item(key = "all") {
                Chip(tr("All faces"), selected = true, onClick = {}, modifier = Modifier.aurumEntrance(0, distance = 8.dp))
            }
            item(key = "divider") {
                Box(Modifier.width(1.dp).height(22.dp).background(p.hairline).clearAndSetSemantics {})
            }
            var index = 1
            for ((title, controls) in groups) {
                val entrance = index++
                item(key = "group-$title") {
                    Text(
                        title,
                        style = AurumType.label,
                        color = p.textTertiary,
                        modifier = Modifier.padding(start = 4.dp).semantics { heading() }.aurumEntrance(entrance, distance = 8.dp),
                    )
                }
                for (c in controls) {
                    val chipIndex = index++
                    item(key = c.name) {
                        val changed = value(c) != 0.0
                        val changedLabel = tr("Changed")
                        Box(Modifier.aurumEntrance(chipIndex, distance = 8.dp)) {
                            Chip(
                                trDynamic(c.displayName),
                                selected = c == control,
                                onClick = { control = c },
                                modifier = Modifier.semantics { if (changed) stateDescription = changedLabel },
                            )
                            if (changed) {
                                Box(
                                    Modifier.align(Alignment.TopEnd).padding(2.dp).size(6.dp).clip(CircleShape).background(p.accent)
                                        .clearAndSetSemantics {},
                                )
                            }
                        }
                    }
                }
            }
        }

        val note = tr("Retouch is for members. Try it freely; you'll be asked only when you export.")
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Spacing.m).semantics(mergeDescendants = true) { contentDescription = note },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            CrownBadge(14.dp)
            Text(note, style = AurumType.caption, color = p.textTertiary)
        }
    }
}

/** Strengths read 0…100; reshape controls −100…+100. */
private fun format(value: Double, control: RetouchControl): String {
    val scaled = (value * 100).roundToInt()
    return if (control.isReshape && scaled > 0) "+$scaled" else "$scaled"
}
