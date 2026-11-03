package com.aurum.app.ui.autostudio

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.aurum.app.depth.DepthMotionRenderer
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AmbientGlow
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.DrawnCheckmark
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.GoldProgressRing
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.LabeledSlider
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.aurumPopIn
import com.aurum.app.ui.common.aurumPopOut
import com.aurum.app.ui.common.aurumRiseIn
import com.aurum.app.ui.common.aurumRiseOut
import com.aurum.app.ui.common.aurumSheetIn
import com.aurum.app.ui.common.aurumSheetOut
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.common.pressClickable
import com.aurum.app.ui.common.pressable
import com.aurum.app.ui.paywall.PaywallScreen
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.LocalReduceMotion
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.DepthMotionPreset
import com.aurum.core.Entitlement
import com.aurum.core.Tier
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.aspectRatio

/**
 * 3D Motion: a still photo given depth and a slow camera move, previewed
 * live and exported as a looping video. Ported from the iOS `DepthMotionView`.
 */
@Composable
fun DepthMotionScreen(model: AppViewModel) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val container = model.container
    val state = remember { DepthMotionModel(context.applicationContext, container, scope) }
    val entitlement by container.membership.entitlement.collectAsState()

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) state.setPhoto(uri)
    }
    fun pick() {
        runCatching { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
    }
    // Opens the picker on arrival, as iOS does, once the launcher is registered.
    LaunchedEffect(Unit) {
        withFrameNanos { }
        if (state.photo == null) pick()
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) state.export(entitlement) else state.permissionDenied()
    }
    fun save() {
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            !state.requiresMembership(entitlement) &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        if (needsPermission) permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else state.export(entitlement)
    }

    BackHandler(enabled = state.isPaywallPresented) { state.isPaywallPresented = false }

    Box(Modifier.fillMaxSize().background(p.background)) {
        AmbientGlow(intensity = 0.5f)
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            DepthHeader(title = tr("3D Motion"), onClose = { model.closeFlow() }, modifier = Modifier.aurumEntrance(0))
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = Spacing.m, vertical = Spacing.xs)
                    .aurumEntrance(1),
                contentAlignment = Alignment.Center,
            ) {
                DepthPreview(state, onPick = ::pick)
            }
            DepthControls(
                state = state,
                entitlement = entitlement,
                watermarkNote = entitlement == Entitlement.free,
                onPreset = {
                    state.preset = it
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                },
                onChangePhoto = ::pick,
                onSave = ::save,
                onShare = { uri ->
                    val title = context.tr("Share")
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "video/mp4"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    runCatching { context.startActivity(Intent.createChooser(send, title)) }
                },
            )
        }

        AnimatedVisibility(state.isPaywallPresented, enter = aurumSheetIn(), exit = aurumSheetOut()) {
            PaywallScreen(
                container,
                onClose = { state.isPaywallPresented = false },
                onMember = { state.isPaywallPresented = false },
            )
        }
    }
}

@Composable
private fun DepthHeader(title: String, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Row(
        modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = Spacing.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
    ) {
        IconAction(AurumIcons.close, tr("Close"), onClose)
        Text(
            title, style = AurumType.title, color = p.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
    }
}

/** The preview: placeholder, depth search, or the live loop. */
@Composable
private fun DepthPreview(state: DepthMotionModel, onPick: () -> Unit) {
    val p = LocalPalette.current
    val renderer = state.renderer
    val key = when (state.phase) {
        DepthMotionPhase.Empty -> 0
        DepthMotionPhase.Loading -> 1
        else -> if (renderer != null) 2 else 3
    }
    val enter = aurumRiseIn()
    val exit = aurumRiseOut()
    AnimatedContent(
        targetState = key,
        transitionSpec = { enter togetherWith exit },
        contentAlignment = Alignment.Center,
        label = "depthPreview",
        modifier = Modifier.fillMaxSize(),
    ) { shown ->
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            when (shown) {
                0, 3 -> PreviewPlaceholder(
                    text = if (shown == 0) tr("Choose a photo to begin") else ((state.phase as? DepthMotionPhase.Failed)?.message ?: tr("Choose a photo to begin")),
                    onClick = onPick,
                )
                1 -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    GoldProgressRing(progress = null, size = 40.dp)
                    Text(
                        tr("Finding depth…"), style = AurumType.caption, color = p.textSecondary,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                    )
                }
                else -> state.renderer?.let { LivePreview(state, it) }
            }
        }
    }
}

@Composable
private fun PreviewPlaceholder(text: String, onClick: () -> Unit) {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(20.dp)
    Box(
        Modifier
            .fillMaxSize()
            .clip(shape)
            .background(Brush.verticalGradient(listOf(p.surfaceRaised, p.surface)))
            .border(1.dp, p.hairline, shape)
            .pressClickable(onClickLabel = tr("Choose a photo"), scale = 0.985f, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
            Icon(AurumIcons.photo, contentDescription = null, tint = p.accent, modifier = Modifier.size(28.dp))
            Text(text, style = AurumType.caption, color = p.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = Spacing.m))
        }
    }
}

/**
 * The looping move, drawn every display frame from the prepared layers. With
 * reduced motion, one still frame a quarter into the loop shows the depth
 * without moving (it follows the move and depth controls).
 */
@Composable
private fun LivePreview(state: DepthMotionModel, renderer: DepthMotionRenderer) {
    val p = LocalPalette.current
    val reduce = LocalReduceMotion.current
    var time by remember { mutableDoubleStateOf(DepthMotionModel.DURATION / 4) }
    LaunchedEffect(renderer, reduce) {
        if (reduce) {
            time = DepthMotionModel.DURATION / 4
            return@LaunchedEffect
        }
        val start = withFrameNanos { it }
        while (true) {
            withFrameNanos { now -> time = (now - start) / 1_000_000_000.0 }
        }
    }
    val title = presetTitle(state.preset)
    val description = tr("Preview of your photo with the %@ move", title)
    val shape = RoundedCornerShape(12.dp)
    val aspect = renderer.width.toFloat() / renderer.height.toFloat()
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        // The largest frame of the photo's shape that fits.
        Box(Modifier.aspectRatio(aspect).clip(shape).border(1.dp, p.hairline, shape)) {
            Canvas(Modifier.fillMaxSize().semantics { contentDescription = description }) {
                val motion = state.motion
                drawIntoCanvas { canvas ->
                    renderer.draw(canvas.nativeCanvas, size.width, size.height, motion, time, DepthMotionModel.DURATION)
                }
            }
            if (!state.usesRealDepth) {
                Text(
                    tr("Estimated depth"),
                    style = AurumType.label,
                    color = p.textSecondary,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(Spacing.xs)
                        .clip(RoundedCornerShape(50))
                        .background(Color.Black.copy(alpha = 0.45f))
                        .padding(horizontal = Spacing.xs, vertical = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun DepthControls(
    state: DepthMotionModel,
    entitlement: Entitlement,
    watermarkNote: Boolean,
    onPreset: (DepthMotionPreset) -> Unit,
    onChangePhoto: () -> Unit,
    onSave: () -> Unit,
    onShare: (android.net.Uri) -> Unit,
) {
    val p = LocalPalette.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(p.surface)
            .drawHairline(p.accent.copy(alpha = 0.35f))
            .navigationBarsPadding()
            .padding(Spacing.m),
        verticalArrangement = Arrangement.spacedBy(Spacing.s),
    ) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).aurumEntrance(2),
            horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
        ) {
            DepthMotionPreset.entries.forEach { preset ->
                MoveChip(presetTitle(preset), selected = state.preset == preset, member = preset.tier == Tier.member) { onPreset(preset) }
            }
        }
        LabeledSlider(
            label = tr("Depth"),
            value = state.intensity.toFloat(),
            range = 0f..1f,
            onChange = { state.intensity = it.toDouble() },
            onFinished = {},
            modifier = Modifier.aurumEntrance(3),
        )
        Box(Modifier.fillMaxWidth().heightIn(min = 26.dp).aurumEntrance(4)) {
            DepthStatus(state, entitlement, watermarkNote, onShare)
        }
        Row(
            Modifier.fillMaxWidth().aurumEntrance(5),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextAction(tr("Change photo"), onChangePhoto, enabled = state.phase !is DepthMotionPhase.Exporting)
            Spacer(Modifier.weight(1f))
            GoldButton(
                tr("Save video"),
                onClick = onSave,
                compact = true,
                enabled = state.photo != null && state.isReady,
                busy = state.phase is DepthMotionPhase.Exporting,
                sheen = state.isReady,
            )
        }
    }
}

/** A thin gold line along the top edge. */
private fun Modifier.drawHairline(color: Color): Modifier = drawBehind {
    drawRect(color, size = Size(size.width, 0.5.dp.toPx()))
}

/** The line under the controls: export progress, the saved check, a failure, or the membership note. */
@Composable
private fun DepthStatus(state: DepthMotionModel, entitlement: Entitlement, watermarkNote: Boolean, onShare: (android.net.Uri) -> Unit) {
    val p = LocalPalette.current
    val phase = state.phase
    val key = when (phase) {
        is DepthMotionPhase.Exporting -> "exporting"
        is DepthMotionPhase.Saved -> "saved"
        is DepthMotionPhase.Failed -> if (state.renderer != null) "failed" else "note"
        else -> "note"
    }
    val rise = aurumRiseIn()
    val pop = aurumPopIn()
    val out = aurumRiseOut()
    val popOut = aurumPopOut()
    AnimatedContent(
        targetState = key,
        transitionSpec = { (if (targetState == "saved") pop else rise) togetherWith (if (initialState == "saved") popOut else out) },
        label = "depthStatus",
    ) { shown ->
        when (shown) {
            "exporting" -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                val progress = (state.phase as? DepthMotionPhase.Exporting)?.progress ?: 1.0
                GoldProgressRing(progress = progress.toFloat(), size = 26.dp)
                Text(
                    tr("Rendering your video…"), style = AurumType.caption, color = p.textSecondary,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
            "saved" -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                DrawnCheckmark(size = 22.dp)
                Text(
                    tr("Saved to Photos"), style = AurumType.caption, color = p.accent,
                    modifier = Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite },
                )
                val saved = state.phase as? DepthMotionPhase.Saved
                if (saved != null) TextAction(tr("Share"), { onShare(saved.uri) })
            }
            "failed" -> Text(
                (state.phase as? DepthMotionPhase.Failed)?.message.orEmpty(),
                style = AurumType.caption, color = p.textSecondary,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
            else -> if (state.requiresMembership(entitlement)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    CrownBadge(14.dp)
                    Text(
                        tr("%@ is a member move. Preview freely; membership is asked for when you save.", presetTitle(state.preset)),
                        style = AurumType.caption, color = p.textTertiary,
                    )
                }
            } else {
                Text(
                    if (watermarkNote) tr("A 4-second loop, with a small mark on free exports.") else tr("A 4-second loop at full quality."),
                    style = AurumType.caption, color = p.textTertiary,
                )
            }
        }
    }
}

/** A move chip with a crown for members' moves; 48 dp tall for touch. */
@Composable
private fun MoveChip(text: String, selected: Boolean, member: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    val background by androidx.compose.animation.animateColorAsState(if (selected) p.accent else p.surfaceRaised, motion(), label = "moveChip")
    val content = if (selected) p.onAccent else p.textPrimary
    val shape = RoundedCornerShape(20.dp)
    val isSelected = selected
    Row(
        Modifier
            .heightIn(min = 48.dp)
            .pressable(interaction)
            .clip(shape)
            .background(background)
            .clickable(interactionSource = interaction, indication = LocalIndication.current, role = Role.Tab, onClick = onClick)
            .semantics { this.selected = isSelected }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (member) Icon(AurumIcons.crown, contentDescription = null, tint = if (selected) p.onAccent else p.accent, modifier = Modifier.size(13.dp))
        Text(text, style = AurumType.caption, color = content, maxLines = 1)
    }
}

@Composable
private fun presetTitle(preset: DepthMotionPreset): String = when (preset) {
    DepthMotionPreset.orbit -> tr("Orbit")
    DepthMotionPreset.dolly -> tr("Dolly")
    DepthMotionPreset.swing -> tr("Swing")
    DepthMotionPreset.float -> tr("Float")
}
