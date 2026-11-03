package com.aurum.app.ui.video

import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.media3.common.util.UnstableApi
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.Chip
import com.aurum.app.ui.common.CrownBadge
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.LabeledSlider
import com.aurum.app.ui.common.LookThumbnail
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.common.pressClickable
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import com.aurum.app.video.BeatAnalyzer
import com.aurum.app.video.MusicLibrary
import com.aurum.core.AnimatedEffect
import com.aurum.core.BookendEffect
import com.aurum.core.BookendPreset
import com.aurum.core.Clip
import com.aurum.core.LayerAnimation
import com.aurum.core.MusicSource
import com.aurum.core.OverlayContent
import com.aurum.core.Seconds
import com.aurum.core.Tier
import com.aurum.core.TimedLayer
import com.aurum.core.TextOverlay
import com.aurum.core.VideoExportRules
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The sheet for the active video tool (iOS `VideoToolSheet`). */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
fun VideoToolSheet(tool: VideoTool, model: VideoEditorModel) {
    Column(Modifier.fillMaxWidth().padding(bottom = Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        when (tool) {
            VideoTool.trim -> TrimSheet(model)
            VideoTool.speed -> SpeedSheet(model)
            VideoTool.volume -> VolumeSheet(model)
            VideoTool.transition -> TransitionSheet(model)
            VideoTool.music -> MusicSheet(model)
            VideoTool.text -> TextSheet(model)
            VideoTool.effects -> EffectsSheet(model)
            VideoTool.look -> LookSheet(model)
            VideoTool.bookends -> BookendsSheet(model)
            VideoTool.aspect -> AspectSheet(model)
            VideoTool.split, VideoTool.reverse -> Unit
        }
    }
}

@Composable
private fun SelectClipHint() {
    Text(
        tr("Tap a clip on the timeline first."), style = AurumType.caption, color = LocalPalette.current.textTertiary,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.m),
    )
}

@Composable
private fun Hint(text: String, secondary: Boolean = false) {
    val p = LocalPalette.current
    Text(text, style = AurumType.caption, color = if (secondary) p.textSecondary else p.textTertiary, modifier = Modifier.padding(horizontal = Spacing.m))
}

/**
 * A slider that groups one drag into one undo step, as iOS's
 * `sliderEditing` does.
 */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun EditSlider(
    model: VideoEditorModel,
    label: String,
    value: Double,
    range: ClosedFloatingPointRange<Double>,
    modifier: Modifier = Modifier,
    step: Double? = null,
    format: (Float) -> String = { (it * 100).roundToInt().toString() },
    onChange: (Double) -> Unit,
) {
    val haptics = LocalHapticFeedback.current
    var last by remember { mutableStateOf(value) }
    LabeledSlider(
        label = label,
        value = value.toFloat().coerceIn(range.start.toFloat(), range.endInclusive.toFloat()),
        range = range.start.toFloat()..range.endInclusive.toFloat(),
        onChange = { raw ->
            model.beginInteraction()
            var v = raw.toDouble()
            if (step != null) {
                // Detents: snap near whole steps and tick when one is crossed.
                val nearest = (v / step).roundToInt() * step
                if (abs(v - nearest) < step * 0.06) v = nearest
                if (floorStep(v, step) != floorStep(last, step)) haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            }
            last = v
            onChange(v)
        },
        onFinished = { model.endInteraction() },
        modifier = modifier.padding(horizontal = Spacing.m),
        format = format,
    )
}

private fun floorStep(v: Double, step: Double) = kotlin.math.floor(v / step).toInt()

private fun Context.secondsLabel(value: Seconds): String = this.tr("%@ s", "%.1f".format(value))

/** A horizontal row of chips with the sheet's side gutter. */
@Composable
private fun ChipRow(content: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = Spacing.m, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) { content() }
}

/** A chip with a crown in its corner for member items. */
@Composable
private fun CrownedChip(text: String, selected: Boolean, member: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier) {
        Chip(text, selected, onClick)
        if (member) Box(Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-4).dp)) { CrownBadge(14.dp) }
    }
}

// ---------------------------------------------------------------- trim

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun TrimSheet(model: VideoEditorModel) {
    val p = LocalPalette.current
    val haptics = LocalHapticFeedback.current
    val context = LocalContext.current
    val clip = model.selectedClip
    val index = model.selectedClipIndex
    if (clip == null || index == null) { SelectClipHint(); return }
    Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.m), verticalAlignment = Alignment.CenterVertically) {
        Text(if (clip.kind == Clip.Kind.video) tr("Clip %lld", index + 1) else tr("Photo %lld", index + 1), style = AurumType.headline, color = p.textPrimary)
        Spacer(Modifier.weight(1f))
        Text(context.secondsLabel(clip.duration), style = AurumType.caption, color = p.textSecondary)
    }
    if (clip.kind == Clip.Kind.video) {
        val upper = max(clip.sourceDuration, Clip.MINIMUM_DURATION * 2)
        EditSlider(model, tr("Start"), clip.trimStart, 0.0..upper, step = 1.0, format = { context.secondsLabel(it.toDouble()) }) { v ->
            model.trimSelected(v, model.selectedClip?.trimEnd ?: clip.trimEnd)
        }
        EditSlider(model, tr("End"), clip.trimEnd, 0.0..upper, step = 1.0, format = { context.secondsLabel(it.toDouble()) }) { v ->
            model.trimSelected(model.selectedClip?.trimStart ?: clip.trimStart, v)
        }
    } else {
        EditSlider(model, tr("Length"), min(max(clip.trimEnd - clip.trimStart, 0.5), 10.0), 0.5..10.0, step = 0.5, format = { context.secondsLabel(it.toDouble()) }) { v ->
            model.setPhotoLength(v)
        }
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.l), verticalAlignment = Alignment.CenterVertically) {
        TextAction(tr("Move earlier"), { model.moveSelectedClip(-1) }, enabled = index > 0)
        TextAction(tr("Move later"), { model.moveSelectedClip(1) }, enabled = index < model.project.clips.size - 1)
        Spacer(Modifier.weight(1f))
        TextAction(tr("Delete"), {
            model.deleteSelectedClip()
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        }, enabled = model.canDeleteClip)
    }
}

// ---------------------------------------------------------------- speed

private val SPEEDS = listOf(0.25, 0.5, 1.0, 1.5, 2.0, 4.0)

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun SpeedSheet(model: VideoEditorModel) {
    val p = LocalPalette.current
    val haptics = LocalHapticFeedback.current
    val clip = model.selectedClip ?: run { SelectClipHint(); return }
    Text(tr("Speed"), style = AurumType.headline, color = p.textPrimary, modifier = Modifier.padding(horizontal = Spacing.m))
    ChipRow {
        for (speed in SPEEDS) {
            Chip(speedLabel(speed), abs(clip.speed - speed) < 0.001, {
                model.setSpeed(speed)
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            })
        }
    }
    Hint(tr("Slower clips last longer on the timeline."))
}

// ---------------------------------------------------------------- volume

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun VolumeSheet(model: VideoEditorModel) {
    val clip = model.selectedClip
    if (clip == null) {
        SelectClipHint()
    } else if (clip.kind == Clip.Kind.video) {
        EditSlider(model, tr("Clip sound"), clip.volume, 0.0..1.0) { model.setVolume(it) }
        if (clip.isReversed) Hint(tr("Reversed clips play without sound."))
    } else {
        Hint(tr("Photos have no sound."))
    }
    model.project.music?.let { music ->
        EditSlider(model, tr("Music"), music.volume, 0.0..1.0) { model.setMusicVolume(it) }
    }
}

// ---------------------------------------------------------------- transition

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun TransitionSheet(model: VideoEditorModel) {
    val p = LocalPalette.current
    val haptics = LocalHapticFeedback.current
    val clip = model.selectedClip
    val index = model.selectedClipIndex
    if (clip == null || index == null) { SelectClipHint(); return }
    if (index == 0) {
        Hint(tr("The first clip opens the video, so it has no transition. Select a later clip."))
        return
    }
    Text(tr("Into clip %lld", index + 1), style = AurumType.headline, color = p.textPrimary, modifier = Modifier.padding(horizontal = Spacing.m))
    val current = TransitionChoice.of(clip.transitionIn)
    ChipRow {
        for (choice in TransitionChoice.entries) {
            Chip(tr(choice.titleKey), current == choice, {
                model.setTransition(choice)
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            })
        }
    }
}

// ---------------------------------------------------------------- music

/** Library tracks, songs the user imported, and the music volume. The library ships empty. */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun MusicSheet(model: VideoEditorModel) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    var imported by remember { mutableStateOf<List<File>>(emptyList()) }
    var importFailed by remember { mutableStateOf(false) }
    var analysing by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { imported = withContext(Dispatchers.IO) { MusicLibrary.importedSongs(context) } }

    // Uses an imported song, finding its beats first so cuts can land on them.
    fun use(fileName: String) {
        analysing = fileName
        scope.launch {
            val beats = withContext(Dispatchers.Default) { BeatAnalyzer.analyze(File(MusicLibrary.directory(context), fileName)) }
            analysing = null
            model.useImportedSong(fileName, beats)
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val name = withContext(Dispatchers.IO) { runCatching { MusicLibrary.importSong(context, uri) }.getOrNull() }
            if (name == null) {
                importFailed = true
            } else {
                imported = withContext(Dispatchers.IO) { MusicLibrary.importedSongs(context) }
                importFailed = false
                use(name)
            }
        }
    }

    val music = model.project.music
    Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.m), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text(music?.title ?: tr("No music"), style = AurumType.headline, color = p.textPrimary, maxLines = 1, modifier = Modifier.weight(1f))
        if (music != null) TextAction(tr("Remove"), { model.setMusic(null) })
        TextAction(tr("Import a song"), { picker.launch(arrayOf("audio/*")) })
    }
    ChipRow {
        for (track in model.content.music) {
            CrownedChip(track.title, music?.source == MusicSource.Library(track.id), track.tier == Tier.member, {
                model.useLibraryTrack(track)
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            })
        }
        for (file in imported) {
            val selected = music?.source == MusicSource.Imported(file.name) || analysing == file.name
            Chip(file.nameWithoutExtension, selected, {
                use(file.name)
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            })
        }
    }
    if (model.content.music.isEmpty() && imported.isEmpty()) Hint(tr("Import a song from Files to play under your video."))
    if (importFailed) Hint(tr("That song couldn't be imported."), secondary = true)
    if (music != null) EditSlider(model, tr("Music volume"), music.volume, 0.0..1.0) { model.setMusicVolume(it) }
}

// ---------------------------------------------------------------- text

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun TextSheet(model: VideoEditorModel) {
    val layer = model.selectedLayer
    val text = (layer?.overlay?.content as? OverlayContent.Text)?.text
    if (layer != null && text != null) {
        TextEditor(model, layer, text)
    } else {
        val words = tr("Your words")
        GoldButton(tr("Add text"), onClick = { model.addText(words) }, compact = true, modifier = Modifier.padding(horizontal = Spacing.m))
        Hint(tr("Text appears at the playhead for three seconds. Tap its bar under the timeline to edit it."))
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun TextEditor(model: VideoEditorModel, layer: TimedLayer, text: TextOverlay) {
    val p = LocalPalette.current
    val focus = remember { FocusRequester() }
    LaunchedEffect(layer.id) { runCatching { focus.requestFocus() } }
    Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.m), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        OutlinedTextField(
            value = text.text,
            onValueChange = { value -> model.updateSelectedText { it.copy(text = value) } },
            placeholder = { Text(tr("Your words")) },
            singleLine = true,
            textStyle = AurumType.body,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = p.accent, unfocusedBorderColor = p.hairline,
                focusedTextColor = p.textPrimary, unfocusedTextColor = p.textPrimary, cursorColor = p.accent,
            ),
            modifier = Modifier.weight(1f).focusRequester(focus),
        )
        IconAction(AurumIcons.close, tr("Delete text"), { model.removeSelectedLayer() })
    }
    AnimationRow(tr("In"), layer.animationIn) { a -> model.updateSelectedLayer { it.copy(animationIn = a) } }
    AnimationRow(tr("Out"), layer.animationOut) { a -> model.updateSelectedLayer { it.copy(animationOut = a) } }
    Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.m), horizontalArrangement = Arrangement.spacedBy(Spacing.l), verticalAlignment = Alignment.CenterVertically) {
        TextAction(tr("Start here"), { model.setSelectedLayerBound(isStart = true) })
        TextAction(tr("End here"), { model.setSelectedLayerBound(isStart = false) })
        Spacer(Modifier.weight(1f))
        Text("${timecode(layer.start)} – ${timecode(layer.end)}", style = AurumType.caption, color = p.textTertiary)
    }
}

@Composable
private fun AnimationRow(title: String, selected: LayerAnimation, set: (LayerAnimation) -> Unit) {
    val p = LocalPalette.current
    val haptics = LocalHapticFeedback.current
    Row(Modifier.fillMaxWidth().padding(start = Spacing.m).semantics { contentDescription = title }, verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = AurumType.label, color = p.textTertiary, modifier = Modifier.width(36.dp))
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(end = Spacing.m, top = 4.dp, bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
            for (animation in LayerAnimation.entries) {
                Chip(trDynamic(animation.displayName), animation == selected, {
                    set(animation)
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                })
            }
        }
    }
}

// ---------------------------------------------------------------- effects

/** Effects over the whole video. Member effects carry a crown; membership is asked for only at export. */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun EffectsSheet(model: VideoEditorModel) {
    val haptics = LocalHapticFeedback.current
    ChipRow {
        for (kind in AnimatedEffect.Kind.entries) {
            val effect = model.effectOf(kind)
            CrownedChip(
                trDynamic(kind.displayName), effect != null, VideoExportRules.tier(kind) == Tier.member,
                onClick = {
                    if (effect != null && model.selectedEffectID != effect.id) model.selectedEffectID = effect.id else model.toggleEffect(kind)
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                },
            )
        }
    }
    val id = model.selectedEffectID
    val effect = id?.let { i -> model.project.effects.firstOrNull { it.id == i } }
    if (effect != null) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            EditSlider(model, tr("%@ intensity", trDynamic(effect.kind.displayName)), effect.intensity, 0.0..1.0, modifier = Modifier.weight(1f)) {
                model.setEffectIntensity(it)
            }
            TextAction(tr("Remove"), { model.removeEffect(effect.id) }, modifier = Modifier.padding(end = Spacing.m))
        }
    } else {
        Hint(tr("Tap an effect to add it to the whole video."))
    }
}

// ---------------------------------------------------------------- look

/** One look graded over every clip, from the photo catalogue. */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun LookSheet(model: VideoEditorModel) {
    val haptics = LocalHapticFeedback.current
    val catalog = model.catalog
    var collectionID by remember { mutableStateOf("") }
    val active = model.activeLook
    val current = collectionID.ifEmpty {
        active?.lookID?.let { catalog.look(it)?.collection } ?: catalog.collections.firstOrNull()?.id.orEmpty()
    }
    ChipRow {
        for (collection in catalog.collections) {
            Chip(trDynamic(collection.name), current == collection.id, { collectionID = collection.id })
        }
    }
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = Spacing.m, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(Spacing.s),
    ) {
        for (look in catalog.looks(current)) {
            LookThumbnail(
                name = look.name, image = null, swatch = look.swatch,
                selected = active?.lookID == look.id, premium = look.tier == Tier.member,
                modifier = Modifier.pressClickable {
                    model.selectLook(look.id)
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                },
            )
        }
    }
    if (active != null) EditSlider(model, tr("Intensity"), active.intensity, 0.0..1.0) { model.setLookIntensity(it) }
}

// ---------------------------------------------------------------- intro and outro

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun BookendsSheet(model: VideoEditorModel) {
    BookendRow(model, tr("Intro"), model.introPresets, model.project.intro, isIntro = true)
    BookendRow(model, tr("Outro"), model.outroPresets, model.project.outro, isIntro = false)
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun BookendRow(model: VideoEditorModel, title: String, presets: List<BookendPreset>, current: BookendEffect?, isIntro: Boolean) {
    val p = LocalPalette.current
    val haptics = LocalHapticFeedback.current
    Text(title, style = AurumType.label, color = p.textTertiary, modifier = Modifier.padding(horizontal = Spacing.m))
    ChipRow {
        Chip(tr("None"), current == null, { if (isIntro) model.setIntro(null) else model.setOutro(null) })
        for (preset in presets) {
            CrownedChip(trDynamic(preset.name), current?.presetID == preset.id, preset.tier == Tier.member, {
                if (isIntro) model.setIntro(preset) else model.setOutro(preset)
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            })
        }
    }
    if (current != null) {
        OutlinedTextField(
            value = current.title.orEmpty(),
            onValueChange = { model.setBookendTitle(it, intro = isIntro) },
            placeholder = { Text(if (isIntro) tr("Opening title (optional)") else tr("Closing title (optional)")) },
            singleLine = true,
            textStyle = AurumType.body,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = p.accent, unfocusedBorderColor = p.hairline,
                focusedTextColor = p.textPrimary, unfocusedTextColor = p.textPrimary, cursorColor = p.accent,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.m),
        )
    }
}

// ---------------------------------------------------------------- aspect

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun AspectSheet(model: VideoEditorModel) {
    val haptics = LocalHapticFeedback.current
    ChipRow {
        for (aspect in VideoEditorModel.aspects) {
            Chip(trDynamic(aspect.label), model.project.aspect == aspect, {
                model.setAspect(aspect)
                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            })
        }
    }
}
