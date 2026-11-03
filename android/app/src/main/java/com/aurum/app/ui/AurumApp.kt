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
import com.aurum.app.ui.autostudio.AutoStudioScreen
import com.aurum.app.ui.autostudio.DepthMotionScreen
import com.aurum.app.ui.camera.CameraScreen
import com.aurum.app.ui.collage.CarouselScreen
import com.aurum.app.ui.collage.CollageScreen
import com.aurum.app.ui.templates.TemplatesScreen
import com.aurum.app.ui.video.VideoEditorScreen
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

    BackHandler(enabled = model.screen != Screen.Shell && model.screen != Screen.Onboarding) { model.back() }

    val fade = motion<Float>()
    Box(Modifier.fillMaxSize().background(LocalPalette.current.background)) {
        AnimatedContent(
            targetState = model.screen,
            transitionSpec = { fadeIn(fade) togetherWith fadeOut(fade) },
            contentKey = { if (it is Screen.Video) "video-${it.project?.id}" else it::class },
            label = "screen",
        ) { screen ->
            when (screen) {
                Screen.Onboarding -> OnboardingScreen(model)
                Screen.Shell -> ShellScreen(model)
                is Screen.Studio -> StudioScreen(model, screen.session)
                is Screen.Video -> VideoEditorScreen(model, screen.project, screen.source)
                Screen.Templates -> TemplatesScreen(model)
                Screen.Camera -> CameraScreen(model)
                Screen.AutoStudio -> AutoStudioScreen(model)
                Screen.DepthMotion -> DepthMotionScreen(model)
                Screen.Collage -> CollageScreen(model)
                Screen.Carousel -> CarouselScreen(model)
            }
        }
    }
}
