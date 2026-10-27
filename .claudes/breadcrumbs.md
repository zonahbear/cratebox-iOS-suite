## 2026-10-22: layout fit across iPhone and iPad (branch claude/project-thread-p80d0m, from preview/truecurve-usb)

- Why buttons fell off: the phone layout's fixed sizes only fit 16 Pro Max / Plus / Air (CI screenshotted only the
  16 Pro Max). The middle column is `.clipped()`, so overflow got cut off. SE was 181 pt too wide, the 16 22 pt.
- Fix: `PhoneMetrics` (PhoneLayout.swift) is computed from the room between the edge strips and passed in the
  environment. It sizes PhoneDeck (jog, CUE/PLAY, loops, pads), MixerView.phoneBody and the top bar. Under 640 pt (SE)
  it switches to compact sizes. Under 680 pt the master section goes into a MASTER popover (MasterButton).
  Edge strips are 40 pt minimum (they were 46). Deck Bridge got the same strips and a narrow top bar, with jog min 72.
- iPad: landscape only (project.yml). Under 800 pt tall (mini), BEAT FX folds into a button and the library min drops to 130.
- HeatButton() calls removed from both top bars. The HEAT thread removes the rest (TrueCurve files, BT strings, -heat shot).
- ios.yml has a `devices` input (manual run) for SE / 16 / iPad mini screenshots.
- Not done: picking the layout by window size instead of device (risky with safe areas, untestable here).
- Next: check the screenshots from the manual run and tune the sizes. No local Swift toolchain, so CI is the compiler.
- 2026-10-22 23:51: CI run 39871146676 was green. SE, 16, 16 Pro Max and iPad mini (2 decks) all fit. iPad mini in 4-deck
  mode overflowed (two columns of decks), so on a short iPad 4-deck mode now uses the iPhone pattern: the two decks the
  controller is on, plus the 2-channel phone mixer. SE MIX/LIBRARY picker widened to 132 (LIBRARY was truncating).

## 2026-10-23: compact phone layout (commit 88aec82, same branch)

- Real SE testers run Display Zoom: 568 × 320 pt. The 540 pt deck row pushed the strips off (middle wasn't fixed-width).
- `Views/CompactPhone.swift`: CompactScreen (no strips; deck faces PLAY | PADS at 44 pt; deck ⋯ = range/TAP/GRID/MT/Q;
  top ⋯ = WAVE/4 DECKS/BEAT FX/REC/Settings; slim mixer + EQ sheet). PhoneScreen picks it via `autoCompact` (no island,
  middle < 640, height < 360) or `@AppStorage("cb.compact")` (Settings → Look → Compact layout).
- PhoneScreen and BridgeScreen middles now `.frame(width: total - 2*band)` so overflow clips instead of shoving strips.
- CI-only launch args: `-screen 568x320` (ScreenFrame modifier in CrateboxApp), `-metrics YES` (Documents/metrics.txt),
  `-pads` (right deck on PADS face), `-cb.compact YES`. ios.yml input `measure` = measure all sims + save ios-resolution.com.
- Next: review run 39882922135 shots/metrics (ci-logs-preview), fix, show Jonah. No TestFlight without his OK.

## 2026-10-23 03:15: device sizes measured; docs/device-sizes.md is the law

- [`docs/device-sizes.md`](../docs/device-sizes.md): measured sizes, scales and safe areas for 15 simulators (ios.yml run
  39886977167), all matching ios-resolution.com, plus that site's full table (144 rows, including Display Zoom sizes).
  Jonah's rule: it's the only source for sizes, shipping and personal/heat builds. Also in CLAUDE.md and team memory.
- Compact layout screenshots (run 39882922135): SE at 568 × 320 fits in 2-deck, 4-deck and PADS. iPhone 16 with the switch is fine.
- The measurement step ran out of its 60 min limit after 15 of 21 sims (the rest were mostly iPads). Raise it or split runs next time.
- personal/heat port: local branch `heat-compact` (8c6935d) = layout commits + HEAT button in the compact top bar,
  ios.yml on the .heat bundle id. Not pushed: pushing personal/heat uploads to TestFlight, which needs Jonah's OK. Watch-mic PR #7
  also targets personal/heat; whichever lands second merges the other (overlaps in ContentView Settings + project.yml).
- Not verified: island phones with Display Zoom on (e.g. 16 Pro Max zoomed to 812 × 375 portrait-equivalent); not screenshotted.

## 2026-10-23 06:20: Performance Mode EJECT (branch claude/project-thread-3e42ho, from preview/truecurve-usb)

- iOS has no unmount for apps (DADiskUnmount is macOS / Catalyst only) and no plug-in notice. iPhone Files has no
  USB eject either (Apple's guide: just unplug; not re-verified, support.apple.com unreachable from CI box).
- `App/DriveWatch.swift`: every 2 s checks known drive folders (device sticks, music folders on another volume,
  Cratebox USB's open stick) with checkResourceIsReachable; unplugged → released; ejected → waits for a replug.
  EJECT: refuses while any deck (or the USB preview) plays, waits for loads/analysis/saves, `DeckModel.unload()`
  (new, CrateboxKit), Devices.eject (flush, now keeps the bookmark), ends security-scoped access, alert.
- `Views/EjectButton.swift`: EJECT / + USB in PhoneTopBar, CompactTopBar, iPad topBar; 44 × 44 touch, 30 pt drawn.
- Library: offline state, release/reconnect, scan of an unplugged folder no longer wipes its tracks, a leaked
  security-scope start fixed in addFolder.
- CI: `-demo -eject [-stopped]` shots (stand-in "DJ USB"). Not tested on a real stick yet.
- Next: check CI run, screenshots to Jonah, port to personal/heat (his OK before pushing it: it uploads to TestFlight).

## 2026-10-23 19:40: SYNC retimed a playing deck when the other deck loaded (branch claude/project-thread-wtndnj)

- Jonah's repros: 140 playing with SYNC, load a 75 on the other deck → 75; 72.5 playing synced, load a 72.5 → 36.25.
- Cause (Core.swift DeckModel, same in cratebox.html Deck): master() preferred an unsynced deck over a playing one, so
  the playing synced deck followed the freshly loaded, stopped deck; syncTick re-picked half/double time only when
  the master *object* changed, so a new track on the same deck kept the old multiplier (½ from a 145 → 36.25).
- Fix: a playing synced deck only follows the playing deck it already follows (syncWith + syncTrack). When that
  master stops or loads, it holds its tempo and leads (syncSince set oldest). rate() uses syncRate whenever synced,
  setSync with no master starts from the fader's rate, the fader moves a leader relatively, beginLoad resets sync state.
- Tests: CoreTests testLoadingTheOtherDeckNeverRetimesAPlayingSyncedDeck / testSyncedDeckWithNoMasterHoldsWhenATrackLoads
  (not run: no Swift here; ios.yml is the compiler). Web: Cratebox tests/test_sync.py 14/14 with the new checks.
- Not changed: SYNC off still jumps to the tempo fader's position (old behaviour).
- personal/heat still needs the same commit (Core.swift applies cleanly there; push to it uploads TestFlight).

## 2026-10-27 22:40: code review of the shipping app + personal/heat (PR #27, branch claude/project-thread-p0805m)

- Report: project files `ios-review/index.html` (published as an artifact). Findings F1-F9 fixed, P1-P9 proposed.
- Key fix: `DeckModel.playhead()` = now() + core.lag() x speed. `now()` is the HEARD position (AppModel.smoothClock
  subtracts audio.latency); relative jumps and phase matching must use playhead() or they land short on Bluetooth.
- Engine `.unload` now trashes the track (was freed on the audio thread). Library background analysis passes Settings.bpmRange.
- Merging PR #27 = TestFlight upload (testflight.yml on preview/truecurve-usb). Waiting on Jonah's go.
- personal/heat port: 3 patches in project files `ios-review/personal-heat-port/` (PR #26 BPM range, the review fixes,
  HEAT wording). Not pushed: pushing personal/heat uploads Cratebox HEAT to TestFlight.
- Open proposals needing Jonah: relative-drag tempo/cross faders (P1), streaming decode (P2), 44 pt targets (P3).

## 2026-10-27 23:55: ChatGPT + Gemini cross-review of PR #27 (commit a864304)

- Table of every claim (confirmed / rejected, with file:line) is in the report, section "Cross-review results".
- Engine track hand-off: `retired` (audio thread only) → swap into `trash` under the try-lock → snapshot swaps it
  out and frees after unlocking. Never append to `trash` from apply() (that raced snapshot()).
- USB backups are named by the flattened full path + ms stamp + random tail (every ANLZ file is ANLZ0000.DAT).
- Recorder tap is lock-free on the audio thread (try-lock publish, drop-and-count when full); stop reports errors.
- Load task must not write TrackInfo: Devices.readAnalysis(at:) → RBRead value, Devices.apply on main.
- Staged USB playlist edits persist in Application Support/Cratebox/usb/<stick>.playlists.json with the db hashes.
- Rejected: Gemini's auto-loop/hot-cue lag concern (loops wrap by modulo; hot cues are absolute), contentShape-only
  44 pt targets (can't exceed the frame), "SYNC still locks" wording (shared lag cancels).
- New proposals P10-P13 (group write journal, re-analyse on BPM range change, SYNC phase-offset indicator, async REC stop).
- HEAT port: 5 patches now (0004 = this commit, 0005 = HEAT recorder note). Still not pushed.
