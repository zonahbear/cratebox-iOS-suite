# CLAUDE.md: cratebox-iOS-suite

Read this first; it exists so you don't have to re-parse the repo. Update it when you change structure,
CI, conventions, or finish/start a piece of open work. Keep it under ~150 lines.

## What this repo is

Native Swift iOS app "Cratebox Suite" (SwiftUI + AVAudioEngine + CoreMIDI, iOS 17+, landscape, v0.1.0).
Bundle ID `com.zonahbear.cratebox.suite`; installs beside the original Cratebox iOS app. Three modes behind one
selector: **Performance Mode** (DJ: 4 decks, mixer, FX, DDJ-FLX4), **Deck Bridge** (phone as a MIDI controller
for rekordbox), **Cratebox USB** (inspect/edit/preflight rekordbox USB sticks). Forked from the `ios` branch of
zonahbear/Cratebox. The repo also carries a copy of the web app (see Cross-repo).

User-facing docs: `README.md` (long; don't re-read unless you need install/feature wording).

## Map

```
ios/project.yml              XcodeGen spec (no .xcodeproj in git). Version lives here (MARKETING_VERSION).
ios/App/                     the app target
  CrateboxApp.swift          entry point
  AppModel.swift             glue: audio host + engine, decks, controller actions (pressAction/setAbs port)
  AudioHost.swift            AVAudioEngine setup, routing (FLX4 4-ch, Split, Bluetooth latency)
  MIDIHost.swift Devices.swift  CoreMIDI in/out, device list
  Library.swift Playlists.swift Recorder.swift   music folders, playlists, WAV/AAC recording
  Suite/SuiteMode.swift      mode selector; launch args -demo -four -browse -wave -bridge -usb (used by CI)
  Views/                     Performance Mode UI (ContentView, DeckView, MixerView, LibraryView, BrowserView,
                             PhoneLayout, WaveStack = WAVE mode, Theme)
  DeckBridge/                DeckBridge.swift (MIDI send/receive, network session) + DeckBridgeView.swift
  CrateboxUSB/               USBSession.swift (state, scans, writes), USBPanels.swift (staged changes,
                             settings, Proving Ground), USBPreview.swift, CrateboxUSBView.swift
  ObjC/ObjCTry.*             catches ObjC exceptions from AVFoundation
ios/CrateboxKit/             Swift package, UI-free, all the tested logic
  Core.swift                 decks, sync, cues, loops, grid edit, mixer/FX state (port of web Deck class)
  Engine.swift DeckPlayer.swift Mixer.swift FxUnit.swift   DSP (ports of the web AudioWorklets)
  Analysis.swift             BPM / grid / key / phrases / waveform (port of web analyser)
  Controller.swift           controller profiles, MIDI learn; Resources/mixxx_maps.json (= web MIXXX_MAPS)
  DeckBridgeMap.swift        Deck Bridge message layout + generates the rekordbox mapping CSV
  PDB.swift PDBCheck.swift ANLZ.swift   export.pdb read/write, ANLZ analysis files
  OneLibrary.swift SQLCipher.swift SQLiteDB.swift   exportLibrary.db (encrypted) read/write
  USBLibrary.swift USBPreflight.swift USBHardware.swift   stick model, preflight scans, player capability table
  USBSafeWrite.swift         ALL stick writes go through here (backup, journal, read-back, rename, recovery)
  RekordboxXML.swift Version.swift
ios/CrateboxKit/Tests/       XCTest suites + Fixtures/ (DSP oracles .f32, pdb/onelibrary/sqlcipher samples)
ios/tools/                   oracle generators: dsp_oracle.js / analysis_oracle.js (run the web code to make
                             expected outputs), onelibrary_fixture.py, sqlcipher_ref.py
deckbridge/                  `Cratebox Deck Bridge.midi.csv` (rekordbox import) + setup README
tests/fixtures/rekordbox_usb real rekordbox USB export (no audio), used by tests and the CI simulator run
tests/*.py tests/*.js tools/*.js   web-app tests/tools (copies from Cratebox; see Cross-repo)
cratebox.html index.html sw.js manifest.webmanifest filetest.html start_cratebox.py   web app copy
reports.txt                  problem reports, appended by .github/workflows/reports.yml from issues
```

## Build, test, CI

- **CI is the only real iOS build.** Cloud sessions have no Xcode/iOS SDK. You can run CrateboxKit tests on
  Linux only if you install a Swift toolchain yourself, and the SwiftUI app target won't compile there.
- `.github/workflows/ios.yml` (macos-15) on push to `main` or `preview/**` touching `ios/**` or the workflow:
  1. `tests/make_tracks.py` builds test WAVs, checked against `Fixtures/music.md5`
  2. `cd ios/CrateboxKit && CRATEBOX_MUSIC=<dir> swift test -c release -Xswiftc -enable-testing`
     (continue-on-error: a test failure does NOT fail the job; read the log)
  3. `xcodegen generate` + unsigned `xcodebuild` → `CrateboxSuite.ipa`
  4. publish: `main` → release `ios-latest`. On `main` today preview branches publish nothing; the
     `preview/bridge-send` branch changes this to publish preview builds to a separate `ios-preview` release.
  5. simulator launches (iPhone 16 Pro Max, iPad Pro 13") with screenshots for each launch arg
  6. summary + screenshots force-pushed to branch `ci-logs` (main) or `ci-logs-preview` (preview/*):
     read `ios-latest.txt` and `shots/` there instead of downloading Action logs.
- Local Mac: `brew install xcodegen && cd ios && xcodegen generate && open Cratebox.xcodeproj`.
- Web-app tests (`python tests/test_*.py`, playwright + chromium; `node tests/test_rekordbox.js`) belong to the
  web copy; run them in Cratebox, not here.

## Conventions

- Branches: `main` = what ships. `preview/<topic>` = installable test build via CI (Jonah sideloads it with
  SideStore). Session branches are `claude/...`. Don't push to another thread's preview branch.
- Commit messages: one plain-English sentence or two per feature, `Area: what changed for the user`
  (e.g. "Deck Bridge: ...", "CI: ...", "WAVE fixes: ...").
- CrateboxKit code is a close port of cratebox.html; keep names/structure parallel and check parity with the
  oracles in `ios/tools/` (sample-for-sample DSP, identical analysis, byte-for-byte PDB).
- Comments explain the why at the top of each file; match that density.
- User-facing text: plain, specific, no marketing tone. CHANGELOG.md here is the *web app's* changelog.

## Cross-repo

- **zonahbear/Cratebox** is the source of truth for `cratebox.html` and the other web files. This repo's copy
  is periodically synced from it; edit there first, then copy across. As of 2026-10-21 the copy is one commit
  behind (Cratebox `62ffff7`, phone status-bar/safe-area: 2 lines).
- **zonahbear/Cratebox-Linux** is a separate Rust port of the same web app; shares no code, only behaviour.
- Controller maps: `tools/mixxx2cratebox.py` turns Mixxx XML into the web app's `MIXXX_MAPS`; this repo's
  `mixxx_maps.json` and Linux's `src/maps.rs` are derived from that table.
- For a section map of `cratebox.html` (6.5k lines), see Cratebox's CLAUDE.md.

## Gotchas

- **USB writes are locked** behind Cratebox USB → ⚙ → **Proving Ground**: each write type stays off until the
  user proves it on their own players. Never default a write to on. Every write goes through `USBSafeWrite`;
  on a stick with both libraries, playlists go to both or neither. Unproven edits stay as Staged changes.
- **Deck Bridge × rekordbox (from real testing, 2026-10-21):** rekordbox takes **no jog wheel** from a generic
  MIDI device. `JogRotate` rows are ignored, so the platter sends Search (top) or Pitch Bend (edge) instead.
  rekordbox MIDI LEARN can grab the wrong note (deck 4 bend learned as `9371` = Search fwd; real bend up is
  `9373`, down `9372`). Re-importing the CSV doesn't clear learned rows: delete old rows/mapping first.
  Hot cue pads follow rekordbox's pad mode. Tempo direction is CDJ-style (up = slower).
  Layout: deck N on MIDI channel N, pads on 8–11, mixer globals 7, Beat FX 5, 14-bit faders.
- **Windows needs rtpMIDI** for Deck Bridge (Wi-Fi or USB-hotspot); Mac needs nothing.
- Format specs disagree (crate-digger / pyrekordbox / rekordcrate), e.g. a plain cue's type byte (1 vs 0);
  PQT2 in .EXT is undecoded. Write tests against real fixtures, not one spec.
- Free Apple ID = 3 sideloaded apps, 7-day signature; CI builds are unsigned on purpose.

## Open work (update this when it changes)

- `preview/bridge-send` (PR #1 tracks it): Deck Bridge send/Search/bend fixes, waiting on Jonah's rekordbox retest.
- `preview/usb-writers`: cue / grid / track-info writers (still Proving Ground locked); includes bridge-send.
- Sync `cratebox.html` from Cratebox `62ffff7`; consider a CI check that fails when the copy drifts.
- Not ported yet from web: Report a problem, Classic look, interface size, browse knob tree walking.
