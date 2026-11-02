// Next-track suggestions: scores library tracks against what's playing now (tempo, key, energy, sound, genre).
// Reference implementation for ios/CrateboxKit/Sources/CrateboxKit/NextTrack.swift (same names, same maths) and
// for the web app / Cratebox OS ports later. DRAFT: not wired into any app yet.
// Run the checks: node tools/next_track.js
'use strict';

// ---- keys: 0-11 major (C...B), 12-23 minor, same numbering as Keys in Core.swift / the web app ----
function camelot(k) {
  if (k < 0) return null;
  const minor = k >= 12, pc = k % 12, rel = minor ? (pc + 3) % 12 : pc;
  return { num: ((rel * 7) % 12 + 7) % 12 + 1, minor };
}
function shiftKey(k, semis) { return k < 0 ? k : (k >= 12 ? 12 : 0) + (((k % 12) + semis) % 12 + 12) % 12; }
// JS Math.round (half up), as jsRound in the Swift code
const jsRound = (x) => Math.floor(x + 0.5);

// how well key b follows key a, 0...1, and a short name for the move
function keyScore(a, b) {
  const x = camelot(a), y = camelot(b);
  if (!x || !y) return { s: 0.5, why: 'key ?' };            // unknown: neutral, not a veto
  const d = ((y.num - x.num) % 12 + 12) % 12;                // steps clockwise round the wheel
  const step = Math.min(d, 12 - d);
  if (x.minor === y.minor) {
    if (d === 0) return { s: 1, why: 'same key' };
    if (step === 1) return { s: 0.9, why: d === 1 ? '+1' : '−1' };
    if (step === 2) return { s: 0.6, why: d === 2 ? '+2' : '−2' };
    if (d === 7) return { s: 0.55, why: '+1 semitone' };    // the "energy boost" key change
    if (d === 5) return { s: 0.45, why: '−1 semitone' };
  } else {
    if (d === 0) return { s: 0.85, why: 'relative' };
    // diagonal: minor → major one step up (8A → 9B), major → minor one step down (9B → 8A)
    if ((!x.minor && d === 11) || (x.minor && d === 1)) return { s: 0.6, why: 'diagonal' };
  }
  return { s: 0.1, why: 'clash' };
}

// ---- tempo: like DeckModel.pickMult, ½× / 1× / 2× of the playing tempo, within the target deck's range ----
// ref: the BPM you hear now; bpm: the candidate's own; range: the target deck's ± range in % (100 = WIDE)
function tempoFit(ref, bpm, range) {
  if (!(ref > 0) || !(bpm > 0)) return null;
  const r = ref / bpm;
  const fits = [1, 0.5, 2].filter((k) => range >= 100 || Math.abs(r * k - 1) <= range / 100 + 1e-9);
  if (!fits.length) return null;
  const k = fits.reduce((a, b) => (Math.abs(Math.log(r * b)) < Math.abs(Math.log(r * a)) ? b : a));
  return { mult: k, rate: r * k, pct: (r * k - 1) * 100 };
}
// 1 at no change, 0 at the comfort edge (the range, but never wider than 8% even on WIDE); ½×/2× costs 15%
function tempoScore(fit, range) {
  const comfort = Math.min(range, 8);
  return Math.max(0, 1 - Math.abs(fit.pct) / comfort) * (fit.mult === 1 ? 1 : 0.85);
}

// ---- energy and sound: from the waveform the analyser already makes (rms, low, mid, high bytes) ----
// energy 0...1: loudness of the body of the track (10%-90%, skips intro/outro) with a push for bass weight.
// bands: the average low / mid / high split, normalised to sum 1 (a crude "what it sounds like").
function profile(wave) {
  const n = wave.rms.length, a = Math.floor(n * 0.1), b = Math.max(a + 1, Math.floor(n * 0.9));
  let rms = 0, lo = 0, mi = 0, hi = 0;
  for (let i = a; i < b; i++) { rms += wave.rms[i]; lo += wave.low[i]; mi += wave.mid[i]; hi += wave.high[i]; }
  const m = b - a, tot = lo + mi + hi || 1;
  const bands = [lo / tot, mi / tot, hi / tot];
  const energy = Math.min(1, Math.max(0, (rms / m / 255) * 0.75 + bands[0] * 0.25 / 0.5));
  return { energy, bands };
}
// flow: 0 hold, +1 build, −1 drop. The wanted step is 0.08 of the 0...1 scale
function energyScore(now, cand, flow) {
  const want = now + 0.08 * flow;
  return Math.max(0, 1 - Math.abs(cand - want) / 0.4);
}
function soundScore(a, b) {   // 1 - half the L1 distance of two band splits
  return 1 - 0.5 * (Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2]));
}

const WEIGHTS = { tempo: 0.35, key: 0.3, energy: 0.15, sound: 0.12, genre: 0.08 };

// now: { id, bpm (as heard), key (as heard), energy?, bands?, genre? }
// cand: { id, bpm, key, energy?, bands?, genre?, artist? }
// opts: { range (target deck ±%), keylock (target deck's master tempo), flow (−1/0/+1), played: Set of ids }
// returns { score 0-100, fit, keyAfter, parts, why[] } or null when the track can't follow at all
function scoreNext(now, cand, opts) {
  if (cand.id === now.id) return null;
  const fit = tempoFit(now.bpm, cand.bpm, opts.range);
  if (!fit) return null;                                      // can't reach the tempo on this deck: not offered
  const keyAfter = opts.keylock || cand.key < 0 ? cand.key : shiftKey(cand.key, jsRound(12 * Math.log2(fit.rate)));
  const k = keyScore(now.key, keyAfter);
  const parts = { tempo: tempoScore(fit, opts.range), key: k.s };
  if (now.energy != null && cand.energy != null) parts.energy = energyScore(now.energy, cand.energy, opts.flow || 0);
  if (now.bands && cand.bands) parts.sound = soundScore(now.bands, cand.bands);
  if (now.genre && cand.genre) parts.genre = now.genre.toLowerCase() === cand.genre.toLowerCase() ? 1 : 0;
  let sum = 0, w = 0;
  for (const p in parts) { sum += parts[p] * WEIGHTS[p]; w += WEIGHTS[p]; }
  let score = (sum / w) * 100;
  if (k.why === 'clash') score *= 0.6;                         // a known clash shouldn't outrank a harmonic move
  if (opts.played && opts.played.has(cand.id)) score *= 0.3; // played this session: sinks, still findable
  const why = [
    (fit.mult === 0.5 ? '½× ' : fit.mult === 2 ? '2× ' : '') + (fit.pct >= 0 ? '+' : '') + fit.pct.toFixed(1) + '%',
    k.why + (keyAfter !== cand.key ? ' (pitched)' : ''),
  ];
  if (parts.energy != null) {
    const d = cand.energy - now.energy;
    why.push(Math.abs(d) < 0.04 ? 'energy =' : d > 0 ? 'energy ↑' : 'energy ↓');
  }
  return { score, fit, keyAfter, parts, why };
}

// best first; ties keep library order (stable sort)
function suggest(now, tracks, opts, limit) {
  const out = [];
  for (const t of tracks) { const r = scoreNext(now, t, opts); if (r) out.push({ t, ...r }); }
  out.sort((a, b) => b.score - a.score);
  return limit ? out.slice(0, limit) : out;
}

module.exports = { camelot, shiftKey, keyScore, tempoFit, tempoScore, profile, energyScore, soundScore, scoreNext, suggest, WEIGHTS };

// ---- checks (the Swift tests use the same cases and numbers) ----
if (require.main === module) {
  const assert = require('assert');
  const near = (a, b, e = 1e-6) => assert.ok(Math.abs(a - b) < e, `${a} != ${b}`);
  const A = (n) => [8, 3, 10, 5, 0, 7, 2, 9, 4, 11, 6, 1][n - 1] + 12; // nA (minor) → key index: 8A = A minor = 21
  const B = (n) => [11, 6, 1, 8, 3, 10, 5, 0, 7, 2, 9, 4][n - 1];      // nB (major): 8B = C major = 0, 1B = B major
  for (let n = 1; n <= 12; n++) { assert.deepStrictEqual(camelot(A(n)), { num: n, minor: true }); assert.deepStrictEqual(camelot(B(n)), { num: n, minor: false }); }

  // keys
  near(keyScore(A(8), A(8)).s, 1); near(keyScore(A(8), A(9)).s, 0.9); near(keyScore(A(8), A(7)).s, 0.9);
  near(keyScore(A(12), A(1)).s, 0.9);                       // wraps round
  near(keyScore(A(8), B(8)).s, 0.85); near(keyScore(A(8), B(9)).s, 0.6); near(keyScore(B(9), A(8)).s, 0.6);
  near(keyScore(A(8), A(10)).s, 0.6); near(keyScore(A(8), A(3)).s, 0.55); near(keyScore(A(8), A(2)).s, 0.1);
  near(keyScore(-1, A(8)).s, 0.5);

  // tempo: 124 playing, 128 candidate on ±6%: −3.1%. A 64 plays half time (½×, the 62 under 124), also −3.1%
  let f = tempoFit(124, 128, 6); near(f.mult, 1); near(f.pct, (124 / 128 - 1) * 100);
  f = tempoFit(124, 64, 6); near(f.mult, 0.5); near(f.pct, (124 / 128 - 1) * 100);
  assert.strictEqual(tempoFit(140, 92, 10), null);          // Jonah's 140/92: no fit on ±10% (same as SYNC)
  f = tempoFit(140, 92, 100); near(f.mult, 0.5);            // WIDE: ½× (−23.9%) beats 1× (+52%)
  near(tempoScore(tempoFit(128, 128, 10), 10), 1);
  near(tempoScore(tempoFit(124, 128, 6), 6), 1 - (4 / 128 * 100) / 6);
  near(tempoScore(tempoFit(140, 92, 100), 100), 0);         // −23.9% is past the 8% comfort edge

  // pitch moves the key without master tempo: +6% on a 8A track is +1 semitone = 3A
  const now = { id: 'a', bpm: 128, key: A(8) };
  let r = scoreNext(now, { id: 'b', bpm: 120.75, key: A(8) }, { range: 10, keylock: false });
  assert.strictEqual(r.keyAfter, A(3)); assert.ok(r.why[1].includes('pitched'));
  r = scoreNext(now, { id: 'b', bpm: 120.75, key: A(8) }, { range: 10, keylock: true });
  assert.strictEqual(r.keyAfter, A(8));

  // weights renormalise over what's known: tempo + key only
  r = scoreNext(now, { id: 'c', bpm: 128, key: A(9) }, { range: 10, keylock: true });
  near(r.score, (1 * 0.35 + 0.9 * 0.3) / 0.65 * 100);
  assert.strictEqual(scoreNext(now, { id: 'a', bpm: 128, key: A(8) }, { range: 10 }), null); // itself

  // energy flow
  near(energyScore(0.5, 0.58, 1), 1); near(energyScore(0.5, 0.5, 0), 1); near(energyScore(0.5, 0.9, 0), 0);
  near(soundScore([0.5, 0.3, 0.2], [0.5, 0.3, 0.2]), 1); near(soundScore([1, 0, 0], [0, 1, 0]), 0);

  // played tracks sink; ranking
  const lib = [
    { id: 'clash', bpm: 128, key: A(2) },
    { id: 'perfect', bpm: 128, key: A(8) },
    { id: 'played', bpm: 128, key: A(8) },
    { id: 'far', bpm: 150, key: A(8) },
    { id: 'half', bpm: 64, key: A(9) },
  ];
  const s = suggest(now, lib, { range: 10, keylock: true, played: new Set(['played']) });
  assert.deepStrictEqual(s.map((x) => x.t.id), ['perfect', 'half', 'clash', 'played']); // 'far' (+17%) not offered
  near(s[1].score, (1 * 0.85 * 0.35 + 0.9 * 0.3) / 0.65 * 100);
  near(s[2].score, (1 * 0.35 + 0.1 * 0.3) / 0.65 * 100 * 0.6);   // clash: 35.1
  near(s[3].score, 30);                                           // played: 100 × 0.3

  // profile from a waveform
  const w = { rms: Array(100).fill(128), low: Array(100).fill(100), mid: Array(100).fill(60), high: Array(100).fill(40) };
  const p = profile(w); near(p.bands[0], 0.5); near(p.energy, (128 / 255) * 0.75 + 0.25);
  console.log('next_track: all checks pass');
}
