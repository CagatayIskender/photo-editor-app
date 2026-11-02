package com.aurum.app.ui.shell

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.ComingFeature
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.SectionTitle
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing

/** Starts a new edit with the system photo picker, next to the other ways to create. */
@Composable
fun CreateScreen(model: AppViewModel) {
    val p = LocalPalette.current
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = Spacing.m),
        verticalArrangement = Arrangement.spacedBy(Spacing.l),
    ) {
        Column(Modifier.padding(horizontal = Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Text(tr("Create"), style = AurumType.title, color = p.textPrimary, modifier = Modifier.semantics { heading() })
            Text(tr("Pick a photo to edit"), style = AurumType.body, color = p.textSecondary)
            GoldButton(tr("Choose a photo"), onClick = { model.startCreating() })
            Text(
                tr("AURUM can see only the photos you pick. Nothing is uploaded."),
                style = AurumType.caption, color = p.textTertiary,
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Row(Modifier.padding(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                CreateTile(AurumIcons.layers, tr("Video"), tr("Clips and photos"), Modifier.weight(1f)) { model.openComingSoon(ComingFeature.video) }
                CreateTile(AurumIcons.sparkle, tr("Templates"), tr("Cut to the beat"), Modifier.weight(1f)) { model.openComingSoon(ComingFeature.templates) }
                CreateTile(AurumIcons.camera, tr("Camera"), tr("Shoot in a look"), Modifier.weight(1f)) { model.openComingSoon(ComingFeature.camera) }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            SectionTitle(tr("AI Studio"), Modifier.padding(horizontal = Spacing.m))
            AtelierRow(model)
        }
    }
}
