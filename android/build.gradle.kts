// The Android Gradle plugin goes on the root classpath (next to the Kotlin
// plugins, so they share a class loader) only when :app is part of the build.
buildscript {
    if (findProject(":app") != null) {
        dependencies { classpath(libs.android.gradle.plugin) }
    }
}

plugins {
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
