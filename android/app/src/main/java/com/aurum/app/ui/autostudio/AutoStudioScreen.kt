package com.aurum.app.ui.autostudio

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AmbientGlow
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.GoldProgressRing
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.aurumRiseIn
import com.aurum.app.ui.common.aurumRiseOut
import com.aurum.app.ui.common.aurumSheetIn
import com.aurum.app.ui.common.aurumSheetOut
import com.aurum.app.ui.common.aurumShimmer
import com.aurum.app.ui.common.pressClickable
import com.aurum.app.ui.paywall.PaywallScreen
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.LocalReduceMotion
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.AutoFeature
import com.aurum.core.AutoSuggestion
import com.aurum.core.Tier
import kotlin.math.abs

/**
 * The Auto Studio: one photo, suggested one-tap fixes found on the phone, and
 * every tool as a card. Nothing is generated or uploaded.
 */
@Composable
fun AutoStudioScreen(model: AppViewModel) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val state = remember { AutoStudioModel(context.applicationContext, model.container, scope) }
    var open by remember { mutableStateOf<AutoFeature?>(null) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) state.setPhoto(uri)
    }
    val pickPhoto: () -> Unit = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }

    BackHandler(enabled = open != null && !state.isPaywallPresented) { open = null }
    BackHandler(enabled = state.isPaywallPresented) { state.isPaywallPresented = false }

    val reduce = LocalReduceMotion.current
    Box(Modifier.fillMaxSize().background(p.background)) {
        AnimatedContent(
            targetState = open,
            transitionSpec = {
                if (reduce) {
                    fadeIn(tween(140)) togetherWith fadeOut(tween(120))
                } else {
                    val forward = targetState != null
                    (slideInHorizontally(tween(360)) { if (forward) it / 3 else -it / 3 } + fadeIn(tween(300))) togetherWith
                        (slideOutHorizontally(tween(300)) { if (forward) -it / 4 else it / 4 } + fadeOut(tween(220)))
                }
            },
            label = "autoStudio",
        ) { feature ->
            if (feature == null) {
                AutoStudioHome(
                    state = state,
                    onClose = model::closeFlow,
                    onPick = pickPhoto,
                    onOpen = { f ->
                        state.select(f)
                        open = f
                    },
                    onSuggestion = { s ->
                        open = s.feature
                        state.apply(s)
                    },
                    onDepthMotion = model::openDepthMotion,
                )
            } else {
                AutoFeatureScreen(state, model, feature, onBack = { open = null }, onPick = pickPhoto)
            }
        }

        AnimatedVisibility(state.isPaywallPresented, enter = aurumSheetIn(), exit = aurumSheetOut()) {
            PaywallScreen(
                model.container,
                onClose = { state.isPaywallPresented = false },
                onMember = { state.isPaywallPresented = false },
            )
        }
    }
}

@Composable
private fun AutoStudioHome(
    state: AutoStudioModel,
    onClose: () -> Unit,
    onPick: () -> Unit,
    onOpen: (AutoFeature) -> Unit,
    onSuggestion: (AutoSuggestion) -> Unit,
    onDepthMotion: () -> Unit,
) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxSize()) {
        AmbientGlow(intensity = 0.6f)
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            AtelierHeader(tr("Auto Studio"), onClose)
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = Spacing.m),
                verticalArrangement = Arrangement.spacedBy(Spacing.l),
            ) {
                // Intro
                Column(Modifier.padding(horizontal = Spacing.m).aurumEntrance(0), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    Text(tr("Quick fixes, made on your phone."), style = AurumType.editorial, color = p.textPrimary)
                    Text(
                        tr("Open a photo and AURUM looks for faces, people, the horizon and the light, then suggests fixes. Everything runs on your phone with classic photo processing; nothing is uploaded."),
                        style = AurumType.caption, color = p.textSecondary,
                    )
                }

                // Photo
                Column(Modifier.padding(horizontal = Spacing.m).aurumEntrance(1), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                    val preview = state.sourcePreview
                    if (preview != null) {
                        AtelierImage(
                            preview, Modifier.fillMaxWidth().height(240.dp),
                            isScanning = state.isAnalysing, contentDescription = tr("Your photo"),
                        )
                        TextAction(tr("Change photo"), onPick, enabled = !state.isBusy)
                    } else {
                        AtelierImage(
                            null,
                            Modifier.fillMaxWidth().height(160.dp).clip(RoundedCornerShape(18.dp)).pressClickable(onClick = onPick),
                            placeholder = if (state.phase == AutoStudioModel.Phase.Loading) tr("Opening your photo…") else tr("Choose a photo to begin"),
                        )
                    }
                    val phase = state.phase
                    if (phase is AutoStudioModel.Phase.Failed && preview == null) {
                        Text(phase.message, style = AurumType.caption, color = p.textSecondary)
                    }
                }

                // Suggestions
                AnimatedVisibility(state.isAnalysing, enter = aurumRiseIn(), exit = aurumRiseOut()) {
                    AnalysingRow(Modifier.padding(horizontal = Spacing.m))
                }
                AnimatedVisibility(!state.isAnalysing && state.suggestions.isNotEmpty(), enter = aurumRiseIn(), exit = aurumRiseOut()) {
                    Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                        Text(tr("Suggested for this photo").uppercase(), style = AurumType.label, color = p.textTertiary, modifier = Modifier.padding(horizontal = Spacing.m))
                        Row(
                            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Spacing.m),
                            horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
                        ) {
                            state.suggestions.forEachIndexed { index, suggestion ->
                                CrownedChip(
                                    suggestionTitle(suggestion),
                                    selected = false,
                                    member = suggestion.feature.tier == Tier.member,
                                    onClick = { onSuggestion(suggestion) },
                                    modifier = Modifier.aurumEntrance(index, distance = 10.dp),
                                )
                            }
                        }
                    }
                }

                // Tools
                BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = Spacing.m)) {
                    val columns = if (maxWidth >= 600.dp) maxOf(3, (maxWidth / 200.dp).toInt()) else 2
                    val cards: List<AutoFeature?> = AutoFeature.entries + listOf(null)
                    Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        cards.chunked(columns).forEachIndexed { row, items ->
                            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                                items.forEachIndexed { col, feature ->
                                    val index = row * columns + col + 2
                                    val cardModifier = Modifier.weight(1f).aurumEntrance(index)
                                    if (feature != null) {
                                        FeatureCard(feature, cardModifier) { onOpen(feature) }
                                    } else {
                                        MotionCard(cardModifier, onDepthMotion)
                                    }
                                }
                                repeat(columns - items.size) { Spacer(Modifier.weight(1f)) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AnalysingRow(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(p.surface)
            .border(1.dp, p.accent.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .aurumShimmer(true, intensity = 0.12f, durationMillis = 2200)
            .padding(Spacing.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.s),
    ) {
        GoldProgressRing(null, size = 22.dp)
        Text(tr("Looking at your photo…"), style = AurumType.caption, color = p.textSecondary)
    }
}

/** A tool card: name, what it does, and whether keeping the result needs membership. */
@Composable
private fun FeatureCard(feature: AutoFeature, modifier: Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    val title = featureTitle(feature)
    val subtitle = featureSubtitle(feature)
    val footer = when {
        feature.tier == Tier.member -> tr("Free preview · members keep")
        feature == AutoFeature.portraitLooks -> tr("Free and members' looks")
        else -> tr("Free · on your phone")
    }
    CardFrame(modifier.semantics(mergeDescendants = true) {}, onClick) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Icon(featureIcon(feature), null, tint = p.accent, modifier = Modifier.size(22.dp))
            Spacer(Modifier.weight(1f))
            if (feature.tier == Tier.member) CrownBadge(16.dp)
        }
        Spacer(Modifier.height(4.dp))
        Text(title, style = AurumType.headline, color = p.textPrimary)
        Text(subtitle, style = AurumType.caption, color = p.textTertiary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.weight(1f))
        Text(footer, style = AurumType.label, color = p.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun MotionCard(modifier: Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    val title = tr("3D Motion")
    val subtitle = tr("Depth and gentle movement for a still photo")
    val footer = tr("On your phone")
    CardFrame(modifier.semantics(mergeDescendants = true) {}, onClick) {
        Icon(AutoStudioIcons.threeD, null, tint = p.accent, modifier = Modifier.size(22.dp))
        Spacer(Modifier.height(4.dp))
        Text(title, style = AurumType.headline, color = p.textPrimary)
        Text(subtitle, style = AurumType.caption, color = p.textTertiary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.weight(1f))
        Text(footer, style = AurumType.label, color = p.textSecondary, maxLines = 1)
    }
}

@Composable
private fun CardFrame(modifier: Modifier, onClick: () -> Unit, content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    Column(
        modifier
            .heightIn(min = 150.dp)
            .pressClickable(role = Role.Button, onClick = onClick)
            .clip(RoundedCornerShape(14.dp))
            .background(Brush.verticalGradient(listOf(p.surfaceRaised, p.surface)))
            .border(1.dp, p.hairline, RoundedCornerShape(14.dp))
            .padding(Spacing.s),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        content = content,
    )
}

// MARK: Text

@Composable
internal fun featureTitle(feature: AutoFeature): String = when (feature) {
    AutoFeature.enhance -> tr("Auto Enhance")
    AutoFeature.portraitBlur -> tr("Portrait Blur")
    AutoFeature.replaceBackground -> tr("Background")
    AutoFeature.relight -> tr("Relight")
    AutoFeature.retouch -> tr("Skin Retouch")
    AutoFeature.removeObject -> tr("Remove Object")
    AutoFeature.portraitLooks -> tr("Portrait Looks")
}

@Composable
internal fun featureSubtitle(feature: AutoFeature): String = when (feature) {
    AutoFeature.enhance -> tr("Tone, colour, horizon and red eye in one tap")
    AutoFeature.portraitBlur -> tr("A soft, blurred background behind people")
    AutoFeature.replaceBackground -> tr("Keep the subject, change what's behind")
    AutoFeature.relight -> tr("Soft, warm light on faces")
    AutoFeature.retouch -> tr("Natural smoothing, placed on each face")
    AutoFeature.removeObject -> tr("Brush over what shouldn't be there")
    AutoFeature.portraitLooks -> tr("Curated looks made for faces")
}

/** A suggestion's button title, such as "Straighten 2.3°". */
@Composable
internal fun suggestionTitle(suggestion: AutoSuggestion): String = when (suggestion.kind) {
    AutoSuggestion.Kind.fixRedEye -> tr("Fix red eye")
    AutoSuggestion.Kind.straighten -> tr("Straighten %@°", "%.1f".format(abs(suggestion.degrees ?: 0.0)))
    AutoSuggestion.Kind.brightenFaces -> tr("Brighten faces")
    AutoSuggestion.Kind.blurBackground -> tr("Blur background")
    AutoSuggestion.Kind.balanceColour -> tr("Balance colour")
    AutoSuggestion.Kind.smoothSkin -> tr("Smooth skin")
    AutoSuggestion.Kind.enhance -> tr("Enhance")
}

private fun featureIcon(feature: AutoFeature): ImageVector = when (feature) {
    AutoFeature.enhance -> AutoStudioIcons.wand
    AutoFeature.portraitBlur -> AurumIcons.camera
    AutoFeature.replaceBackground -> AurumIcons.layers
    AutoFeature.relight -> AurumIcons.sparkle
    AutoFeature.retouch -> AutoStudioIcons.retouch
    AutoFeature.removeObject -> AutoStudioIcons.eraser
    AutoFeature.portraitLooks -> AutoStudioIcons.looks
}

/** Line icons for the Auto Studio, drawn like [AurumIcons] on a 24 unit grid. */
internal object AutoStudioIcons {
    private fun icon(name: String, vararg paths: String): ImageVector {
        val b = ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f)
        for (d in paths) {
            b.addPath(
                addPathNodes(d),
                stroke = SolidColor(androidx.compose.ui.graphics.Color.Black),
                strokeLineWidth = 1.5f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round,
            )
        }
        return b.build()
    }

    val wand = icon("wand", "M4,20 L14,10 M12,8 L16,12", "M17,3 V6 M15.5,4.5 H18.5 M20,8 V10 M19,9 H21")
    val retouch = icon("retouch", "M12,3.5 C7.5,3.5 5.5,7 5.5,11 C5.5,16 8.5,20.5 12,20.5 C15.5,20.5 18.5,16 18.5,11 C18.5,7 16.5,3.5 12,3.5 Z", "M9,10.5 H10 M14,10.5 H15 M9.5,15.5 C11,16.7 13,16.7 14.5,15.5")
    val eraser = icon("eraser", "M4,16 L13,7 L19,13 L12,20 H7 Z M8.5,11.5 L14.5,17.5 M12,20 H20")
    val looks = icon("looks", "M9,5 a5,5 0 1,0 0.01,0 Z M15,5 a5,5 0 1,0 0.01,0 Z M12,10 a5,5 0 1,0 0.01,0 Z")
    val threeD = icon("threeD", "M12,3 L20,7.5 V16.5 L12,21 L4,16.5 V7.5 Z M4,7.5 L12,12 L20,7.5 M12,12 V21")
}
