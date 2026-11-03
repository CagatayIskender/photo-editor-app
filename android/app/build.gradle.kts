import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    // On the root classpath via buildscript (see ../build.gradle.kts), so no version here.
    id("com.android.application")
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.aurum.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.aurum.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.4.0"
        // English source and Turkish, generated from App/Localizable.xcstrings.
        resourceConfigurations += listOf("en", "tr")
        vectorDrawables.useSupportLibrary = false
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.exifinterface)
    implementation(libs.kotlinx.coroutines.android)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.play.billing)

    // Video editor, beat templates and 3D Motion export (on-device).
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.transformer)
    implementation(libs.media3.effect)
    implementation(libs.media3.common)
    implementation(libs.media3.ui)
    // Live-look camera.
    implementation(libs.camerax.core)
    implementation(libs.camerax.camera2)
    implementation(libs.camerax.lifecycle)
    implementation(libs.camerax.view)
    // Auto Studio: bundled, on-device models only. Nothing is uploaded.
    implementation(libs.mlkit.face)
    implementation(libs.mlkit.selfie)

    testImplementation(libs.junit)
}

// Fails the build early when the shared catalogues, fonts, stickers or strings
// under src/main were not regenerated after a change at the repository root.
val verifySharedAssets by tasks.registering(Exec::class) {
    group = "verification"
    description = "Checks the Android copies of the shared catalogues are current (tools/sync_android_assets.py --check)."
    commandLine("python3", rootProject.file("tools/sync_android_assets.py").absolutePath, "--check")
    isIgnoreExitValue = false
    // For machines without Python: -Paurum.skipAssetCheck
    onlyIf { !project.hasProperty("aurum.skipAssetCheck") }
}
tasks.named("preBuild") { dependsOn(verifySharedAssets) }
