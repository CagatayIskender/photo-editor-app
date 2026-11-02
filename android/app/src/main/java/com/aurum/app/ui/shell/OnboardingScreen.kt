package com.aurum.app.ui.shell

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.ui.theme.hex

private const val MAX_VIBES = 3

/** Three calm pages: the promise, the aesthetic picker, and privacy. */
@Composable
fun OnboardingScreen(model: AppViewModel) {
    val p = LocalPalette.current
    var page by rememberSaveable { mutableIntStateOf(0) }
    val vibes = remember { mutableStateListOf<String>() }
    val catalog = model.container.catalog
    val fade = motion<Float>()

    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(Spacing.l)) {
        AnimatedContent(
            targetState = page,
            transitionSpec = { fadeIn(fade) togetherWith fadeOut(fade) },
            modifier = Modifier.weight(1f),
            label = "onboarding",
        ) { current ->
            when (current) {
                0 -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Spacing.s, Alignment.Bottom)) {
                    Text(model.container.brand.appName, style = AurumType.label, color = p.accent)
                    Text(tr("Make every photo\nlook considered."), style = AurumType.display, color = p.textPrimary)
                    Text(tr("Pick a photo, choose a look, export. Most edits take less than ten seconds."), style = AurumType.body, color = p.textSecondary)
                    Spacer(Modifier.height(Spacing.l))
                }
                1 -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Spacer(Modifier.height(Spacing.l))
                    Text(tr("Choose your aesthetic"), style = AurumType.title, color = p.textPrimary)
                    Text(tr("Pick up to three. We'll start your edits from these."), style = AurumType.body, color = p.textSecondary)
                    LazyVerticalGrid(
                        columns = GridCells.Fixed(2),
                        horizontalArrangement = Arrangement.spacedBy(Spacing.s),
                        verticalArrangement = Arrangement.spacedBy(Spacing.s),
                        modifier = Modifier.weight(1f),
                    ) {
                        items(catalog.collections, key = { it.id }) { collection ->
                            val isSelected = collection.id in vibes
                            val swatch = catalog.looks(collection.id).firstOrNull()?.swatch?.map(::hex).orEmpty()
                            Column(
                                Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(p.surface)
                                    .border(if (isSelected) 2.dp else 1.dp, if (isSelected) p.accent else p.hairline, RoundedCornerShape(14.dp))
                                    .clickable(role = Role.Checkbox) {
                                        if (isSelected) vibes.remove(collection.id) else if (vibes.size < MAX_VIBES) vibes.add(collection.id)
                                    }
                                    .semantics { selected = isSelected }
                                    .padding(Spacing.s),
                                verticalArrangement = Arrangement.spacedBy(4.dp),
                            ) {
                                Box(
                                    Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(8.dp))
                                        .background(Brush.linearGradient(if (swatch.size >= 2) swatch else listOf(p.surfaceRaised, p.surface))),
                                )
                                Text(trDynamic(collection.name), style = AurumType.editorial, color = p.textPrimary)
                                Text(trDynamic(collection.tagline), style = AurumType.caption, color = p.textSecondary, maxLines = 2)
                            }
                        }
                    }
                }
                else -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Spacing.s, Alignment.Bottom)) {
                    Text(tr("Your photos stay yours"), style = AurumType.title, color = p.textPrimary)
                    Text(
                        tr("AURUM edits on your phone. Your photos are never uploaded. You choose which photos AURUM can see."),
                        style = AurumType.body, color = p.textSecondary,
                    )
                    Spacer(Modifier.height(Spacing.l))
                }
            }
        }

        val pageLabel = tr("Page %lld of 3", page + 1)
        Row(
            Modifier.fillMaxWidth().padding(vertical = Spacing.m).semantics { contentDescription = pageLabel },
            horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        ) {
            repeat(3) { i ->
                Box(Modifier.size(6.dp).clip(CircleShape).background(if (i == page) p.accent else p.hairline))
            }
        }
        val primary = when (page) {
            0 -> tr("Begin")
            1 -> if (vibes.isEmpty()) tr("Skip for now") else tr("Continue")
            else -> tr("Continue")
        }
        GoldButton(primary, onClick = {
            if (page < 2) page += 1 else model.completeOnboarding(vibes.toList())
        })
        if (page == 0) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                TextAction(tr("Skip for now"), onClick = { model.completeOnboarding(emptyList()) }, color = p.textSecondary)
            }
        }
    }
}
