# Cratebox

Version 1.1.1. What changed in each version: [CHANGELOG.md](CHANGELOG.md).

A lightweight DJ app (2 or 4 decks) that runs in Chrome, built around the Pioneer DDJ-FLX4.

## Start it (Windows)

1. Plug in the FLX4.
2. Double-click **Start Cratebox.bat**. Chrome opens Cratebox. Keep the black window open while you play.
3. Click **Start**. When Chrome asks about MIDI devices, allow it (including "control and reprogram", which keeps the FLX4's lights awake).
4. Click **Add music folder** and pick the folder you DJ from. Nothing is copied or uploaded; tracks are read in place, and the folder is remembered next time.

Mac/Linux: run `python3 start_cratebox.py`.

It has to run through the launcher (a tiny local web server) rather than by double-clicking the HTML: Chrome only allows MIDI controllers, folder access and the audio engine on `http://localhost`. The launcher always uses port 8611, so your library, BPMs and cue points persist.

## Sound

Wire it like rekordbox: speakers on the FLX4's rear MASTER outputs, headphones in the front jack.

- **Output**: the DDJ-FLX4 is picked automatically once Chrome shows device names (choose "Show device names" if they're hidden). Your choice is remembered.
- The **ch pill** next to it shows how many output channels Chrome sees on that device. The FLX4 has 4: 1–2 are master, 3–4 are the headphone jack.
- **Headphones**:
  - **Auto** (default): uses the FLX4 jack whenever the output has 4 channels.
  - **FLX4 jack (channels 3–4)**: the rekordbox setup.
  - **Another device**: cue mix on a second sound output (for example your laptop's headphone jack), master stays on the FLX4.
  - **Split**: mono master left, mono cue right, for a single output and a splitter cable.
- **Test cue** beeps three times in the headphone mix only. If you also hear it from the speakers, cue isn't separated yet.
- The **CUE/MST** knob (and the FLX4's HEADPHONES MIX knob) blends cue and master in the headphones. It starts fully on **CUE**: the headphones are silent until you press a channel's **CUE**. From fully left up to 12 o'clock it's cue only, with no master at all; past 12 o'clock the master fades in, and fully right is master only. So the master is only in your headphones when you turn past the middle or press MASTER CUE.
- **MASTER CUE**: the FLX4's own MASTER CUE button puts the master in the headphones in the controller's hardware. On other setups (Split, another device), the **MST** button under the CUE/MST knob does the same in Cratebox (also learnable on a controller).
- HEADPHONES LEVEL and MASTER LEVEL on the FLX4 are analog and always work.

### Fixing headphone cueing (pill says "2 ch")

Chrome can only reach the headphone jack if Windows presents the FLX4 as a 4-channel device:

1. Windows Settings → System → Sound → **More sound settings** → **Playback** tab.
2. Select the **DDJ-FLX4** device → **Configure**. If **Quadraphonic** is listed, pick it → Next → Finish.
3. Close the Cratebox tab and start it again. The pill should now say **4 ch**, and Auto switches to the FLX4 jack. Press **Test cue**.

If Configure only offers Stereo, Windows is exposing the FLX4 as a 2-channel device. The FLX4 is class compliant, so it also works without Pioneer's driver: try with the driver uninstalled (Windows' built-in USB audio driver), or reinstalled, and check Configure again. If neither gives you 4 channels, use **Another device** and plug your headphones into the laptop.

## Controllers

Cratebox picks a mapping from the controller's name. **Settings → Controller** shows which one it chose, lets you pick another, and has **Learn** for fixing or adding controls.

| Hardware | Mapping |
|---|---|
| DDJ-FLX4 | Built in, checked on the hardware (table below) |
| DDJ-400, DDJ-200, DDJ-SB, SB2, SB3, DDJ-SX, SX2, SX3, XDJ-RX, CDJ-2000 / NXS / NXS2, CDJ-850, CDJ-350 | Built from Mixxx's community mapping for that exact model |
| Other rekordbox-series units: DDJ-FLX2, FLX6, FLX6-GT, FLX10, 800, 1000, GRV6, RB, RR, RX, RZ; XDJ-RX2, RX3, XZ, AZ, OPUS-QUAD | The shared rekordbox-series layout (the FLX4's, extended to four decks) |
| Other Serato-series units: DDJ-SR, SR2, SZ, SZ2, REV1, REV5, REV7, 1000SRT | The shared Serato-series layout (the DDJ-SX's) |
| CDJ-3000, other CDJ / XDJ players in MIDI mode | The CDJ-2000 layout |
| Anything else that speaks MIDI, including DJM mixers | Learn |

Only the FLX4 has been tested on real hardware. The others come from published community mappings or from the product line's shared layout: the main controls (play, cue, sync, jog, tempo, faders, EQ, pads, browse, load) should work, details may not. Four-deck controllers drive decks 1/2 from their deck 3/4 layers too; in 4-deck mode, the **deck layer** toggles (see 4 decks) put either side on deck 3 or 4. CDJs and XDJs need their MIDI (or "PC/DJ software") mode switched on and each player on its own MIDI channel (1 and 2).

**Learn:** Settings → Controller → **Learn…**, click a control on screen (it gets a yellow outline), then press, move or turn the real one. Faders and knobs pick up Pioneer-style 14-bit fine control automatically. For the jog, touch the platter then turn it. The library buttons (browse knob, load, jog side for nudging) are in the yellow bar. What you learn overrides the built-in mapping, is saved per mapping, and can be exported to a file and imported on another computer. **Clear learned** goes back to the built-in mapping.

Mappings for the Mixxx-derived models were generated by `tools/mixxx2cratebox.py` from the [Mixxx](https://mixxx.org) project's controller mappings (GPL-2.0), credit to their authors.

### DDJ-FLX4 controls

| Control | What it does |
|---|---|
| PLAY/PAUSE | Play / pause. SHIFT: play from the cue point |
| CUE | CDJ-style: playing → back to the cue point; stopped → set cue (snapped to the beat with Q on); on the cue → preview while held. SHIFT: back to the start |
| BEAT SYNC | Match tempo and beat phase to the other deck; stays locked while on. Long press: sync on. SHIFT: tempo range ±6/10/16%/WIDE |
| Jog top (touched) | Scratch / move the track by hand. Fling it backwards and let go for a backspin; **Backspin** in Settings sets how long it spins. Too touchy? **Jog sensitivity** in Settings (25–200%) |
| Jog side | Nudge (pitch bend) while playing, fine search while stopped |
| SHIFT + jog | Fast search |
| TEMPO fader | ±range; top is slower, like a CDJ |
| LOOP IN / OUT / RELOOP-EXIT | Manual loops. Hold IN for half a second for a 4-beat loop. SHIFT+IN halves, SHIFT+OUT doubles |
| CUE/LOOP CALL ◀ ▶ | In a loop: halve/double it. Otherwise: jump to the previous/next hot cue. SHIFT: jump a bar back/forward |
| Pads, HOT CUE mode | Set or recall hot cues A–H; SHIFT+pad deletes |
| Pads, BEAT LOOP mode (SHIFT + BEAT JUMP) | 1/4, 1/2, 1, 2, 4, 8, 16, 32-beat loops |
| Pads, BEAT JUMP mode | Jump −1/+1, −2/+2, −4/+4, −8/+8 beats |
| Pads, PAD FX1 / PAD FX2 mode (SHIFT + PAD FX1) | Hold a pad for an effect on that deck, let go to stop (banks below) |
| BEAT FX: FX SELECT (SHIFT: previous), BEAT ◀ ▶, CH SELECT, LEVEL/DEPTH, ON/OFF (SHIFT: all off) | The Beat FX unit; the ON/OFF light follows it |
| Channel faders, crossfader, TRIM, HI/MID/LOW (full kill), CFX filter | Mixer |
| Headphone CUE buttons | Send a channel to the headphones |
| BROWSE knob / LOAD 1 / LOAD 2 | Scroll the library and load the selected track |
| SHIFT + BROWSE | Waveform zoom |
| SHIFT + press BROWSE | Expand the library over the jogs and mixer (or click **Expand library**) |

LEDs follow the software: PLAY and CUE blink like a CDJ, pads light for set hot cues and the active loop size, loop/sync/cue buttons light when on, and the channel level meters show each deck's level.

Not mapped yet: the sampler, key shift and the keyboard pad mode. SMART CFX and SMART FADER can be set up as deck layer buttons (see 4 decks).

## 4 decks

**4 DECKS** in the header (computers and tablets) adds decks 3 and 4 under decks 1 and 2, a fourth and fifth waveform, and a 4-channel mixer in the order **3 1 2 4**. The crossfader sends 1 and 3 left, 2 and 4 right. **2 DECKS** goes back (once decks 3 and 4 are stopped: a playing deck is never cut off). Your choice is remembered.

- Decks 3 and 4 start **compact**: title, waveform, CUE, PLAY, SYNC, a 4-beat loop and ± tempo. **⤢** opens the full deck.
- Load them by dragging a track onto them, or with Ctrl+Shift+← / → (Shift+← / → loads decks 1 and 2).
- With four decks, SYNC follows the deck that isn't synced itself and is playing (the one playing longest, if there are several).
- **Deck layers** (playing decks 3 and 4 from a 2-channel controller like the FLX4): above the mixer's channel strips there's one number per deck, in the mixer's order **3 1 | 2 4**. Click a deck's number to put that side of the controller on it (left side: 1 or 3, right side: 2 or 4). The decks the controller plays are lit, with a slow pulse, and their players get an outline in their colour. Everything on that side follows: PLAY, CUE, SYNC, the jog, pads, loops, LOAD, the tempo fader, and that channel's fader, EQ, TRIM, CFX and CUE, plus the lights and the VU meter. The BEAT FX CH SELECT lever follows the side it points at.
- **On the FLX4's SMART CFX and SMART FADER:** Settings → Controller → **Deck layers on SMART CFX / FADER…**, then press SMART CFX and SMART FADER when asked. From then on SMART CFX switches the left side 1 ⇄ 3 and SMART FADER the right side 2 ⇄ 4. Their lights stay off on purpose: on the FLX4 those two lights switch the controller's own Smart CFX / Smart Fader on, which moves the EQ and BEAT FX by itself; the pulsing deck numbers over the mixer show which decks it plays. (Any two spare buttons work the same way on other controllers.)
- **No jumps when you switch:** after switching, a fader or knob only takes over once you move it to (or past) the new deck's setting, so deck 3's tempo or volume never jumps to where deck 1's was (soft takeover). Until then, moving it does nothing.
- The toggles can be learned onto spare buttons (Settings → Controller → **Learn…**, click a toggle, press the button). Going back to **2 DECKS** puts the controller on decks 1 and 2 again.

## Recording

**● REC** in the header records the master output (exactly what the speakers get, after the limiter) until you press it again; the button shows the running time. The file is saved to your downloads as `Cratebox set <date> <time>.wav` (or `.mp3`).

- **Format** (Settings → Recording format): WAV, lossless 16-bit (about 600 MB per hour), or MP3 at 320 kbps (about 140 MB per hour). The MP3 encoder (lamejs, LGPL, in `vendor/`) runs in the background and works offline.
- A **tracklist** is kept while recording: every track that was playing and could be heard (fader up, crossfader open), with the time it came in. **Save tracklist** saves it as a text file.
- Leaving or reloading the page while recording (or while anything plays) asks first.

## Looks and screen size

- **Look** (Settings): **Booth** (the default), a club-player style: each deck becomes its own player with a black screen holding its scrolling waveform, and the controls are drawn like hardware (rubber pads, LED rings, fader caps). Phones take Booth's colours and keep their own layout. **Cratebox classic** is the original look, with shared waveforms across the top.
- **Interface size** (Settings, computers): **Auto** scales the whole app up on big screens, so a 1440p or 4K monitor is filled the way a laptop is (Auto treats the window as about 1600 x 900). Or pick 100–175% yourself.

## Audio first

Playback runs on the browser's real-time audio thread and nothing else in the app can interrupt it:

- Sync and the beat lock run on their own timer, not the screen refresh: they keep working with the tab in the background or the screen busy, and a drawing error can't stop them.
- A stopped deck costs (almost) nothing; decks 3 and 4 use no audio processing until 4-deck mode is turned on.
- The recorder reuses its buffers, so it makes no garbage on the audio thread.
- Library analysis runs two tracks at a time while nothing plays. On a computer with 2 cores (4 hardware threads or fewer) and on phones it stops completely while music plays, so it never takes CPU time from the audio: a job under way is ended the moment you press PLAY, its track goes back in the queue, and the library carries on when everything stops. Tracks you load are still analysed straight away. On bigger computers, one track at a time keeps going while you play, with a breather in between.
- Loading a track never holds up the other decks: the replaced track's audio is handed back to the page to be thrown away there, not on the audio thread.
- If the browser stops the audio (another app such as rekordbox takes the controller's sound, the controller is unplugged, the laptop sleeps), Cratebox starts it again by itself and shows a small banner until it's back; it never covers the decks.
- **Audio buffer** (Settings): Medium is the default. Small gives the tightest jog feel on a strong computer; Large is the safest from dropouts. It takes effect after a reload.

## Report a problem

Settings → **Report a problem…**: describe what happened; device details (browser, screen, controller, version, recent errors; no personal info or track names) are added if you leave the box ticked. **Send on GitHub** opens a pre-filled issue (needs a GitHub account); each one is copied into [`reports.txt`](reports.txt) in this repository automatically. **Copy report** puts it on the clipboard to send any other way.

## Sync

**SYNC** (or BEAT SYNC on the FLX4) matches tempo and lines up the beats, then keeps them locked.

- **Halftime / double time:** if one track is half or double the other (70 and 140, 65 and 130, 85 and 170), sync leaves its speed alone and locks every beat of the slower one to every other beat of the faster one. The button shows **SYNC ½** or **SYNC ×2**. The master's tempo changes carry it along at half or double.
- **Beat lock:** while both decks play, Cratebox keeps comparing their beat grids and corrects with a tiny speed change (at most 0.6%), so the mix never drifts. The **±ms** readout next to the key shows how far apart the beats are: green is locked. An offset of more than a quarter beat is left alone on purpose; SYNC off and on re-locks it.
- If the readout says locked but you still hear the beats slide, that track's beat grid is off. Fix it with **GRID**.

## Waveforms

- **RGB** (default): colour shows what's playing, rekordbox-style. Red is lows (kicks, sub), green is mids, blue is highs (hats, cymbals); mixes blend (a kick with a click goes orange-white). The lighter core is the average level, the outer edge the peaks. Detail is 300 points per second, drawn pixel by pixel.
- **3-band** (Settings): the older blue/orange/white style.
- Scroll the mouse wheel over a waveform to zoom (or SHIFT + BROWSE on the FLX4).
- The waveforms follow tempo: speed a track up and its waveform squeezes together, so two synced decks show their beats at the same spacing.

## Beat FX and Pad FX

**Beat FX** (the strip at the bottom of the mixer; **FX** in the header on phones; the FLX4's BEAT FX section):

- **Effect**: ECHO, DELAY, PING PONG, REVERB, FLANGER, FILTER (a sweep), TRANS (a gate), ROLL, HPF, LPF. Click to go to the next, Shift-click or right-click for the previous (FX SELECT / SHIFT + FX SELECT on the FLX4).
- **◀ ▶ beats**: the effect's timing, locked to the beat grid of the deck it's on (on MASTER: the deck the mix follows). ECHO 1/2 at 140 BPM repeats every 0.214 s, TRANS gates on the beat, ROLL repeats the slice of the grid you're in. Each effect remembers its own setting. REVERB, HPF and LPF have none.
- **Channel**: 1, 2 (and 3, 4 in 4-deck mode) or **M**aster. On the FLX4, the CH SELECT lever: 1, 2 or MASTER.
- **Level**: how much effect (for HPF/LPF and FILTER, how far the filter goes; for TRANS, how hard it cuts). The FLX4's LEVEL/DEPTH knob.
- **FX ON**: echoes, delays and reverb ring out naturally when you switch off, like on a club mixer; the others stop at once.

On a channel the effect sits after the EQ and filter and before the fader and CUE, so you hear it in the headphones when you cue that channel.

**Pad FX** (**PAD FX** pad mode on each deck; PAD FX1 / PAD FX2 on the FLX4): hold a pad and that effect runs on that deck until you let go.

| Pad | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| **PAD FX1** | Echo 1/2 | Echo 1 | Reverb | Roll 1/4 | Roll 1/2 | Trans 1/4 | HPF | LPF |
| **PAD FX2** (press PAD FX again on screen) | Ping pong 1/2 | Delay 3/4 | Flanger 16 | Roll 1/8 | Roll 1 | Trans 1/8 | Filter 4 | Echo 1/4 |

All effects run on the audio thread with the decks; with nothing on, each insert is a plain copy and costs nothing. Reverb and echo on every insert at once still run about 17x faster than real time in testing.

## Bar counter

Each deck's waveform shows where you are as **bar.beat** beside the red playhead line, like rekordbox: 1.1, 1.2, 1.3, 1.4, 2.1 and so on, counted on the beat grid from the track's first downbeat. If the count is a beat off, the grid's downbeat is: pause on the "1" and press **BAR 1 HERE** in GRID.

## Phrases

Each track is split into phrases on bar lines and named: **Intro**, **Build**, **Drop**, **Groove** (drums in, not the peak), **Breakdown**, **Outro**. They show as a coloured strip under the track overview and along the top of the scrolling waveform, and the deck shows where you are, e.g. `DROP 13/16` = bar 13 of a 16-bar drop. Handy for landing your next drop on the 1 of the other track's.

It works from loudness, the low end, the highs and whether a kick is in, so it's reliable for the big changes (drums in or out, drops) and rougher on subtle ones (Groove vs Drop). Phrases follow the beat grid: fix the grid and they're redone automatically.

## Master tempo

The **MT** button on each deck (on by default, remembered) is keylock: moving the tempo fader or syncing changes the speed but keeps the key, like MASTER TEMPO on a CDJ. Turn it off for vinyl behaviour, where faster also means higher.

It works by rebuilding the sound from short overlapping slices (WSOLA, the same family of technique as SoundTouch). Within ±8% it's clean; past ±16% you'll hear some smearing on vocals and long pads. Scratching always plays the raw record, then keylock picks up again when you let go.

## Keys

Every track gets a key in Camelot notation (8A = A minor, 8B = C major). Tracks mix smoothly with the same code, one number either side with the same letter, or the same number with the other letter. While a deck is playing, the library highlights the keys that fit it, and typing a code like `8a` into search filters by key. With MT off, pitching a track changes its key, and the deck shows both (`9A (8A)`).

Key detection is built for electronic music (natural minor). The usual mistake is swapping a key with its relative major or minor (7A vs 7B), which still mixes fine.

## Beat grid

Analysis looks at the whole track: it finds the tempo to a fraction of a BPM (no more rounding 127.95 to 128 and drifting), puts the beat lines on the kicks and snares rather than the off-beat hats or bass, and guesses which beat is bar 1. Tracks analysed by the old version get redone automatically in the background.

To fix a grid, click **GRID** on the deck:
- Type a BPM and press Enter, or use **−.01 / +.01** (Shift: 0.1), **÷2 / ×2**, or **TAP** along with the beat. The beat under the playhead stays put.
- **◀ / ▶** slide the whole grid 5 ms (Shift: 1 ms).
- Pause on a kick, then **BEAT HERE** snaps the nearest beat line to it, or **BAR 1 HERE** makes it the first beat of a bar.
- **RESET** goes back to the analysis.

Edits are saved with the track, re-analysis never overwrites them, and the library shows hand-edited BPMs in yellow.

## Library and analysis

- New tracks are analyzed in the background: BPM, beat grid, key and a 3-band waveform (blue = lows, orange = mids, white = highs). Results are cached.
- **BPM range** (default 88–175) decides whether half/double-time tracks read as, say, 140 or 70. Change it and every track is re-folded instantly.
- Titles and artists come from MP3 ID3 tags, otherwise from "Artist - Title" file names.
- Drag a row onto a deck, double-click it, press LOAD, or use Shift+← / Shift+→. Drop any audio file from Explorer straight onto a deck too.
- Hot cues and cue points are saved per track.
- Ctrl-click and Shift-click select several rows; Ctrl+A selects the whole list. Click the **#** header to go back to the list's own order.

## Playlists

The column on the left of the library is the tree: **Collection**, your **Playlists**, and any rekordbox **Devices**.

- **+** makes a playlist, **▤** a folder. Type a name and press Enter. Double-click to rename; hover and click **×** to delete (it asks first).
- Add tracks by dragging rows onto a playlist in the tree, or select them and use **Add to ▾**. Drag a playlist onto a folder to file it there, or onto the PLAYLISTS heading to take it back out.
- Inside a playlist, drag rows up and down to rearrange them, and press **Delete** (or **Remove from list**) to take them out. That only removes them from the playlist, never from your folder.
- Each list remembers how you sorted it (click a column heading; **#** goes back to the playlist's own order), also after a restart.
- Playlists are kept in the browser. A track whose folder isn't connected shows greyed out, and comes back by itself once you reconnect the folder (matched by file name and size).
- **FLX4:** press the BROWSE knob to jump to the tree, turn it to walk the playlists (the list follows as you go), press again to go back to the tracks. LOAD still loads.
- **Phone:** tap **☰** in the library for the tree, **⋯** on a playlist to rename or delete it, and **Add to ▾** to add the selected track.

## rekordbox

**USB sticks and SD cards** (desktop Chrome/Edge): click **+ USB** under DEVICES and pick the drive itself (the folder that holds `PIONEER`). Cratebox reads the rekordbox export on it: every track, the playlist tree, and for each track you load, rekordbox's own beat grid, phrases, hot cues A–H and first memory cue. These replace Cratebox's own analysis for that track, until you edit the grid or set cues yourself. Your edits stay on this computer.

- **Edit its playlists (off by default).** Turn it on in **Settings → rekordbox USB playlists → Editable**; it warns first that this is untested and may damage the stick, and you can turn it off again there. Then a stick's playlists work like your own: drag its tracks onto them, drag rows to reorder, **Delete** to take a track out, double-click to rename, **×** to delete, and **+** / **▤** on the stick for a new playlist or folder. Only tracks already on that stick can go in its playlists. Each change is written back into the stick's `export.pdb` a moment later (the browser asks once for permission to write to it), so CDJs and rekordbox see it.
- **What's written, and the safety net.** Only the two playlist tables inside `export.pdb` change; tracks, analysis files, history and everything else stay exactly as rekordbox wrote them. Before the first save each session, the database as it was is kept next to it as `PIONEER/rekordbox/export.pdb.cratebox-backup` (to undo everything, rename it back to `export.pdb`). Every save is read back and checked; if anything doesn't come out right, nothing is written. If rekordbox exported to the stick after Cratebox opened it, Cratebox refuses to save over that: close the stick and open it again.
- **Things to know.** Syncing a playlist from rekordbox to the stick again replaces your changes to it. Newer players that read rekordbox's *OneLibrary* database (`exportLibrary.db`) instead of `export.pdb` won't see the changes; Cratebox says so when a stick has one. Written to match how rekordbox lays the database out, and checked against an independent reader (rekordcrate), but not yet on a CDJ: keep the backup until you've seen the playlists on your players.
- **⧉** on a device playlist copies it into your own playlists. Those tracks still play from the stick, so they show greyed out when it's not plugged in.
- **×** on the device closes it. The browser remembers the drive, and it opens again by itself when it's plugged in and Chrome still has permission.

**rekordbox XML** (the **⋯** next to PLAYLISTS):

- **Import:** in rekordbox, *File → Export Collection in xml format*, then pick that file. Your playlists arrive in a folder called "rekordbox (date)". For tracks Cratebox can find in your music folder (matched by file name and size), it takes rekordbox's beat grid, key, hot cues and memory cue. Tracks it can't find appear greyed out in their playlists.
- **Export:** writes `cratebox-rekordbox.xml` with every track, its grid, key and cues, and all your playlists. rekordbox needs full file paths, so the first time it asks where your music folder is on this computer (for example `C:\Users\jonah\Music`). Change it later under *Music folder path for export*. In rekordbox: *Preferences → Advanced*, set **Imported Library** (under rekordbox xml) to the file, tick **rekordbox xml** under *Preferences → View → Layout*, and the playlists show in the rekordbox xml tree (hit its reload button after re-exporting).

## iPhone and iPad

Cratebox runs on iOS by touch. Safari has no Web MIDI (and every iOS browser is Safari underneath), so **for the FLX4 on an iPhone or iPad, open Cratebox in the free [MIDIWeb Browser](https://apps.apple.com/us/app/midiweb-browser/id6757226617) app** instead, with the FLX4 plugged in through a USB-C cable (or Apple's Lightning to USB 3 Camera Adapter on older phones). Cratebox picks up the Web MIDI that app adds, even if it arrives a moment after the page loads.

- The older *Web MIDI Browser* app hasn't been updated since 2016 and can't pick files, so you can't add music in it; use MIDIWeb Browser.
- If **Add music** does nothing in a MIDI browser app, open `filetest.html` (next to `cratebox.html`) in that app: it tries four ways of picking files and shows which ones the app allows.
- Each app keeps its own storage: tracks added in Safari aren't visible in MIDIWeb Browser. Add your music inside the app you DJ from.
- The FLX4 takes its power from the phone over USB. If it doesn't show up, try a powered USB-C hub.

What works: both decks, mixer, sync, loops, hot cues (hold a pad to delete one), master tempo, keys, phrases, grid editing. Sound goes to whatever the phone or iPad is plugged into; for headphone cueing use **Split** (master in one ear, cue in the other) with a splitter cable.

**On an iPhone, turn it sideways.** The phone layout is landscape: both waveforms on top, then deck 1, the mixer and deck 2 on one screen with no scrolling (sized for an iPhone 16 Pro Max, and it scales down to smaller iPhones and to Safari with its toolbar showing).
- **MIX / LIBRARY** tabs at the top. In the library, tap **1** or **2** on a row to load it.
- **⋯** on a deck: loops, beat jump, tempo range and the grid editor.
- **⚙**: headphones (Split), test cue, master level, BPM range, waveform style, jog sensitivity, backspin.
- The screen stays on while a track plays. If a call or Siri cuts the audio, a **Tap to resume audio** button appears.

An iPad gets the full desktop layout, by touch.

**Getting it onto the phone.** iOS only allows the audio engine on a secure (https) site, so Cratebox needs hosting once. The free, stable way is GitHub Pages:

1. Make a free GitHub account, then a new **public** repository called `cratebox`.
2. **Add file → Upload files**: `cratebox.html`, `index.html`, `sw.js`, `manifest.webmanifest`, `icon-180.png`, `icon-512.png`. Commit.
3. **Settings → Pages**: Source **Deploy from a branch**, branch **main**, folder **/ (root)**, Save. After a minute it's live at `https://YOUR-NAME.github.io/cratebox/`.
4. Open that in Safari on the iPhone/iPad → **Share → Add to Home Screen**. Launch it from the icon: full screen, and it works offline after the first visit.

Only the app goes on GitHub, never your music.

**Your music on iOS.** Tap **Add music** and pick tracks in the Files app (iCloud Drive, On My iPhone, a USB drive...). They're copied into Cratebox's own storage on the device, so the library is still there next time; **Remove** deletes the selected one. Keep it on the Home Screen: Safari may clear storage for sites you haven't opened in a while, but not for Home Screen apps. Long tracks use a lot of memory; older phones may struggle with two 8-minute tracks loaded.

## Android

Chrome for Android has Web MIDI, so **the FLX4 (and the other controllers) work on an Android phone or tablet**, unlike on iPhone.

- Host it on https first (the GitHub Pages steps above; open the link in Chrome on Android, then ⋮ → **Add to Home screen**). Chrome asks once for permission to use MIDI devices: allow it.
- **Cabling:** the FLX4 can't run off the phone's power. Plug a USB power adapter or power bank into the FLX4's **power** USB port, and the phone into its **device** USB port (a USB-C to USB-C cable). That's Pioneer's own setup for rekordbox on Android.
- On a phone you get the same landscape layout as on iPhone. The controller is picked up by name. **⚙** has the controller and mapping pickers and Learn.
- **Music:** Android Chrome can't open a folder, so **Add music** copies the tracks you pick into Cratebox's storage, like on iPhone.
- **Sound:** Android usually sends all audio to a USB audio device once it's plugged in, so the master comes out of the FLX4. Headphone cueing on the FLX4's own headphone socket is untested; **Split** (master one ear, cue the other) always works.

## Limits

- No key shift.
- rekordbox: USB/SD exports in the classic `export.pdb` format, which every rekordbox 5/6/7 USB export still includes. Device Library Plus (`exportLibrary.db`) alone isn't read. Playlists on a stick can be edited (written into `export.pdb` only), and Cratebox doesn't read rekordbox 6/7's own encrypted `master.db` on your PC: use the XML export for that.
- rekordbox beat grids with tempo changes come in as one tempo (the most common one).
- Audio files must be something Chrome can decode: MP3, WAV, FLAC, AAC/M4A, OGG/Opus. Not AIFF.
- Beat grids assume a steady tempo. Live-drummed tracks will drift.

## Tests

`python tests/make_tracks.py tests/music` builds four synthetic tracks with known tempos, keys and sections, then `python tests/test_cratebox.py` drives Cratebox in headless Chrome with real FLX4 MIDI messages, `python tests/test_controllers.py` drives every built-in controller mapping and MIDI learn, `python tests/test_ios.py` checks the touch/iPhone mode (no MIDI, imported files, phone screen sizes), `python tests/test_ios_midi.py` runs an iPhone inside a MIDI browser app (Web MIDI added late, stand-in FLX4), `python tests/test_android.py` runs an emulated Android phone with a stand-in FLX4 on Web MIDI, and `python tests/test_sync.py` checks halftime/double-time sync and the beat lock, `python tests/test_layout.py [folder]` audits the layout on 19 screen sizes from an iPhone SE to a 1440p monitor (nothing off screen, overlapping, cut off or too small to tap; screenshots into the folder if given; `CB_THEME=booth` and `CB_FOUR=1` audit the Booth look and 4-deck mode), `python tests/test_fourdeck.py` covers 4-deck mode and the big-screen zoom, `python tests/test_record.py` records WAV and MP3 sets and checks the files and tracklist, `python tests/test_audio_first.py` checks that playback and sync never depend on the screen, `python tests/test_report.py` covers Report a problem, `python tests/test_barcounter.py` checks the bar counter, `python tests/test_theme.py` checks the default look, `python tests/test_jog.py` checks jog sensitivity, `python tests/test_headphones.py` measures the headphone mix (cue, master cue, mix knob), `python tests/test_fx.py` renders every effect offline on test signals and measures it (echo timing and decay, tails, ping pong sides, reverb, trans gating, roll repeats, filters, CPU) and drives the Beat FX and Pad FX controls on screen and from the FLX4, and `python tests/test_playlists.py` covers playlists, rekordbox XML import/export and a rekordbox USB export. `node tests/test_rekordbox.js` checks the rekordbox file readers against a real USB export (`tests/fixtures/rekordbox_usb`, from pyrekordbox's test data, MIT licence) and against hand-built cue lists. The Python tests need `pip install playwright` and `playwright install chromium`.
