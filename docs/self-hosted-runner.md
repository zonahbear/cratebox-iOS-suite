# Self-hosted runner: the MacBook Pro M4 Pro

The iOS CI (`ios.yml`) and TestFlight (`testflight.yml`) workflows run on Jonah's 14" MacBook Pro (M4 Pro, macOS 27,
Xcode 27) by default. Runner input `m4` = this Mac; `xcode-27` = GitHub's hosted Apple Silicon Mac, the backup while the
M4 is off. No Intel runner, ever. Both workflows check for Xcode 27 on arm64 and stop if they don't find it.

Labels: GitHub gives every self-hosted Mac `self-hosted`, `macOS` and `ARM64`; we add **`cratebox-m4`**. The workflows
ask for all four, so a job can't land on anything else by accident. (Don't name the label `xcode-27`: that's GitHub's
hosted runner.)

A personal-account runner belongs to one repository, so the Mac runs two: one for **zonahbear/cratebox-iOS-suite**
(TestFlight uploads still happen there, MONO-4) and one for **zonahbear/Cratebox** (the monorepo's iOS CI).

## 1. GitHub settings first (security)

A self-hosted runner runs whatever a workflow tells it to, on your Mac. Anyone can open a pull request on a public repo,
and a pull request can add its own workflow file. GitHub's advice is to use self-hosted runners only with private repos.

- **cratebox-iOS-suite → make it private** (Settings → General → Danger Zone → Change visibility). It was public only for
  free hosted minutes; self-hosted runners cost no minutes on private repos either. Catch: the hosted `xcode-27` backup
  would then use the private-repo allowance (macOS minutes count 10x).
- **Both repos:** Settings → Actions → General → "Approval for running fork pull request workflows from contributors"
  → **Require approval for all external contributors**. Never press "Approve and run" on someone else's pull request.
- Cratebox (monorepo) stays public. Its iOS workflows only run on Run workflow (`workflow_dispatch`) and pushes to
  `main`, never on pull requests, and only you can do either.

## 2. On the Mac, in your own (admin) account, once

1. Xcode 27 in /Applications (Xcode.app is fine). Then in Terminal:
   `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`
2. The iOS 27 simulator runtime: Xcode → Settings → Components (you're already downloading it). Check with
   `xcrun simctl list runtimes`.
3. Homebrew (https://brew.sh) if it isn't there, then `brew install xcodegen coreutils`. The runner's account can use
   these but can't install anything itself, and the workflows stop with "MISSING xcodegen/gtimeout" if they're absent.
4. A separate **standard** (not admin) user for the runner: System Settings → Users & Groups → Add User, name `ci`.
   Workflow code then can't touch your files, your login keychain, your browser sign-ins or Claude, and can't sudo.
5. Stay awake on the charger: System Settings → Battery → Options → "Prevent automatic sleeping on power adapter when the
   display is off" on. With the lid closed it still sleeps unless an external display is connected. Jobs that arrive
   while it sleeps wait in the queue (GitHub gives up after 24 hours).

## 3. As the `ci` user: install the two runners

Switch to `ci` (Control Center → your name → `ci`, so your own session keeps running), open Terminal, and run
`xcodebuild -version` once (it should say Xcode 27).

For each repo, open its Settings → Actions → Runners → **New self-hosted runner**, choose macOS and ARM64, and copy the
**Download** commands from that page (they carry the current runner version and its checksum). Use these folders:

| Repo | Folder | Runner name |
|---|---|---|
| zonahbear/cratebox-iOS-suite | `~/actions-runner-suite` | `m4-suite` |
| zonahbear/Cratebox | `~/actions-runner-mono` | `m4-mono` |

Then, inside each folder (the token is the one on that page; it expires after an hour):

```sh
export PATH="/opt/homebrew/bin:$PATH"      # the runner remembers this PATH, so brew's tools are found
./config.sh --url https://github.com/zonahbear/cratebox-iOS-suite --token <TOKEN> \
  --name m4-suite --labels cratebox-m4 --work _work --unattended
./svc.sh install && ./svc.sh start && ./svc.sh status
```

(For the monorepo: `--url https://github.com/zonahbear/Cratebox --name m4-mono`.)

Each repo's Settings → Actions → Runners should now list the runner as **Idle** with `self-hosted, macOS, ARM64,
cratebox-m4`. Switch back to your own account. **Don't log `ci` out**: the runners are launch agents that run only
while `ci` is logged in. After a restart, log in as `ci` once and switch back.

## 4. First run

Actions → iOS checks → Run workflow → runner `m4`. The log's first lines say `RUNNER m4-… (self-hosted)` and the Xcode
version. TestFlight: Actions → TestFlight → Run workflow → `m4` (pushes go to `m4` by default).

## Disk

- Builds stay on the internal SSD: `~ci/actions-runner-*/_work`. DerivedData, the signing keychain and the .p12 live in
  the job's temp folder and are deleted after every job; the TestFlight job also removes its provisioning profile and
  API key from `ci`'s home.
- Every few weeks: `xcrun simctl delete unavailable` as `ci`, and `du -sh ~/Library/Developer` to see what simulators use.
- The runner never touches the 1 TB music drive. To keep `ci` out of it entirely: Finder → the drive → Get Info →
  untick "Ignore ownership on this volume".

## Removing a runner

In its folder as `ci`: `./svc.sh stop && ./svc.sh uninstall && ./config.sh remove --token <removal token>` (the token
is on the runner's page in Settings → Actions → Runners).

## Not verified yet

Written 2026-11-13 before the first run. Untested: simulators booting while `ci` is in the background (fast user
switching). If they don't, run the runners under your own account instead (same steps, less isolation) and say so here.
