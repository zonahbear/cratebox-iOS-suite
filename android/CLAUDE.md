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
    Analysis.kt       = Analysis.swift; AnalysisTest needs CRATEBOX_MUSIC (python3 tests/make_tracks.py <dir>)
    Core.kt Controller.kt   decks/sync/FX state/Keys, controller profiles + MIDI engine (mixxx_maps.json read
                      from ios/CrateboxKit/Sources/CrateboxKit/Resources via a resources srcDir). Core is not
                      observable: the app redraws from it each frame; after editing core.mixer call mixerChanged()
    DeckBridgeMap.kt  = DeckBridgeMap.swift; rekordboxCSV() must equal deckbridge/Cratebox Deck Bridge.midi.csv
    PDB.kt PDBWrite.kt ANLZ.kt RekordboxXML.kt   export.pdb / analysis files / XML (playlist writer byte-identical
                      to the web app's). UInt32 fields are Longs.
    SQLCipher.kt OneLibrary.kt   javax.crypto codec; OneLibrary via SQLiteDB, a seam: set SQLite.opener (app:
                      android.database.sqlite, not written yet; tests: JdbcSQLite.install(), sqlite-jdbc)
    USBLibrary.kt USBHardware.kt USBPreflight.kt USBSafeWrite.kt USBTrackWrite.kt   stick files through StickFS
                      (paths relative to the stick root). FileStickFS for tests / real paths; the app needs a SAF
                      StickFS (DocumentsContract has no atomic rename-over: delete + rename, the journal covers it).
                      Journal JSON matches iOS (`when` = seconds since 2001), so recovery works across both apps.
  src/test/kotlin/... JUnit ports of CrateboxKitTests; system property cratebox.repo = repo root (fixtures)
platformcheck/        compiles app/.../platform against android-all (robolectric jar) so the platform layer is
                      type-checked without an SDK: `gradle :platformcheck:compileKotlin`. Not a runtime test.
app/src/main/kotlin/com/zonahbear/cratebox/platform/   Android layer (no UI yet, no app/build.gradle.kts yet)
    AudioHost AudioDecoder Recorder   AAudio-less AudioTrack host, MediaCodec decode, wav/aac recording to MediaStore
    MidiHost Main                     android.media.midi in/out (+ framer from core), main-thread helpers
    PuffcoBle HeatController          HEAT: BluetoothGatt Lorax, SimPuffco; safety rules kept
    SafStickFS AndroidSQLite          StickFS over DocumentsContract; SQLite.opener for OneLibrary
    Library Devices USBSession USBPreview AndroidPrefs   library/folders, mounted sticks, Cratebox USB (gated)
    RtpMidiSession DeckBridge         Deck Bridge: USB MIDI peripheral mode + own AppleMIDI session (Bonjour
                                      _apple-midi._udp, ports 5004/5005+). No BLE MIDI peripheral on Android.
    AppModel                          wires it all (decks, library views, MIDI learn, LEDs, HEAT, USB); ControlTarget
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

- Phase 2 done (2026-10-22): all of CrateboxKit (preview/truecurve-usb) in :core, 64 tests green, every Swift
  test ported with the same expected values. Stick fixture: tests/fixtures/rekordbox_usb.
- Phase 3 platform layer done (2026-10-22): everything under platform/ compiles via :platformcheck; 83 core
  tests green. Untested on a device. minSdk 29: no API 33+ calls without a Build.VERSION gate.
- Manifest must set android:largeHeap (decoded decks are float PCM in RAM).
- Phase 4 (needs the Android SDK, so a session that reaches dl.google.com): :app app/build.gradle.kts + manifest +
  Compose UI over AppModel (Performance Mode, HEAT, Deck Bridge, Cratebox USB behind Proving Ground), signed
  private APK (keys in GitHub secrets), manual-only CI.
