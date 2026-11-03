package com.aurum.app.ui.common

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.LocalReduceMotion

/**
 * The Android counterpart of AurumDesign's MotionKit: entrances, press
 * states, shimmer, ambient glow, a drawn checkmark and a gold progress ring.
 * Every effect honours the system "Remove animations" setting
 * ([LocalReduceMotion]): movement is dropped and only fades (or nothing) remain.
 */
object Motion {
    const val entranceMillis = 520
    const val staggerMillis = 45
    const val shimmerMillis = 2600
}

/** Fades and lifts the element in on first composition, staggered by [index]. Only fades with reduced motion. */
fun Modifier.aurumEntrance(index: Int = 0, distance: Dp = 14.dp, delayMillis: Int = 0): Modifier = composed {
    val reduce = LocalReduceMotion.current
    val progress = remember { Animatable(if (reduce) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!reduce) {
            progress.animateTo(
                1f,
                tween(Motion.entranceMillis, delayMillis = delayMillis + (index.coerceAtMost(12) * Motion.staggerMillis)),
            )
        }
    }
    graphicsLayer {
        alpha = progress.value
        translationY = (1f - progress.value) * distance.toPx()
    }
}

/** A tile or card that sinks slightly under the finger. Pass the same [interaction] to its `clickable`. */
fun Modifier.pressable(interaction: MutableInteractionSource, scale: Float = 0.965f): Modifier = composed {
    val pressed by interaction.collectIsPressedAsState()
    val reduce = LocalReduceMotion.current
    val target = if (pressed && !reduce) scale else 1f
    val s by animateFloatAsState(target, spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow), label = "press")
    graphicsLayer { scaleX = s; scaleY = s; alpha = if (pressed && reduce) 0.8f else 1f }
}

/** A slow diagonal sheen of champagne light across the element. Still with reduced motion. */
fun Modifier.aurumShimmer(active: Boolean = true, intensity: Float = 0.22f, durationMillis: Int = Motion.shimmerMillis): Modifier = composed {
    if (!active || LocalReduceMotion.current) return@composed this
    val accent = LocalPalette.current.accent
    val t = rememberInfiniteTransition(label = "shimmer")
    val phase by t.animateFloat(
        -1f, 2f,
        infiniteRepeatable(tween(durationMillis, easing = LinearEasing), RepeatMode.Restart),
        label = "shimmerPhase",
    )
    drawWithContent {
        drawContent()
        val w = size.width
        val x = phase * w
        drawRect(
            Brush.linearGradient(
                listOf(Color.Transparent, accent.copy(alpha = intensity), Color.Transparent),
                start = Offset(x - w * 0.35f, 0f),
                end = Offset(x + w * 0.35f, size.height),
            ),
        )
    }
}

/** A rounded placeholder that breathes while content loads. */
@Composable
fun SkeletonBlock(modifier: Modifier = Modifier, cornerRadius: Dp = 12.dp) {
    val p = LocalPalette.current
    Box(modifier.clip(RoundedCornerShape(cornerRadius)).background(p.surface).aurumShimmer(intensity = 0.12f))
}

/** A slow-drifting champagne glow over the onyx background, for hero screens. Still with reduced motion. */
@Composable
fun AmbientGlow(modifier: Modifier = Modifier, intensity: Float = 1f) {
    val accent = LocalPalette.current.accent
    val reduce = LocalReduceMotion.current
    val drift = if (reduce) {
        0.5f
    } else {
        val t = rememberInfiniteTransition(label = "glow")
        val v by t.animateFloat(0f, 1f, infiniteRepeatable(tween(14000, easing = LinearEasing), RepeatMode.Reverse), label = "glowDrift")
        v
    }
    Canvas(modifier.fillMaxSize()) {
        val c1 = Offset(size.width * (0.2f + 0.5f * drift), size.height * (0.15f + 0.1f * drift))
        drawCircle(
            Brush.radialGradient(listOf(accent.copy(alpha = 0.16f * intensity), Color.Transparent), center = c1, radius = size.maxDimension * 0.55f),
            radius = size.maxDimension * 0.55f, center = c1,
        )
        val c2 = Offset(size.width * (0.85f - 0.4f * drift), size.height * (0.75f - 0.1f * drift))
        drawCircle(
            Brush.radialGradient(listOf(accent.copy(alpha = 0.08f * intensity), Color.Transparent), center = c2, radius = size.maxDimension * 0.45f),
            radius = size.maxDimension * 0.45f, center = c2,
        )
    }
}

/** Rise and fade, for cards and panels. A plain fade with reduced motion. */
@Composable
fun aurumRiseIn(): EnterTransition =
    if (LocalReduceMotion.current) fadeIn(tween(160)) else fadeIn(tween(280)) + slideInVertically(tween(320)) { it / 8 }

@Composable
fun aurumRiseOut(): ExitTransition =
    if (LocalReduceMotion.current) fadeOut(tween(120)) else fadeOut(tween(200)) + slideOutVertically(tween(240)) { it / 10 }

/** Pop in, for badges, checkmarks and small confirmations. */
@Composable
fun aurumPopIn(): EnterTransition =
    if (LocalReduceMotion.current) fadeIn(tween(120)) else fadeIn(tween(180)) + scaleIn(spring(dampingRatio = 0.6f), initialScale = 0.7f)

@Composable
fun aurumPopOut(): ExitTransition =
    if (LocalReduceMotion.current) fadeOut(tween(100)) else fadeOut(tween(140)) + scaleOut(tween(140), targetScale = 0.85f)

/** Slides up from the bottom edge, for tool sheets and panels. */
@Composable
fun aurumSheetIn(): EnterTransition =
    if (LocalReduceMotion.current) fadeIn(tween(140)) else slideInVertically(spring(dampingRatio = 0.86f, stiffness = Spring.StiffnessMediumLow)) { it } + fadeIn(tween(160))

@Composable
fun aurumSheetOut(): ExitTransition =
    if (LocalReduceMotion.current) fadeOut(tween(120)) else slideOutVertically(tween(220)) { it } + fadeOut(tween(180))

/** A gold check that draws itself, for "Saved" and purchase confirmations. */
@Composable
fun DrawnCheckmark(size: Dp = 56.dp, modifier: Modifier = Modifier) {
    val accent = LocalPalette.current.accent
    val reduce = LocalReduceMotion.current
    val ring = remember { Animatable(if (reduce) 1f else 0f) }
    val tick = remember { Animatable(if (reduce) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!reduce) {
            ring.animateTo(1f, tween(420))
            tick.animateTo(1f, tween(320))
        }
    }
    Canvas(modifier.size(size)) {
        val stroke = this.size.minDimension * 0.06f
        drawArc(accent, -90f, 360f * ring.value, false, style = Stroke(stroke, cap = StrokeCap.Round))
        val w = this.size.width
        val h = this.size.height
        val path = Path().apply {
            moveTo(w * 0.29f, h * 0.52f)
            lineTo(w * 0.44f, h * 0.66f)
            lineTo(w * 0.72f, h * 0.37f)
        }
        val measure = PathMeasure().apply { setPath(path, false) }
        val partial = Path()
        measure.getSegment(0f, measure.length * tick.value, partial, true)
        drawPath(partial, accent, style = Stroke(stroke * 1.2f, cap = StrokeCap.Round))
    }
}

/** A thin gold progress ring with a soft trailing glow. Pass null for an indeterminate spinner. */
@Composable
fun GoldProgressRing(progress: Float?, size: Dp = 44.dp, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val reduce = LocalReduceMotion.current
    val spin = if (progress == null && !reduce) {
        val t = rememberInfiniteTransition(label = "ring")
        val v by t.animateFloat(0f, 360f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "ringSpin")
        v
    } else 0f
    val shown by animateFloatAsState(progress ?: 0.28f, if (reduce) tween(0) else tween(300), label = "ringProgress")
    Canvas(
        modifier.size(size).semantics {
            if (progress != null) progressBarRangeInfo = ProgressBarRangeInfo(progress.coerceIn(0f, 1f), 0f..1f)
        },
    ) {
        val stroke = this.size.minDimension * 0.07f
        drawCircle(p.hairline, style = Stroke(stroke))
        val sweep = 360f * shown.coerceIn(0f, 1f)
        val start = -90f + spin
        drawArc(p.accent.copy(alpha = 0.25f), start, sweep, false, style = Stroke(stroke * 2.6f, cap = StrokeCap.Round))
        drawArc(p.accent, start, sweep, false, style = Stroke(stroke, cap = StrokeCap.Round))
    }
}

/** A full-surface overlay with a centred ring and a short caption, for long on-device work. */
@Composable
fun BusyVeil(progress: Float?, modifier: Modifier = Modifier, caption: @Composable (() -> Unit)? = null) {
    val p = LocalPalette.current
    Box(modifier.fillMaxSize().background(p.background.copy(alpha = 0.72f)), contentAlignment = androidx.compose.ui.Alignment.Center) {
        androidx.compose.foundation.layout.Column(
            horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
            verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp),
        ) {
            GoldProgressRing(progress)
            caption?.invoke()
        }
    }
}

/** `clickable` with the sink-under-the-finger press state of [pressable], for tiles and cards. */
fun Modifier.pressClickable(
    role: androidx.compose.ui.semantics.Role = androidx.compose.ui.semantics.Role.Button,
    onClickLabel: String? = null,
    enabled: Boolean = true,
    scale: Float = 0.965f,
    onClick: () -> Unit,
): Modifier = composed {
    val interaction = remember { MutableInteractionSource() }
    pressable(interaction, scale).then(
        Modifier.clickable(
            interactionSource = interaction,
            indication = androidx.compose.foundation.LocalIndication.current,
            enabled = enabled,
            onClickLabel = onClickLabel,
            role = role,
            onClick = onClick,
        ),
    )
}
