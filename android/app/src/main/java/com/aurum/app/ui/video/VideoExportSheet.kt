package com.aurum.app.ui.video

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.media3.common.util.UnstableApi
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.DrawnCheckmark
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.GoldProgressRing
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.OutlineButton
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.paywall.PaywallScreen
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.video.VideoRenderer
import com.aurum.core.Entitlement
import com.aurum.core.PremiumItem
import com.aurum.core.VideoExportRules
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.roundToInt

/** The phases of a video export (iOS `VideoExportViewModel.Phase`). */
private sealed interface Phase {
    data object Ready : Phase
    data class Rendering(val progress: Float) : Phase
    data object Saved : Phase
    data class ShareReady(val uri: Uri) : Phase
    data class Failed(val message: String) : Phase
}

/**
 * Save or Share a finished video. If it uses member items the sheet names
 * them and offers two equal choices: join, or export without them. Free
 * exports are capped at the free size and carry the small mark.
 */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
fun VideoExportSheet(app: AppViewModel, editor: VideoEditorModel, onDismiss: () -> Unit) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val container = app.container
    val content = editor.content
    val entitlement by container.membership.entitlement.collectAsState()
    var phase by remember { mutableStateOf<Phase>(Phase.Ready) }
    var withoutPremium by remember { mutableStateOf(false) }
    var showPaywall by remember { mutableStateOf(false) }
    var pendingToPhotos by remember { mutableStateOf(true) }
    val renderer = remember { VideoRenderer(context, container.catalog, content) }
    val original = editor.project

    LaunchedEffect(Unit) { if (editor.isPlaying) editor.togglePlay() }
    LaunchedEffect(entitlement) { if (entitlement == Entitlement.member) withoutPremium = false }

    val project = if (withoutPremium) VideoExportRules.strippingPremium(original, container.catalog, content.bookends) else original
    val decision = VideoExportRules.decision(project, entitlement, container.catalog, content.templates, content.bookends)
    val premiumItems = VideoExportRules.premiumItems(original, container.catalog, content.templates, content.bookends)
    val canExportWithout = VideoExportRules.canExportWithoutPremium(premiumItems)
    val rendering = phase is Phase.Rendering
    val noPermission = tr("AURUM needs permission to add videos. You can allow it in Settings.")
    val didntFinish = tr("The export didn't finish. Please try again.")

    fun export(toPhotos: Boolean) {
        if (decision.requiresMembership) { showPaywall = true; return }
        phase = Phase.Rendering(0f)
        scope.launch {
            phase = try {
                val dir = File(context.cacheDir, "VideoExport").apply { mkdirs() }
                dir.listFiles()?.forEach { it.delete() }
                val output = File(dir, "${container.brand.appName}-${original.id.toString().uppercase().take(8)}.mp4")
                val settings = VideoRenderer.Settings(
                    maxPixelSize = decision.maxPixelSize,
                    frameRate = 30,
                    watermark = if (decision.watermark) container.brand.watermarkText else null,
                    brandName = container.brand.appName,
                )
                renderer.render(project, settings, output) { value ->
                    if (phase is Phase.Rendering) phase = Phase.Rendering(value.coerceIn(0f, 1f))
                }
                container.prefs.recordCreation()
                editor.lastSavedProject = original
                if (toPhotos) {
                    VideoRenderer.saveToMovies(context, output)
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    Phase.Saved
                } else {
                    Phase.ShareReady(FileProvider.getUriForFile(context, context.packageName + ".files", output))
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: SecurityException) {
                Phase.Failed(noPermission)
            } catch (e: Exception) {
                Phase.Failed(didntFinish)
            }
        }
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) export(pendingToPhotos) else phase = Phase.Failed(noPermission)
    }

    fun save() {
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        pendingToPhotos = true
        if (needsPermission) permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else export(true)
    }

    if (showPaywall) {
        PaywallScreen(container, onClose = { showPaywall = false }, onMember = { showPaywall = false })
        return
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(p.background.copy(alpha = 0.6f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { if (!rendering) onDismiss() },
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                .background(p.surface)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                .aurumEntrance(distance = 48.dp)
                .animateContentSize(motion())
                .navigationBarsPadding()
                .padding(Spacing.l),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Export video"), style = AurumType.title, color = p.textPrimary, modifier = Modifier.weight(1f).semantics { heading() })
                IconAction(AurumIcons.close, tr("Close"), onDismiss, enabled = !rendering)
            }
            when (val s = phase) {
                is Phase.Rendering -> {
                    val progressLabel = tr("Export progress")
                    Column(Modifier.fillMaxWidth().heightIn(min = 120.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        GoldProgressRing(s.progress, size = 64.dp, modifier = Modifier.semantics { contentDescription = progressLabel })
                        Text(tr("Finishing your video…"), style = AurumType.body, color = p.textSecondary, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                        Text("${(s.progress * 100).roundToInt()}%", style = AurumType.caption, color = p.textTertiary)
                    }
                }
                Phase.Saved -> Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    DrawnCheckmark(56.dp)
                    Text(tr("Saved to Photos"), style = AurumType.headline, color = p.textPrimary, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    GoldButton(tr("Done"), onClick = onDismiss)
                }
                is Phase.ShareReady -> Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    val shareTitle = tr("Share")
                    GoldButton(shareTitle, onClick = {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "video/mp4"
                            putExtra(Intent.EXTRA_STREAM, s.uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        context.startActivity(Intent.createChooser(send, shareTitle))
                    }, modifier = Modifier.fillMaxWidth())
                    TextAction(tr("Done"), onDismiss, modifier = Modifier.align(Alignment.CenterHorizontally))
                }
                is Phase.Failed -> {
                    Text(s.message, style = AurumType.body, color = p.textSecondary)
                    GoldButton(tr("Try again"), onClick = { phase = Phase.Ready })
                }
                Phase.Ready -> if (decision.requiresMembership) {
                    MembershipChoice(app, decision.premiumItems, canExportWithout, onJoin = { showPaywall = true }, onWithout = { withoutPremium = true })
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        GoldButton(tr("Save"), onClick = ::save, sheen = true, modifier = Modifier.weight(1f))
                        OutlineButton(tr("Share"), onClick = { pendingToPhotos = false; export(false) }, modifier = Modifier.weight(1f), icon = AurumIcons.share)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                        val summary = if (decision.watermark) {
                            tr("Free export: up to %lld px with a small %@ mark", decision.maxPixelSize, container.brand.watermarkText)
                        } else {
                            tr("Up to 4K, no watermark")
                        }
                        Text(summary, style = AurumType.caption, color = p.textTertiary, modifier = Modifier.weight(1f, fill = false))
                        if (entitlement == Entitlement.free) TextAction(tr("Remove mark"), { showPaywall = true })
                    }
                }
            }
        }
    }
}

@Composable
private fun MembershipChoice(app: AppViewModel, items: List<PremiumItem>, canExportWithout: Boolean, onJoin: () -> Unit, onWithout: () -> Unit) {
    val p = LocalPalette.current
    Text(tr("This video uses member items"), style = AurumType.headline, color = p.textPrimary, modifier = Modifier.semantics { heading() })
    Text(
        if (items.size == 1) tr("1 member item in this video") else tr("%lld member items in this video", items.size),
        style = AurumType.caption, color = p.textTertiary,
    )
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (item in items) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                CrownBadge(16.dp)
                val name = when (item) {
                    is PremiumItem.Look -> item.name
                    is PremiumItem.Sticker -> tr("Members' sticker")
                    else -> trDynamic(item.displayName)
                }
                Text(name, style = AurumType.body, color = p.textPrimary)
            }
        }
    }
    GoldButton(tr("Join %@", app.container.brand.membershipName), onClick = onJoin, modifier = Modifier.fillMaxWidth())
    if (canExportWithout) {
        OutlineButton(tr("Export without them"), onClick = onWithout, modifier = Modifier.fillMaxWidth())
    } else {
        Text(tr("This template is for members, so it can't be exported without membership."), style = AurumType.caption, color = p.textTertiary)
    }
}
