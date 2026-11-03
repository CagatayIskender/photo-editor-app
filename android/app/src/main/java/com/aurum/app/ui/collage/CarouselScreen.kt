package com.aurum.app.ui.collage

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewModelScope
import com.aurum.app.collage.CarouselSession
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.Chip
import com.aurum.app.ui.common.DrawnCheckmark
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.GoldProgressRing
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.aurumPopIn
import com.aurum.app.ui.common.aurumPopOut
import com.aurum.app.ui.common.aurumRiseIn
import com.aurum.app.ui.common.aurumRiseOut
import com.aurum.app.ui.common.aurumShimmer
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.common.pressable
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.Entitlement

/** Carousel: one wide photo, cut into panels that swipe as one image. */
@Composable
fun CarouselScreen(model: AppViewModel) {
    val context = LocalContext.current
    val container = model.container
    val session = remember { CarouselSession(model.getApplication<Application>(), container, model.viewModelScope) }
    val entitlement by container.membership.entitlement.collectAsState()
    val haptic = LocalHapticFeedback.current

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) session.setPhoto(uri)
    }
    val pick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
    // Android 8 and 9 need a storage permission to add to the photo library.
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) session.export(container.membership.entitlement.value) else session.permissionDenied()
    }
    val saveAll = {
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        if (needsPermission) permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else session.export(entitlement)
    }

    AtelierScaffold(
        title = tr("Carousel"),
        onClose = model::closeFlow,
        action = {
            GoldButton(
                tr("Save all"),
                onClick = saveAll,
                compact = true,
                enabled = session.canExport,
                busy = session.phase is CarouselSession.Phase.Exporting,
            )
        },
    ) {
        Column(
            Modifier.weight(1f).fillMaxWidth().padding(Spacing.m),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            Source(session, onPick = pick)
            PanelStrip(session)
            Status(session, entitlement)
        }
        AtelierControls {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Panels"), style = AurumType.label, color = LocalPalette.current.textTertiary, modifier = Modifier.weight(1f))
                Stepper(
                    value = session.count,
                    range = CarouselSession.MIN_PANELS..CarouselSession.MAX_PANELS,
                    label = tr("Panels"),
                    onChange = {
                        session.setCount(it)
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    },
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                CarouselSession.aspects.forEach { aspect ->
                    Chip(aspect.label, selected = session.aspect == aspect, onClick = { session.setAspect(aspect) })
                }
                Spacer(Modifier.weight(1f))
                TextAction(tr("Change photo"), { pick() })
            }
        }
    }
}

/** The picker prompt before a photo is chosen, and a progress ring while it loads. */
@Composable
private fun Source(session: CarouselSession, onPick: () -> Unit) {
    val p = LocalPalette.current
    val phase = session.phase
    if (session.photo == null && phase !is CarouselSession.Phase.Loading) {
        val interaction = remember { MutableInteractionSource() }
        val shape = RoundedCornerShape(16.dp)
        Box(
            Modifier
                .fillMaxWidth()
                .height(220.dp)
                .aurumEntrance(0)
                .pressable(interaction)
                .clip(shape)
                .background(p.surface)
                .clickable(interactionSource = interaction, indication = null, role = Role.Button, onClick = onPick),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                tr("Choose a wide photo to begin"),
                style = AurumType.editorial, color = p.textSecondary, textAlign = TextAlign.Center,
                modifier = Modifier.padding(Spacing.l),
            )
        }
    } else if (phase is CarouselSession.Phase.Loading) {
        Box(Modifier.fillMaxWidth().heightIn(min = 160.dp), contentAlignment = Alignment.Center) {
            GoldProgressRing(progress = null, size = 40.dp)
        }
    }
}

@Composable
private fun PanelStrip(session: CarouselSession) {
    val p = LocalPalette.current
    val panels = session.panels
    if (panels.isEmpty()) return
    LazyRow(
        Modifier.fillMaxWidth().animateContentSize(motion()),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        itemsIndexed(panels) { index, panel ->
            val description = tr("Panel %lld of %lld", index + 1, panels.size)
            Box(
                Modifier
                    .aurumEntrance(index, 10.dp)
                    .semantics { contentDescription = description; role = Role.Image },
            ) {
                Image(
                    panel,
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.height(300.dp),
                )
                Text(
                    "${index + 1}/${panels.size}",
                    style = AurumType.label, color = p.textPrimary,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(6.dp)
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.45f))
                        .padding(horizontal = 6.dp, vertical = 3.dp),
                )
            }
        }
    }
}

@Composable
private fun Status(session: CarouselSession, entitlement: Entitlement) {
    val p = LocalPalette.current
    val rise = aurumRiseIn() togetherWith aurumRiseOut()
    val pop = aurumPopIn() togetherWith aurumPopOut()
    val kind = when (val phase = session.phase) {
        is CarouselSession.Phase.Exporting -> "exporting"
        is CarouselSession.Phase.Saved -> "saved"
        is CarouselSession.Phase.Failed -> "failed:${phase.message}"
        else -> if (session.photo != null) "hint" else "none"
    }
    AnimatedContent(
        targetState = kind,
        transitionSpec = { if (targetState == "saved") pop else rise },
        label = "carouselStatus",
        modifier = Modifier.heightIn(min = 48.dp),
    ) { target ->
        // Counts change while exporting, so they are read live rather than from the animated key.
        val phase = session.phase
        when {
            target == "exporting" && phase is CarouselSession.Phase.Exporting -> Row(
                Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Spacing.s),
            ) {
                GoldProgressRing(progress = phase.done.toFloat() / maxOf(phase.total, 1), size = 26.dp)
                Text(tr("Saving %lld of %lld…", phase.done, phase.total), style = AurumType.caption, color = p.textSecondary)
            }
            target == "saved" && phase is CarouselSession.Phase.Saved -> Row(
                Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
            ) {
                DrawnCheckmark(size = 20.dp)
                Text(tr("%lld panels saved to Photos, in order.", phase.count), style = AurumType.caption, color = p.accent)
            }
            target.startsWith("failed:") -> Text(target.removePrefix("failed:"), style = AurumType.caption, color = p.textSecondary)
            target == "hint" -> Text(
                if (entitlement == Entitlement.free) {
                    tr("Post the panels in order and they swipe as one photo. Free exports carry a small mark on the last panel.")
                } else {
                    tr("Post the panels in order and they swipe as one photo.")
                },
                style = AurumType.caption, color = p.textTertiary,
            )
            else -> Unit
        }
    }
}

/** A minus / count / plus control, with 48 dp targets. */
@Composable
private fun Stepper(value: Int, range: IntRange, label: String, onChange: (Int) -> Unit) {
    val p = LocalPalette.current
    val fewer = tr("Fewer panels")
    val more = tr("More panels")
    Row(
        Modifier.semantics(mergeDescendants = false) { stateDescription = value.toString() },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StepperButton("−", fewer, enabled = value > range.first) { onChange(value - 1) }
        Text(
            value.toString(),
            style = AurumType.headline, color = p.textPrimary, textAlign = TextAlign.Center,
            modifier = Modifier.width(36.dp).semantics { contentDescription = label },
        )
        StepperButton("+", more, enabled = value < range.last) { onChange(value + 1) }
    }
}

@Composable
private fun StepperButton(glyph: String, description: String, enabled: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    val interaction = remember { MutableInteractionSource() }
    Box(
        Modifier
            .size(48.dp)
            .pressable(interaction)
            .clip(CircleShape)
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(glyph, style = AurumType.title, color = if (enabled) p.accent else p.textTertiary.copy(alpha = 0.5f))
    }
}
