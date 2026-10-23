# Cratebox HEAT: Jonah's own build (internal TestFlight only)

This branch, `personal/heat`, is the only place HEAT (TrueCurve mini, Puffco over Bluetooth) still lives in the
iOS app. It builds a **separate app**, "Cratebox HEAT" (`com.zonahbear.cratebox.heat`), with its own App Store
Connect record. It goes to **internal** TestFlight testers only and is **never submitted for review**: HEAT would
fail guideline 1.4.3. The real app, `com.zonahbear.cratebox.suite`, has HEAT removed entirely.

- **Never merge this branch into `main` or a `preview/*` branch.** To pick up new app work, merge the other way
  (`main` → `personal/heat`), then check the bundle id and display name in `ios/project.yml` are still HEAT's.
- Both apps install side by side on one phone.

## One-time setup (reuses the certificate and API key from TESTFLIGHT.md)

1. developer.apple.com → Identifiers → **+** → App ID, Explicit `com.zonahbear.cratebox.heat`, description
   `Cratebox HEAT`, no capabilities.
2. appstoreconnect.apple.com → Apps → **+** → New App: iOS, name e.g. `Cratebox HEAT (private)`, that bundle id,
   SKU `cratebox-heat`. Never press "Add for Review".
3. Profiles → **+** → Distribution → App Store Connect → App ID `com.zonahbear.cratebox.heat` → the same Apple
   Distribution certificate → name `Cratebox HEAT App Store` → download.
4. GitHub → Settings → Secrets → Actions → new secret **`IOS_PROFILE_HEAT_BASE64`**:
   `[Convert]::ToBase64String([IO.File]::ReadAllBytes("<path to .mobileprovision>")) | Set-Clipboard`.
   The other five secrets are shared with the real app.
5. Actions → **TestFlight** → Run workflow → branch `personal/heat` (or push to the branch). Logs: branch
   `ci-logs-testflight-heat`.
6. App Store Connect → Cratebox HEAT → TestFlight → answer encryption → Internal Testing group → add yourself.
   Builds expire after 90 days, so re-run the workflow before then.

## Cratebox Mic: the Apple Watch as a mic (experiment)

This app also carries a watch app, **Cratebox Mic** (`com.zonahbear.cratebox.heat.watchkitapp`, `ios/WatchMic`),
which streams the watch's mic to Cratebox on the phone. watchOS only allows its own network connection during a
CallKit call (Apple TN3135), so **Go live** starts a call "to Cratebox" and the voice goes over UDP for as long as it
runs. It's an experiment: latency and whether it works with no Wi-Fi are what it's for finding out.

One-time setup, on top of the steps above:

1. developer.apple.com → Identifiers → **+** → App ID, Explicit `com.zonahbear.cratebox.heat.watchkitapp`,
   description `Cratebox Mic`, no capabilities.
2. Profiles → **+** → Distribution → App Store Connect → that App ID → the same certificate → name
   `Cratebox Mic App Store` → download.
3. GitHub secret **`IOS_PROFILE_HEAT_WATCH_BASE64`**, made the same way as `IOS_PROFILE_HEAT_BASE64`.
   Until it exists the TestFlight workflow skips (it says which secret is missing) rather than failing.

The watch app installs from the Watch app on the iPhone (Available Apps) once Cratebox HEAT is on the phone.

Using it:

1. Phone: Settings → Watch mic → **Apple Watch as a mic…** → Listen. Allow local network when asked.
2. Watch: open Cratebox Mic → **Go live**. The crown sets the level, the big button mutes. If Bonjour doesn't find
   the phone, type the address the phone shows.
3. The phone's Mute and Level always win over the watch's.

The test plan: on shared Wi-Fi, then with Wi-Fi off on both, then 10 minutes wrist down. Note the watch's round
trip, the phone's dropouts, and a clap test (clap near the watch, record the room and the speakers, read the gap).
Known limits: the voice goes onto the master after the limiter, so it isn't limited and isn't in recordings.
