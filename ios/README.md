# Cratebox for iOS

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

1. Download **Cratebox.ipa** from the [`ios-latest` release](https://github.com/zonahbear/Cratebox/releases/tag/ios-latest) (every push to the `ios` branch rebuilds it).
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
