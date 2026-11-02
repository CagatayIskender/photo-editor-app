package com.aurum.app.ui.shell

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.ui.ComingFeature
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.OutlineButton
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing

/** A calm page for iOS features that have not reached Android yet. Nothing here is a dead end. */
@Composable
fun ComingSoonScreen(feature: ComingFeature, onBack: () -> Unit) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        IconAction(AurumIcons.back, tr("Close"), onBack, Modifier.padding(Spacing.xs))
        Column(
            Modifier.align(Alignment.Center).padding(Spacing.l),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Spacing.s),
        ) {
            CrownBadge(22.dp)
            Text(tr("Coming to Android"), style = AurumType.label, color = p.accent)
            Text(tr(feature.titleKey), style = AurumType.title, color = p.textPrimary, modifier = Modifier.semantics { heading() })
            Text(
                tr("This part of the atelier is still being made for Android. Photo editing is ready now."),
                style = AurumType.body, color = p.textSecondary, textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(Spacing.s))
            OutlineButton(tr("Done"), onClick = onBack)
        }
    }
}
