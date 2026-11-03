package com.aurum.app.ui.collage

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewModelScope
import com.aurum.app.collage.CollageRenderer
import com.aurum.app.collage.CollageSession
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.DrawnCheckmark
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.GoldProgressRing
import com.aurum.app.ui.common.LabeledSlider
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.aurumPopIn
import com.aurum.app.ui.common.aurumPopOut
import com.aurum.app.ui.common.aurumRiseIn
import com.aurum.app.ui.common.aurumRiseOut
import com.aurum.app.ui.common.aurumShimmer
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.common.pressable
import com.aurum.app.ui.paywall.PaywallScreen
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.CollageCellGeometry
import com.aurum.core.CollageLayout
import com.aurum.core.CollageProject
import com.aurum.core.ExportDecision
import com.aurum.core.Tier
import kotlin.math.min
import kotlin.math.roundToInt

/** What the status line under the canvas shows. */
private sealed interface CollageStatus {
    data object Exporting : CollageStatus
    data class Saved(val uri: android.net.Uri) : CollageStatus
    data class Failed(val message: String) : CollageStatus
    data class Selected(val index: Int) : CollageStatus
    data object MemberLayout : CollageStatus
    data object Hint : CollageStatus
}

/**
 * The collage editor: a layout picker, the canvas (tap to select or swap,
 * drag and pinch to frame), and spacing, corners and background below.
 */
@Composable
fun CollageScreen(model: AppViewModel) {
    val context = LocalContext.current
    val container = model.container
    val session = remember { CollageSession(model.getApplication<Application>(), container, model.viewModelScope) }
    val entitlement by container.membership.entitlement.collectAsState()
    var replaceIndex by remember { mutableStateOf<Int?>(null) }

    val fillPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(6)) { uris ->
        if (uris.isNotEmpty()) session.add(uris)
    }
    val replacePicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        val index = replaceIndex
        if (uri != null && index != null) session.replace(index, uri)
        replaceIndex = null
    }
    val pickFill = { fillPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
    val pickReplace = { index: Int ->
        replaceIndex = index
        replacePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }
    // Android 8 and 9 need a storage permission to add to the photo library.
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) session.export() else session.permissionDenied()
    }
    val save = {
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        if (needsPermission) permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else session.export()
    }

    LaunchedEffect(Unit) { if (session.project.filledCount == 0) pickFill() }
    BackHandler(enabled = session.isPaywallPresented) { session.isPaywallPresented = false }

    if (session.isPaywallPresented) {
        PaywallScreen(
            container,
            onClose = { session.isPaywallPresented = false },
            onMember = { session.isPaywallPresented = false },
        )
        return
    }

    val p = LocalPalette.current
    val haptic = LocalHapticFeedback.current
    val project = session.project
    val status: CollageStatus = when (val phase = session.phase) {
        CollageSession.Phase.Exporting -> CollageStatus.Exporting
        is CollageSession.Phase.Saved -> CollageStatus.Saved(phase.uri)
        is CollageSession.Phase.Failed -> CollageStatus.Failed(phase.message)
        CollageSession.Phase.Editing -> {
            val selected = session.selectedCell
            when {
                selected != null -> CollageStatus.Selected(selected)
                session.decision(entitlement) is ExportDecision.RequiresMembership -> CollageStatus.MemberLayout
                else -> CollageStatus.Hint
            }
        }
    }

    AtelierScaffold(
        title = tr("Collage"),
        onClose = model::closeFlow,
        action = {
            GoldButton(
                tr("Save"),
                onClick = save,
                compact = true,
                enabled = session.canExport,
                busy = session.phase == CollageSession.Phase.Exporting,
            )
        },
    ) {
        CollageCanvas(
            session,
            onEmptyCell = { pickFill() },
            onTapCell = { index ->
                if (session.tap(index)) haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                else haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            },
            modifier = Modifier.weight(1f).fillMaxWidth().padding(Spacing.m),
        )
        StatusLine(
            status,
            onReplace = { pickReplace(it) },
            onRemove = { session.clear(it) },
            onOpenInStudio = { uri -> model.openCapturedPhoto(uri, null) },
        )
        AtelierControls {
            LayoutStrip(session)
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                LabeledSlider(
                    tr("Spacing"), project.spacing.toFloat(),
                    CollageProject.SPACING_RANGE.start.toFloat()..CollageProject.SPACING_RANGE.endInclusive.toFloat(),
                    onChange = { session.setSpacing(it.toDouble()) }, onFinished = {},
                    modifier = Modifier.weight(1f),
                )
                LabeledSlider(
                    tr("Corners"), project.cornerRadius.toFloat(),
                    CollageProject.CORNER_RADIUS_RANGE.start.toFloat()..CollageProject.CORNER_RADIUS_RANGE.endInclusive.toFloat(),
                    onChange = { session.setCornerRadius(it.toDouble()) }, onFinished = {},
                    modifier = Modifier.weight(1f),
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                val backgroundLabel = tr("Background colour")
                CollageSession.backgrounds.forEach { hex ->
                    BackgroundSwatch(hex, project.backgroundHex == hex, backgroundLabel) {
                        session.setBackground(hex)
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    }
                }
                Spacer(Modifier.weight(1f))
                if (session.emptyCellCount > 0) TextAction(tr("Add photos"), { pickFill() })
            }
        }
    }
}

@Composable
private fun StatusLine(
    status: CollageStatus,
    onReplace: (Int) -> Unit,
    onRemove: (Int) -> Unit,
    onOpenInStudio: (android.net.Uri) -> Unit,
) {
    val p = LocalPalette.current
    val rise = aurumRiseIn() togetherWith aurumRiseOut()
    val pop = aurumPopIn() togetherWith aurumPopOut()
    StatusSlot {
        AnimatedContent(
            targetState = status,
            transitionSpec = { if (targetState is CollageStatus.Saved) pop else rise },
            label = "collageStatus",
        ) { s ->
            when (s) {
                CollageStatus.Exporting -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    GoldProgressRing(progress = null, size = 22.dp)
                    Text(tr("Finishing your collage…"), style = AurumType.caption, color = p.textSecondary)
                }
                is CollageStatus.Saved -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    DrawnCheckmark(size = 20.dp)
                    Text(tr("Saved to Photos"), style = AurumType.caption, color = p.accent, modifier = Modifier.weight(1f, fill = false))
                    TextAction(tr("Open in Studio"), { onOpenInStudio(s.uri) })
                }
                is CollageStatus.Failed -> Text(s.message, style = AurumType.caption, color = p.textSecondary)
                is CollageStatus.Selected -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        tr("Tap another photo to swap, or drag and pinch to frame."),
                        style = AurumType.caption, color = p.textTertiary, modifier = Modifier.weight(1f),
                    )
                    TextAction(tr("Replace"), { onReplace(s.index) })
                    TextAction(tr("Remove"), { onRemove(s.index) })
                }
                CollageStatus.MemberLayout -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    CrownBadge(14.dp)
                    Text(tr("A member layout. Membership is asked for when you save."), style = AurumType.caption, color = p.textTertiary)
                }
                CollageStatus.Hint -> Text(tr("Tap a photo to select it."), style = AurumType.caption, color = p.textTertiary)
            }
        }
    }
}

@Composable
private fun LayoutStrip(session: CollageSession) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
        items(session.layouts, key = { it.id }) { layout ->
            LayoutThumbnail(layout, selected = session.project.layout.id == layout.id) { session.setLayout(layout) }
        }
    }
}

@Composable
private fun BackgroundSwatch(hex: String, selected: Boolean, label: String, onClick: () -> Unit) {
    val p = LocalPalette.current
    val scale by animateFloatAsState(if (selected) 1.12f else 1f, motion(), label = "swatchScale")
    val interaction = remember { MutableInteractionSource() }
    Box(
        Modifier
            .size(48.dp)
            .pressable(interaction)
            .clickable(interactionSource = interaction, indication = null, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label; this.selected = selected },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(28.dp)
                .graphicsLayer { scaleX = scale; scaleY = scale }
                .clip(CircleShape)
                .background(Color(CollageRenderer.color(hex)))
                .border(if (selected) 2.dp else 1.dp, if (selected) p.accent else p.hairline, CircleShape),
        )
    }
}

/** A small drawing of a layout's cells. */
@Composable
private fun LayoutThumbnail(layout: CollageLayout, selected: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    val background by animateColorAsState(if (selected) p.surfaceRaised else Color.Transparent, motion(), label = "layoutBg")
    val shape = RoundedCornerShape(12.dp)
    val description = tr("%@ layout, %lld photos", trDynamic(layout.name), layout.photoCount)
    Column(
        Modifier
            .pressable(interaction)
            .clip(shape)
            .background(background)
            .border(1.dp, if (selected) p.accent.copy(alpha = 0.35f) else Color.Transparent, shape)
            .clickable(interactionSource = interaction, indication = null, role = Role.Tab, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = description; this.selected = selected }
            .padding(Spacing.xs),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        val height = 56.dp
        val width = height * layout.canvasRatio.toFloat()
        Box(Modifier.size(width, height)) {
            val fill = if (selected) p.accent.copy(alpha = 0.85f) else p.textTertiary.copy(alpha = 0.6f)
            androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                layout.frames(0.04).forEach { r ->
                    drawRoundRect(
                        fill,
                        topLeft = Offset((r.x * size.width).toFloat(), (r.y * size.height).toFloat()),
                        size = Size((r.width * size.width).toFloat(), (r.height * size.height).toFloat()),
                        cornerRadius = CornerRadius(2.dp.toPx()),
                    )
                }
            }
            if (layout.tier == Tier.member) {
                Box(Modifier.align(Alignment.TopEnd).offset(x = 6.dp, y = (-6).dp)) { CrownBadge(12.dp) }
            }
        }
        Text(trDynamic(layout.name), style = AurumType.caption, color = if (selected) p.textPrimary else p.textTertiary, maxLines = 1)
    }
}

/** The collage as the user frames it. Matches [CollageRenderer] exactly. */
@Composable
private fun CollageCanvas(
    session: CollageSession,
    onEmptyCell: () -> Unit,
    onTapCell: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val project = session.project
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val ratio = project.layout.canvasRatio.toFloat()
        val maxW = constraints.maxWidth.toFloat()
        val maxH = constraints.maxHeight.toFloat()
        val fitW = if (maxH > 0f && maxW / maxH > ratio) maxH * ratio else maxW
        val fitH = if (ratio > 0f) fitW / ratio else maxH
        val radius = (project.cornerRadius * min(fitW, fitH)).toFloat()
        Box(
            Modifier
                .size(with(density) { fitW.toDp() }, with(density) { fitH.toDp() })
                .clip(RoundedCornerShape(0.dp))
                .background(Color(CollageRenderer.color(project.backgroundHex))),
        ) {
            project.frames.forEachIndexed { index, f ->
                key(index) {
                    CollageCell(
                        session, index,
                        x = (f.x * fitW).toFloat(), y = (f.y * fitH).toFloat(),
                        w = (f.width * fitW).toFloat(), h = (f.height * fitH).toFloat(),
                        radius = radius,
                        onEmptyCell = onEmptyCell, onTapCell = onTapCell,
                    )
                }
            }
        }
    }
}

@Composable
private fun CollageCell(
    session: CollageSession,
    index: Int,
    x: Float, y: Float, w: Float, h: Float,
    radius: Float,
    onEmptyCell: () -> Unit,
    onTapCell: (Int) -> Unit,
) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    val spec = motion<Float>(300)
    val ax by animateFloatAsState(x, spec, label = "cellX")
    val ay by animateFloatAsState(y, spec, label = "cellY")
    val aw by animateFloatAsState(w, spec, label = "cellW")
    val ah by animateFloatAsState(h, spec, label = "cellH")
    val cell = session.project.cells.getOrNull(index)
    val isSelected = session.selectedCell == index
    val scale by animateFloatAsState(if (isSelected) 0.985f else 1f, motion(), label = "cellScale")
    val shape = RoundedCornerShape(min(radius, min(aw, ah) / 2f).coerceAtLeast(0f))
    val thumb = cell?.let { session.thumbnails[it.source.localIdentifier] }
    val thumbAlpha by animateFloatAsState(if (thumb != null) 1f else 0f, motion(), label = "thumbAlpha")
    val label = if (cell == null) tr("Empty cell %lld", index + 1) else tr("Photo %lld", index + 1)
    val hint = if (cell == null) tr("Add a photo") else tr("Select, then select another photo to swap")
    val isEmpty = cell == null

    Box(
        Modifier
            .offset { IntOffset(ax.roundToInt(), ay.roundToInt()) }
            .size(with(density) { aw.toDp() }, with(density) { ah.toDp() })
            .aurumEntrance(index, 8.dp)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(shape)
            .background(if (isEmpty) p.surface else p.surfaceRaised)
            .then(if (isSelected) Modifier.border(BorderStroke(2.dp, p.accent), shape) else Modifier)
            .pointerInput(isEmpty, session.selectedCell) {
                detectTapGestures(onTap = { if (isEmpty) onEmptyCell() else onTapCell(index) })
            }
            .then(
                if (isSelected && !isEmpty) {
                    Modifier.pointerInput(index, aw, ah) {
                        detectTransformGestures { _, pan, zoom, _ ->
                            session.adjust(index, pan.x.toDouble(), pan.y.toDouble(), zoom.toDouble(), aw.toDouble(), ah.toDouble())
                        }
                    }
                } else Modifier,
            )
            .semantics(mergeDescendants = true) {
                contentDescription = label
                role = Role.Button
                selected = isSelected
                onClick(label = hint) {
                    if (isEmpty) onEmptyCell() else onTapCell(index)
                    true
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        if (cell != null) {
            if (thumb == null) Box(Modifier.fillMaxSize().aurumShimmer(intensity = 0.12f))
            androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                if (thumb != null) {
                    val frame = CollageCellGeometry.imageFrame(
                        size.width.toDouble(), size.height.toDouble(),
                        cell.source.pixelSize.width.toDouble(), cell.source.pixelSize.height.toDouble(),
                        cell.zoom, cell.center,
                    )
                    drawImage(
                        thumb,
                        dstOffset = IntOffset(frame.x.roundToInt(), frame.y.roundToInt()),
                        dstSize = IntSize(frame.width.roundToInt(), frame.height.roundToInt()),
                        alpha = thumbAlpha,
                        filterQuality = FilterQuality.Medium,
                    )
                }
            }
        } else {
            Icon(AurumIcons.plus, contentDescription = null, tint = p.textTertiary, modifier = Modifier.size(22.dp))
        }
    }
}
