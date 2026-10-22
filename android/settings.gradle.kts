// Cratebox Suite for Android. :core is plain Kotlin (no Android), a port of ios/CrateboxKit, so its tests run on
// any JVM. :app is the Android app; it's only included when an Android SDK is around (ANDROID_HOME or
// local.properties), so `gradle :core:test` works on a machine without one; :platformcheck then type-checks the
// app's Android platform layer against android-all from Maven Central.
pluginManagement {
    repositories {
        google { content { includeGroupByRegex("com\\.android.*|androidx.*|com\\.google.*") } }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google { content { includeGroupByRegex("com\\.android.*|androidx.*|com\\.google.*") } }
        mavenCentral()
    }
}
rootProject.name = "CrateboxSuite"
include(":core")
// compile-checks app/.../platform against Android's framework jar when there's no SDK (see platformcheck/)
include(":platformcheck")
val hasSdk = System.getenv("ANDROID_HOME") != null || System.getenv("ANDROID_SDK_ROOT") != null ||
    file("local.properties").let { it.exists() && it.readText().contains("sdk.dir") }
if (hasSdk) include(":app")
