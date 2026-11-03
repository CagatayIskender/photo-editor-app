package com.aurum.app.ui.collage

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.ui.common.AmbientGlow
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing

/** The shared frame of the collage and carousel screens: onyx with an ambient glow, header on top, controls below. */
@Composable
internal fun AtelierScaffold(
    title: String,
    onClose: () -> Unit,
    action: @Composable () -> Unit,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxSize().background(p.background)) {
        AmbientGlow(Modifier.fillMaxSize(), intensity = 0.4f)
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = Spacing.xs, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconAction(AurumIcons.close, tr("Close"), onClose)
                Text(
                    title,
                    style = AurumType.headline,
                    color = p.textPrimary,
                    modifier = Modifier.weight(1f).padding(horizontal = Spacing.xs).semantics { heading() },
                )
                Box(Modifier.padding(end = Spacing.xs)) { action() }
            }
            content()
        }
    }
}

/** A raised bar for the controls, with a gold hairline on its top edge. */
@Composable
internal fun AtelierControls(content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(p.surface)
            .drawBehind {
                drawLine(p.accent.copy(alpha = 0.35f), Offset(0f, 0f), Offset(size.width, 0f), strokeWidth = 1f)
            }
            .padding(Spacing.m),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(Spacing.s),
        content = content,
    )
}

/** Keeps the status line a steady height so the canvas above does not jump. */
@Composable
internal fun StatusSlot(content: @Composable () -> Unit) {
    Box(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = Spacing.m),
        contentAlignment = Alignment.CenterStart,
    ) { content() }
}
