# Next-track suggestions (draft)

Status: **draft, not wired into any app.** Scorer + tests exist; no UI, no cached energy yet.
Mock: https://claude.ai/artifact/JWmXhgHsiMiucGkUHMZnsq

## What it does

Given the track you hear now and the deck you're loading into, rank the library by how well each track would
follow. Everything runs on the device from data Cratebox already has. No cloud, no accounts.

- Code: `ios/CrateboxKit/Sources/CrateboxKit/NextTrack.swift` (`NextTrack.score`, `NextTrack.suggest`).
- Reference: `tools/next_track.js` (same maths; `node tools/next_track.js` runs the checks). The web app and
  Cratebox OS (Rust) ports should copy this file's numbers.
- Tests: `NextTrackTests.swift` uses the same cases and numbers as the JS checks.

## Score (0-100)

| Part | Weight | Source | Rule |
|---|---|---|---|
| Tempo | 35% | BPM | ½× / 1× / 2× of the heard tempo, **only if the target deck's range reaches it** (same rule as SYNC's `pickMult`). Not reachable = not offered. 1 at 0%, 0 at min(range, 8%). ½×/2× ×0.85. |
| Key | 30% | key (Camelot) | same 1.0, ±1 0.9, relative 0.85, ±2 / diagonal 0.6, +1 semitone 0.55, −1 semitone 0.45, else clash 0.1 and the total ×0.6. With master tempo **off**, checked after the pitch change (`Keys.shift`, 12·log2(rate), like `keyNow`). |
| Energy | 15% | waveform rms + low band | wanted = now + 0.08 × flow (DROP −1 / HOLD 0 / BUILD +1); 0 at 0.4 away. |
| Sound | 12% | waveform low/mid/high | 1 − half the L1 distance of the band splits. |
| Genre | 8% | rekordbox PDB genre | 1 if equal (case-insensitive), else 0. |

Missing parts drop out and the rest are re-weighted. Played this session: ×0.3 (sinks, stays findable).

"Now" = the master deck (`DeckModel.master()` / `pickMaster`) at `effBpm()` and `keyNow()`. Target = the
deck you're loading into: its `range` and `mt`.

## What's missing before it can ship

1. **Energy/sound need caching.** `TrackRecord` has no waveform; the waveform only exists on a loaded deck.
   Plan: add `energy: Double?, bands: [Double]?` to `TrackRecord`, fill them in `Library` analysis via
   `NextTrack.profile(wave)`; old records fill on next analysis (no forced re-scan). Until then the score is tempo
   + key (+ genre on sticks), which is already the useful 80%.
2. **Session history.** Nothing records what was played. Plan: `AppModel.played: Set<String>`, add on PLAY that
   lasts > 30 s, cleared on app start or a "new set" button.
3. **UI.** Proposed: a MATCH sort key in the quick library (`SortKey.match`, sorts by score for the deck not on
   air), score pill + key chip per row, and a DROP / HOLD / BUILD toggle in its header. Touch mode: the same list,
   no extra buttons. Not built.
4. **Energy formula is a guess.** Weights and the 0.75/0.25 rms/bass mix are untuned. Needs a check against real
   tracks (compare with rekordbox / Mixed In Key energy if Jonah has them).

## Not planned (ask first)

Online similarity (Spotify/Last.fm features), ML embeddings, "sounds like" from audio fingerprints beyond the
3-band split. All bigger, some need network or paid APIs.
