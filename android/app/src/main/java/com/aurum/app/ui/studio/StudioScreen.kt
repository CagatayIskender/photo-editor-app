package com.aurum.app.ui.studio

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateRotation
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.dp
import com.aurum.app.imaging.OverlayPainter
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.NormalizedPoint
import com.aurum.core.Overlay
import com.aurum.core.OverlayContent
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

@Composable
fun StudioScreen(model: AppViewModel, session: StudioSession) {
    val p = LocalPalette.current
    var exportFlow by remember(session) { mutableStateOf(false) }
    var comparing by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize().background(p.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            // Top bar
            Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.xs), verticalAlignment = Alignment.CenterVertically) {
                IconAction(AurumIcons.close, tr("Close"), { model.closeStudio(session) })
                Spacer(Modifier.weight(1f))
                CompareButton(onChange = { comparing = it })
                IconAction(AurumIcons.undo, tr("Undo"), session::undo, enabled = session.canUndo)
                IconAction(AurumIcons.redo, tr("Redo"), session::redo, enabled = session.canRedo)
                Spacer(Modifier.width(4.dp))
                TextAction(tr("Export"), { exportFlow = true }, enabled = session.preview != null)
            }
            PhotoCanvas(session, comparing, Modifier.weight(1f).fillMaxWidth().padding(horizontal = Spacing.xs))
            HorizontalDivider(color = p.hairline, thickness = 0.5.dp)
            Box(Modifier.fillMaxWidth().heightIn(min = 196.dp, max = 320.dp).verticalScroll(rememberScrollState())) {
                when (session.tool) {
                    StudioTool.looks -> LooksPanel(session)
                    StudioTool.adjust -> AdjustPanel(session)
                    StudioTool.crop -> CropPanel(session)
                    StudioTool.text -> TextPanel(session)
                    StudioTool.stickers -> StickersPanel(session)
                }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.xs), horizontalArrangement = Arrangement.SpaceEvenly) {
                for (tool in StudioTool.entries) {
                    val isSelected = session.tool == tool
                    Text(
                        tr(tool.titleKey),
                        style = AurumType.headline,
                        color = if (isSelected) p.accent else p.textTertiary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .clickable(role = Role.Tab) { session.tool = tool }
                            .semantics { selected = isSelected }
                            .padding(horizontal = 8.dp, vertical = 12.dp),
                    )
                }
            }
        }

        AnimatedVisibility(exportFlow, enter = fadeIn(motion()), exit = fadeOut(motion())) {
            ExportFlow(model, session, onDismiss = { exportFlow = false })
        }
    }
}

/** Touch and hold to see the photo without looks or adjustments. */
@Composable
private fun CompareButton(onChange: (Boolean) -> Unit) {
    val p = LocalPalette.current
    val label = tr("Touch and hold to see the original")
    Box(
        Modifier
            .size(44.dp)
            .clip(CircleShape)
            .semantics { contentDescription = label }
            .pointerInput(Unit) {
                detectTapGestures(onPress = {
                    onChange(true)
                    tryAwaitRelease()
                    onChange(false)
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(AurumIcons.compare, null, tint = p.textPrimary, modifier = Modifier.size(22.dp))
    }
}

/**
 * The photo with its overlays. Drag, pinch and rotate move the touched
 * overlay; a horizontal swipe elsewhere changes the look within its
 * collection; a tap on empty photo clears the selection.
 */
@Composable
private fun PhotoCanvas(session: StudioSession, comparing: Boolean, modifier: Modifier) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val image = if (comparing) session.original ?: session.preview else session.preview
        when {
            session.loadFailed -> Text(tr("This photo couldn't be opened."), style = AurumType.body, color = p.textTertiary)
            image == null -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                CircularProgressIndicator(color = p.accent, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
                Text(tr("Opening your photo…"), style = AurumType.caption, color = p.textTertiary)
            }
            else -> {
                val boxW = constraints.maxWidth.toFloat()
                val boxH = constraints.maxHeight.toFloat()
                val scale = min(boxW / image.width, boxH / image.height)
                val w = with(density) { (image.width * scale).toDp() }
                val h = with(density) { (image.height * scale).toDp() }
                val look = session.document.lookApplications.lastOrNull()?.let { session.catalog.look(it.lookID) }
                val description = if (look != null) tr("Your photo, with the %@ look", look.name) else tr("Your photo")
                val swipeHint = tr("Swipe left or right on the photo to change the look")
                Image(
                    image,
                    contentDescription = null,
                    contentScale = ContentScale.FillBounds,
                    modifier = Modifier.size(w, h).semantics {
                        contentDescription = "$description. $swipeHint"
                    },
                )
                val doc = session.document
                val selectedID = session.selectedOverlayID
                Canvas(
                    Modifier
                        .size(w, h)
                        .pointerInput(session) { overlayGestures(session) },
                ) {
                    if (!comparing) {
                        drawIntoCanvas { canvas ->
                            session.painter.draw(canvas.nativeCanvas, doc.overlays, size.width, size.height, null)
                        }
                        doc.overlays.firstOrNull { it.id == selectedID && !it.isHidden }?.let { overlay ->
                            val unit = size.width / OverlayPainter.REFERENCE_WIDTH
                            val b = session.painter.bounds(overlay)
                            val s = overlay.scale.toFloat() * unit
                            translate((overlay.center.x * size.width).toFloat(), (overlay.center.y * size.height).toFloat()) {
                                rotate(overlay.rotationDegrees.toFloat(), pivot = Offset.Zero) {
                                    drawRect(
                                        color = p.accent,
                                        topLeft = Offset(b.left * s - 8, b.top * s - 8),
                                        size = Size(b.width() * s + 16, b.height() * s + 16),
                                        style = Stroke(width = 1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f))),
                                    )
                                }
                            }
                        }
                    }
                }
                if (comparing) {
                    Text(
                        tr("ORIGINAL"), style = AurumType.label, color = p.textPrimary,
                        modifier = Modifier.align(Alignment.TopCenter).padding(top = Spacing.s)
                            .clip(RoundedCornerShape(10.dp)).background(p.background.copy(alpha = 0.6f)).padding(horizontal = 10.dp, vertical = 4.dp),
                    )
                }
            }
        }
    }
}

/** True when ([x], [y]) in canvas pixels falls on [overlay]. */
private fun hits(session: StudioSession, overlay: Overlay, x: Float, y: Float, w: Float, h: Float, slop: Float): Boolean {
    val unit = w / OverlayPainter.REFERENCE_WIDTH
    val s = (overlay.scale.toFloat() * unit).coerceAtLeast(1e-3f)
    val dx = x - (overlay.center.x * w).toFloat()
    val dy = y - (overlay.center.y * h).toFloat()
    val r = Math.toRadians(-overlay.rotationDegrees)
    val lx = ((dx * cos(r) - dy * sin(r)) / s).toFloat()
    val ly = ((dx * sin(r) + dy * cos(r)) / s).toFloat()
    val b = session.painter.bounds(overlay)
    val pad = slop / s
    return lx >= b.left - pad && lx <= b.right + pad && ly >= b.top - pad && ly <= b.bottom + pad
}

private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.overlayGestures(session: StudioSession) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val w = size.width.toFloat()
        val h = size.height.toFloat()
        val target = session.document.overlays.lastOrNull {
            !it.isHidden && hits(session, it, down.position.x, down.position.y, w, h, 12.dp.toPx())
        }
        if (target != null) {
            session.selectedOverlayID = target.id
            session.tool = if (target.content is OverlayContent.Text) StudioTool.text else StudioTool.stickers
        }
        var started = false
        var panX = 0f
        var travelled = 0f
        var maxPointers = 1
        while (true) {
            val event = awaitPointerEvent()
            if (event.changes.none { it.pressed }) break
            maxPointers = max(maxPointers, event.changes.count { it.pressed })
            val pan = event.calculatePan()
            travelled += pan.getDistance()
            if (target != null) {
                val zoom = event.calculateZoom()
                val rotation = event.calculateRotation()
                if (pan == Offset.Zero && zoom == 1f && rotation == 0f) continue
                val current = session.document.overlays.firstOrNull { it.id == target.id } ?: break
                if (!started) {
                    session.begin()
                    started = true
                }
                session.updateOverlay(
                    current.copy(
                        center = NormalizedPoint(
                            (current.center.x + pan.x / w).coerceIn(0.0, 1.0),
                            (current.center.y + pan.y / h).coerceIn(0.0, 1.0),
                        ),
                        scale = (current.scale * zoom).coerceIn(0.1, 12.0),
                        rotationDegrees = current.rotationDegrees + rotation,
                    ),
                    live = true,
                )
                event.changes.forEach { it.consume() }
            } else {
                panX += pan.x
            }
        }
        if (started) {
            session.end()
        } else if (target == null) {
            if (maxPointers == 1 && abs(panX) > 64.dp.toPx()) {
                session.cycleLook(if (panX < 0) 1 else -1)
            } else if (travelled < viewConfiguration.touchSlop) {
                session.selectedOverlayID = null
            }
        }
    }
}
