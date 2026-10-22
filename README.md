# Cratebox iOS Suite

A DJ app for iPhone and iPad with three modes behind one selector (the cyan button, top left):

| Mode | What it's for |
| --- | --- |
| **Performance Mode** | DJ on the phone or iPad: up to 4 decks, mixer, Beat FX and Pad FX, the DDJ-FLX4 and other controllers, your music folders and rekordbox USB sticks, recording. |
| **Deck Bridge** | Use the phone as a touch controller for rekordbox's decks 3 and 4 (or 1 and 2) on a computer. |
| **Cratebox USB** | Prepare and check a rekordbox USB stick before a gig: both libraries, preview, cues and grid, playlists, a preflight scan for the players you'll be on. |

Native Swift (SwiftUI, AVAudioEngine, CoreMIDI), iOS 17 or later, landscape. Version 0.1.0, early: expect rough
edges and please report them.

This is a fork of Cratebox for iOS (the `ios` branch of [zonahbear/Cratebox](https://github.com/zonahbear/Cratebox),
which is left as it was). It installs **beside** Cratebox, not over it (bundle ID `com.zonahbear.cratebox.suite`).

## Install

Through **TestFlight**: Jonah adds you as a tester, you get an email, and you install the TestFlight app and the
build from it. Builds come from `main` (`.github/workflows/testflight.yml`) and last 90 days. Sideloaded
(SideStore / AltStore) builds are retired; if you have one, delete it and install from TestFlight. Settings and
library don't carry over between the two.

## Performance Mode

- **Controller:** plug in the DDJ-FLX4 (USB-C, or Lightning with Apple's camera adapter). An iPhone may not power it; a powered USB-C hub fixes that and gives a second port for a USB stick. Other Pioneer / AlphaTheta controllers have profiles (Settings → Controller); anything else can be mapped with MIDI learn.
- **Sound:** with the FLX4, the master goes to its outputs and the headphone mix to its headphone jack. Settings → **Test cue** beeps in the headphones only. Without a 4-channel interface, Settings → **Split** puts a mono master left and the cue right (splitter cable). Bluetooth works, with a latency warning: waveforms are shifted to match what you hear.
- **Music:** Library → **Add music folder…** and pick it in Files (on the device, iCloud Drive or a USB drive). Nothing is copied.
- **rekordbox USB:** **+ USB** under DEVICES, pick the drive itself. Tracks load with rekordbox's grid, phrases and cues. Playlist editing on the stick is off by default (Settings → rekordbox USB playlists).
- **4 decks:** the **4 DECKS** button. On the FLX4, the deck numbers over the mixer (or SMART CFX / SMART FADER) switch each side between 1/3 and 2/4, with soft takeover.
- **Recording:** **REC** in the header; WAV or AAC with a tracklist, in Files → On My iPhone/iPad → Cratebox.

Different from the web app: recording is WAV or AAC (iOS has no MP3 encoder); the limiter catches peaks
instantly instead of looking 6 ms ahead. Not there yet: Report a problem, the Classic look, interface size, the
browse knob walking the playlist tree.

## Deck Bridge

The phone becomes a controller for rekordbox: jog wheels, PLAY / CUE, SYNC, key lock, quantize, slip, 8 hot cue
pads (SHIFT deletes), loops, tempo, trim, EQ, filter, channel faders, headphone cue, crossfader, Beat FX, browse and
load. rekordbox lights the buttons back.

> **On Windows, install rtpMIDI before anything else.** Deck Bridge can't reach rekordbox on a Windows PC
> without it, over Wi-Fi *or* a USB cable: Windows has no network MIDI of its own and doesn't see a plugged-in
> iPhone as a MIDI device. On a Mac nothing extra is needed.

1. **Link** the phone to the computer over MIDI (any one of these):
   - **Windows (Wi-Fi or USB cable): rtpMIDI, required.** Windows has no network MIDI of its own, so it needs **rtpMIDI**, a network-MIDI driver by Tobias Erichsen, at no charge ([download page](https://www.tobias-erichsen.de/software/rtpmidi.html)). It's not part of Cratebox. Its page lists Windows 7 to 10; it isn't listed for Windows 11 there, so check it installs on yours.
     1. Install Apple's **Bonjour** first if the rtpMIDI installer asks for it (rtpMIDI uses it to find the phone), then run the rtpMIDI installer.
     2. Open **rtpMIDI**. Under **My Sessions**, click **+** to add a session. Its **local Name** is what rekordbox will list as the MIDI device (e.g. `Deck Bridge`). Tick the checkbox to **enable** it.
     3. Set **Who may connect to me** to **Anyone** (or add the phone to the directory and choose **Only computers in my directory**).
     4. On the phone: Cratebox Suite → Deck Bridge → ⚙ → turn on **Network MIDI (Wi-Fi)**.
     5. In rtpMIDI's **Directory**, select the phone and click **Connect**. It moves to **Participants**, and Deck Bridge's link pill turns on.
     6. If the phone never shows up in the Directory: put both on the same network (not a guest network that keeps devices apart), and allow rtpMIDI through Windows Firewall on private networks. It talks over two UDP ports next to each other, 5004 and 5005 by default. You can also add the phone by hand with **+** under Directory, using the phone's IP address and port 5004.
     7. **Over a USB cable instead of Wi-Fi** (steadier at a venue, and it charges the phone): plug the phone in, turn on **Personal Hotspot** on the phone, and Windows sees the cable as a wired network. Then do steps 4–5 the same way: rtpMIDI is still what carries the MIDI, the cable is only the connection. Windows needs Apple's iPhone driver for this (it comes with iTunes or the Apple Devices app).
     8. rtpMIDI runs as a Windows service and reconnects saved connections at start-up, so this is a one-time setup.
   - **Mac, Wi-Fi:** built in. Audio MIDI Setup → Window → Show MIDI Studio → the globe (Network). Under **Directory** pick the phone and press **Connect**.
   - **Mac, USB cable:** no rtpMIDI needed. Plug the phone in. Audio MIDI Setup → Window → Show Audio Devices → **Enable** under the iPhone.
   - **Bluetooth:** Deck Bridge → ⚙ → **Bluetooth MIDI…**, then pair it on the computer (Mac: Audio MIDI Setup → MIDI Studio → Bluetooth).
2. **Import** the mapping once: in rekordbox, MIDI (top right) → pick the device (on Windows, the rtpMIDI session's **local Name**) → **IMPORT** → [`deckbridge/Cratebox Deck Bridge.midi.csv`](deckbridge/) (or share it from Deck Bridge → ⚙).

Cratebox doesn't ship its own desktop companion app; on Windows, rtpMIDI fills that role. Not yet tested against a running rekordbox: the jog wheels and hot cue pads are the
rows most likely to need **MIDI LEARN** (Deck Bridge → ⚙ → Learn helper sends any control on demand). Details:
[`deckbridge/README.md`](deckbridge/README.md).

## Cratebox USB

**Open USB** and pick the stick in Files. Cratebox reads both rekordbox libraries:

- **Device Library** (`PIONEER/rekordbox/export.pdb`), read by most players
- **OneLibrary** (`PIONEER/rekordbox/exportLibrary.db`, encrypted), read by the newer ones

and shows where the two disagree.

- **Preview:** tap a track to play it on a full Cratebox deck with rekordbox's colour waveform, grid and cues.
- **Edit:** hot cues, memory cues, saved loops, beat grid (BPM, nudge, bar 1, tap), track info, and playlists (new, rename, delete, reorder, add, remove).
- **Preflight scan:** pick the players at the gig and mark your set (**Set Priority**), then:

  | Scan | Checks |
  | --- | --- |
  | Emergency | Seconds. The set only: files present, formats the players read, the libraries they need. |
  | Standard | The whole stick, set first: file headers (codec, sample rate, bit depth), database structure and integrity, the two libraries against each other, file names FAT32 can't hold, file system. |
  | Deep | Everything above, plus decoding every file and parsing every analysis file. |

  Players: CDJ-3000X, CDJ-3000, CDJ-2000NXS2, CDJ-2000NXS, CDJ-900NXS, XDJ-1000MK2, XDJ-700, XDJ-XZ, XDJ-RX3, XDJ-RX2, XDJ-AZ, OPUS-QUAD, OMNIS-DUO, and **Unknown** (strictest: both libraries, FAT32, MP3/AAC/WAV/AIFF at 16-bit / 48 kHz). Players marked **?** weren't confirmed against their manuals and are checked strictly.
- **Fixing:** one-tap **Quick Fix** for groups of issues; **Fix / Review / Skip** on each one. A readiness badge (Ready / warnings / Not ready) sits in the top bar.
- **Eject:** finishes any write, flushes the stick and tells you when it's safe to unplug.

### What it writes to a stick

Nothing, by default. Each kind of write stays locked until you've proven it on your own players
(Cratebox USB → ⚙ → **Proving Ground**: make the change on a spare copy of a stick, play it on each player, then
unlock that write).

| Write | State |
| --- | --- |
| Playlists → Device Library | Writer tested byte for byte against the web app's; not yet confirmed on a player |
| Playlists → OneLibrary | Writer tested (SQLite integrity check, read-back, re-encrypt); not yet confirmed on a player |
| Cues, loops, beat grid → analysis files | No writer yet |
| Track info → the libraries | No writer yet |

Until then, edits are kept as **Staged changes**: Performance Mode uses your cues and grids when it plays the
stick, and you can export them as rekordbox XML. On a stick with both libraries, playlists are written to both or
neither. Every write is backed up (on the stick in `PIONEER/rekordbox/.cratebox/backups`, and in the app),
journaled, staged, read back, checked and swapped in with one rename; if the stick is pulled half way, the next
open puts the right version back.

## Building

GitHub Actions on macOS. `testflight.yml` (on push to `main`) builds, signs and uploads to TestFlight; setup is in
`ios/TESTFLIGHT.md`. `ios.yml` (started by hand) runs the CrateboxKit tests (`swift test`) and launches the app in
the iPhone and iPad simulators, with screenshots to the `ci-logs` branch.

Locally on a Mac: `brew install xcodegen && cd ios && xcodegen generate && open Cratebox.xcodeproj`.

### What's tested

The parts that decide how Cratebox sounds are ports of the web app's own code, checked against it in
`ios/CrateboxKit/Tests`:

| Part | Check |
| --- | --- |
| Deck player (key lock, scratch, backspin, loops) | 4 scenarios, sample for sample against the web app |
| Beat FX / Pad FX (all 10 effects) | 11 scenarios, sample for sample against the web app |
| Track analysis (BPM, grid, key, phrases, waveform) | identical results on the test tracks |
| export.pdb read and playlist writer | byte for byte against the web app's |
| OneLibrary decryption | against a real rekordbox database and SQLCipher's own output |
| OneLibrary playlist writer, preflight scans, staged writes and recovery, Deck Bridge messages and mapping file | unit tests on a copy of a real rekordbox stick |

## Layout

```
ios/App/                 the app: Performance Mode (Views/), Suite/ (mode selector), DeckBridge/, CrateboxUSB/
ios/CrateboxKit/         engine, analysis, controller mapping, rekordbox formats, preflight (Swift package, tested)
deckbridge/              rekordbox mapping file and Deck Bridge setup notes
tests/fixtures/          a copy of a real rekordbox USB export (no audio), used by the tests and the simulator run
```

The web app and the Linux version live in [zonahbear/Cratebox](https://github.com/zonahbear/Cratebox) and
[zonahbear/Cratebox-Linux](https://github.com/zonahbear/Cratebox-Linux).
