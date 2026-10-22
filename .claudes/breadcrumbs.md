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
