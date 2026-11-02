package com.aurum.app.l10n

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext

/**
 * Looks up a string by its English source text, the way SwiftUI's Text("Begin")
 * does on iOS. Keys come from App/Localizable.xcstrings plus
 * android/l10n/android_strings.json; tools/sync_android_assets.py --check fails
 * the build when a literal key used here has no string.
 *
 * A key with no entry (for example catalogue content) is shown as written.
 */
@Composable
@ReadOnlyComposable
fun tr(key: String, vararg args: Any): String {
    LocalConfiguration.current // re-read when the locale changes
    return LocalContext.current.tr(key, *args)
}

/** Same as [tr] for text that is not a literal key (catalogue and config content). */
@Composable
@ReadOnlyComposable
fun trDynamic(value: String): String = tr(value)

fun Context.tr(key: String, vararg args: Any): String {
    val id = L10nKeys.ids[key]
    return when {
        id != null && args.isEmpty() -> getString(id)
        id != null -> getString(id, *args)
        args.isEmpty() -> key
        else -> String.format(key.replace("%lld", "%d").replace("%@", "%s"), *args)
    }
}
