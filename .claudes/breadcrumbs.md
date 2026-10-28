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
  middle < 640, height < 360) or `@AppStorage("cb.compact")` (Settings → Look → Touch mode, was "Compact layout").
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

## 2026-10-28 01:20: second cross-review round (R1-R4), proposals, EQ tap (PR #27)

- R1: DeckModel's optimistic pos/posT are stamped with the AUDIO clock (`audioNow = core.clock() + core.lag()`),
  like the engine's reports; speed changes go through `rebase(speed:)`. Test: two jumps before a report, 250 ms lag.
- R2: USB backups carry `.nNNNNNNNN.` sequence numbers (order); pruning keeps backups a journal points at.
- R3: RecordRing (CrateboxKit) + Engine.tapChanges: Recorder.stop waits off-main until the tap is gone, then finish().
- R4: RequestTokens: USBSession reload/scan results are dropped after eject/reopen/newer request; per-scan Cancel.
- USBSafeWrite.group: multi-file writes (playlists to both libraries, USBTrackWrite.apply) have a group journal;
  recover() puts every finished member back. swapFailed keeps the journal for the next open.
- EQ: tap LOW/MID/HI = centre → kill, else → centre (MixerCurves.eqTap), in CompactPhone always, else only with
  no controller. Faders use `.faderDrag` (relative). SYNC phaseHeld → "TEMPO ±ms".
- ios.yml now fails the run if the tests or the app build fail (last step). Still read the log.
- Open: P2 (streaming/mono decode: changes analysis input, parity risk), P9 (measure new devices).
- HEAT (personal/heat only): Engine.recordAfterMix + recordMixed → REC includes the watch mic; slot-4 backup kept in
  UserDefaults `cb.tc.restore.<id>` and restored on the next connect after the device's own cycle.

## 2026-10-28: Touch mode (was Compact layout)

- Sketch agreed with Jonah: https://claude.ai/artifact/Hzv1TWAEQPeZSiX1XSPFtb (568 × 320 and 667 × 375 from docs/device-sizes.md).
- CompactPhone.swift: the mixer has a HI / MID / LOW knob column per channel beside its fader, sized by `CompactMetrics.knob(face:)`:
  47 pt at 320 tall, 57 pt at 375, at most 60. A tap uses MixerCurves.eqTap, so a centred knob cuts and a turned
  or cut one goes back to the centre; a cut knob shows a red ring and CUT. The crossfader runs across the bottom.
  No headphone CUE (Jonah: Touch mode is for playing without a controller). TRIM/CFX: top bar ⋯ → Trim & filter….
  PLAY face: the platter sits over a CUE / PLAY / SYNC row and the tempo fader (22 pt) is on the outside.
- Setting label: Settings → Look → Touch mode (key still `cb.compact`). Same change on personal/heat.
- Unverified: no simulator screenshots of the new layout yet (ios.yml's app build still fails on the WatchMic icon);
  TestFlight is the first compile.

## 2026-10-28: touch EQ reverted, SCRATCH added

- Jonah: "revert last fixes. looks like shit". The TouchBandEQ phone mixer is reverted on both branches. Don't bring it back unless he asks.
- SCRATCH (phones, both layouts): `AppModel.scratch` (Set of deck indexes). `ScratchView` (PhoneLayout.swift) replaces only that
  deck's player at the same height, showing a big platter with SCRATCH (lit, tap to go back), CUE and PLAY. The mixer and the other deck stay as they are.
  Standard layout: an SCR tab after FX2, with the controls in a column on the inside edge. Touch mode: an SCR button in the deck header (when
  there's no 1⇄3 button) and SCRATCH in the deck's ⋯, with SCR / CUE / PLAY in a row under the platter.

## 2026-10-28: SYNC fixes (Jonah's 140/92 runaway report)

- Report cause 1 (master flip-flop snapping to the fader) is outdated, fixed in #23. Cause 2 (−24% / +31% jumps): Jonah chose
  "limit to range": `pickMult(r, range:)` only offers ½×/1×/2× when the change fits ±6/10/16%; WIDE allows any.
  If none fits, SYNC stays off and the status says why (`syncOutOfRange`). Cause 3 is real: an offset over ¼ beat used to be
  left alone. Now it's only left alone when the user made it with the platter (`phaseFree`, set by jogTouch and bend nudges, cleared on SYNC or once
  back within 2 ms). Any other offset is pulled back at up to 2%.
- Hold SYNC (0.5 s) = `makeMaster()`: that deck leads (it gets the oldest syncSince and no syncWith) and the other synced decks follow it.
  The UI calls `syncPressed()`, which ignores the release that ends a hold. The FLX4's SYNC (MIDI) still just toggles.
- Tests: testSyncFlipFlop140And92EndsOnTheBeat, testSyncMultipliersStayInTheTempoRange, testHoldSyncMakesTheMaster.
  The web app and Linux still have the old ¼-beat deadband and no range limit (parity gap).
