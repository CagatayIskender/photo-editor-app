package com.aurum.app.ui.video

import android.view.TextureView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.util.UnstableApi
import com.aurum.app.imaging.OverlayPainter
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.BusyVeil
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.GoldProgressRing
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.QuietState
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.aurumSheetIn
import com.aurum.app.ui.common.aurumSheetOut
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.common.pressClickable
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.LocalReduceMotion
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.video.MediaProbe
import com.aurum.app.video.PickedMedia
import com.aurum.core.Clip
import com.aurum.core.LayerAnimator
import com.aurum.core.OverlayContent
import com.aurum.core.Seconds
import com.aurum.core.TimedLayer
import com.aurum.core.Transition
import com.aurum.core.VideoProject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The video editor (iOS `VideoEditorView`): the player on top, a timeline of
 * clips sized by their length with trim handles and the playhead, then a
 * tool sheet and the tool rail. With no project it first asks for photos and
 * clips with the system picker.
 */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
fun VideoEditorScreen(model: AppViewModel, project: VideoProject?, source: String) {
    var current by remember(project) { mutableStateOf(project) }
    val start = current
    if (start == null) {
        PickMedia(model, onPicked = { current = it })
    } else {
        Editor(model, start)
    }
}

/** Asks for photos and clips, in picking order, and builds a plain timeline from them. */
@Composable
private fun PickMedia(model: AppViewModel, onPicked: (VideoProject) -> Unit) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var probing by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        if (uris.isEmpty()) {
            model.closeFlow()
            return@rememberLauncherForActivityResult
        }
        probing = true
        scope.launch {
            val picked: List<PickedMedia> = withContext(Dispatchers.IO) { uris.mapNotNull { MediaProbe.probe(context, it) } }
            probing = false
            if (picked.isEmpty()) failed = true else onPicked(MediaProbe.project(picked))
        }
    }
    val launch = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) }
    LaunchedEffect(Unit) { launch() }
    Box(Modifier.fillMaxSize().background(p.background).statusBarsPadding(), contentAlignment = Alignment.Center) {
        if (failed) {
            QuietState(tr("Couldn't build the video"), tr("Pick at least one photo or clip."), Modifier.aurumEntrance()) {
                GoldButton(tr("Choose photos and clips"), onClick = { failed = false; launch() }, compact = true)
            }
        }
        IconAction(AurumIcons.close, tr("Close"), { model.closeFlow() }, Modifier.align(Alignment.TopStart).padding(Spacing.xs))
        if (probing) BusyVeil(null)
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun Editor(app: AppViewModel, project: VideoProject) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val model = remember(project.id) { VideoEditorModel(context, app.container, project) }
    DisposableEffect(model) { onDispose { model.close() } }
    var confirmClose by remember { mutableStateOf(false) }
    BackHandler(enabled = !model.isExportPresented) { confirmClose = true }

    Box(Modifier.fillMaxSize().background(p.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            TopBar(model, onClose = { confirmClose = true })
            PlayerArea(model, Modifier.weight(1f).fillMaxWidth())
            Transport(model)
            Timeline(model, Modifier.fillMaxWidth().height(112.dp))
            val tool = model.activeTool
            AnimatedVisibility(tool != null && !tool.isAction, enter = aurumSheetIn(), exit = aurumSheetOut()) {
                // Keeps showing the last tool while the sheet slides away.
                var shown by remember { mutableStateOf(tool) }
                if (tool != null) shown = tool
                shown?.let { t ->
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(max = 300.dp)
                            .clip(RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp))
                            .background(p.surface)
                            .verticalScroll(rememberScrollState())
                            .padding(top = Spacing.s),
                    ) { VideoToolSheet(t, model) }
                }
            }
            ToolRail(model)
        }

        AnimatedVisibility(model.isExportPresented, enter = fadeIn(motion()), exit = fadeOut(motion())) {
            VideoExportSheet(app, model, onDismiss = { model.isExportPresented = false })
        }
    }

    if (confirmClose) {
        AlertDialog(
            onDismissRequest = { confirmClose = false },
            containerColor = p.surface,
            title = { Text(tr("Discard this video?"), style = AurumType.headline, color = p.textPrimary) },
            text = { Text(tr("Videos aren't kept as drafts yet. Export it first to keep it."), style = AurumType.body, color = p.textSecondary) },
            confirmButton = {
                Text(
                    tr("Discard"), style = AurumType.headline, color = Color(0xFFE5826F),
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button) {
                        confirmClose = false
                        app.closeFlow()
                    }.padding(12.dp),
                )
            },
            dismissButton = {
                Text(
                    tr("Keep editing"), style = AurumType.headline, color = p.accent,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button) { confirmClose = false }.padding(12.dp),
                )
            },
        )
    }
}

// ---------------------------------------------------------------- top bar

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun TopBar(model: VideoEditorModel, onClose: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = Spacing.xs), verticalAlignment = Alignment.CenterVertically) {
        IconAction(AurumIcons.close, tr("Close"), onClose)
        Spacer(Modifier.weight(1f))
        IconAction(AurumIcons.undo, tr("Undo"), model::undo, enabled = model.canUndo)
        IconAction(AurumIcons.redo, tr("Redo"), model::redo, enabled = model.canRedo)
        Spacer(Modifier.weight(1f))
        GoldButton(tr("Export"), onClick = model::presentExport, compact = true, enabled = model.project.clips.isNotEmpty())
    }
}

// ---------------------------------------------------------------- player

/** The preview letterboxed in the project's aspect, with text layers drawn live on top. */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun PlayerArea(model: VideoEditorModel, modifier: Modifier) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val density = LocalDensity.current
    val painter = remember { OverlayPainter(context) }
    val playLabel = if (model.isPlaying) tr("Pause") else tr("Play")
    val previewLabel = tr("Video preview")
    BoxWithConstraints(
        modifier
            .padding(horizontal = Spacing.m, vertical = Spacing.s)
            .pointerInput(model) { detectTapGestures { model.togglePlay() } },
        contentAlignment = Alignment.Center,
    ) {
        val ratio = (model.project.aspect.ratio ?: (9.0 / 16.0)).toFloat()
        val boxW = constraints.maxWidth.toFloat()
        val boxH = constraints.maxHeight.toFloat()
        val fitW = min(boxW, boxH * ratio)
        val targetW by animateFloatAsState(fitW, motion(320), label = "playerW")
        val targetH = targetW / ratio
        val w = with(density) { targetW.toDp() }
        val h = with(density) { targetH.toDp() }
        Box(
            Modifier
                .size(w, h)
                .clip(RoundedCornerShape(10.dp))
                .background(Color.Black)
                .semantics {
                    contentDescription = previewLabel
                    onClick(label = playLabel) { model.togglePlay(); true }
                },
        ) {
            if (model.hasPreview) {
                AndroidView(
                    factory = { TextureView(it).also { view -> model.player.setVideoTextureView(view) } },
                    modifier = Modifier.fillMaxSize(),
                    onRelease = { view -> model.player.clearVideoTextureView(view) },
                )
            }
            val playhead = model.playhead
            val project = model.project
            Canvas(Modifier.fillMaxSize()) {
                val overlays = LayerAnimator.overlays(project, playhead)
                if (overlays.isNotEmpty()) {
                    drawIntoCanvas { painter.draw(it.nativeCanvas, overlays, size.width, size.height, null) }
                }
            }
        }
        when {
            model.previewFailed -> Text(tr("This video couldn't be previewed."), style = AurumType.body, color = p.textTertiary)
            model.isBuilding && !model.hasPreview -> GoldProgressRing(null, size = 36.dp)
        }
    }
}

// ---------------------------------------------------------------- transport

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun Transport(model: VideoEditorModel) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = Spacing.s), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
        IconAction(if (model.isPlaying) VideoIcons.pause else VideoIcons.play, if (model.isPlaying) tr("Pause") else tr("Play"), model::togglePlay, enabled = model.hasPreview)
        Text("${timecode(model.playhead)} / ${timecode(model.duration)}", style = AurumType.caption, color = p.textSecondary)
        Spacer(Modifier.weight(1f))
        AnimatedVisibility(model.isBuilding, enter = fadeIn(motion()), exit = fadeOut(motion())) {
            val label = tr("Updating preview")
            GoldProgressRing(null, size = 20.dp, modifier = Modifier.semantics { contentDescription = label })
        }
    }
}

/** "m:ss" for a time in seconds. */
fun timecode(seconds: Seconds): String {
    val total = floor(max(0.0, seconds)).toInt()
    return "%d:%02d".format(total / 60, total % 60)
}

// ---------------------------------------------------------------- tool rail

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun ToolRail(model: VideoEditorModel) {
    val p = LocalPalette.current
    val haptics = LocalHapticFeedback.current
    Row(
        Modifier.fillMaxWidth().height(68.dp).background(p.background).horizontalScroll(rememberScrollState()).padding(horizontal = Spacing.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        VideoTool.entries.forEachIndexed { index, tool ->
            val available = model.isToolAvailable(tool)
            val active = model.activeTool == tool
            val tint by animateColorAsState(if (active) p.accent else p.textSecondary, motion(), label = "toolTint")
            val title = tr(tool.titleKey)
            Column(
                Modifier
                    .widthIn(min = 64.dp)
                    .fillMaxHeight()
                    .aurumEntrance(index, distance = 8.dp)
                    .graphicsLayer { alpha = if (available) 1f else 0.4f }
                    .pressClickable(enabled = available) {
                        val acted = model.toolTapped(tool)
                        haptics.performHapticFeedback(if (acted) HapticFeedbackType.TextHandleMove else HapticFeedbackType.LongPress)
                    }
                    .semantics { selected = active },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(toolIcon(tool), null, tint = tint, modifier = Modifier.size(22.dp))
                Spacer(Modifier.height(4.dp))
                Text(title, style = AurumType.caption, color = tint, maxLines = 1)
            }
        }
    }
}

private fun toolIcon(tool: VideoTool) = when (tool) {
    VideoTool.trim -> VideoIcons.trim
    VideoTool.split -> VideoIcons.split
    VideoTool.speed -> VideoIcons.speed
    VideoTool.reverse -> VideoIcons.reverse
    VideoTool.volume -> VideoIcons.volume
    VideoTool.transition -> VideoIcons.transition
    VideoTool.music -> VideoIcons.music
    VideoTool.text -> VideoIcons.text
    VideoTool.effects -> VideoIcons.effects
    VideoTool.look -> VideoIcons.look
    VideoTool.bookends -> VideoIcons.bookends
    VideoTool.aspect -> VideoIcons.aspect
}

// ---------------------------------------------------------------- timeline

private val POINTS_PER_SECOND = 48.dp
private val CLIP_HEIGHT = 56.dp

/**
 * Clips laid out at their start times, each as wide as it lasts. The ruler
 * scrubs; the selected clip shows trim handles; text layers sit in a thin
 * lane below.
 */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun Timeline(model: VideoEditorModel, modifier: Modifier) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    val context = LocalContext.current
    val project = model.project
    val scroll = rememberScrollState()
    val pps = with(density) { POINTS_PER_SECOND.toPx() }
    val total = POINTS_PER_SECOND * max(project.duration, 0.5).toFloat()
    val seconds = max(1, ceil(project.duration).toInt())
    val thumbnails = remember { mutableStateMapOf<String, ImageBitmap>() }
    val reduce = LocalReduceMotion.current
    val gutter = with(density) { Spacing.m.toPx() }

    // Follows the playhead while playing.
    val second = model.playhead.toInt()
    LaunchedEffect(second, model.isPlaying) {
        if (!model.isPlaying) return@LaunchedEffect
        val target = (gutter + model.playhead * pps - scroll.viewportSize / 2f).roundToInt().coerceIn(0, scroll.maxValue)
        if (reduce) scroll.scrollTo(target) else scroll.animateScrollTo(target)
    }

    Box(modifier.horizontalScroll(scroll)) {
        Column(Modifier.padding(horizontal = Spacing.m, vertical = Spacing.xs), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Ruler(model, seconds, total)
            Box(Modifier.width(total).height(CLIP_HEIGHT)) {
                project.intro?.let { intro ->
                    BookendBlock(tr("Intro"), POINTS_PER_SECOND * intro.duration.toFloat(), 0.dp) { model.toolTapped(VideoTool.bookends) }
                }
                project.outro?.let { outro ->
                    BookendBlock(tr("Outro"), POINTS_PER_SECOND * outro.duration.toFloat(), POINTS_PER_SECOND * (project.duration - outro.duration).toFloat()) {
                        model.toolTapped(VideoTool.bookends)
                    }
                }
                val starts = project.clipStartTimes
                project.clips.forEachIndexed { index, clip ->
                    val key = clip.source.localIdentifier + clip.kind
                    LaunchedEffect(key) {
                        if (thumbnails[key] == null) {
                            withContext(Dispatchers.IO) { MediaProbe.thumbnail(context, clip, 80) }?.let { thumbnails[key] = it.asImageBitmap() }
                        }
                    }
                    ClipCell(
                        model, clip, index, thumbnails[key],
                        x = POINTS_PER_SECOND * starts.getOrElse(index) { 0.0 }.toFloat(),
                        width = POINTS_PER_SECOND * clip.duration.toFloat(),
                        pps = pps,
                    )
                }
            }
            LayerLane(model, project.layers, total)
        }
        // Playhead.
        val x = with(density) { (gutter + model.playhead * pps).toFloat().toDp() } - 1.dp
        Box(
            Modifier
                .offset(x = x)
                .padding(top = Spacing.xs)
                .width(2.dp)
                .height(22.dp + 6.dp + CLIP_HEIGHT + 6.dp + 12.dp)
                .shadow(3.dp, spotColor = p.accent, ambientColor = p.accent)
                .background(p.accent),
        )
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun Ruler(model: VideoEditorModel, seconds: Int, width: Dp) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    val pps = with(density) { POINTS_PER_SECOND.toPx() }
    val label = tr("Playhead")
    Box(
        Modifier
            .width(width)
            .height(22.dp)
            .pointerInput(model) {
                detectTapGestures { model.seek(it.x / pps.toDouble()); model.selectClipAtPlayhead() }
            }
            .pointerInput(model) {
                detectHorizontalDragGestures(
                    onDragEnd = { model.selectClipAtPlayhead() },
                ) { change, _ -> model.seek(change.position.x / pps.toDouble()) }
            }
            .semantics {
                contentDescription = label
                stateDescription = timecode(model.playhead)
                progressBarRangeInfo = ProgressBarRangeInfo(model.playhead.toFloat(), 0f..max(0.01f, model.duration.toFloat()))
                setProgress { value -> model.seek(value.toDouble()); true }
            },
    ) {
        for (s in 0 until seconds) {
            Column(Modifier.offset(x = POINTS_PER_SECOND * s)) {
                Box(Modifier.width(1.dp).height(if (s % 5 == 0) 8.dp else 5.dp).background(if (s % 5 == 0) p.textTertiary else p.hairline))
                if (s % 5 == 0) Text(timecode(s.toDouble()), style = AurumType.label, color = p.textTertiary, maxLines = 1)
            }
        }
    }
}

@Composable
private fun BookendBlock(title: String, width: Dp, x: Dp, onTap: () -> Unit) {
    val p = LocalPalette.current
    Box(
        Modifier
            .offset(x = x + 1.dp)
            .width(max(width.value - 2f, 8f).dp)
            .height(CLIP_HEIGHT)
            .clip(RoundedCornerShape(8.dp))
            .background(p.surfaceRaised)
            .border(1.dp, p.accent.copy(alpha = 0.45f), RoundedCornerShape(8.dp))
            .clickable(role = Role.Button, onClick = onTap),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = AurumType.label, color = p.accent, maxLines = 1, modifier = Modifier.padding(horizontal = 4.dp))
    }
}

/** One clip: its first frame, a speed badge, a mark for the transition into it, and trim handles when selected. */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun ClipCell(model: VideoEditorModel, clip: Clip, index: Int, image: ImageBitmap?, x: Dp, width: Dp, pps: Float) {
    val p = LocalPalette.current
    val haptics = LocalHapticFeedback.current
    val selected = model.selectedClipID == clip.id
    val borderColor by animateColorAsState(if (selected) p.accent else p.hairline, motion(), label = "clipBorder")
    val length = "%.1f".format(clip.duration)
    val label = if (clip.kind == Clip.Kind.video) tr("Clip %lld, %@ seconds", index + 1, length) else tr("Photo %lld, %@ seconds", index + 1, length)
    val earlier = tr("Move earlier")
    val later = tr("Move later")
    val cellWidth = max(width.value - 2f, 8f).dp
    Box(
        Modifier
            .offset(x = x + 1.dp)
            .width(cellWidth)
            .height(CLIP_HEIGHT)
            .aurumEntrance(index, distance = 8.dp),
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .then(if (selected) Modifier.shadow(6.dp, RoundedCornerShape(8.dp), spotColor = p.accent, ambientColor = p.accent) else Modifier)
                .clip(RoundedCornerShape(8.dp))
                .background(p.surfaceRaised)
                .border(if (selected) 2.dp else 1.dp, borderColor, RoundedCornerShape(8.dp))
                .clickable(role = Role.Button) {
                    model.selectedClipID = clip.id
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                }
                .semantics {
                    contentDescription = label
                    this.selected = selected
                    customActions = listOf(
                        CustomAccessibilityAction(earlier) { model.selectedClipID = clip.id; model.moveSelectedClip(-1); true },
                        CustomAccessibilityAction(later) { model.selectedClipID = clip.id; model.moveSelectedClip(1); true },
                    )
                },
        ) {
            if (image != null) Image(image, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            val badge = clip.speed != 1.0 || clip.isReversed || (clip.volume == 0.0 && clip.kind == Clip.Kind.video)
            if (badge) {
                Row(
                    Modifier.align(Alignment.BottomStart).padding(4.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f)).padding(horizontal = 4.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    if (clip.speed != 1.0) Text(speedLabel(clip.speed), style = AurumType.label, color = p.textPrimary)
                    if (clip.isReversed) Icon(VideoIcons.reverse, null, tint = p.textPrimary, modifier = Modifier.size(10.dp))
                    if (clip.volume == 0.0 && clip.kind == Clip.Kind.video) Icon(VideoIcons.muted, null, tint = p.textPrimary, modifier = Modifier.size(10.dp))
                }
            }
        }
        if (clip.transitionIn != Transition.Cut) {
            Box(Modifier.align(Alignment.CenterStart).offset(x = (-4).dp).size(8.dp).graphicsLayer { rotationZ = 45f }.background(p.accent))
        }
        if (selected) {
            TrimHandle(model, clip, leading = true, pps = pps, modifier = Modifier.align(Alignment.CenterStart).offset(x = (-11).dp))
            TrimHandle(model, clip, leading = false, pps = pps, modifier = Modifier.align(Alignment.CenterEnd).offset(x = 11.dp))
        }
    }
}

private fun Modifier.fillMaxSize(): Modifier = this.fillMaxSize()

/** A gold handle that drags the clip's in or out point. */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun TrimHandle(model: VideoEditorModel, clip: Clip, leading: Boolean, pps: Float, modifier: Modifier) {
    val p = LocalPalette.current
    val haptics = LocalHapticFeedback.current
    Box(
        modifier
            .width(22.dp)
            .height(CLIP_HEIGHT)
            .pointerInput(clip.id, leading) {
                var base: Pair<Double, Double>? = null
                var dragged = 0f
                detectDragGestures(
                    onDragStart = {
                        val c = model.selectedClip ?: return@detectDragGestures
                        base = c.trimStart to c.trimEnd
                        dragged = 0f
                        model.beginInteraction()
                    },
                    onDragEnd = {
                        base = null
                        model.endInteraction()
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    },
                    onDragCancel = {
                        base = null
                        model.endInteraction()
                    },
                ) { change, amount ->
                    change.consume()
                    val b = base ?: return@detectDragGestures
                    dragged += amount.x
                    val delta = dragged / pps * clip.speed
                    var s = b.first
                    var e = b.second
                    when {
                        leading && !clip.isReversed -> s = b.first + delta
                        leading && clip.isReversed -> e = b.second - delta
                        !leading && !clip.isReversed -> e = b.second + delta
                        else -> s = b.first - delta
                    }
                    model.trimSelected(s, e)
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.width(6.dp).height(CLIP_HEIGHT * 0.55f).clip(CircleShape).background(p.accent))
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun LayerLane(model: VideoEditorModel, layers: List<TimedLayer>, width: Dp) {
    val p = LocalPalette.current
    Box(Modifier.width(width).height(12.dp)) {
        for (layer in layers) {
            val selected = model.selectedLayerID == layer.id
            val text = (layer.overlay.content as? OverlayContent.Text)?.text?.text
            val label = if (text != null) tr("Text: %@", text) else tr("Layer")
            Box(
                Modifier
                    .offset(x = POINTS_PER_SECOND * layer.start.toFloat())
                    .width(max((POINTS_PER_SECOND * (layer.end - layer.start).toFloat()).value, 6f).dp)
                    .height(12.dp)
                    .clickable(role = Role.Button) {
                        model.selectedLayerID = layer.id
                        if (model.activeTool != VideoTool.text) model.toolTapped(VideoTool.text)
                    }
                    .semantics { contentDescription = label; this.selected = selected },
                contentAlignment = Alignment.Center,
            ) {
                Box(Modifier.fillMaxWidth().height(6.dp).clip(CircleShape).background(if (selected) p.accent else p.textTertiary.copy(alpha = 0.6f)))
            }
        }
    }
}

/** "1.5×" with up to two decimals, as on iOS. */
fun speedLabel(speed: Double): String {
    val s = if (speed == floor(speed)) "%d".format(speed.toInt()) else "%.2f".format(speed).trimEnd('0').trimEnd('.', ',')
    return "$s×"
}
