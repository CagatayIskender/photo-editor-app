package com.aurum.app.ui.studio

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aurum.app.imaging.OverlayPainter
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.Chip
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.LabeledSlider
import com.aurum.app.ui.common.OutlineButton
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.ui.theme.hex
import com.aurum.core.AdjustmentControl
import com.aurum.core.AdjustmentSet
import com.aurum.core.AspectPreset
import com.aurum.core.CropSpec
import com.aurum.core.Overlay
import com.aurum.core.OverlayContent
import com.aurum.core.OverlayFont
import com.aurum.core.StickerDefinition
import com.aurum.core.StickerOverlay
import com.aurum.core.TextOverlay
import com.aurum.core.TextStyle as OverlayTextStyle
import com.aurum.core.Tier

// ---------------------------------------------------------------- Adjust

@Composable
fun AdjustPanel(session: StudioSession) {
    val p = LocalPalette.current
    var selected by rememberSaveable { mutableStateOf(AdjustmentControl.exposure) }
    val adjustments = session.document.adjustments
    val neutral = AdjustmentSet()
    Column(Modifier.fillMaxWidth().padding(vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
            items(AdjustmentControl.entries.toList(), key = { it.name }) { control ->
                val changed = adjustments[control] != neutral[control]
                Box {
                    Chip(trDynamic(control.displayName), selected == control, { selected = control })
                    if (changed) {
                        val changedLabel = tr("Changed")
                        Box(
                            Modifier.align(Alignment.TopEnd).padding(2.dp).size(6.dp).clip(CircleShape).background(p.accent)
                                .semantics { contentDescription = changedLabel },
                        )
                    }
                }
            }
        }
        Column(Modifier.padding(horizontal = Spacing.m)) {
            val range = selected.range
            LabeledSlider(
                trDynamic(selected.displayName),
                adjustments[selected].toFloat(),
                range.start.toFloat()..range.endInclusive.toFloat(),
                onChange = { session.update(session.document.withAdjustments(session.document.adjustments.with(selected, it.toDouble()))) },
                onFinished = session::end,
            )
            TextAction(
                tr("Reset all"),
                { session.commit(session.document.withAdjustments(AdjustmentSet())) },
                enabled = !adjustments.isNeutral,
                color = p.textSecondary,
            )
        }
    }
}

// ---------------------------------------------------------------- Crop

@Composable
fun CropPanel(session: StudioSession) {
    val p = LocalPalette.current
    val crop = session.document.crop
    fun commit(c: CropSpec) = session.commit(session.document.copy(crop = c))
    Column(Modifier.fillMaxWidth().padding(vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Text(tr("Aspect"), style = AurumType.caption, color = p.textSecondary, modifier = Modifier.padding(horizontal = Spacing.m))
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
            items(AspectPreset.entries.toList(), key = { it.name }) { aspect ->
                Chip(trDynamic(aspect.label), crop.aspect == aspect, {
                    val centred = CropSpec.centred(aspect, session.document.source.pixelSize)
                    // Free keeps the current frame; drag handles are not on Android yet.
                    val rect = if (aspect == AspectPreset.free) crop.rect else centred.rect
                    commit(crop.copy(aspect = aspect, rect = rect))
                })
            }
        }
        Column(Modifier.padding(horizontal = Spacing.m)) {
            LabeledSlider(
                tr("Straighten"),
                crop.straightenDegrees.toFloat(),
                -45f..45f,
                onChange = { session.update(session.document.copy(crop = CropSpec.of(crop.rect, crop.aspect, crop.quarterTurns, it.toDouble(), crop.flipHorizontal, crop.flipVertical))) },
                onFinished = session::end,
                format = { "%.1f°".format(it) },
            )
        }
        Row(Modifier.padding(horizontal = Spacing.xs), verticalAlignment = Alignment.CenterVertically) {
            IconAction(AurumIcons.rotate, tr("Rotate 90 degrees"), {
                commit(CropSpec.of(crop.rect, crop.aspect, crop.quarterTurns + 1, crop.straightenDegrees, crop.flipHorizontal, crop.flipVertical))
            })
            IconAction(AurumIcons.flip, tr("Flip horizontally"), { commit(crop.copy(flipHorizontal = !crop.flipHorizontal)) })
            TextAction(tr("Reset"), { commit(CropSpec.identity) }, enabled = !crop.isIdentity, color = p.textSecondary)
        }
    }
}

// ---------------------------------------------------------------- Text

private val TEXT_COLOURS = listOf("#F4EFE6", "#C9A86A", "#0B0B0C", "#B9A28A", "#8C2F39", "#3D5A6C")

private val TEXT_STYLES = listOf(
    OverlayTextStyle.plain to "Plain",
    OverlayTextStyle.shadow to "Shadow",
    OverlayTextStyle.outline to "Outline",
    OverlayTextStyle.glow to "Glow",
    OverlayTextStyle.gradient to "Gilded",
    OverlayTextStyle.box to "Label",
)

@Composable
fun TextPanel(session: StudioSession) {
    val p = LocalPalette.current
    val overlay = session.selectedOverlay
    val text = (overlay?.content as? OverlayContent.Text)?.text
    val defaultWords = tr("Your words")
    // A text edit stays one undo step until the panel closes or another overlay is picked.
    DisposableEffect(overlay?.id) { onDispose { session.end() } }

    Column(Modifier.fillMaxWidth().padding(vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        if (overlay == null || text == null) {
            Column(Modifier.padding(horizontal = Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                OutlineButton(tr("Add text"), onClick = {
                    val new = Overlay(content = OverlayContent.Text(TextOverlay(text = defaultWords)))
                    session.commit(session.document.addOverlay(new))
                    session.selectedOverlayID = new.id
                }, icon = AurumIcons.plus)
                Text(tr("Tap text on the photo to edit it. Drag, pinch and rotate to place it."), style = AurumType.caption, color = p.textTertiary)
            }
        } else {
            TextEditor(session, overlay, text)
        }
    }
}

@Composable
private fun TextEditor(session: StudioSession, overlay: Overlay, text: TextOverlay) {
    val p = LocalPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        fun change(t: TextOverlay, live: Boolean = false) =
            session.updateOverlay(overlay.copy(content = OverlayContent.Text(t)), live)

        OutlinedTextField(
            value = text.text,
            onValueChange = { change(text.copy(text = it), live = true) },
            label = { Text(tr("Your words")) },
            textStyle = AurumType.body,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = p.accent, unfocusedBorderColor = p.hairline,
                focusedTextColor = p.textPrimary, unfocusedTextColor = p.textPrimary, cursorColor = p.accent,
                focusedLabelColor = p.accent,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.m),
        )
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
            items(OverlayFont.all, key = { it.id }) { font ->
                val family = OverlayPainter.FONT_RESOURCES[font.resourceName]?.let {
                    FontFamily(Font(it, style = if (font.isItalic) FontStyle.Italic else FontStyle.Normal))
                }
                val fontLabel = tr("Font %@", font.displayName)
                Chip(
                    font.displayName,
                    text.fontID == font.id,
                    { session.end(); change(text.copy(fontID = font.id)) },
                    Modifier.semantics { contentDescription = fontLabel },
                    fontFamilyStyle = TextStyle(fontFamily = family ?: FontFamily.Serif, fontSize = 15.sp),
                )
            }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            items(TEXT_COLOURS, key = { it }) { hexValue ->
                val isSelected = text.colorHex.equals(hexValue, ignoreCase = true)
                val colourLabel = tr("Colour %@", hexValue)
                Box(
                    Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(hex(hexValue))
                        .border(if (isSelected) 2.dp else 1.dp, if (isSelected) p.accent else p.hairline, CircleShape)
                        .clickable(role = Role.RadioButton) { session.end(); change(text.copy(colorHex = hexValue)) }
                        .semantics { contentDescription = colourLabel; selected = isSelected },
                )
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            LazyRow(
                Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = Spacing.m),
                horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
            ) {
                items(TEXT_STYLES, key = { it.first.name }) { (style, key) ->
                    Chip(tr(key), text.style == style, { session.end(); change(text.copy(style = style)) })
                }
            }
            IconAction(AurumIcons.trash, tr("Delete text"), {
                session.end()
                session.commit(session.document.removeOverlay(overlay.id))
                session.selectedOverlayID = null
            })
        }
    }
}

// ---------------------------------------------------------------- Stickers

@Composable
fun StickersPanel(session: StudioSession) {
    val p = LocalPalette.current
    var category by rememberSaveable { mutableStateOf(StickerDefinition.categories.first()) }
    val selectedSticker = (session.selectedOverlay?.content as? OverlayContent.Sticker)?.sticker
    Column(Modifier.fillMaxWidth().padding(vertical = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
            items(StickerDefinition.categories, key = { it }) { c ->
                Chip(trDynamic(c), category == c, { category = c })
            }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            val inCategory = StickerDefinition.starterSet.filter { it.category == category && it.id in OverlayPainter.STICKER_RESOURCES }
            items(inCategory, key = { it.id }) { sticker ->
                val res = OverlayPainter.STICKER_RESOURCES.getValue(sticker.id)
                val name = trDynamic(sticker.name)
                val label = if (sticker.tier == Tier.member) tr("%@, members only", name) else name
                Box(
                    Modifier
                        .size(76.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(p.surfaceRaised)
                        .clickable(role = Role.Button) {
                            val new = Overlay(content = OverlayContent.Sticker(StickerOverlay(sticker.id, sticker.tier)))
                            session.commit(session.document.addOverlay(new))
                            session.selectedOverlayID = new.id
                        }
                        .semantics { contentDescription = label }
                        .padding(10.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Image(painterResource(res), contentDescription = null, modifier = Modifier.size(56.dp))
                    if (sticker.tier == Tier.member) {
                        Box(Modifier.align(Alignment.TopEnd)) { CrownBadge(11.dp) }
                    }
                }
            }
        }
        if (selectedSticker != null) {
            val overlayID = session.selectedOverlayID
            Row(Modifier.padding(horizontal = Spacing.xs), verticalAlignment = Alignment.CenterVertically) {
                TextAction(tr("Remove"), {
                    if (overlayID != null) session.commit(session.document.removeOverlay(overlayID))
                    session.selectedOverlayID = null
                }, color = p.textSecondary)
            }
        }
    }
}
