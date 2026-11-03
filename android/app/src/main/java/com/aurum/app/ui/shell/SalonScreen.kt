package com.aurum.app.ui.shell

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import android.graphics.BitmapFactory
import com.aurum.app.data.DraftSummary
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.aurumEntrance
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.LookThumbnail
import com.aurum.app.ui.common.SectionTitle
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.ui.theme.hex
import com.aurum.core.Entitlement
import com.aurum.core.Tier
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * The home tab: a featured collection, ways to create, the user's drafts and
 * every collection as a row of looks. Tapping a look opens the photo picker
 * with that look queued, so the photo opens already wearing it.
 */
@Composable
fun SalonScreen(model: AppViewModel) {
    val p = LocalPalette.current
    val c = model.container
    val entitlement by c.membership.entitlement.collectAsState()
    val drafts by c.drafts.drafts.collectAsState()
    val vibes = remember { c.prefs.vibes }
    val collections = remember(vibes) {
        val chosen = vibes.mapNotNull { id -> c.catalog.collections.firstOrNull { it.id == id } }
        chosen + c.catalog.collections.filter { it.id !in vibes }
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = Spacing.xl), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.m).padding(top = Spacing.m), verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Salon"), style = AurumType.title, color = p.textPrimary, modifier = Modifier.weight(1f).semantics { heading() })
                if (entitlement == Entitlement.member) {
                    CrownBadge(16.dp)
                    Spacer(Modifier.width(4.dp))
                    Text(tr("Member"), style = AurumType.label, color = p.accent)
                }
            }
        }
        item { Hero(model) }
        item { CreateRow(model) }
        item { AtelierRow(model) }
        item { DropsCard(model) }
        if (drafts.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    SectionTitle(tr("Continue"), Modifier.padding(horizontal = Spacing.m))
                    LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        items(drafts.take(10), key = { it.id }) { draft ->
                            DraftTile(draft, 104.dp, Modifier.clickable(role = Role.Button) { model.openDraft(draft.id) })
                        }
                    }
                }
            }
        }
        items(collections, key = { it.id }) { collection ->
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                Column(Modifier.padding(horizontal = Spacing.m).semantics(mergeDescendants = true) { heading() }) {
                    Text(trDynamic(collection.name), style = AurumType.editorial, color = p.textPrimary)
                    Text(trDynamic(collection.tagline), style = AurumType.caption, color = p.textTertiary)
                }
                val hint = tr("Pick a photo to edit with this look")
                LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    items(c.catalog.looks(collection.id), key = { it.id }) { look ->
                        LookThumbnail(
                            name = look.name,
                            image = null,
                            swatch = look.swatch,
                            selected = false,
                            premium = look.tier == Tier.member,
                            modifier = Modifier.clickable(role = Role.Button, onClickLabel = hint) { model.startCreating(look.id) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun Hero(model: AppViewModel) {
    val p = LocalPalette.current
    val c = model.container
    val collection = c.catalog.collections.firstOrNull { it.id == c.config.salonHeroCollection } ?: c.catalog.collections.firstOrNull()
    val looks = collection?.let { c.catalog.looks(it.id) }.orEmpty()
    val swatch = looks.firstOrNull()?.swatch?.map(::hex)?.takeIf { it.size >= 2 } ?: listOf(p.surface, p.surfaceRaised)
    Box(
        Modifier
            .padding(horizontal = Spacing.m)
            .fillMaxWidth()
            .heightIn(min = 320.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(Brush.linearGradient(swatch.reversed()))
            .background(Brush.verticalGradient(listOf(Color.Transparent, p.background.copy(alpha = 0.9f)))),
    ) {
        Column(Modifier.align(Alignment.BottomStart).padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
            Text(tr("FEATURED COLLECTION"), style = AurumType.label, color = p.accent)
            Text(collection?.let { trDynamic(it.name) }.orEmpty(), style = AurumType.display, color = p.textPrimary)
            Text(collection?.let { trDynamic(it.tagline) }.orEmpty(), style = AurumType.body, color = p.textSecondary)
            Spacer(Modifier.height(4.dp))
            GoldButton(tr("Start editing"), onClick = { model.startCreating(looks.firstOrNull()?.id) }, compact = true)
        }
    }
}

@Composable
private fun CreateRow(model: AppViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        SectionTitle(tr("Create"), Modifier.padding(horizontal = Spacing.m))
        Row(Modifier.padding(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            CreateTile(AurumIcons.layers, tr("Video"), tr("Clips and photos"), Modifier.weight(1f)) { model.startVideo() }
            CreateTile(AurumIcons.sparkle, tr("Templates"), tr("Cut to the beat"), Modifier.weight(1f)) { model.openTemplates() }
            CreateTile(AurumIcons.camera, tr("Camera"), tr("Shoot in a look"), Modifier.weight(1f)) { model.openCamera() }
        }
    }
}

/** Auto Studio, 3D Motion, Collage and Carousel; on Android these open a coming-soon page. */
@Composable
fun AtelierRow(model: AppViewModel) {
    data class Entry(val title: String, val subtitle: String, val icon: ImageVector, val open: () -> Unit)
    val entries = listOf(
        Entry("Auto Studio", "Enhance, retouch, remove", AurumIcons.sparkle, model::openAutoStudio),
        Entry("3D Motion", "Depth for a still", AurumIcons.layers, model::openDepthMotion),
        Entry("Collage", "Photos, composed", AurumIcons.photo, model::openCollage),
        Entry("Carousel", "One photo, many panels", AurumIcons.more, model::openCarousel),
    )
    LazyRow(contentPadding = PaddingValues(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
        itemsIndexed(entries, key = { _, e -> e.title }) { index, e ->
            CreateTile(e.icon, tr(e.title), tr(e.subtitle), Modifier.width(150.dp).aurumEntrance(index)) { e.open() }
        }
    }
}

@Composable
fun CreateTile(icon: ImageVector, title: String, subtitle: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    Column(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(p.surface)
            .border(1.dp, p.hairline, RoundedCornerShape(14.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(Spacing.s),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(icon, contentDescription = null, tint = p.accent, modifier = Modifier.size(22.dp))
        Spacer(Modifier.height(4.dp))
        Text(title, style = AurumType.headline, color = p.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(subtitle, style = AurumType.caption, color = p.textTertiary, maxLines = 2)
    }
}

/** The drop now showing (if any) and a quiet line about the creating streak. */
@Composable
private fun DropsCard(model: AppViewModel) {
    val p = LocalPalette.current
    val c = model.container
    val now = remember { Instant.now() }
    val zone = remember { ZoneId.systemDefault() }
    val active = remember { c.drops.active(now).firstOrNull() }
    val streak = remember { c.prefs.streak }
    val days = streak.current(now, zone)
    val atRisk = streak.isAtRisk(now, zone)
    val streakText = when {
        days <= 0 -> null
        atRisk && days == 1 -> tr("Create something today to keep your streak.")
        atRisk -> tr("Create something today to keep your %lld-day streak.", days)
        days == 1 -> tr("1 day of creating")
        else -> tr("%lld days in a row", days)
    }
    if (active == null && streakText == null) return
    Column(Modifier.padding(horizontal = Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        if (active != null) {
            val until = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withZone(zone).format(active.endsAt)
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(p.surface)
                    .border(1.dp, p.hairline, RoundedCornerShape(14.dp))
                    .clickable(role = Role.Button) { model.startCreating(active.lookIDs.firstOrNull()) }
                    .padding(Spacing.m),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(tr("NOW SHOWING"), style = AurumType.label, color = p.accent)
                Text(trDynamic(active.title), style = AurumType.editorial, color = p.textPrimary)
                val looks = active.lookIDs.size
                val parts = listOfNotNull(
                    tr("Until %@", until),
                    when { looks == 1 -> tr("1 look"); looks > 1 -> tr("%lld looks", looks); else -> null },
                )
                Text(parts.joinToString(" · "), style = AurumType.caption, color = p.textTertiary)
            }
        }
        if (streakText != null) Text(streakText, style = AurumType.caption, color = p.textTertiary)
    }
}

/** A saved draft's thumbnail and title. */
@Composable
fun DraftTile(draft: DraftSummary, width: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val image by produceState<ImageBitmap?>(null, draft.thumbnail, draft.modifiedAt) {
        value = withContext(Dispatchers.IO) {
            draft.thumbnail?.let { f -> runCatching { BitmapFactory.decodeFile(f.path)?.asImageBitmap() }.getOrNull() }
        }
    }
    val title = draft.title ?: tr("Untitled edit")
    Column(modifier.width(width).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(width, width * 1.25f).clip(RoundedCornerShape(10.dp)).background(p.surfaceRaised)) {
            image?.let { Image(it, contentDescription = tr("Draft, %@", title), contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize()) }
        }
        Text(title, style = AurumType.caption, color = p.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
