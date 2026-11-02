// AURUM for Android.
//
// `core` is plain Kotlin/JVM and builds anywhere a JDK does. `app` needs the
// Android SDK; it is included only when one is configured (local.properties
// `sdk.dir`, or ANDROID_HOME / ANDROID_SDK_ROOT), so `gradle :core:test` works
// on machines and CI images without Android tooling. Force either way with
// -Paurum.includeApp=true|false.

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
    }
}

rootProject.name = "aurum-android"

include(":core")

fun androidSdkDir(): java.io.File? {
    val props = java.util.Properties()
    val local = java.io.File(settingsDir, "local.properties")
    if (local.isFile) local.inputStream().use { props.load(it) }
    val path = props.getProperty("sdk.dir") ?: System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")
    return path?.let { java.io.File(it) }?.takeIf { it.isDirectory }
}

val includeApp = providers.gradleProperty("aurum.includeApp").orNull?.toBoolean() ?: (androidSdkDir() != null)
if (includeApp) {
    include(":app")
} else {
    logger.lifecycle("AURUM: no Android SDK found, so only :core is configured. See android/README.md.")
}
