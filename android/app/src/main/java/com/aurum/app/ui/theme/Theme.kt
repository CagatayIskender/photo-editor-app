package com.aurum.app.ui.theme

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aurum.app.R
import com.aurum.core.BrandConfig

/** The quiet-luxury palette, read from Brand/brand.json so both platforms match. */
@Immutable
data class AurumPalette(
    val background: Color,
    val surface: Color,
    val surfaceRaised: Color,
    val hairline: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val accent: Color,
    val onAccent: Color,
) {
    companion object {
        fun from(brand: BrandConfig) = with(brand.colors) {
            AurumPalette(
                background = hex(onyx),
                surface = hex(graphite),
                surfaceRaised = hex(graphiteRaised),
                hairline = hex(hairline),
                textPrimary = hex(ivory),
                textSecondary = hex(ivoryDim),
                textTertiary = hex(stone),
                accent = hex(champagne),
                onAccent = hex(onyx),
            )
        }
    }
}

/** Parses "#RRGGBB"; invalid input gives magenta so mistakes are visible, like iOS. */
fun hex(value: String): Color {
    val s = value.trim().removePrefix("#")
    val v = if (s.length == 6) s.toLongOrNull(16) else null
    return if (v == null) Color(0xFFFF00FF) else Color(0xFF000000 or v)
}

object AurumFonts {
    val display = FontFamily(
        Font(R.font.playfair_display_medium, FontWeight.Medium),
        Font(R.font.playfair_display_italic, FontWeight.Normal, FontStyle.Italic),
    )
    val italiana = FontFamily(Font(R.font.italiana_regular))
    val text = FontFamily(
        Font(R.font.inter_regular, FontWeight.Normal),
        Font(R.font.inter_medium, FontWeight.Medium),
        Font(R.font.inter_semi_bold, FontWeight.SemiBold),
    )
}

/** Type roles mirroring the iOS `aurumText` styles. */
object AurumType {
    val display = TextStyle(fontFamily = AurumFonts.display, fontWeight = FontWeight.Medium, fontSize = 34.sp, lineHeight = 40.sp)
    val title = TextStyle(fontFamily = AurumFonts.display, fontWeight = FontWeight.Medium, fontSize = 26.sp, lineHeight = 32.sp)
    val editorial = TextStyle(fontFamily = AurumFonts.italiana, fontSize = 22.sp, lineHeight = 28.sp)
    val headline = TextStyle(fontFamily = AurumFonts.text, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 22.sp)
    val body = TextStyle(fontFamily = AurumFonts.text, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 22.sp)
    val caption = TextStyle(fontFamily = AurumFonts.text, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp)
    val label = TextStyle(fontFamily = AurumFonts.text, fontWeight = FontWeight.Medium, fontSize = 11.sp, letterSpacing = 1.6.sp)
}

object Spacing {
    val xs = 8.dp
    val s = 12.dp
    val m = 16.dp
    val l = 24.dp
    val xl = 32.dp
}

val LocalPalette = staticCompositionLocalOf<AurumPalette> { error("AurumTheme not applied") }

/** True when the system "Remove animations" setting is on (animator duration scale 0). */
val LocalReduceMotion = staticCompositionLocalOf { false }

private fun animationsOff(context: Context): Boolean =
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

@Composable
fun AurumTheme(brand: BrandConfig, content: @Composable () -> Unit) {
    val palette = remember(brand) { AurumPalette.from(brand) }
    val context = LocalContext.current
    var reduceMotion by remember { mutableStateOf(animationsOff(context)) }
    DisposableEffect(context) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { reduceMotion = animationsOff(context) }
        }
        context.contentResolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, observer,
        )
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    val scheme = darkColorScheme(
        primary = palette.accent,
        onPrimary = palette.onAccent,
        background = palette.background,
        onBackground = palette.textPrimary,
        surface = palette.surface,
        onSurface = palette.textPrimary,
        surfaceVariant = palette.surfaceRaised,
        onSurfaceVariant = palette.textSecondary,
        outline = palette.hairline,
        secondary = palette.accent,
    )
    CompositionLocalProvider(LocalPalette provides palette, LocalReduceMotion provides reduceMotion) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
