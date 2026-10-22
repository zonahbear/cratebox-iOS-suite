// Compile-checks the app's Android platform layer (app/src/main/kotlin/.../platform: audio, decoding, MIDI,
// Bluetooth, SAF, SQLite) on a machine without the Android SDK, against Robolectric's android-all jar from
// Maven Central (the real framework classes, API 36). Nothing here ships: the app compiles the same files for
// real once an SDK is around. Only framework APIs belong in platform/ (no AndroidX), and anything past API 29
// (minSdk) needs a Build.VERSION check, which this can't enforce: lint does in the real build.
plugins { kotlin("jvm") }

java { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
    sourceSets["main"].kotlin.srcDir("../app/src/main/kotlin/com/zonahbear/cratebox/platform")
}

dependencies {
    implementation(project(":core"))
    compileOnly("org.robolectric:android-all:16-robolectric-13921718")
}
