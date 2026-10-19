// Renders the web app's audio processors (the WORKLET in cratebox.html: DeckPlayer, FxUnit) in node on
// fixed test signals and scenarios, and writes what they output. The Swift port (CrateboxKit DSP) is
// tested against these files sample for sample.
//
//     node ios/tools/dsp_oracle.js cratebox.html ios/CrateboxKit/Tests/CrateboxKitTests/Fixtures/dsp
const fs = require("fs"), path = require("path");
const html = fs.readFileSync(process.argv[2], "utf8");
const OUT = process.argv[3];
fs.mkdirSync(OUT, { recursive: true });
const src = html.slice(html.indexOf("const WORKLET = `") + "const WORKLET = `".length);
const code = src.slice(0, src.indexOf("\n`;"));
const SR = 44100;
global.sampleRate = SR; global.currentTime = 0;
const procs = {};
global.registerProcessor = (n, c) => { procs[n] = c; };
global.AudioWorkletProcessor = class { constructor() { this.port = { postMessage() {}, onmessage: null }; } };
eval(code);

// deterministic test signal: two sines, a decaying click every half second, a little noise (LCG)
function signal(n) {
  const L = new Float32Array(n), R = new Float32Array(n);
  let seed = 12345;
  const rnd = () => { seed = (seed * 1103515245 + 12345) >>> 0; return seed / 4294967296 - 0.5; };
  for (let i = 0; i < n; i++) {
    const t = i / SR, c = (i % (SR / 2)) / SR;
    const click = Math.exp(-c * 60) * Math.sin(2 * Math.PI * 80 * c);
    L[i] = 0.3 * Math.sin(2 * Math.PI * 220 * t) + 0.4 * click + 0.02 * rnd();
    R[i] = 0.3 * Math.sin(2 * Math.PI * 330 * t + 0.5) + 0.4 * click + 0.02 * rnd();
  }
  return [L, R];
}
const N = SR * 4;
const [SL, SR_] = signal(N);
fs.writeFileSync(path.join(OUT, "signal.f32"), Buffer.concat([Buffer.from(SL.buffer), Buffer.from(SR_.buffer)]));

function render(proc, blocks, steps, input) {
  const P = new procs[proc]();
  const outL = new Float32Array(blocks * 128), outR = new Float32Array(blocks * 128);
  for (let b = 0; b < blocks; b++) {
    global.currentTime = b * 128 / SR;
    for (const s of steps) if (s.block === b) P.port.onmessage({ data: s.msg });
    const oL = new Float32Array(128), oR = new Float32Array(128);
    const ins = input ? [[input[0].subarray(b * 128, b * 128 + 128), input[1].subarray(b * 128, b * 128 + 128)]] : [[]];
    P.process(ins, [[oL, oR]]);
    outL.set(oL, b * 128); outR.set(oR, b * 128);
  }
  return [outL, outR];
}
const scen = {};
const load = { t: "load", L: SL, R: SR_, mt: false };
scen.deck_plain = { proc: "deck-player", blocks: 400, steps: [{ block: 0, msg: load }, { block: 2, msg: { t: "play", v: true } }, { block: 150, msg: { t: "rate", v: 1.06 } }, { block: 300, msg: { t: "play", v: false } }] };
scen.deck_mt = { proc: "deck-player", blocks: 400, steps: [{ block: 0, msg: { ...load, mt: true } }, { block: 0, msg: { t: "rate", v: 0.94 } }, { block: 1, msg: { t: "play", v: true } }, { block: 200, msg: { t: "rate", v: 1.08 } }] };
scen.deck_loop_seek = { proc: "deck-player", blocks: 500, steps: [{ block: 0, msg: load }, { block: 0, msg: { t: "seek", v: 22050 } }, { block: 1, msg: { t: "play", v: true } },
  { block: 50, msg: { t: "loop", on: true, a: 30000, b: 41025 } }, { block: 300, msg: { t: "loop", on: false, a: 0, b: 0 } }, { block: 320, msg: { t: "seek", v: 100000 } }, { block: 400, msg: { t: "bend", v: 0.05 } }] };
scen.deck_scratch = { proc: "deck-player", blocks: 400, steps: [{ block: 0, msg: load }, { block: 1, msg: { t: "play", v: true } }, { block: 100, msg: { t: "scratch", v: true } },
  ...Array.from({ length: 60 }, (_, k) => ({ block: 101 + k, msg: { t: "jog", v: (k < 30 ? -1 : 1) * 300 } })), { block: 200, msg: { t: "scratch", v: false } },
  { block: 250, msg: { t: "scratch", v: true } }, ...Array.from({ length: 10 }, (_, k) => ({ block: 251 + k, msg: { t: "jog", v: -2500 } })), { block: 262, msg: { t: "scratch", v: false } }] };
const clock = { t: "clock", t0: 0, beat0: 0, bps: 126 / 60, spb: 60 / 126 };
for (const fx of ["ECHO", "DELAY", "PING PONG", "REVERB", "FLANGER", "FILTER", "TRANS", "ROLL", "HPF", "LPF"]) {
  scen["fx_" + fx.replace(" ", "_")] = { proc: "fx-unit", blocks: 700, input: true, steps: [{ block: 0, msg: clock },
    { block: 10, msg: { t: "slot", slot: "beat", fx, beats: fx === "TRANS" ? 0.25 : 0.5, depth: 0.7, on: true } }, { block: 400, msg: { t: "slot", slot: "beat", on: false } }] };
}
scen.fx_pad_and_beat = { proc: "fx-unit", blocks: 500, input: true, steps: [{ block: 0, msg: clock }, { block: 5, msg: { t: "slot", slot: "beat", fx: "ECHO", beats: 0.75, depth: 0.5, on: true } },
  { block: 100, msg: { t: "slot", slot: "pad", fx: "ROLL", beats: 0.125, depth: 1, on: true } }, { block: 250, msg: { t: "slot", slot: "pad", on: false } }, { block: 300, msg: { t: "slot", slot: "beat", depth: 0.9, beats: 1 } }] };
const index = {};
for (const [k, s] of Object.entries(scen)) {
  const [L, R] = render(s.proc, s.blocks, s.steps, s.input ? [SL, SR_] : null);
  fs.writeFileSync(path.join(OUT, k + ".f32"), Buffer.concat([Buffer.from(L.buffer), Buffer.from(R.buffer)]));
  // the steps as JSON, with the track as a marker (the Swift side loads signal.f32)
  index[k] = { proc: s.proc, blocks: s.blocks, input: !!s.input, steps: s.steps.map((x) => ({ block: x.block, msg: x.msg.t === "load" ? { ...x.msg, L: "signal", R: "signal" } : x.msg })) };
}
fs.writeFileSync(path.join(OUT, "scenarios.json"), JSON.stringify(index, null, 1));
console.log(Object.keys(index).length, "scenarios");
