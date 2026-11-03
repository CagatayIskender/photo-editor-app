package com.aurum.app.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.graphicsLayer
import com.aurum.app.ui.common.aurumRiseIn
import com.aurum.app.ui.common.aurumRiseOut
import com.aurum.app.ui.common.motion
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.Tab
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import kotlinx.coroutines.delay

/** Salon, Create and Vault, with a quiet notice line for links and errors. */
@Composable
fun ShellScreen(model: AppViewModel) {
    val p = LocalPalette.current
    Column(Modifier.fillMaxSize().background(p.background)) {
        Box(Modifier.weight(1f).statusBarsPadding()) {
            val fade = motion<Float>(220)
            Crossfade(model.tab, animationSpec = fade, label = "tab") { tab ->
                when (tab) {
                    Tab.salon -> SalonScreen(model)
                    Tab.create -> CreateScreen(model)
                    Tab.vault -> VaultScreen(model)
                }
            }
            val notice = model.notice
            // Keeps the last text on screen while the notice animates out.
            var shown by remember { mutableStateOf("") }
            if (notice != null) {
                shown = notice
                LaunchedEffect(notice) {
                    delay(4000)
                    model.notice = null
                }
            }
            AnimatedVisibility(notice != null, Modifier.align(Alignment.BottomCenter), enter = aurumRiseIn(), exit = aurumRiseOut()) {
                Text(
                    shown,
                    style = AurumType.body,
                    color = p.textPrimary,
                    modifier = Modifier
                        .padding(Spacing.m)
                        .clip(RoundedCornerShape(12.dp))
                        .background(p.surfaceRaised)
                        .clickable { model.notice = null }
                        .padding(Spacing.m)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
        HorizontalDivider(color = p.hairline, thickness = 0.5.dp)
        Row(Modifier.fillMaxWidth().navigationBarsPadding().background(p.background)) {
            TabItem(tr("Salon"), AurumIcons.sparkle, model.tab == Tab.salon, Modifier.weight(1f)) { model.tab = Tab.salon }
            TabItem(tr("Create"), AurumIcons.plus, model.tab == Tab.create, Modifier.weight(1f)) { model.tab = Tab.create }
            TabItem(tr("Vault"), AurumIcons.layers, model.tab == Tab.vault, Modifier.weight(1f)) { model.tab = Tab.vault }
        }
    }
}

@Composable
private fun TabItem(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, isSelected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    val color by animateColorAsState(if (isSelected) p.accent else p.textTertiary, motion(), label = "tab")
    val lift by animateFloatAsState(if (isSelected) 1.08f else 1f, motion(), label = "tabLift")
    Column(
        modifier
            .heightIn(min = 56.dp)
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics { selected = isSelected }
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(22.dp).graphicsLayer { scaleX = lift; scaleY = lift })
        Text(title, style = AurumType.caption, color = color)
    }
}
