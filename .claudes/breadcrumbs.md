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
