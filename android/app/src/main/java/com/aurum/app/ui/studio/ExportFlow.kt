package com.aurum.app.ui.studio

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.aurum.app.imaging.PhotoExporter
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.OutlineButton
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.paywall.PaywallScreen
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.core.ExportDecision
import com.aurum.core.PremiumItem
import kotlinx.coroutines.launch

private sealed interface ExportState {
    data object Ready : ExportState
    data object Working : ExportState
    data class Saved(val uri: Uri) : ExportState
    data object Failed : ExportState
    data object PermissionDenied : ExportState
}

/**
 * Export: the gate (member items in a free edit), the export sheet, and the
 * paywall. The paywall is reachable only from here, as on iOS.
 */
@Composable
fun ExportFlow(model: AppViewModel, session: StudioSession, onDismiss: () -> Unit) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val container = model.container
    var decision by remember { mutableStateOf(session.exportDecision()) }
    var showPaywall by remember { mutableStateOf(false) }
    var state by remember { mutableStateOf<ExportState>(ExportState.Ready) }
    val exporter = remember { PhotoExporter(context, container.renderer, session.painter, container.brand.watermarkText) }

    fun run(allowed: ExportDecision.Allowed) {
        state = ExportState.Working
        scope.launch {
            state = runCatching { exporter.export(session.document, session.sourceUri, allowed) }
                .fold(
                    onSuccess = { uri ->
                        container.prefs.recordCreation()
                        ExportState.Saved(uri)
                    },
                    onFailure = { ExportState.Failed },
                )
        }
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val allowed = decision as? ExportDecision.Allowed
        if (granted && allowed != null) run(allowed) else state = ExportState.PermissionDenied
    }

    fun save(allowed: ExportDecision.Allowed) {
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        if (needsPermission) permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE) else run(allowed)
    }

    if (showPaywall) {
        PaywallScreen(
            container,
            onClose = { showPaywall = false },
            onMember = {
                showPaywall = false
                decision = session.exportDecision()
            },
        )
        return
    }

    // Scrim; tapping it closes unless an export is running.
    Box(
        Modifier
            .fillMaxSize()
            .background(p.background.copy(alpha = 0.6f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                if (state != ExportState.Working) onDismiss()
            },
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                .background(p.surface)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                .navigationBarsPadding()
                .padding(Spacing.l),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            when (val d = decision) {
                is ExportDecision.RequiresMembership -> GateContent(
                    model, d.items,
                    onJoin = { showPaywall = true },
                    onWithout = {
                        session.stripPremium()
                        decision = session.exportDecision()
                    },
                    onClose = onDismiss,
                )
                is ExportDecision.Allowed -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(tr("Export"), style = AurumType.title, color = p.textPrimary, modifier = Modifier.weight(1f).semantics { heading() })
                        if (state != ExportState.Working) IconAction(AurumIcons.close, tr("Close"), onDismiss)
                    }
                    when (val s = state) {
                        ExportState.Ready -> {
                            Text(
                                if (d.watermark) tr("Free export: up to %lld px with a small %@ mark", d.maxPixelSize ?: 0, container.brand.watermarkText)
                                else tr("Full resolution, no watermark"),
                                style = AurumType.caption, color = p.textTertiary,
                            )
                            GoldButton(tr("Save"), onClick = { save(d) })
                            if (d.watermark) TextAction(tr("Remove mark"), { showPaywall = true })
                        }
                        ExportState.Working -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            CircularProgressIndicator(color = p.accent, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                            Text(tr("Finishing your photo…"), style = AurumType.body, color = p.textSecondary, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                        }
                        is ExportState.Saved -> {
                            Text(tr("Saved to Photos"), style = AurumType.headline, color = p.textPrimary, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                            val shareTitle = tr("Share")
                            OutlineButton(shareTitle, onClick = {
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = "image/jpeg"
                                    putExtra(Intent.EXTRA_STREAM, s.uri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                context.startActivity(Intent.createChooser(send, shareTitle))
                            }, modifier = Modifier.fillMaxWidth(), icon = AurumIcons.share)
                            GoldButton(tr("Done"), onClick = onDismiss)
                        }
                        ExportState.Failed -> {
                            Text(tr("The export didn't finish. Please try again."), style = AurumType.body, color = p.textSecondary)
                            GoldButton(tr("Try again"), onClick = { state = ExportState.Ready })
                        }
                        ExportState.PermissionDenied -> {
                            Text(tr("AURUM needs permission to add photos. You can allow it in Settings."), style = AurumType.body, color = p.textSecondary)
                            GoldButton(tr("Try again"), onClick = { state = ExportState.Ready })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GateContent(model: AppViewModel, items: List<PremiumItem>, onJoin: () -> Unit, onWithout: () -> Unit, onClose: () -> Unit) {
    val p = LocalPalette.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(tr("This edit uses member items"), style = AurumType.headline, color = p.textPrimary, modifier = Modifier.weight(1f).semantics { heading() })
        IconAction(AurumIcons.close, tr("Close"), onClose)
    }
    Text(
        if (items.size == 1) tr("1 member item in this edit") else tr("%lld member items in this edit", items.size),
        style = AurumType.caption, color = p.textTertiary,
    )
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        for (item in items) {
            val name = when (item) {
                is PremiumItem.Look -> item.name // look names are brand content
                is PremiumItem.Sticker -> tr("Members' sticker")
                else -> trDynamic(item.displayName)
            }
            Text("· $name", style = AurumType.body, color = p.textPrimary)
        }
    }
    GoldButton(tr("Join %@", model.container.brand.membershipName), onClick = onJoin)
    OutlineButton(tr("Export without them"), onClick = onWithout, modifier = Modifier.fillMaxWidth())
}
