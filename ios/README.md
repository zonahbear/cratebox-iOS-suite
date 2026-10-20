# Cratebox iOS Suite

A fork of Cratebox for iOS (the `ios` branch of zonahbear/Cratebox, left untouched) with three modes behind one
selector (the cyan capsule, top left):

- **Performance Mode**: the Cratebox DJ app as it was: decks, mixer, FX, controller, library, recording.
- **Deck Bridge**: a touch controller for rekordbox's decks 3 and 4 over standard MIDI (network, USB to a Mac,
  or Bluetooth), with a rekordbox mapping file to import. See [`deckbridge/`](../deckbridge/README.md).
- **Cratebox USB**: a rekordbox USB stick manager: both libraries (Device Library `export.pdb` and OneLibrary
  `exportLibrary.db`), preview playback with rekordbox's waveform and grid, cue / loop / grid / info editing,
  playlist editing, preflight scans for the players at the gig, quick fixes, staged and recoverable writes.

It installs beside Cratebox (its own bundle ID, `com.zonahbear.cratebox.suite`).

### Cratebox USB: what it writes, and what it won't (yet)

Nothing is written to a stick unless that kind of write is *proven*: Cratebox USB → ⚙ → Proving Ground.

| Write | State | Until then |
| --- | --- | --- |
| Playlists → Device Library | writer tested byte for byte, not yet on a player | staged |
| Playlists → OneLibrary | writer tested (SQLite + read-back + re-encrypt), not yet on a player | staged |
| Cues, loops, grid → analysis files | no writer | kept in Cratebox: Performance Mode uses them; rekordbox XML export |
| Track info → both libraries | no writer | same |

On a stick with both libraries, playlists go to both or neither. Every write: backup (stick and app), journal,
staged file, read-back, checks, one rename, read-back; a cut-off write is recovered next time the stick opens.

### Cratebox USB: the scans

| | |
| --- | --- |
| Emergency | the set (Set Priority) only: files there, formats the players read, the libraries they need. Seconds. |
| Standard | the whole stick, set first: file headers (codec, kHz, bits), export.pdb structure, OneLibrary integrity, the two libraries against each other, FAT32 names |
| Deep | + decodes every file, parses every analysis file, hot cues older players can't show |

Players: CDJ-3000X, CDJ-3000, CDJ-2000NXS2, CDJ-2000NXS, CDJ-900NXS, XDJ-1000MK2, XDJ-700, XDJ-XZ, XDJ-RX3,
XDJ-RX2, XDJ-AZ, OPUS-QUAD, OMNIS-DUO, and "Unknown" (needs both libraries, FAT32, MP3/AAC/WAV/AIFF at
16-bit / 48 kHz). Models marked ? in the app weren't confirmed against their manuals and are checked strictly.

## Cratebox for iOS (Performance Mode)

A native iPhone and iPad version of Cratebox: Swift, AVAudioEngine, CoreMIDI, SwiftUI. Up to 4 decks, the
DDJ-FLX4 (and the other Pioneer / AlphaTheta profiles) over USB, music folders and rekordbox USB sticks
through the Files app.

The parts that decide how Cratebox sounds and analyses are ports of the web app's own code, line by line,
and are tested against it (`swift test` in `CrateboxKit`):

| Part | Checked against the web app |
| --- | --- |
| Deck player (keylock, scratch, backspin, loops) | 4 scenarios, sample for sample (max error 0) |
| Beat FX / Pad FX (all 10 effects) | 11 scenarios, sample for sample (max error 0) |
| Track analysis (BPM, grid, key, phrases, waveform) | the 4 synthetic test tracks: identical results |
| rekordbox export.pdb (read, and the playlist writer) | byte for byte, including a table that grows by pages |
| ANLZ, rekordbox XML, FLX4 mapping, sync, beat lock, soft takeover | unit tests |

## Install (free Apple ID, re-signed every 7 days)

1. Download **CrateboxSuite.ipa** from the [`ios-latest` release](https://github.com/zonahbear/cratebox-iOS-suite/releases/tag/ios-latest) (every push to `main` rebuilds it).
2. Install **SideStore** on the iPhone/iPad once (its setup needs a computer one time, to make a pairing file; its own guide covers Windows, macOS and Linux). AltStore works too.
3. In SideStore: **My Apps → +** and pick `Cratebox.ipa`. Sign in with your Apple ID when it asks.
4. SideStore refreshes the app every few days (a free Apple ID's signature lasts 7 days). Your library, cues and settings stay.

## Using it

- **Controller:** plug the FLX4 in (USB-C, or Lightning with Apple's camera adapter). An iPhone may not power it: a powered USB-C hub fixes that, and also gives a second port for a USB stick.
- **Sound:** with the FLX4 connected, the master goes to its outputs and the headphone mix to its headphone jack (outputs 3/4). Settings → **Test cue** beeps in the headphones only. Without a 4-channel interface, Settings → Split puts a mono master left and the cue right (splitter cable).
- **Music:** Library → **Add music folder…** and pick it in Files (on the device, iCloud Drive, or a USB drive). Nothing is copied; the folder comes back after a restart.
- **rekordbox USB:** **+ USB** under DEVICES and pick the drive itself. Tracks load with rekordbox's grid, phrases and cues. Playlist editing is off by default (Settings → rekordbox USB playlists).
- **Recording:** **REC** in the header; WAV or AAC, with a tracklist, in Files → On My iPhone/iPad → Cratebox.
- **4 decks:** the 4 DECKS button; on the FLX4 the deck numbers over the mixer (or SMART CFX / SMART FADER, Settings → Controller) switch each side between 1/3 and 2/4, with soft takeover.

## Different from the web app

- Recording is WAV or **AAC** (no MP3 encoder on iOS).
- The master limiter catches peaks at once instead of looking 6 ms ahead, so it never clips (no makeup gain).
- Not there yet: Report a problem, the Classic look, interface size, the browse knob walking the playlist tree (it moves through the track list).

## Building

GitHub Actions (`.github/workflows/ios.yml`) on macOS: core tests, then `xcodegen generate` and an unsigned
`xcodebuild`, packaged as `Cratebox.ipa`, plus a launch in the iPhone and iPad simulators. Locally on a Mac:
`brew install xcodegen && cd ios && xcodegen generate && open Cratebox.xcodeproj`.
