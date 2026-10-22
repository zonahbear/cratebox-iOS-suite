# CLAUDE.md: Cratebox Suite for Android

Read this first; update it when structure or open work changes. Keep it short.

## What this is

Android port of the iOS suite (Performance Mode, Deck Bridge, Cratebox USB incl. writers, HEAT). Native Kotlin.
Plan and reasoning: https://claude.ai/artifact/CNJfWYLNw3Y7SnFpJUfv6p (started 2026-10-22).
Distribution is private (Jonah plans to sell the suite): APKs go to testers directly, Play internal testing later.

## Map

```
settings.gradle.kts   :core always; :app only when an Android SDK is found (ANDROID_HOME / local.properties)
core/                 plain Kotlin/JVM port of ios/CrateboxKit (no Android imports). Java 17 bytecode.
  src/main/kotlin/com/zonahbear/cratebox/core/
    TrueCurve.kt      = CrateboxKit TrueCurve.swift (curve, Driver, Learner, SimHeater, paste, Lorax bytes)
    DeckPlayer.kt FxUnit.kt Mixer.kt Engine.kt   = the Swift DSP; DSPTest matches the web oracles exactly
  src/test/kotlin/... JUnit ports of CrateboxKitTests; system property cratebox.repo = repo root (fixtures)
app/                  (not yet) Compose app: audio host, MIDI, BLE, Storage Access Framework
```

## Build / test

- `cd android && ./gradlew :core:test` (or `gradle :core:test`). Works in cloud sessions: needs only Maven
  Central + Gradle plugin portal. Maven Central sometimes answers 429; retry with `--max-workers=1`.
- APK needs the Android SDK from dl.google.com / maven.google.com. The cloud environment in use before
  2026-10-22 06:42Z blocked those; Jonah changed the project environment, so newer sessions may reach them.
- No push-triggered CI. Any APK workflow must be manual (Actions minutes ran out; Linux runner if needed).

## Conventions

- Port the Swift (which ports cratebox.html) closely: same names, same structure, same comments' intent.
  Each Swift test file gets a Kotlin test file with the same expected numbers.
- Safety rules carried from TrueCurve: slot 4 (index 3) backup/restore, 600°F cutoff, 350–590°F clamp.
- USB writes stay locked behind Proving Ground, unproven by default, all through a SafeWrite equivalent.

## Open work

- Phase 2: port the rest of CrateboxKit (Core, DSP, Analysis, Controller, DeckBridgeMap, PDB/ANLZ/OneLibrary/
  SQLCipher, preflight, writers). Reference branch: preview/truecurve-usb. Done: TrueCurve, DSP chain (DeckPlayer, FxUnit, Mixer, Engine).
- Phase 3+: :app (Performance Mode, HEAT, Deck Bridge via USB MIDI then RTP-MIDI, Cratebox USB).
