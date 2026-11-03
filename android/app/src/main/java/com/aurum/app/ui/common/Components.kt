package com.aurum.app.ui.common

import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Image
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.LocalReduceMotion
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.ui.theme.hex

/** Animation spec that collapses to a jump when the system has animations turned off. */
@Composable
fun <T> motion(durationMillis: Int = 240): FiniteAnimationSpec<T> =
    if (LocalReduceMotion.current) snap() else tween(durationMillis)

@Composable
fun GoldButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    compact: Boolean = false,
    busy: Boolean = false,
    /** A slow sheen of light, for the single most important action on a hero screen (paywall, export). */
    sheen: Boolean = false,
) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    val background by animateColorAsState(if (enabled) p.accent else p.accent.copy(alpha = 0.4f), motion(), label = "goldButton")
    Box(
        modifier
            .then(if (compact) Modifier else Modifier.fillMaxWidth())
            .heightIn(min = if (compact) 40.dp else 52.dp)
            .pressable(interaction, 0.975f)
            .clip(RoundedCornerShape(26.dp))
            .background(background)
            .aurumShimmer(active = sheen && enabled && !busy, intensity = 0.45f)
            .clickable(interactionSource = interaction, indication = LocalIndication.current, enabled = enabled && !busy, role = Role.Button, onClick = onClick)
            .padding(horizontal = Spacing.l, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Crossfade(busy, animationSpec = motion(), label = "goldButtonBusy") { isBusy ->
            if (isBusy) {
                CircularProgressIndicator(Modifier.size(20.dp), color = p.onAccent, strokeWidth = 2.dp)
            } else {
                Text(text, style = AurumType.headline, color = p.onAccent, textAlign = TextAlign.Center)
            }
        }
    }
}

@Composable
fun OutlineButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier
            .heightIn(min = 48.dp)
            .pressable(interaction, 0.975f)
            .clip(RoundedCornerShape(24.dp))
            .border(1.dp, p.hairline, RoundedCornerShape(24.dp))
            .clickable(interactionSource = interaction, indication = LocalIndication.current, role = Role.Button, onClick = onClick)
            .padding(horizontal = Spacing.m, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = p.textPrimary, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, style = AurumType.headline, color = p.textPrimary)
    }
}

@Composable
fun TextAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, color: Color? = null) {
    val p = LocalPalette.current
    Text(
        text,
        style = AurumType.headline,
        color = (color ?: p.accent).copy(alpha = if (enabled) 1f else 0.4f),
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .heightIn(min = 44.dp)
            .padding(horizontal = 10.dp, vertical = 12.dp),
    )
}

/** A 44 dp tappable icon with a spoken label. */
@Composable
fun IconAction(icon: ImageVector, label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, tint: Color? = null) {
    val p = LocalPalette.current
    Box(
        modifier
            .size(44.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = (tint ?: p.textPrimary).copy(alpha = if (enabled) 1f else 0.3f), modifier = Modifier.size(22.dp))
    }
}

@Composable
fun Chip(text: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, fontFamilyStyle: androidx.compose.ui.text.TextStyle? = null) {
    val p = LocalPalette.current
    val isSelected = selected
    val background by animateColorAsState(if (selected) p.accent else p.surfaceRaised, motion(), label = "chip")
    val foreground by animateColorAsState(if (selected) p.onAccent else p.textPrimary, motion(), label = "chipText")
    Box(
        modifier
            .heightIn(min = 36.dp)
            .pressClickable(role = Role.Tab, scale = 0.94f, onClick = onClick)
            .clip(RoundedCornerShape(18.dp))
            .background(background)
            .semantics { this.selected = isSelected }
            .padding(horizontal = 14.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, style = fontFamilyStyle ?: AurumType.caption, color = foreground, maxLines = 1)
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = AurumType.headline, color = LocalPalette.current.textPrimary, modifier = modifier.semantics { heading() })
}

@Composable
fun CrownBadge(size: Dp = 14.dp) {
    Icon(AurumIcons.crown, contentDescription = null, tint = LocalPalette.current.accent, modifier = Modifier.size(size))
}

/** A look as a square: the photo in that look when rendered, otherwise its swatch gradient. */
@Composable
fun LookThumbnail(
    name: String,
    image: ImageBitmap?,
    swatch: List<String>,
    selected: Boolean,
    premium: Boolean,
    modifier: Modifier = Modifier,
    size: Dp = 76.dp,
    favourite: Boolean = false,
) {
    val p = LocalPalette.current
    val border by animateDpAsState(if (selected) 2.dp else 1.dp, motion(), label = "lookBorder")
    val borderColor by animateColorAsState(if (selected) p.accent else p.hairline, motion(), label = "lookBorderColor")
    val lift by animateFloatAsState(if (selected) 1.04f else 1f, motion(), label = "lookLift")
    Column(modifier.width(size), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .size(size)
                .graphicsLayer { scaleX = lift; scaleY = lift }
                .clip(RoundedCornerShape(10.dp))
                .border(border, borderColor, RoundedCornerShape(10.dp)),
        ) {
            if (image != null) {
                Image(image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
            } else {
                Box(Modifier.matchParentSize().background(Brush.linearGradient(swatch.map(::hex).let { if (it.size >= 2) it else listOf(it.firstOrNull() ?: p.surface, p.surfaceRaised) })))
            }
            if (premium) {
                Box(Modifier.align(Alignment.TopEnd).padding(4.dp).clip(CircleShape).background(p.background.copy(alpha = 0.7f)).padding(3.dp)) {
                    CrownBadge(11.dp)
                }
            }
            if (favourite) {
                Icon(AurumIcons.bookmarkFilled, null, tint = p.accent, modifier = Modifier.align(Alignment.TopStart).padding(4.dp).size(12.dp))
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            name,
            style = AurumType.caption,
            color = if (selected) p.accent else p.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A labelled slider; values are shown as -100…100 or 0…100. */
@Composable
fun LabeledSlider(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onChange: (Float) -> Unit,
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
    format: (Float) -> String = { (it * 100).toInt().toString() },
) {
    val p = LocalPalette.current
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, style = AurumType.caption, color = p.textSecondary)
            Text(format(value), style = AurumType.caption, color = p.textTertiary)
        }
        Slider(
            value = value,
            onValueChange = onChange,
            onValueChangeFinished = onFinished,
            valueRange = range,
            colors = SliderDefaults.colors(
                thumbColor = p.accent,
                activeTrackColor = p.accent,
                inactiveTrackColor = p.hairline,
            ),
            modifier = Modifier.semantics { contentDescription = label },
        )
    }
}

/** A quiet centred message with an optional action, for empty and error states. */
@Composable
fun QuietState(title: String, body: String?, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    val p = LocalPalette.current
    Column(modifier.padding(Spacing.l), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Text(title, style = AurumType.editorial, color = p.textPrimary, textAlign = TextAlign.Center)
        if (body != null) Text(body, style = AurumType.body, color = p.textSecondary, textAlign = TextAlign.Center)
        if (action != null) {
            Spacer(Modifier.height(Spacing.xs))
            action()
        }
    }
}
