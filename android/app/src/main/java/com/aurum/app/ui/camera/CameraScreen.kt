package com.aurum.app.ui.camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.provider.Settings
import android.view.Surface
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.ui.unit.sp
import com.aurum.app.camera.LiveCamera
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.GoldProgressRing
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.LookThumbnail
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.common.pressable
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.LocalReduceMotion
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.LookApplication
import com.aurum.core.Tier
import com.aurum.core.render.LiveLut
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Strength of the live look, and of the look the Studio opens with: the iOS default. */
private const val LOOK_INTENSITY = 0.8

private enum class Access { Checking, Granted, Denied, DeniedForGood }

private fun Context.findActivity(): Activity? {
    var c: Context = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}

/**
 * The AURUM camera: a live preview wearing the chosen look, a strip of looks to
 * swap while framing, and a shutter. The shot opens in the Studio still wearing
 * its look, so it can be changed. Counterpart of the iOS `CameraView`.
 */
@Composable
fun CameraScreen(model: AppViewModel) {
    val context = LocalContext.current
    val p = LocalPalette.current
    var access by remember {
        mutableStateOf(
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) Access.Granted
            else Access.Checking,
        )
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        access = when {
            granted -> Access.Granted
            // Denied and Android will not show the prompt again: only Settings can change it.
            context.findActivity()?.let { androidx.core.app.ActivityCompat.shouldShowRequestPermissionRationale(it, Manifest.permission.CAMERA) } == false -> Access.DeniedForGood
            else -> Access.Denied
        }
    }
    LaunchedEffect(Unit) {
        if (access == Access.Checking) launcher.launch(Manifest.permission.CAMERA)
    }
    // Coming back from Settings with the permission switched on.
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            ) access = Access.Granted
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (access) {
            Access.Checking -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { GoldProgressRing(progress = null, size = 36.dp) }
            Access.Granted -> CameraContent(model)
            Access.Denied, Access.DeniedForGood -> DeniedState(
                canOpenSettingsOnly = access == Access.DeniedForGood,
                onAllow = { launcher.launch(Manifest.permission.CAMERA) },
                onOpenSettings = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                },
                onClose = { model.closeFlow() },
            )
        }
    }
}

@Composable
private fun DeniedState(canOpenSettingsOnly: Boolean, onAllow: () -> Unit, onOpenSettings: () -> Unit, onClose: () -> Unit) {
    val p = LocalPalette.current
    Column(
        Modifier.fillMaxSize().background(p.background).statusBarsPadding().padding(Spacing.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(AurumIcons.camera, contentDescription = null, tint = p.accent, modifier = Modifier.size(40.dp).aurumEntrance(0))
        Spacer(Modifier.height(Spacing.m))
        Text(tr("Camera access is off"), style = AurumType.title, color = p.textPrimary, textAlign = TextAlign.Center, modifier = Modifier.aurumEntrance(1))
        Spacer(Modifier.height(Spacing.xs))
        Text(
            tr("To shoot with a look applied, allow AURUM to use the camera in Settings. Your photos stay on your phone."),
            style = AurumType.body,
            color = p.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.aurumEntrance(2),
        )
        Spacer(Modifier.height(Spacing.l))
        GoldButton(
            text = if (canOpenSettingsOnly) tr("Open Settings") else tr("Allow camera"),
            onClick = if (canOpenSettingsOnly) onOpenSettings else onAllow,
            compact = true,
            modifier = Modifier.aurumEntrance(3),
        )
        Spacer(Modifier.height(Spacing.xs))
        TextAction(tr("Not now"), onClose, color = p.textSecondary, modifier = Modifier.aurumEntrance(4))
    }
}

@Composable
private fun FailedState(onClose: () -> Unit) {
    val p = LocalPalette.current
    Column(
        Modifier.fillMaxSize().background(p.background).statusBarsPadding().padding(Spacing.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(tr("The camera couldn't start."), style = AurumType.headline, color = p.textPrimary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(Spacing.m))
        GoldButton(text = tr("Close"), onClick = onClose, compact = true)
    }
}

@Composable
private fun CameraContent(model: AppViewModel) {
    val context = LocalContext.current
    val p = LocalPalette.current
    val reduce = LocalReduceMotion.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val lifecycleOwner = LocalLifecycleOwner.current
    val catalog = model.container.catalog
    val renderer = model.container.renderer

    val camera = remember { LiveCamera(context) }
    DisposableEffect(Unit) { onDispose { camera.release() } }
    val previewView = remember {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }

    var front by remember { mutableStateOf(false) }
    var ready by remember { mutableStateOf(false) }
    var lookID by remember { mutableStateOf<String?>(null) }
    var showsGrid by remember { mutableStateOf(false) }
    var timerSeconds by remember { mutableIntStateOf(0) }
    var flashMode by remember { mutableIntStateOf(0) }
    var countdown by remember { mutableStateOf<Int?>(null) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var focusPoint by remember { mutableStateOf<Offset?>(null) }
    val flashAlpha = remember { Animatable(0f) }
    val shutterPulse = remember { Animatable(1f) }
    val focusAlpha = remember { Animatable(0f) }
    val luts = remember { HashMap<String, LiveLut?>() }

    // Start, or switch lens. The bind follows the screen's lifecycle, so leaving the app stops the camera.
    val orientation = LocalConfiguration.current.orientation
    val rotation = LocalView.current.display?.rotation ?: Surface.ROTATION_0
    LaunchedEffect(front, rotation) {
        ready = false
        camera.bind(lifecycleOwner, previewView, front, rotation) { ok -> ready = ok }
    }

    LaunchedEffect(message) {
        if (message != null) {
            delay(3200)
            message = null
        }
    }

    fun selectLook(id: String?) {
        lookID = id
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        if (id == null) {
            camera.setLut(null)
            return
        }
        scope.launch {
            val lut = if (luts.containsKey(id)) luts[id] else withContext(Dispatchers.Default) {
                LiveLut.forLook(renderer, catalog, LookApplication.of(id, LOOK_INTENSITY))
            }.also { luts[id] = it }
            // Only the newest choice may reach the camera.
            if (lookID == id) camera.setLut(lut)
        }
    }

    fun cycleTimer() {
        timerSeconds = when (timerSeconds) { 0 -> 3; 3 -> 10; else -> 0 }
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
    }

    fun cycleFlash() {
        flashMode = (flashMode + 1) % 3
        camera.setFlash(flashMode)
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
    }

    val couldntTake = tr("The photo couldn't be taken. Please try again.")

    fun shutterTapped() {
        if (busy || countdown != null || !ready) return
        scope.launch {
            if (timerSeconds > 0) {
                for (n in timerSeconds downTo 1) {
                    countdown = n
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    delay(1000)
                }
                countdown = null
            }
            busy = true
            launch { // the shutter dips and springs back
                if (!reduce) {
                    shutterPulse.animateTo(0.78f, tween(70))
                    shutterPulse.animateTo(1f, spring(dampingRatio = 0.45f, stiffness = Spring.StiffnessMedium))
                }
            }
            val file: File? = camera.takePhoto()
            if (file == null) {
                busy = false
                message = couldntTake
                return@launch
            }
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            if (!reduce) {
                flashAlpha.snapTo(0.7f)
                flashAlpha.animateTo(0f, tween(350))
            }
            withContext(Dispatchers.IO) { camera.addToGallery(file) }
            camera.unbind()
            busy = false
            // The look is kept as an edit, not burned in: the Studio opens the original wearing it.
            model.openCapturedPhoto(Uri.fromFile(file), lookID)
        }
    }

    if (camera.failed) {
        FailedState(onClose = { model.closeFlow() })
        return
    }

    Column(Modifier.fillMaxSize().background(Color.Black).statusBarsPadding().navigationBarsPadding()) {
        // Top bar
        Row(
            Modifier.fillMaxWidth().height(52.dp).padding(horizontal = Spacing.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconAction(AurumIcons.close, tr("Close"), { model.closeFlow() }, enabled = !busy)
            Spacer(Modifier.weight(1f))
            val timerOff = tr("Off")
            val timerLabel = if (timerSeconds == 0) tr("Timer off") else tr("%lld s", timerSeconds)
            BarText(
                text = timerLabel,
                active = timerSeconds != 0,
                description = tr("Self-timer"),
                value = if (timerSeconds == 0) timerOff else tr("%lld seconds", timerSeconds),
                onClick = ::cycleTimer,
            )
            if (camera.hasFlash) {
                val flashLabel = when (flashMode) { 1 -> tr("Flash auto"); 2 -> tr("Flash on"); else -> tr("Flash off") }
                BarText(text = flashLabel, active = flashMode != 0, description = tr("Flash"), value = flashLabel, onClick = ::cycleFlash)
            }
            BarText(text = tr("Grid"), active = showsGrid, description = tr("Grid"), value = null, selected = showsGrid, onClick = {
                showsGrid = !showsGrid
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            })
            Spacer(Modifier.weight(1f))
            IconAction(AurumIcons.flip, tr("Switch camera"), {
                front = !front
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            }, enabled = !busy)
        }

        // Preview
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(horizontal = Spacing.xs), contentAlignment = Alignment.Center) {
            val ratio = if (orientation == Configuration.ORIENTATION_LANDSCAPE) 4f / 3f else 3f / 4f
            val w = minOf(maxWidth, maxHeight * ratio)
            val h = w / ratio
            val look = lookID?.let { catalog.look(it) }
            val previewLabel = if (look != null) tr("Camera preview, with the %@ look", look.name) else tr("Camera preview")
            Box(
                Modifier
                    .size(w, h)
                    .clip(RoundedCornerShape(12.dp))
                    .background(p.surface)
                    .semantics { contentDescription = previewLabel; role = Role.Image }
                    .pointerInput(Unit) {
                        detectTapGestures { offset ->
                            camera.focus(previewView, offset.x, offset.y)
                            focusPoint = offset
                            scope.launch {
                                focusAlpha.snapTo(1f)
                                delay(600)
                                focusAlpha.animateTo(0f, tween(400))
                            }
                        }
                    },
            ) {
                AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
                // The graded frame covers the plain preview; with "Original" there is none.
                androidx.compose.animation.AnimatedVisibility(camera.frame != null, enter = fadeIn(motion(200)), exit = fadeOut(motion(200))) {
                    camera.frame?.let { Image(it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                }
                if (showsGrid) CameraGrid()
                FocusRing(focusPoint, focusAlpha.value)
                if (!ready) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { GoldProgressRing(progress = null, size = 36.dp) }
                Box(Modifier.fillMaxSize().alpha(flashAlpha.value).background(Color.White))
            }
            countdown?.let { current ->
                val takingLabel = tr("Taking photo in %lld", current)
                AnimatedContent(
                    targetState = current,
                    transitionSpec = {
                        if (reduce) fadeIn(tween(0)) togetherWith fadeOut(tween(0))
                        else (scaleIn(initialScale = 1.4f, animationSpec = tween(320)) + fadeIn(tween(320))) togetherWith fadeOut(tween(200))
                    },
                    label = "countdown",
                    modifier = Modifier.semantics { contentDescription = takingLabel },
                ) { n ->
                    Text(n.toString(), style = AurumType.display.copy(fontSize = 84.sp), color = p.textPrimary)
                }
            }
            androidx.compose.animation.AnimatedVisibility(
                message != null,
                modifier = Modifier.align(Alignment.TopCenter).padding(top = Spacing.s),
                enter = fadeIn(motion(200)),
                exit = fadeOut(motion(200)),
            ) {
                Text(
                    message.orEmpty(),
                    style = AurumType.caption,
                    color = p.textPrimary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color.Black.copy(alpha = 0.7f))
                        .clickable { message = null }
                        .padding(horizontal = Spacing.m, vertical = Spacing.xs),
                )
            }
        }

        // Look strip
        val originalName = tr("Original")
        val originalSwatch = remember(p) { listOf(p.surfaceRaised.toHexString(), p.surface.toHexString()) }
        LazyRow(
            Modifier.fillMaxWidth().height(112.dp).aurumEntrance(1),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Spacing.m, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(Spacing.s),
        ) {
            item(key = "original") {
                LookTile(enabled = !busy, selected = lookID == null, label = originalName, onClick = { selectLook(null) }) {
                    LookThumbnail(originalName, null, originalSwatch, selected = lookID == null, premium = false)
                }
            }
            items(catalog.looks, key = { it.id }) { look ->
                LookTile(enabled = !busy, selected = lookID == look.id, label = look.name, onClick = { selectLook(look.id) }) {
                    LookThumbnail(look.name, null, look.swatch, selected = lookID == look.id, premium = look.tier == Tier.member)
                }
            }
        }

        // Shutter
        Box(Modifier.fillMaxWidth().height(112.dp).aurumEntrance(2), contentAlignment = Alignment.Center) {
            Shutter(enabled = ready && !busy && countdown == null, busy = busy, pulse = shutterPulse.value, onClick = ::shutterTapped)
        }
    }
}

private fun Color.toHexString(): String = String.format("#%06X", toArgb() and 0xFFFFFF)

@Composable
private fun BarText(text: String, active: Boolean, description: String, value: String?, onClick: () -> Unit, selected: Boolean? = null) {
    val p = LocalPalette.current
    Box(
        Modifier
            .heightIn(min = 48.dp)
            .widthIn(min = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = description
                if (value != null) stateDescription = value
                if (selected != null) this.selected = selected
            }
            .padding(horizontal = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, style = AurumType.label, color = if (active) p.accent else p.textSecondary, maxLines = 1)
    }
}

@Composable
private fun LookTile(enabled: Boolean, selected: Boolean, label: String, onClick: () -> Unit, content: @Composable () -> Unit) {
    val source = remember { MutableInteractionSource() }
    Box(
        Modifier
            .pressable(source)
            .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Tab, onClick = onClick)
            .semantics { contentDescription = label; this.selected = selected },
    ) { content() }
}

/** The shutter: a ring and a disc that sinks under the finger, springs on capture and shows progress while saving. */
@Composable
private fun Shutter(enabled: Boolean, busy: Boolean, pulse: Float, onClick: () -> Unit) {
    val p = LocalPalette.current
    val reduce = LocalReduceMotion.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val disc by animateFloatAsState(
        if (pressed && !reduce) 0.88f else 1f,
        spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMedium),
        label = "shutterDisc",
    )
    val ring by animateFloatAsState(
        if (pressed && !reduce) 0.95f else 1f,
        spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow),
        label = "shutterRing",
    )
    val label = tr("Shutter")
    Box(
        Modifier
            .size(88.dp)
            .clip(CircleShape)
            .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(78.dp).scale(ring).border(3.dp, p.textPrimary.copy(alpha = 0.9f), CircleShape))
        Box(Modifier.size(62.dp).scale(disc * pulse).clip(CircleShape).background(if (enabled || busy) p.textPrimary else p.textPrimary.copy(alpha = 0.4f)))
        if (busy) GoldProgressRing(progress = null, size = 30.dp)
    }
}

/** Rule-of-thirds lines over the preview. */
@Composable
private fun CameraGrid() {
    val line = LocalPalette.current.textPrimary.copy(alpha = 0.35f)
    Canvas(Modifier.fillMaxSize()) {
        for (i in 1..2) {
            val x = size.width * i / 3f
            val y = size.height * i / 3f
            drawLine(line, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1f)
            drawLine(line, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
        }
    }
}

/** A thin gold ring where the preview was tapped to focus. */
@Composable
private fun FocusRing(point: Offset?, alpha: Float) {
    if (point == null || alpha <= 0f) return
    val gold = LocalPalette.current.accent
    Canvas(Modifier.fillMaxSize()) {
        drawCircle(gold.copy(alpha = alpha), radius = 34.dp.toPx(), center = point, style = Stroke(1.5.dp.toPx()))
    }
}
