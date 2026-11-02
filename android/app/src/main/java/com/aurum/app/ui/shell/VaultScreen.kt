package com.aurum.app.ui.shell

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.Chip
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.QuietState
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.OperationKind

/** Drafts to continue and presets to reuse or share. */
@Composable
fun VaultScreen(model: AppViewModel) {
    val p = LocalPalette.current
    val c = model.container
    val context = LocalContext.current
    var showPresets by rememberSaveable { mutableStateOf(false) }
    val drafts by c.drafts.drafts.collectAsState()
    val presets by c.presets.presets.collectAsState()

    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Text(tr("Vault"), style = AurumType.title, color = p.textPrimary, modifier = Modifier.semantics { heading() })
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                Chip(tr("Drafts"), !showPresets, { showPresets = false })
                Chip(tr("Presets"), showPresets, { showPresets = true })
            }
        }
        if (!showPresets) {
            if (drafts.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    QuietState(tr("No drafts yet"), tr("Edits you leave unfinished are kept here."))
                }
            } else {
                val deleteLabel = tr("Delete draft")
                LazyVerticalGrid(
                    columns = GridCells.Adaptive(104.dp),
                    contentPadding = PaddingValues(Spacing.m),
                    horizontalArrangement = Arrangement.spacedBy(Spacing.s),
                    verticalArrangement = Arrangement.spacedBy(Spacing.m),
                ) {
                    items(drafts, key = { it.id }) { draft ->
                        Box {
                            DraftTile(
                                draft, 104.dp,
                                Modifier
                                    .clickable(role = Role.Button) { model.openDraft(draft.id) }
                                    .semantics {
                                        customActions = listOf(CustomAccessibilityAction(deleteLabel) { model.deleteDraft(draft.id); true })
                                    },
                            )
                            IconAction(AurumIcons.trash, deleteLabel, { model.deleteDraft(draft.id) }, Modifier.align(Alignment.TopEnd))
                        }
                    }
                }
            }
        } else {
            if (presets.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    QuietState(tr("No presets yet"), tr("Save an edit as a preset in the Studio to reuse it on any photo."))
                }
            } else {
                LazyColumn(contentPadding = PaddingValues(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    items(presets, key = { it.id }) { preset ->
                        val looks = preset.operations.mapNotNull { (it.kind as? OperationKind.Look)?.look?.lookID }
                            .mapNotNull { c.catalog.look(it)?.name }
                        val shareTitle = tr("Share %@", preset.name)
                        val shareText = tr("A preset made in AURUM")
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(p.surface).padding(start = Spacing.m),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f).padding(vertical = Spacing.s)) {
                                Text(preset.name, style = AurumType.headline, color = p.textPrimary)
                                Text(
                                    if (looks.isEmpty()) tr("Adjustments only") else looks.joinToString(" + "),
                                    style = AurumType.caption, color = p.textTertiary,
                                )
                            }
                            Text(
                                tr("Use"),
                                style = AurumType.headline, color = p.accent,
                                modifier = Modifier.clickable(role = Role.Button, onClickLabel = tr("Use %@ on a photo", preset.name)) { model.usePreset(preset) }
                                    .padding(12.dp),
                            )
                            IconAction(AurumIcons.share, shareTitle, {
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_TEXT, "$shareText\n${model.presetLink(preset)}")
                                }
                                context.startActivity(Intent.createChooser(send, shareTitle))
                            })
                            IconAction(AurumIcons.trash, tr("Delete preset"), { model.deletePreset(preset.id) })
                        }
                    }
                }
            }
        }
    }
}
