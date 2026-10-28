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

## 2026-10-23: Cratebox Mic (watch mic experiment)
- Added watch app target `CrateboxMic` (ios/WatchMic, watchOS 10+), phone receiver `ios/App/WatchMicReceiver.swift`,
  shared wire + ring `ios/Shared/WatchMicWire.swift`, Settings page `ios/App/Views/WatchMicView.swift`.
- Path: CallKit outgoing call on the watch (TN3135 VoIP exemption) → UDP 24 kHz Int16 mono, 10 ms packets → phone
  jitter buffer → mixed onto master in AudioHost's source node (after the limiter, not recorded).
- testflight.yml now needs secret IOS_PROFILE_HEAT_WATCH_BASE64 (watch App ID profile). Setup: ios/HEAT-APP.md.
- Written without Xcode (no Mac in the cloud sandbox): first compile is the TestFlight run. Fix errors from its log.
- Next: Jonah runs the test plan in HEAT-APP.md; decide go/no-go on real latency and the no-Wi-Fi result.
- Watch only, never in the shipping app (com.zonahbear.cratebox.suite). ios.yml simulator runs now also build the
  watch target and need a watchOS simulator runtime.
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

### 2026-10-23 06:55 Cratebox Mic: Bluetooth fallback didn't connect on build 14
- Jonah: "still no bluetooth". Cause unknown (WC errors were swallowed). Build 15 change: phone starts Watch Connectivity at app launch (not on Listen, so a background launch by the watch still has a delegate), both sides show the link state (activated / reachable / app installed / last error), the watch's timeout message includes it.
- Next: Jonah reads the watch's "BT …" line and the phone's "Watch link …" line with phone Wi-Fi off. If "phone NOT in reach" or errors persist with the phone app open, WC can't carry it during a CallKit call → Wi-Fi + travel router.

### 2026-10-23 08:05 Cratebox Mic: Wi-Fi only; gain, board volume, feedback filter
- Bluetooth (Watch Connectivity) fallback: no packet ever reached the phone with Wi-Fi off; phone saw "watch app open: no". Jonah moved on ("right"), so treat the mic as Wi-Fi only. The WC code is still in, harmless.
- Added: Settings → Apple Watch as a mic → Mic gain (-12...+24 dB, `cb.watchMicGainDb`), Feedback filter (`cb.watchMicFeedback`, `ios/App/MicFeedback.swift`: 100 Hz HPF + up to 8 auto notches, Q 30, detector = peak ≥25 dB over bins 3-8 away, same bin, not fading, ~200 ms), notch list + Reset.
- Board: MIC knob in the mixer (top bar on iPhone, master row on iPad) while Listen is on; `cb.watchMicVol`, squared curve, MIDI-learnable action `micVol` ("Watch mic volume"). The FLX4 MIC LEVEL knob sends no MIDI (absent from Mixxx's full FLX4 mapping; Pioneer's MIDI list not reachable), so it can't be mapped.
- Soft knee above 0.8 on the mic in mix(). Untested on device; the detector thresholds are first guesses.

### 2026-10-23 08:10 Cratebox Mic: tested good
- Build 20 on device: FLX4 MIC LEVEL knob DOES send MIDI (my "no MIDI" call from the Mixxx map was wrong); Jonah mapped it to Watch mic volume. Feedback filter "MUCH better". Wi-Fi only.
- Unmerged on claude/project-thread-uceof1: footer text fix (MIC LEVEL works). Rides the next personal/heat merge, to save macOS minutes.

### 2026-10-23 08:45 Cratebox Mic: Link switch (Bluetooth / Wi-Fi / Auto), Bluetooth without CallKit, crash log
- Jonah: on Bluetooth the phone shows the link connected but the call fails, then the watch app crashes. Bluetooth is his main case; latency OK.
- Watch: Link button cycles bt/wifi/auto (`mic.mode`, default bt). Bluetooth = no CallKit: own .playAndRecord session + `audio` background mode, WC only. MicLog.swift writes a crash-surviving log (+ uncaught ObjC exceptions); "Last session log" on the watch, "Send log to phone" (transferUserInfo).
- Phone: Link picker (`cb.watchMicMode`, default bt; bt = no NWListener), "Bluetooth messages from the watch" counter, Watch log section with Copy.
- Crash cause still unknown (no log yet). Next: Jonah reproduces, sends log.

### 2026-10-23 09:45 Cratebox Mic: auto duck
- Build for PR #16 was refused because the repo had been made private (no free macOS minutes); Jonah made it public again 08:48.
- Auto duck (Settings → Apple Watch as a mic → Auto duck): `cb.duckOn` (off), `cb.duckDb` (-12), `cb.micGate` (mic only while talking, on), `cb.voiceDb` (-35 dBFS after gain), `cb.duckHold` (0.6 s). Detector on the network queue per 10 ms packet: level > threshold AND > adaptive floor + 10 dB, 3 packets running → bumps `voiceStamp`; audio thread holds for holdFrames and ducks master channels only (15 ms attack, ~0.5 s release) before adding the voice. Mixer MIC label shows TALK.

### 2026-10-23 18:40 Cratebox Mic: Bluetooth audio works (build 22); latency worse on both links
- Fix: phone drops standing delay (lowest buffer level before each packet over 1 s, beyond target + 10 ms, is trimmed) on top of the target+150 ms cap; watch never sends stale audio (ring capped to max(30 ms, 2× mic IO buffer), `out` capped likewise), "late drops" shown on the BT line.
- Unverified which side caused it; asked Jonah for watch Round trip / Phone buffer / Mic buffer and phone Buffered now.

## 2026-10-23 19:00 Watch mic: Bluetooth delay grew without limit
- Jonah (build 23): in Bluetooth mode the watch's Round trip climbs to 10,000 ms. Cause: WCSession.sendMessageData queues
  every send and never drops, so when the link is slower than 25 messages/s the delay grows forever.
- Fix (MicCall.swift `sendWC`): every message is answered by the phone; at most 2 unanswered at once (2 s timeout);
  packets gather meanwhile (bigger messages), capped at 10 (100 ms), oldest dropped ("late drops"). Pings ride along.
- Wi-Fi lag report: code path unchanged since build 20; suspected link mismatch (both apps default Bluetooth). Asked
  Jonah to set Link = Wi-Fi on both and read the watch's "Via". Next idea if confirmed: phone accepts both links always.
- 19:05 Watch log from Jonah: no crashes; WC goes unreachable ~0.5 s into every CallKit call (Auto = Wi-Fi in
  practice); Wi-Fi sessions really used UDP, so the link-mismatch theory was wrong. Watch stats are hidden under the
  call screen, so a new `.report(rttMs, lateDrops)` packet (type 5) goes with each ping and the phone shows
  "Round trip (watch)" / "Late drops (watch)" under Link. Wi-Fi lag cause still open (need Buffered now + output route).

## 2026-10-23 19:30 PUFF: Puffco as an instrument (personal/heat only)
- HEAT panel → "HOLD for PUFF": slot 4 at one temperature (default 500°F, `cb.tc.holdF`), 120 s, no curve steering,
  same backup/restore + 600°F cutoff. Reads the bowl ~10/s; `TrueCurve.PuffDrop` (CrateboxKit) turns the dip below
  the settled temperature into 0...1 (dead 3°F, full `cb.tc.puffFull` = 40°F; settled freezes while falling, lets go
  in ~1.5 s on recovery). Beat FX "PUFF" (FxKind.puff, only listed while a Puffco/sim is connected, `fx.puffReady`):
  tape warble = 4.5 ms ± 3.5 ms sine-swept delay, rate 2→7 Hz, LEVEL caps it; amount via `EngineCommand.fxMod`.
- Simulator: SimHeater.airflow (draw), "Hold to hit" button. Tests: testPuffDropFollowsADraw, testPuffWarbleStaysFinite.
- Not compiled here (no Swift on the CI box), not on a real Puffco. Real drop size/noise and BLE read rate unknown: tune
  dead/full after Jonah's first real hits. Never port PUFF to the shipping app.
- 19:35 Jonah (build 27, real Puffco): "needs better temp dip on inhale". Change: dead 3 → 1.5°F, dip also counts fall
  speed (0.5 s ahead past 2°F/s), "Full warble at" default Auto (`cb.tc.puffFull2` = 0: 85% of biggest recent dip,
  ≥6°F, ~60 s memory) plus 4/8/15/25/40. Panel readout: dip / biggest / full at / reads/s, so Jonah can send real numbers.
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
## 2026-10-28 06:20-07:00: theremin, GLOW, 3 decks, quick library (personal/heat, thread "Add theremin, GLOW and 3 decks to Cratebox HEAT")

- PUFF (FxUnit.swift) is now Cratebox OS's theremin: voice 220→880 Hz with the hit (150 ms glide, 5.5 Hz vibrato,
  0.18 2nd harmonic, ×0.22×hit) over the tape warble. Same maths in Cratebox-Linux src/fx.rs and web cratebox.html (#11).
- GLOW: TrueCurve.Glow (rainbow + music envelope, FX depth knob = brightness/speed/sensitivity/nothing) +
  Lorax.Path.lanternCmd/lanternColor (HA-Puff paths, untested on a Proxy). HeatController.glowLoop: ≤5 writes/s,
  never while a curve/HOLD runs, 3 refusals = paused. UserDefaults cb.tc.glow / cb.tc.glowKnob. UI: GlowRow in HeatPanel.
- 3 decks: Core.three + deckCount/activeDecks/setDecks/cycleDecks (prefs cb.three); AppModel.setDecks fixes the
  controller sides; MIDIEngine.setSide refuses decks ≥ deckCount, so the right layer stays on 2. DECKS button
  label "N DECKS", Settings/compact menu = Picker 2/3/4.
- FLX4 0x96 0x48/0x49 (SHIFT+LOAD) → "loadShift" deck 3/4 (assumed from the old map, which sent them to load 1/2;
  not checked on hardware). Quick library (BrowserOverlay): BPM / KEY sort chips (LibraryPane.setStoredSort, shared
  with the library's own sort via a notification) and a load button per active deck.
- Tests: TrueCurveTests testPuffSingsHigherTheHarderTheHit / testGlowBreathesWithTheMusic, CoreTests testThreeDecks /
  testShiftLoadGoesToDecks3And4. ios.yml app build still fails on the empty WatchMic AppIcon (known), so app-target
  code is only compiled by testflight.yml.
- Only the HEAT build got these (Jonah: one TestFlight build). The shipping app (preview/truecurve-usb) has none of it.
