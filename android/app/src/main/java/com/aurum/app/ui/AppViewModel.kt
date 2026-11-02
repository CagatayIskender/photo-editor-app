package com.aurum.app.ui

import android.app.Application
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.aurum.app.container
import com.aurum.app.imaging.ImageLoader
import com.aurum.app.l10n.tr
import com.aurum.app.ui.studio.StudioSession
import com.aurum.core.EditDocument
import com.aurum.core.Preset
import com.aurum.core.PresetLinkCodec
import com.aurum.core.SourceAsset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

enum class Tab { salon, create, vault }

/** Features that exist on iOS and are not on Android yet. */
enum class ComingFeature(val titleKey: String) {
    video("Video"), templates("Templates"), camera("Camera"),
    autoStudio("Auto Studio"), motion("3D Motion"), collage("Collage"), carousel("Carousel"),
}

sealed interface Screen {
    data object Onboarding : Screen
    data object Shell : Screen
    data class Studio(val session: StudioSession) : Screen
    data class ComingSoon(val feature: ComingFeature) : Screen
}

/**
 * App navigation and the actions screens share, the counterpart of the iOS
 * `AppModel`. Navigation is a small state machine rather than a nav graph,
 * since the app has one stack level (the Studio or a coming-soon page).
 */
class AppViewModel(application: Application) : AndroidViewModel(application) {
    val container = application.container
    private val linkCodec = PresetLinkCodec(container.brand.urlScheme)

    var screen: Screen by mutableStateOf(if (container.prefs.hasCompletedOnboarding) Screen.Shell else Screen.Onboarding)
        private set
    var tab by mutableStateOf(Tab.salon)

    /** A short, already localised notice shown at the bottom of the shell. */
    var notice by mutableStateOf<String?>(null)

    /** Applied to the next photo picked: a look tapped in the Salon, or a preset. */
    private var queuedLookID: String? = null
    private var queuedPreset: Preset? = null

    /** Set by the UI to open the system photo picker. */
    var openPicker: (() -> Unit)? = null

    init {
        viewModelScope.launch {
            container.drafts.refresh()
            container.presets.refresh()
            container.membership.refresh()
        }
    }

    fun completeOnboarding(vibes: List<String>) {
        container.prefs.vibes = vibes
        container.prefs.hasCompletedOnboarding = true
        screen = Screen.Shell
    }

    fun startCreating(lookID: String? = null) {
        queuedLookID = lookID
        queuedPreset = null
        openPicker?.invoke()
    }

    fun usePreset(preset: Preset) {
        queuedPreset = preset
        queuedLookID = null
        openPicker?.invoke()
    }

    fun openComingSoon(feature: ComingFeature) {
        screen = Screen.ComingSoon(feature)
    }

    fun back() {
        when (val s = screen) {
            is Screen.Studio -> closeStudio(s.session)
            is Screen.ComingSoon -> screen = Screen.Shell
            else -> Unit
        }
    }

    /** Called with the photo picker's result. */
    fun onPhotoPicked(uri: Uri?) {
        if (uri == null) {
            queuedLookID = null
            queuedPreset = null
            return
        }
        val app = getApplication<Application>()
        // Keep access so drafts can reopen the photo later. Not every picker grants it.
        runCatching { app.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        viewModelScope.launch {
            val size = withContext(Dispatchers.IO) { ImageLoader.size(app, uri) }
            if (size == null) {
                notice = app.tr("This photo couldn't be opened.")
                return@launch
            }
            var doc = EditDocument(source = SourceAsset(uri.toString(), size))
            queuedPreset?.let { doc = it.apply(doc) }
            val look = queuedLookID
            queuedLookID = null
            queuedPreset = null
            openStudio(doc, uri, suggestLook = look == null && doc.isPristine, queuedLook = look)
        }
    }

    fun openDraft(id: UUID) {
        val app = getApplication<Application>()
        viewModelScope.launch {
            val doc = container.drafts.load(id)
            val uri = doc?.let { Uri.parse(it.source.localIdentifier) }
            if (doc == null || uri == null || withContext(Dispatchers.IO) { ImageLoader.size(app, uri) } == null) {
                notice = app.tr("This draft could not be opened.")
                return@launch
            }
            openStudio(doc, uri, suggestLook = false, queuedLook = null)
        }
    }

    private fun openStudio(doc: EditDocument, uri: Uri, suggestLook: Boolean, queuedLook: String?) {
        val session = StudioSession(getApplication(), container, uri, doc, viewModelScope)
        session.load(suggestLook = suggestLook, queuedLookID = queuedLook)
        screen = Screen.Studio(session)
    }

    fun closeStudio(session: StudioSession) {
        screen = Screen.Shell
        viewModelScope.launch { session.close() }
    }

    fun deleteDraft(id: UUID) = viewModelScope.launch { container.drafts.delete(id) }

    fun deletePreset(id: UUID) = viewModelScope.launch { container.presets.delete(id) }

    fun presetLink(preset: Preset): String = linkCodec.link(preset)

    /** Handles aurum://preset/… links from either platform. */
    fun handleLink(uri: Uri?) {
        uri ?: return
        val app = getApplication<Application>()
        val preset = runCatching { linkCodec.preset(uri.toString()) }.getOrNull()
        if (preset == null) {
            notice = app.tr("That link isn't a preset AURUM can open.")
            return
        }
        viewModelScope.launch { container.presets.add(preset) }
        if (screen == Screen.Onboarding) completeOnboarding(emptyList())
        if (screen !is Screen.Studio) {
            tab = Tab.vault
            notice = app.tr("“%@” is ready. Pick a photo to use it.", preset.name)
        }
    }
}
