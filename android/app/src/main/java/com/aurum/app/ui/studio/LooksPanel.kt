package com.aurum.app.ui.studio

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.Chip
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.LabeledSlider
import com.aurum.app.ui.common.LookThumbnail
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.LookApplication
import com.aurum.core.RefineOverrides
import com.aurum.core.Tier

private const val SAVED = "__saved"

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LooksPanel(session: StudioSession) {
    val p = LocalPalette.current
    val catalog = session.catalog
    val doc = session.document
    val active: LookApplication? = doc.lookApplications.lastOrNull()
    val activeRecipe = active?.let { catalog.look(it.lookID) }
    var collectionID by rememberSaveable { mutableStateOf(activeRecipe?.collection ?: catalog.collections.firstOrNull()?.id ?: "") }
    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var refining by rememberSaveable { mutableStateOf(false) }
    var savingPreset by remember { mutableStateOf(false) }

    val looks = when {
        searching -> if (query.isBlank()) catalog.looks else catalog.search(query)
        collectionID == SAVED -> catalog.looks.filter { it.id in session.favouriteLookIDs }
        else -> catalog.looks(collectionID)
    }

    Column(Modifier.fillMaxWidth().padding(vertical = Spacing.xs), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 4.dp)) {
            IconAction(
                if (searching) AurumIcons.close else AurumIcons.search,
                if (searching) tr("Close search") else tr("Search looks"),
                { searching = !searching; query = "" },
            )
            if (searching) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text(tr("Warm, film, noir…"), style = AurumType.body) },
                    singleLine = true,
                    textStyle = AurumType.body,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = p.accent, unfocusedBorderColor = p.hairline,
                        focusedTextColor = p.textPrimary, unfocusedTextColor = p.textPrimary, cursorColor = p.accent,
                    ),
                    modifier = Modifier.weight(1f).padding(end = Spacing.m),
                )
            } else {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(Spacing.xs), contentPadding = PaddingValues(end = Spacing.m)) {
                    item(key = SAVED) { Chip(tr("Saved"), collectionID == SAVED, { collectionID = SAVED }) }
                    items(catalog.collections, key = { it.id }) { c ->
                        Chip(trDynamic(c.name), collectionID == c.id, { collectionID = c.id })
                    }
                }
            }
        }

        val saveLabel = tr("Save look")
        val unsaveLabel = tr("Remove from Saved")
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            items(looks, key = { it.id }) { look ->
                val isActive = look.id == active?.lookID
                val favourite = look.id in session.favouriteLookIDs
                val favouriteLabel = if (favourite) unsaveLabel else saveLabel
                LookThumbnail(
                    name = look.name,
                    image = session.thumbnails[look.id],
                    swatch = look.swatch,
                    selected = isActive,
                    premium = look.tier == Tier.member,
                    favourite = favourite,
                    modifier = Modifier
                        .combinedClickable(
                            role = Role.Button,
                            onLongClickLabel = favouriteLabel,
                            onLongClick = { session.toggleFavourite(look.id) },
                            onClick = {
                                if (isActive) refining = !refining
                                else session.commit(session.document.applyLook(look.id, active?.intensity ?: 0.8))
                            },
                        )
                        .semantics {
                            customActions = listOf(CustomAccessibilityAction(favouriteLabel) { session.toggleFavourite(look.id); true })
                        },
                )
            }
        }

        if (active != null && activeRecipe != null) {
            Column(Modifier.padding(horizontal = Spacing.m)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    LabeledSlider(
                        tr("Intensity"),
                        active.intensity.toFloat(),
                        0f..1f,
                        onChange = { session.update(session.document.setActiveLookIntensity(it.toDouble())) },
                        onFinished = session::end,
                        modifier = Modifier.weight(1f),
                    )
                    TextAction(if (refining) tr("Done") else tr("Refine"), { refining = !refining })
                }
                if (refining) {
                    val base = activeRecipe.params
                    val refine = active.refine
                    fun set(r: RefineOverrides) = session.update(session.document.setActiveLookRefine(r))
                    LabeledSlider(tr("Grain"), (refine.grain ?: base.grain).toFloat(), 0f..1f, { set(refine.copy(grain = it.toDouble())) }, session::end)
                    LabeledSlider(tr("Fade"), (refine.fade ?: base.fade).toFloat(), 0f..1f, { set(refine.copy(fade = it.toDouble())) }, session::end)
                    LabeledSlider(tr("Vignette"), (refine.vignette ?: base.vignette).toFloat(), 0f..1f, { set(refine.copy(vignette = it.toDouble())) }, session::end)
                    LabeledSlider(tr("Light leak"), (refine.lightLeak ?: base.lightLeak).toFloat(), 0f..1f, { set(refine.copy(lightLeak = it.toDouble())) }, session::end)
                }
                TextAction(tr("Save as preset"), { savingPreset = true }, color = p.textSecondary)
            }
        }
    }

    if (savingPreset) {
        val defaultName = tr("My preset")
        var name by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { savingPreset = false },
            containerColor = p.surfaceRaised,
            title = { Text(tr("Save preset"), style = AurumType.title, color = p.textPrimary) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Text(tr("Saves this edit's looks and adjustments so you can use them on any photo."), style = AurumType.body, color = p.textSecondary)
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it.take(60) },
                        label = { Text(tr("Name")) },
                        placeholder = { Text(defaultName) },
                        singleLine = true,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = p.accent, unfocusedBorderColor = p.hairline,
                            focusedTextColor = p.textPrimary, unfocusedTextColor = p.textPrimary, cursorColor = p.accent,
                            focusedLabelColor = p.accent,
                        ),
                    )
                }
            },
            confirmButton = {
                TextAction(tr("Save"), {
                    session.saveAsPreset(name.ifBlank { defaultName })
                    savingPreset = false
                })
            },
            dismissButton = { TextAction(tr("Cancel"), { savingPreset = false }, color = p.textSecondary) },
        )
    }
}
