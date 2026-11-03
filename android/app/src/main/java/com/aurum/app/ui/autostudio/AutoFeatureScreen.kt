package com.aurum.app.ui.autostudio

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.Chip
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.GoldProgressRing
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.LabeledSlider
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.aurumRiseIn
import com.aurum.app.ui.common.aurumRiseOut
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.common.pressClickable
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.ui.theme.hex
import com.aurum.core.AutoFeature
import com.aurum.core.AutoSuggestion
import com.aurum.core.NormalizedPoint
import com.aurum.core.PortraitLook
import com.aurum.core.Straighten
import com.aurum.core.Tier
import com.aurum.core.render.OnDevicePixels
import kotlin.math.min

/**
 * One Auto Studio tool: the photo, the tool's settings, a free preview, and
 * opening the result in the Studio.
 */
@Composable
internal fun AutoFeatureScreen(state: AutoStudioModel, app: AppViewModel, feature: AutoFeature, onBack: () -> Unit, onPick: () -> Unit) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val backgroundPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) state.setBackgroundPhoto(uri)
    }
    val pickBackground = { backgroundPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
    // Android 8 and 9 need storage access to add the result to the photo library.
    val storagePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        state.openResultInStudio(app, permissionDenied = !granted)
    }
    val openInStudio = {
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && !state.resultRequiresMembership &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        if (needsPermission) storagePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else state.openResultInStudio(app)
    }

    Column(Modifier.fillMaxSize().background(p.background).statusBarsPadding().navigationBarsPadding()) {
        AtelierHeader(featureTitle(feature), onBack, back = true)
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Spacing.m),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            Text(featureSubtitle(feature), style = AurumType.body, color = p.textSecondary, modifier = Modifier.aurumEntrance(0))
            Stage(state, feature, onPick, Modifier.fillMaxWidth().height(380.dp).aurumEntrance(1))
            Row(Modifier.fillMaxWidth().aurumEntrance(2), verticalAlignment = Alignment.CenterVertically) {
                TextAction(if (state.hasPhoto) tr("Change photo") else tr("Choose a photo"), onPick, enabled = !state.isBusy)
                Spacer(Modifier.weight(1f))
                if (state.isAnalysing) {
                    val label = tr("Looking at your photo…")
                    GoldProgressRing(null, size = 22.dp, modifier = Modifier.semantics { contentDescription = label })
                }
            }
            if (feature.tier == Tier.member) {
                AtelierNote(
                    tr("Members' tool"),
                    tr("Preview it as often as you like. Membership is needed only to keep the result."),
                    Modifier.aurumEntrance(3),
                )
            }
            AnimatedVisibility(state.hasPhoto && state.phase != AutoStudioModel.Phase.Result, enter = aurumRiseIn(), exit = aurumRiseOut()) {
                Options(state, feature, pickBackground)
            }
            Status(state)
            Actions(state, openInStudio)
        }
    }
}

// MARK: Stage

@Composable
private fun Stage(state: AutoStudioModel, feature: AutoFeature, onPick: () -> Unit, modifier: Modifier) {
    val enter = motion<Float>(420)
    val exit = motion<Float>(220)
    val result = state.resultPreview
    val source = state.sourcePreview
    val mode = when {
        result != null -> 2
        source != null -> 1
        else -> 0
    }
    AnimatedContent(
        targetState = mode,
        transitionSpec = { fadeIn(enter) togetherWith fadeOut(exit) },
        modifier = modifier,
        label = "stage",
    ) { m ->
        when {
            m == 2 && result != null -> BeforeAfterReveal(source, result, contentDescription = tr("Result"))
            m >= 1 && source != null && feature.requiresMask -> MaskCanvas(state, source)
            m >= 1 && source != null -> AtelierImage(
                source, Modifier.fillMaxSize(),
                isScanning = state.isAnalysing || state.phase == AutoStudioModel.Phase.Working,
                contentDescription = tr("Your photo"),
            )
            else -> AtelierImage(
                null,
                Modifier.fillMaxSize().clip(RoundedCornerShape(18.dp)).pressClickable(onClick = onPick),
                placeholder = if (state.phase == AutoStudioModel.Phase.Loading) tr("Opening your photo…") else tr("Choose a photo to begin"),
            )
        }
    }
}

/** The photo with brush strokes painted over it. Drag to paint (or erase). */
@Composable
private fun MaskCanvas(state: AutoStudioModel, image: androidx.compose.ui.graphics.ImageBitmap) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    val label = tr("Your photo. Drag to brush over what should be removed.")
    val value = if (state.maskEditor.hasPaint) tr("Brushed") else tr("Nothing brushed yet")
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val scale = min(constraints.maxWidth.toFloat() / image.width, constraints.maxHeight.toFloat() / image.height)
        val w = with(density) { (image.width * scale).toDp() }
        val h = with(density) { (image.height * scale).toDp() }
        Box(
            Modifier
                .size(w, h)
                .clip(RoundedCornerShape(10.dp))
                .semantics {
                    contentDescription = label
                    stateDescription = value
                }
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        val fw = size.width.toFloat()
                        val fh = size.height.toFloat()
                        fun point(o: Offset) = NormalizedPoint((o.x / fw).toDouble(), (o.y / fh).toDouble())
                        state.maskEditor = state.maskEditor.extend(point(down.position))
                        down.consume()
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) break
                            state.maskEditor = state.maskEditor.extend(point(change.position))
                            change.consume()
                        }
                        state.maskEditor = state.maskEditor.endStroke()
                    }
                },
        ) {
            Image(image, null, contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
            val editor = state.maskEditor
            Canvas(Modifier.fillMaxSize().graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen, alpha = 0.55f)) {
                val side = min(size.width, size.height)
                val strokes = editor.mask.strokes.map { Triple(it.points, it.radius, it.isEraser) } +
                    (if (editor.current.isNotEmpty()) listOf(Triple(editor.current, editor.radius, editor.isEraser)) else emptyList())
                for ((points, radius, eraser) in strokes) {
                    if (points.isEmpty()) continue
                    val width = (radius * 2 * side).toFloat()
                    val blend = if (eraser) BlendMode.Clear else BlendMode.SrcOver
                    if (points.size == 1) {
                        val c = Offset((points[0].x * size.width).toFloat(), (points[0].y * size.height).toFloat())
                        drawCircle(p.accent, radius = width / 2, center = c, blendMode = blend)
                        continue
                    }
                    val path = Path()
                    points.forEachIndexed { i, pt ->
                        val x = (pt.x * size.width).toFloat()
                        val y = (pt.y * size.height).toFloat()
                        if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                    }
                    drawPath(path, p.accent, style = Stroke(width = width, cap = StrokeCap.Round, join = StrokeJoin.Round), blendMode = blend)
                }
            }
        }
    }
}

// MARK: Options

@Composable
private fun Options(state: AutoStudioModel, feature: AutoFeature, pickBackground: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        when (feature) {
            AutoFeature.enhance -> Section(tr("Include")) {
                val o = state.enhanceOptions
                ChipRow {
                    Chip(tr("Auto tone"), o.autoTone, { state.enhanceOptions = o.copy(autoTone = !o.autoTone) })
                    Chip(tr("White balance"), o.whiteBalance, { state.enhanceOptions = o.copy(whiteBalance = !o.whiteBalance) })
                    Chip(straightenTitle(state), o.straighten, { state.enhanceOptions = o.copy(straighten = !o.straighten) })
                    Chip(tr("Red eye"), o.redEye, { state.enhanceOptions = o.copy(redEye = !o.redEye) })
                    Chip(tr("Clarity"), o.clarity, { state.enhanceOptions = o.copy(clarity = !o.clarity) })
                }
            }
            AutoFeature.portraitBlur -> Section(tr("Blur")) {
                LabeledSlider(tr("Blur amount"), state.blurAmount.toFloat(), 0.1f..1f, { state.blurAmount = it.toDouble() }, {})
            }
            AutoFeature.replaceBackground -> Section(tr("Background")) {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    AutoBackgroundChoice.entries.forEachIndexed { index, choice ->
                        BackgroundSwatch(state, choice, Modifier.aurumEntrance(index, distance = 8.dp)) {
                            if (choice == AutoBackgroundChoice.photo && (!state.hasBackgroundPhoto || state.background == AutoBackgroundChoice.photo)) {
                                pickBackground()
                            } else {
                                state.background = choice
                            }
                        }
                    }
                }
                if (state.hasBackgroundPhoto && state.background == AutoBackgroundChoice.photo) {
                    TextAction(tr("Choose another photo"), pickBackground)
                }
            }
            AutoFeature.relight -> Section(tr("Light from")) {
                ChipRow {
                    for (d in OnDevicePixels.LightDirection.entries) {
                        Chip(directionTitle(d), state.lightDirection == d, { state.lightDirection = d })
                    }
                }
                LabeledSlider(tr("Light intensity"), state.lightIntensity.toFloat(), 0f..1f, { state.lightIntensity = it.toDouble() }, {})
            }
            AutoFeature.retouch -> Section(tr("Strength")) {
                LabeledSlider(tr("Retouch strength"), state.retouchStrength.toFloat(), 0f..1f, { state.retouchStrength = it.toDouble() }, {})
            }
            AutoFeature.removeObject -> Section(tr("Brush")) {
                val editor = state.maskEditor
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    Chip(tr("Paint"), !editor.isEraser, { state.maskEditor = editor.copy(isEraser = false) })
                    Chip(tr("Erase"), editor.isEraser, { state.maskEditor = editor.copy(isEraser = true) })
                    Spacer(Modifier.weight(1f))
                    IconAction(AurumIcons.undo, tr("Undo stroke"), { state.maskEditor = state.maskEditor.undo() }, enabled = editor.canUndo)
                    TextAction(tr("Clear"), { state.maskEditor = state.maskEditor.clear() }, enabled = editor.canUndo)
                }
                LabeledSlider(
                    tr("Brush size"), editor.radius.toFloat(), 0.01f..0.12f,
                    { v -> state.maskEditor = state.maskEditor.copy(radius = (Math.round(v * 100) / 100.0).coerceIn(0.01, 0.12)) }, {},
                )
                Text(
                    tr("Works best on small things against plain or repeating backgrounds, such as sky, sand, walls or grass."),
                    style = AurumType.caption, color = LocalPalette.current.textTertiary,
                )
            }
            AutoFeature.portraitLooks -> Section(tr("Look")) {
                ChipRow {
                    for (look in PortraitLook.library) {
                        CrownedChip(trDynamic(look.name), state.portraitLookID == look.id, look.tier == Tier.member, { state.portraitLookID = look.id })
                    }
                }
            }
        }
    }
}

/** "Straighten 2.3°" when a tilted horizon was found, otherwise "Straighten". */
@Composable
private fun straightenTitle(state: AutoStudioModel): String {
    val degrees = state.analysis?.horizonDegrees
    return if (degrees != null && Straighten.isWorthCorrecting(degrees)) {
        suggestionTitle(AutoSuggestion(AutoSuggestion.Kind.straighten, 0.0, degrees))
    } else {
        tr("Straighten")
    }
}

@Composable
private fun directionTitle(d: OnDevicePixels.LightDirection): String = when (d) {
    OnDevicePixels.LightDirection.front -> tr("Front")
    OnDevicePixels.LightDirection.left -> tr("Left")
    OnDevicePixels.LightDirection.right -> tr("Right")
    OnDevicePixels.LightDirection.above -> tr("Above")
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Text(title.uppercase(), style = AurumType.label, color = LocalPalette.current.textTertiary)
        content()
    }
}

@Composable
private fun ChipRow(content: @Composable () -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Spacing.xs), verticalAlignment = Alignment.CenterVertically) {
        content()
    }
}

@Composable
private fun BackgroundSwatch(state: AutoStudioModel, choice: AutoBackgroundChoice, modifier: Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    val isSelected = state.background == choice
    val border by animateDpAsState(if (isSelected) 2.dp else 1.dp, motion(), label = "swatchBorder")
    val title = backgroundTitle(choice)
    Column(
        modifier
            .pressClickable(role = Role.RadioButton, onClick = onClick)
            .semantics(mergeDescendants = true) { selected = isSelected }
            .padding(2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier
                .size(56.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Brush.verticalGradient(choice.swatch.map(::hex)))
                .border(border, if (isSelected) p.accent else p.hairline, RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.Center,
        ) {
            if (choice == AutoBackgroundChoice.photo) {
                Icon(AurumIcons.camera, null, tint = p.textSecondary, modifier = Modifier.size(20.dp))
            }
        }
        Text(title, style = AurumType.caption, color = if (isSelected) p.textPrimary else p.textTertiary)
    }
}

@Composable
private fun backgroundTitle(choice: AutoBackgroundChoice): String = when (choice) {
    AutoBackgroundChoice.ivory -> tr("Ivory")
    AutoBackgroundChoice.onyx -> tr("Onyx")
    AutoBackgroundChoice.champagne -> tr("Champagne")
    AutoBackgroundChoice.blush -> tr("Blush")
    AutoBackgroundChoice.softFocus -> tr("Soft focus")
    AutoBackgroundChoice.photo -> tr("Your photo")
}

// MARK: Status and actions

@Composable
private fun Status(state: AutoStudioModel) {
    val p = LocalPalette.current
    val phase = state.phase
    val busy = phase == AutoStudioModel.Phase.Loading || phase == AutoStudioModel.Phase.Saving || phase == AutoStudioModel.Phase.Working
    AnimatedVisibility(busy, enter = aurumRiseIn(), exit = aurumRiseOut()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            GoldProgressRing(null, size = 24.dp)
            val text = when (phase) {
                AutoStudioModel.Phase.Saving -> tr("Saving to Photos…")
                AutoStudioModel.Phase.Working -> tr("Working…")
                else -> tr("Opening your photo…")
            }
            Text(text, style = AurumType.caption, color = p.textSecondary, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        }
    }
    if (phase is AutoStudioModel.Phase.Failed) {
        Text(phase.message, style = AurumType.caption, color = p.textSecondary, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
    }
}

@Composable
private fun Actions(state: AutoStudioModel, openInStudio: () -> Unit) {
    val p = LocalPalette.current
    if (state.phase == AutoStudioModel.Phase.Result) {
        Column(Modifier.fillMaxWidth().aurumEntrance(0), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            GoldButton(tr("Open in Studio"), openInStudio, sheen = true)
            TextAction(tr("Discard"), state::discardResult, color = p.textSecondary)
        }
    } else if (state.hasPhoto) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            val issue = state.runIssue
            GoldButton(tr("Preview"), state::run, enabled = !state.isBusy && issue == null, busy = state.phase == AutoStudioModel.Phase.Working)
            if (issue != null) {
                Text(issue, style = AurumType.caption, color = p.textSecondary)
            } else {
                Text(tr("Free to preview. Your photo stays on your phone."), style = AurumType.caption, color = p.textTertiary)
            }
        }
    }
}
