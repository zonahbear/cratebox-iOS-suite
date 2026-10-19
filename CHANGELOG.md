# Changelog

All notable changes to Cratebox (the web app). Version numbers follow `MAJOR.MINOR.PATCH`.

## Unreleased

### Added
- **Deck layers: play decks 3 and 4 from the FLX4** (or any 2-channel controller). In 4-deck mode, toggles at the top of the mixer switch the controller's left side between decks 1 and 3 and its right side between 2 and 4. Every control on that side follows (transport, jog, pads, loops, LOAD, tempo, the channel's fader, EQ, TRIM, CFX and CUE), and so do the lights, the VU meter and the BEAT FX CH SELECT lever. The decks being played get an outline in their colour.
- **Soft takeover** after a switch: faders and knobs only take over once they reach the new deck's setting, so nothing jumps.
- The toggles are learnable onto hardware buttons. 2 DECKS puts the controller back on decks 1 and 2.
- **SMART CFX / SMART FADER as deck layer buttons**: Settings → Controller → *Deck layers on SMART CFX / FADER…*, press each once. SMART CFX switches the left side 1 ⇄ 3, SMART FADER the right side 2 ⇄ 4. Their lights stay off: on the FLX4 they switch the controller's own Smart CFX / Smart Fader on, which then moves the EQ and BEAT FX by itself. (Pioneer doesn't publish those two buttons' messages, so they're picked up by pressing them; a button that already does something is refused.)
- `tests/test_layers.py`, `tests/test_header.py`, `tests/test_resume.py`.

### Changed
- **Deck layer toggles sit over their channel strips**: one number per deck in the mixer's own order (3 1 | 2 4). The decks the controller plays are lit in their colour with a slow, soft pulse (none with reduced motion turned on).
- **Track analysis is about twice as fast for a library**: the beat tracker and key detection do the same maths with half the FFTs (two frames per FFT, tables worked out once); BPM, grid, key and phrases come out the same (to floating-point rounding). On a computer with 4 or more hardware threads (the 2017 MacBook Air has 4) two tracks are analysed at a time while nothing plays, one while music plays. Measured: 8 tracks (4 x 5 min, 4 x 75 s) from 15.5 to 7.1 s. Deck loads use whichever analysis worker is free, and the downmix before analysis runs in slices so the screen keeps drawing.

### Fixed
- **Decks 3 and 4 expanded (⤢) get the full deck layout**, like decks 1 and 2: tempo fader, jog and controls side by side (mirrored on deck 4). Before, the full layout was only set for decks 1 and 2, so an expanded deck 3 or 4 piled the jog on top of the pads and buttons.
- **The playing deck no longer stutters while you load a track** on a 2-core computer. Library analysis in the background took the CPU time the audio needed, and the replaced track's audio (~100 MB) was freed on the audio thread; together they held the audio up for up to ~250 ms during a load. Now, on a computer with 2 cores (4 hardware threads or fewer) and on phones, library analysis stops completely while anything plays (a job under way is ended at once and its track goes back in the queue; it carries on when everything stops; tracks you load are still analysed right away), and the replaced track's audio is handed back to the page to be freed there. Worst audio hold-up during 10 loads: 244 ms before, 26-37 ms after. `tests/test_loadstutter.py`.
- **GRID / MT / Q no longer jump around during playback.** When the deck's info row was full (a synced deck with MASTER, the sync offset and a pitched key showing, at 1440 px wide), every change pushed the buttons sideways, and MASTER onto a second line. The row now stays on one line and the buttons stay put; the phrase name, elapsed time and the beat dots give way instead (cut off with …).
- **"Tap to resume audio" no longer freezes the screen.** When the browser stops the audio by itself (another app such as rekordbox takes the controller's sound, the controller is unplugged, the laptop sleeps), Cratebox now starts it again on its own straight away, then every 2 s and on the next click or key press, and goes back to the default output if the chosen one has gone. A small banner says what's going on, without covering the decks; after a few tries it suggests closing rekordbox or checking the cable. The stops and restarts are in problem reports.

## 1.1.1 (2026-10-16)

### Changed
- **Faster drawing on slow computers.** The scrolling waveforms are painted once into a strip and slid along by the graphics card, instead of every pixel being repainted on every frame. The overview, jog wheels and level meters only repaint when something on them changes, so a paused deck costs almost nothing. Measured in headless Chrome with the CPU slowed 4x: 4 decks at 2560x1440 went from 10.6 to 4.1 ms of drawing per frame while playing, and from 10.3 to 1.6 ms when paused; 2 decks at 1440x900 from 4.4 to 1.9 ms playing and 3.9 to 0.9 ms paused.
- Waveform, overview and meter canvases are opaque, so the browser doesn't blend them over the page.

### Added
- **Settings → Waveform detail**: Auto, Sharp or Light. Light draws the waveforms at 1x (a quarter of the pixels on a 2x screen). Auto starts sharp and switches to Light for the session if drawing stays slow for 3 seconds.
- **Settings → Load lock**: Locked (the default, as before: a playing deck won't take a new track) or Unlocked (loading onto a playing deck stops it and loads the new track).
- **Settings → Phrases**: Show or Hide the phrase strips and labels on the waveforms, the overview and the deck's phrase readout.
- Problem reports include the graphics renderer (and whether the browser is drawing without the graphics card), the waveform detail and the drawing time per frame.

### Fixed
- **Phrases on rekordbox library tracks.** A rekordbox track that came without rekordbox's own phrase analysis (no phrases in its .EXT file) showed no phrases at all. Cratebox now works them out itself, on rekordbox's beat grid, when the track loads, and keeps them. rekordbox's own phrases are still used when it has them.
- A paused deck's waveform now redraws when its phrases change (they're worked out again in the background after a grid edit); since the faster drawing it kept showing the old ones until you pressed play.

## 1.1.0 (2026-10-16)

### Added
- **Beat FX**: ECHO, DELAY, PING PONG, REVERB, FLANGER, FILTER, TRANS, ROLL, HPF, LPF, timed to the beat grid. Effect select, BEAT ◀ ▶, channel (1, 2, 3, 4 or MASTER), level, ON. Strip at the bottom of the mixer; its own sheet on phones (FX in the header). Echo, delay and reverb ring out when switched off.
- **Pad FX**: a PAD FX pad mode with two banks of 8 momentary effects (hold a pad, let go to stop).
- **DDJ-FLX4**: the BEAT FX section (FX SELECT and SHIFT, BEAT ◀ ▶, CH SELECT lever incl. MASTER, LEVEL/DEPTH, ON/OFF and SHIFT = all off, with its light) and PAD FX1 / PAD FX2 pads with their lights. Messages from Mixxx's DDJ-FLX4 mapping. Beat FX controls can also be learned on other controllers.
- `tests/test_fx.py`: renders every effect offline and measures it, and drives the controls on screen and over MIDI.

### Changed
- Pad mode buttons show short labels (CUES, LOOP, JUMP, FX) unless the deck is wide.

## 1.0.2 (2026-10-16)

### Fixed
- **Headphone mix knob at 12 o'clock no longer brings the master in.** The left half of the CUE/MASTER knob, up to and including 12 o'clock, is now cue only (with a little room for the FLX4 knob's centre detent); the master fades in only past 12 o'clock, and fully right is master only. With MASTER CUE off and the knob at the centre, you hear only the cued channels.

## 1.0.1 (2026-10-16)

### Fixed
- **Headphone cue.** The CUE/MASTER mix started halfway, so about 70% of the master was always in the headphones, even with no CUE pressed, and the FLX4's MASTER CUE seemed to do little (the master was already there). The mix now starts fully on CUE: silence until you press a channel's CUE, and MASTER CUE (or turning the knob right) clearly brings the master in. Fully left is now exactly cue-only, fully right exactly master-only.

### Added
- **MST** (master cue) button under the CUE/MST knob, for setups without the FLX4's hardware MASTER CUE (Split, another device). Learnable on a controller.

## 1.0.0 (2026-10-16)

### Changed
- **Booth is the default look.** The original look is still in Settings as **Cratebox classic**. A look now only sticks once you pick it in Settings, so everyone who never chose one gets Booth (0.10.x saved "default" without being asked).
- **Settings** moved up to the header, next to Test cue; its panel drops down from there.
### Added
- **Jog sensitivity** (Settings, 25–200%): how far the track moves per turn of the jog, for the controller's platter (scratch, nudge, search) and the on-screen jog. Dragging the waveform stays 1:1 with your hand.

### Notes
- First 1.0 release.

## 0.10.2 (2026-10-16)

### Changed
- The bar counter is now drawn on each deck's scrolling waveform, right beside the red playhead line (like rekordbox and club players), in the deck's colour, instead of in the deck's info row.

## 0.10.1 (2026-10-15)

### Added
- **Bar counter** on every deck, like rekordbox: bar.beat (1.1, 1.2, 1.3, 1.4, 2.1 ...), next to the time. Counted from the beat grid's first downbeat (bars before it read 0.4, 0.3 ...); **BAR 1 HERE** in GRID moves the downbeat. Shown on compact decks and phones too, and bigger in the Booth look.

## 0.10.0 (2026-10-15)

### Added
- **4-deck mode** (computers and tablets): **4 DECKS** in the header adds decks 3 and 4, two more waveforms and a 4-channel mixer (3 1 2 4). Decks 3 and 4 start compact (CUE, PLAY, SYNC, loop, tempo) and expand to full decks with ⤢. Crossfader: 1 and 3 left, 2 and 4 right. Sync picks a master among four decks. Remembered between sessions.
- **Set recording**: ● REC records the master output to WAV (16-bit, lossless) or MP3 (320 kbps, encoded in the background with the bundled lamejs). A tracklist with timestamps is kept while recording and can be saved as text.
- **Looks**: a new **Booth** look in Settings, an original club-player style where each deck is its own player with a screen and waveform, and controls are drawn like hardware. The current look stays the default.
- **Interface size**: Auto scales the whole app up on big screens (1440p, 4K) so it fills them like a laptop screen; or choose 100–175%.
- **Report a problem** (Settings): sends a pre-filled GitHub issue with device details, which a workflow copies into `reports.txt`; or copies the report to the clipboard.
- **Audio buffer** setting: Small / Medium (new default) / Large.
- This changelog.

### Changed: audio first
- Sync and the beat lock now run on their own 20 ms timer instead of the screen refresh: they keep correcting with the tab hidden or the screen busy, and a drawing error can't stop them.
- A stopped deck no longer costs processing on the audio thread; decks 3 and 4 have no audio chain until 4-deck mode is turned on.
- The recorder reuses its buffers (no garbage on the audio thread).
- Library analysis takes a breather between tracks while music plays.
- Waveform drawing skips every other frame when frames get slow, before anything else gives.
- Default audio buffer is now Medium ("balanced") instead of the smallest, trading a few ms of latency for fewer dropouts.
- Leaving or reloading the page while music plays (or records) asks first.
- **2 DECKS** won't hide decks 3 and 4 while they play (it used to stop them).

### Fixed
- Short laptop screens (720–820 px tall): decks and mixer tightened so both waveforms and the library stay visible.

## 0.9.3 (2026-10-15)
### Fixed
- Phones and tablets: **Add music** did nothing in some in-app browsers (iOS MIDI browsers). The tap now lands on the real file picker instead of one opened from script.
### Added
- `filetest.html`: tries four ways of picking files, to see which an in-app browser allows.

## 0.9.2 (2026-10-15)
### Added
- iPhone/iPad: FLX4 support through MIDI browser apps (MIDIWeb Browser). Web MIDI added late by such apps is picked up when you press Start.
### Changed
- File pickers are invisible instead of `display: none`, which some in-app browsers won't open.
- Safari's start screen points to MIDIWeb Browser for controller use.

## 0.9.1 (2026-10-15)
### Fixed
- Phone faders start at 100%, and the handle sits at the bottom at 0%.
- Layout scales from an iPhone SE to a 1440p monitor (narrow phones drop the tiny jog, short laptops get a tighter deck and paired mixer knobs, tablets get finger-sized controls); iPad mini landscape no longer scrolls sideways.
- Service worker: if GitHub Pages answers with an error page (it briefly 404s while redeploying), the cached app is used.
### Changed
- Bigger mixer EQ knobs on phones.

## 0.9.0 (2026-10-14)
### Added
- Sync locks halftime / double time (70↔140, 65↔130, 85↔170) without changing either track's speed; SYNC ½ / SYNC ×2 on the button.
- Beat lock: continuous tiny speed corrections keep synced decks from drifting; ±ms phase readout.
- Playlists, rekordbox USB/SD export and rekordbox XML support; Android controller support; waveform seeking. (Earlier history: see the git log.)
