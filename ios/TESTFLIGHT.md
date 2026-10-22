# TestFlight setup (no Mac needed)

`.github/workflows/testflight.yml` builds a signed App Store copy of `main` and uploads it to TestFlight. It
needs six GitHub secrets, which only the Apple Developer account holder can make. Until they all exist the
workflow skips itself and passes. TestFlight is the only install route; sideloaded builds are retired.

Everything below is a browser plus PowerShell on Windows. `openssl` comes with Git for Windows. Never paste any
of these files or values into a chat; they go only into GitHub's secret boxes.

## 1. Register the bundle ID

developer.apple.com/account → Certificates, IDs & Profiles → **Identifiers** → **+** → App IDs → App.
Description `Cratebox Suite`, Bundle ID **Explicit** `com.zonahbear.cratebox.suite`. Tick no capabilities → Register.

## 2. Make the App Store Connect app record

appstoreconnect.apple.com → **Apps** → **+** → New App. Platform iOS, any name (it must be unique on the
App Store; nothing is public until you submit for review), Bundle ID = the one from step 1, SKU e.g.
`cratebox-suite`, Full Access.

## 3. Distribution certificate (.p12) without a Mac

```powershell
mkdir $HOME\cratebox-signing; cd $HOME\cratebox-signing
$ossl = "C:\Program Files\Git\usr\bin\openssl.exe"
& $ossl req -new -newkey rsa:2048 -nodes -keyout dist.key -out dist.csr -subj "/CN=Cratebox Distribution/C=US"
```

Portal → **Certificates** → **+** → **Apple Distribution** → upload `dist.csr` → download `distribution.cer`
into the same folder. Then:

```powershell
& $ossl x509 -inform DER -in distribution.cer -out distribution.pem
& $ossl pkcs12 -export -inkey dist.key -in distribution.pem -out dist.p12 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
```

It asks for an export password: make one up. That's `IOS_DIST_P12_PASSWORD`. (The old-style encryption flags
are there because macOS's keychain can refuse OpenSSL 3's default .p12 format.) Keep `dist.key`/`dist.p12`
somewhere safe, like a password manager; never commit them.

## 4. App Store provisioning profile

Portal → **Profiles** → **+** → Distribution → **App Store Connect** → App ID `com.zonahbear.cratebox.suite` →
the certificate from step 3 → name it `Cratebox Suite App Store` → download the `.mobileprovision`.
It expires with the certificate (a year). Renew both and update the secrets then.

## 5. App Store Connect API key (for the upload)

App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API** (request access the
first time) → Team Keys → **+**. Name `GitHub CI`, access **App Manager** → Generate → **Download** the
`AuthKey_XXXXXXXXXX.p8` (Apple lets you download it once). Note the **Key ID** (in the row) and the
**Issuer ID** (above the table).

## 6. GitHub secrets

github.com/zonahbear/cratebox-iOS-suite → Settings → Secrets and variables → **Actions** → New repository secret.
Copy each value to the clipboard with PowerShell, then paste into the secret box:

| Secret | Value |
|---|---|
| `IOS_DIST_P12_BASE64` | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\cratebox-signing\dist.p12")) \| Set-Clipboard` |
| `IOS_DIST_P12_PASSWORD` | the export password from step 3 |
| `IOS_PROFILE_BASE64` | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("<path to .mobileprovision>")) \| Set-Clipboard` |
| `ASC_KEY_ID` | Key ID from step 5 |
| `ASC_ISSUER_ID` | Issuer ID from step 5 |
| `ASC_KEY_P8` | `Get-Content "<path to AuthKey_….p8>" -Raw \| Set-Clipboard` |

The team ID isn't needed; the workflow reads it from the profile.

## 7. Run it

Every push to `main` touching `ios/` uploads a build; Actions → **TestFlight** → Run workflow does it on demand.
Build numbers are `<run number>.<attempt>`. If it fails, the summary is on branch `ci-logs-testflight`
(`testflight.txt`).

## 8. Install from TestFlight

App Store Connect → the app → **TestFlight**. A new build takes 5–30 minutes to process. The first time, it shows
**Missing Compliance**: answer the encryption question (the app uses Apple's CommonCrypto to read and write
rekordbox's encrypted `exportLibrary.db`; how to answer is your call). Then Internal Testing → **+** group →
add yourself. Install the TestFlight app on the phone, signed in with the same Apple ID. Builds last 90 days;
internal testers need no Beta App Review.
