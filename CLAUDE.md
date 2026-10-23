# CLAUDE.md: Cratebox Suite (iOS)

Read this first. Keep it short. (The full repo map is in PR #3, branch `claude/project-thread-497h2z`. When that merges,
fold this file into it.)

## Rules

- **Device sizes:** [`docs/device-sizes.md`](docs/device-sizes.md) is the only source for screen sizes, scales, safe
  areas and Display Zoom sizes, for the shipping app and for the personal HEAT build (`personal/heat`). Never estimate a
  size. If a device is missing, measure it (ios.yml, `measure: true`) and add it there first.
- HEAT never goes into the shipping app (`com.zonahbear.cratebox.suite`). It lives only on `personal/heat`
  (`com.zonahbear.cratebox.heat`), which never merges back.
- Installs only via TestFlight (sideloading retired). macOS CI is manual-only.

## Breadcrumbs

Session notes and next steps: [`.claudes/breadcrumbs.md`](.claudes/breadcrumbs.md).
