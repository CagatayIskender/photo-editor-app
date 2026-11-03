package com.aurum.app.ui.templates

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.BusyVeil
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.pressClickable
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.ui.theme.hex
import com.aurum.app.ui.video.timecode
import com.aurum.app.video.MediaProbe
import com.aurum.app.video.VideoContent
import com.aurum.core.BeatGrid
import com.aurum.core.MusicSelection
import com.aurum.core.MusicSource
import com.aurum.core.Seconds
import com.aurum.core.TemplateBuilder
import com.aurum.core.TemplateDefinition
import com.aurum.core.Tier
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * One-tap video templates (iOS `TemplatesView`). Pick one, pick its photos
 * and clips, and the edit is built on the beat and opened in the editor.
 */
@Composable
fun TemplatesScreen(model: AppViewModel) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val content = remember { VideoContent.get(context) }
    val catalog = model.container.catalog
    val templates = content.templates
    var chosen by remember { mutableStateOf<TemplateDefinition?>(null) }
    var pickRequest by remember { mutableStateOf(0) }
    var building by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    val pickAtLeastOne = tr("Pick at least one photo or clip.")

    BackHandler { model.closeFlow() }

    /** The template's default track, if it ships with the app. */
    fun music(template: TemplateDefinition): MusicSelection? {
        val id = template.musicTrackID ?: return null
        val track = content.music.firstOrNull { it.id == id } ?: return null
        return MusicSelection(MusicSource.Library(track.id), track.title, beats = track.beats)
    }

    fun build(uris: List<Uri>) {
        val template = chosen ?: return
        if (uris.isEmpty()) return
        building = true
        scope.launch {
            val picked = withContext(Dispatchers.IO) { uris.mapNotNull { MediaProbe.probe(context, it) } }
            val project = runCatching { TemplateBuilder.build(template, picked.map { it.templateMedia }, music(template)) }.getOrNull()
            building = false
            if (project == null) failure = pickAtLeastOne else model.openVideo(project, "template")
        }
    }

    // The system picker caps the selection at the template's slot count. Fewer is fine: the builder reuses them in order.
    val maxItems = (chosen?.mediaCount ?: 2).coerceAtLeast(2)
    val many = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(maxItems)) { build(it) }
    val one = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> build(listOfNotNull(uri)) }
    // Launched after recomposition, so the multiple picker carries this template's limit.
    LaunchedEffect(pickRequest) {
        val template = chosen ?: return@LaunchedEffect
        if (pickRequest == 0) return@LaunchedEffect
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
        if (template.mediaCount <= 1) one.launch(request) else many.launch(request)
    }

    Box(Modifier.fillMaxSize().background(p.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Box(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = Spacing.xs)) {
                TextAction(tr("Close"), { model.closeFlow() }, modifier = Modifier.align(Alignment.CenterStart), color = p.textSecondary)
                Text(tr("Templates"), style = AurumType.headline, color = p.textPrimary, modifier = Modifier.align(Alignment.Center).semantics { heading() })
            }
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 160.dp),
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(Spacing.m),
                horizontalArrangement = Arrangement.spacedBy(Spacing.s),
                verticalArrangement = Arrangement.spacedBy(Spacing.s),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Text(
                        tr("Choose a template, add your photos and clips, and AURUM cuts them to the beat."),
                        style = AurumType.body, color = p.textSecondary, modifier = Modifier.aurumEntrance(0, distance = 8.dp).padding(bottom = Spacing.xs),
                    )
                }
                if (templates.isEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Column(Modifier.fillMaxWidth().padding(Spacing.xl), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            Icon(AurumIcons.sparkle, null, tint = p.textTertiary, modifier = Modifier.size(28.dp))
                            Text(tr("No templates yet."), style = AurumType.body, color = p.textTertiary)
                        }
                    }
                }
                itemsIndexed(templates, key = { _, t -> t.id }) { index, template ->
                    val swatch = template.lookID?.let { catalog.look(it)?.swatch }.orEmpty()
                    TemplateCard(
                        template, swatch,
                        Modifier.aurumEntrance(index + 1, distance = 16.dp).pressClickable(enabled = !building) {
                            chosen = template
                            pickRequest++
                        },
                    )
                }
            }
        }
        if (building) BusyVeil(null)
    }

    failure?.let { message ->
        AlertDialog(
            onDismissRequest = { failure = null },
            containerColor = p.surface,
            title = { Text(tr("Couldn't build the video"), style = AurumType.headline, color = p.textPrimary) },
            text = { Text(message, style = AurumType.body, color = p.textSecondary) },
            confirmButton = { TextAction(tr("Done"), { failure = null }) },
        )
    }
}

/** "5 photos or clips", for a card. */
@Composable
private fun mediaCountText(count: Int): String = if (count == 1) tr("1 photo or clip") else tr("%lld photos or clips", count)

/** Total length at the template's own tempo. */
private fun length(template: TemplateDefinition): Seconds {
    val beat = BeatGrid(template.bpm).beatLength
    return template.slots.sumOf { it.beats * beat } + (template.intro?.duration ?: 0.0) + (template.outro?.duration ?: 0.0)
}

/** A template's card: its look as a gradient, name, tagline, slot count, length, and the crown for members. */
@Composable
private fun TemplateCard(template: TemplateDefinition, swatch: List<String>, modifier: Modifier) {
    val p = LocalPalette.current
    val count = mediaCountText(template.mediaCount)
    val base = "${template.name}, ${template.tagline}, $count"
    val label = if (template.tier == Tier.member) tr("%@, members only", base) else base
    val colors = swatch.map(::hex).takeIf { it.size >= 2 } ?: (swatch.map(::hex).firstOrNull()?.let { listOf(it, p.surface) } ?: listOf(p.surfaceRaised, p.surface))
    val shape = RoundedCornerShape(16.dp)
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(min = 220.dp)
            .shadow(10.dp, shape, ambientColor = Color.Black.copy(alpha = 0.28f), spotColor = Color.Black.copy(alpha = 0.28f))
            .clip(shape)
            .background(Brush.linearGradient(colors, start = androidx.compose.ui.geometry.Offset(Float.POSITIVE_INFINITY, 0f), end = androidx.compose.ui.geometry.Offset(0f, Float.POSITIVE_INFINITY)))
            .background(Brush.verticalGradient(listOf(Color.Transparent, p.background.copy(alpha = 0.92f))))
            .border(1.dp, Brush.linearGradient(listOf(p.accent.copy(alpha = 0.45f), p.hairline)), shape)
            .clearAndSetSemantics { contentDescription = label },
    ) {
        Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(Spacing.s), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(template.name, style = AurumType.editorial, color = p.textPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(template.tagline, style = AurumType.caption, color = p.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                Text(count, style = AurumType.label, color = p.textSecondary)
                Text("·", style = AurumType.label, color = p.textSecondary)
                Text(timecode(length(template)), style = AurumType.label, color = p.textSecondary)
            }
            Spacer(Modifier.height(4.dp))
            Box(Modifier.height(28.dp).clip(CircleShape).background(p.accent).padding(horizontal = Spacing.s), contentAlignment = Alignment.Center) {
                Text(tr("Use"), style = AurumType.caption.copy(fontWeight = FontWeight.SemiBold), color = p.onAccent)
            }
        }
        if (template.tier == Tier.member) Box(Modifier.align(Alignment.TopEnd).padding(Spacing.xs)) { CrownBadge(22.dp) }
    }
}
