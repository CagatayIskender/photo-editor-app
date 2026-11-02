package com.aurum.app.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import com.aurum.app.ui.common.motion
import com.aurum.app.ui.shell.ComingSoonScreen
import com.aurum.app.ui.shell.OnboardingScreen
import com.aurum.app.ui.shell.ShellScreen
import com.aurum.app.ui.studio.StudioScreen
import com.aurum.app.ui.theme.LocalPalette

@Composable
fun AurumApp(model: AppViewModel) {
    // The system photo picker: no storage permission, and the user picks exactly what AURUM sees.
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        model.onPhotoPicked(uri)
    }
    SideEffect {
        model.openPicker = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
    }

    BackHandler(enabled = model.screen is Screen.Studio || model.screen is Screen.ComingSoon) { model.back() }

    val fade = motion<Float>()
    Box(Modifier.fillMaxSize().background(LocalPalette.current.background)) {
        AnimatedContent(
            targetState = model.screen,
            transitionSpec = { fadeIn(fade) togetherWith fadeOut(fade) },
            contentKey = { it::class },
            label = "screen",
        ) { screen ->
            when (screen) {
                Screen.Onboarding -> OnboardingScreen(model)
                Screen.Shell -> ShellScreen(model)
                is Screen.Studio -> StudioScreen(model, screen.session)
                is Screen.ComingSoon -> ComingSoonScreen(screen.feature, onBack = model::back)
            }
        }
    }
}
