# Breadcrumbs (personal/heat)

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
