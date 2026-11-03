package com.aurum.app.ui.autostudio

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.aurum.app.l10n.tr
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.aurumShimmer
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.LocalReduceMotion
import com.aurum.app.ui.theme.Spacing
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.min

/** Small pieces shared by the Auto Studio screens (the iOS AtelierSupport). */
object AtelierSupport {
    class SaveFailed(message: String) : Exception(message)

    /**
     * Saves a JPEG to the photo library (Pictures/AURUM) and returns its URI,
     * the way the camera hands a capture to the Studio. On Android 8 and 9 the
     * caller must hold WRITE_EXTERNAL_STORAGE. Blocking.
     */
    fun saveJpeg(context: Context, bitmap: Bitmap): Uri {
        val resolver = context.contentResolver
        val name = "AURUM_" + LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")) + ".jpg"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/AURUM")
            values.put(MediaStore.Images.Media.IS_PENDING, 1)
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "AURUM").apply { mkdirs() }
            @Suppress("DEPRECATION")
            values.put(MediaStore.Images.Media.DATA, File(dir, name).absolutePath)
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val uri = resolver.insert(collection, values) ?: throw SaveFailed("insert failed")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)) throw SaveFailed("encode failed")
            } ?: throw SaveFailed("no output stream")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            }
            return uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }
}

/** A header with a close (or back) button and a title, for full-screen flows. */
@Composable
fun AtelierHeader(title: String, onClose: () -> Unit, back: Boolean = false, trailing: @Composable RowScope.() -> Unit = {}) {
    val p = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = Spacing.xs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        IconAction(if (back) AurumIcons.back else AurumIcons.close, if (back) tr("Back") else tr("Close"), onClose)
        Text(
            title, style = AurumType.title, color = p.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
        trailing()
    }
}

/** A calm notice inside a card: a label line and a sentence. */
@Composable
fun AtelierNote(title: String, message: String, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(p.surface)
            .border(1.dp, p.accent.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .padding(Spacing.s)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(title.uppercase(), style = AurumType.label, color = p.accent)
        Text(message, style = AurumType.caption, color = p.textSecondary)
    }
}

/**
 * A picked photo shown at its aspect ratio, or a placeholder. Fades in when it
 * arrives; while [isScanning] a slow gold shimmer passes over it.
 */
@Composable
fun AtelierImage(image: ImageBitmap?, modifier: Modifier = Modifier, placeholder: String = "", isScanning: Boolean = false, contentDescription: String? = null) {
    val p = LocalPalette.current
    val enter = motion<Float>(420)
    val exit = motion<Float>(220)
    AnimatedContent(
        targetState = image,
        transitionSpec = { fadeIn(enter) togetherWith fadeOut(exit) },
        contentKey = { it != null },
        modifier = modifier,
        label = "atelierImage",
    ) { shown ->
        if (shown != null) {
            val frame by animateFloatAsState(if (isScanning) 0.45f else 0f, motion(), label = "scanFrame")
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FittedImage(shown, contentDescription, Modifier.aurumShimmer(isScanning, intensity = 0.3f, durationMillis = 2200), frameAlpha = frame)
            }
        } else {
            Box(
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(18.dp))
                    .background(Brush.verticalGradient(listOf(p.surfaceRaised, p.surface)))
                    .border(1.dp, p.hairline, RoundedCornerShape(18.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text(placeholder, style = AurumType.caption, color = p.textTertiary, modifier = Modifier.padding(Spacing.m))
            }
        }
    }
}

/** An image fitted inside the available space with rounded corners and an optional gold frame. */
@Composable
private fun FittedImage(image: ImageBitmap, contentDescription: String?, modifier: Modifier = Modifier, frameAlpha: Float = 0f) {
    val p = LocalPalette.current
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val density = LocalDensity.current
        val scale = min(constraints.maxWidth.toFloat() / image.width, constraints.maxHeight.toFloat() / image.height)
        val w = with(density) { (image.width * scale).toDp() }
        val h = with(density) { (image.height * scale).toDp() }
        Image(
            image, contentDescription, contentScale = ContentScale.FillBounds,
            modifier = modifier
                .size(w, h)
                .clip(RoundedCornerShape(10.dp))
                .border(1.dp, p.accent.copy(alpha = frameAlpha), RoundedCornerShape(10.dp)),
        )
    }
}

/**
 * The result revealed over the original with a gold edge that wipes across
 * once. With reduced motion the result simply appears.
 */
@Composable
fun BeforeAfterReveal(before: ImageBitmap?, after: ImageBitmap, modifier: Modifier = Modifier, contentDescription: String? = null) {
    val p = LocalPalette.current
    val reduce = LocalReduceMotion.current
    val progress = remember(after) { Animatable(if (reduce || before == null) 1f else 0f) }
    LaunchedEffect(after) {
        if (!reduce && before != null) progress.animateTo(1f, tween(800, easing = FastOutSlowInEasing))
    }
    BoxWithConstraints(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val density = LocalDensity.current
        val scale = min(constraints.maxWidth.toFloat() / after.width, constraints.maxHeight.toFloat() / after.height)
        val w = with(density) { (after.width * scale).toDp() }
        val h = with(density) { (after.height * scale).toDp() }
        Box(Modifier.size(w, h).clip(RoundedCornerShape(10.dp))) {
            if (before != null) {
                Image(before, null, contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
            }
            val t = progress.value
            Image(
                after, contentDescription, contentScale = ContentScale.FillBounds,
                modifier = Modifier.fillMaxSize().drawWithContent {
                    clipRect(right = size.width * t) { this@drawWithContent.drawContent() }
                },
            )
            if (t > 0f && t < 1f) {
                Canvas(Modifier.fillMaxSize()) {
                    val x = size.width * t
                    drawLine(p.accent.copy(alpha = 0.8f), Offset(x, 0f), Offset(x, size.height), strokeWidth = 1.5.dp.toPx())
                }
            }
        }
    }
}

/** A small gold crown in the corner of a chip or card, for members' items. */
@Composable
internal fun CrownedChip(text: String, selected: Boolean, member: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier) {
        com.aurum.app.ui.common.Chip(text, selected, onClick, modifier = Modifier.padding(end = if (member) 6.dp else 0.dp, top = if (member) 4.dp else 0.dp))
        if (member) {
            Box(Modifier.align(Alignment.TopEnd).clip(RoundedCornerShape(8.dp)).background(LocalPalette.current.background.copy(alpha = 0.8f)).padding(2.dp)) {
                com.aurum.app.ui.common.CrownBadge(10.dp)
            }
        }
    }
}
