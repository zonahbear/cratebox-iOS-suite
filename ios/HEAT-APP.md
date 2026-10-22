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
