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
