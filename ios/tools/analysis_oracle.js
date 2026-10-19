// The web app's track analysis (the ANALYZER in cratebox.html) on the synthetic test tracks
// (tests/make_tracks.py), downmixed the way the app does it (monoFor, 11025 Hz). The Swift port
// (CrateboxKit Analysis) must find the same BPM, grid, key, phrases and waveform.
//
//     node ios/tools/analysis_oracle.js cratebox.html tests/music ios/CrateboxKit/Tests/CrateboxKitTests/Fixtures/analysis.json
const fs = require("fs"), path = require("path");
const html = fs.readFileSync(process.argv[2], "utf8");
const a = html.indexOf("const ANALYZER = `") + "const ANALYZER = `".length;
const code = html.slice(a, html.indexOf("\n`;", a));
eval(code.replace(/^onmessage = /m, "var _om = ") + "\nglobal.analyze = analyze;");
function wav(file) {
  const b = fs.readFileSync(file);
  let o = 12, fmt, data;
  while (o < b.length) { const id = b.toString("ascii", o, o + 4), sz = b.readUInt32LE(o + 4); if (id === "fmt ") fmt = o + 8; if (id === "data") { data = [o + 8, sz]; break; } o += 8 + sz + (sz & 1); }
  const ch = b.readUInt16LE(fmt + 2), sr = b.readUInt32LE(fmt + 4), n = data[1] / (2 * ch);
  const chs = Array.from({ length: ch }, () => new Float32Array(n));
  for (let i = 0; i < n; i++) for (let c = 0; c < ch; c++) chs[c][i] = b.readInt16LE(data[0] + 2 * (i * ch + c)) / 32768;
  return { sampleRate: sr, length: n, numberOfChannels: ch, getChannelData: (c) => chs[c] };
}
function monoFor(buffer, target = 11025) {
  const f = Math.max(1, Math.round(buffer.sampleRate / target));
  const n = Math.floor(buffer.length / f);
  const out = new Float32Array(n);
  const chs = [];
  for (let c = 0; c < Math.min(2, buffer.numberOfChannels); c++) chs.push(buffer.getChannelData(c));
  const k = 1 / (f * chs.length);
  for (let i = 0; i < n; i++) { let s = 0; for (const ch of chs) for (let j = 0; j < f; j++) s += ch[i * f + j]; out[i] = s * k; }
  return { mono: out, fs: buffer.sampleRate / f };
}
const out = {};
for (const name of fs.readdirSync(process.argv[3]).filter((x) => x.endsWith(".wav")).sort()) {
  const { mono, fs: sr } = monoFor(wav(path.join(process.argv[3], name)));
  const r = analyze(mono, sr, [88, 176]);
  const sum = (u) => Array.from(u).reduce((p, q) => p + q, 0);
  out[name] = { fs: sr, n: mono.length, monoSum: Array.from(mono).reduce((p, q) => p + q, 0), bpm: r.bpm, firstBeat: r.firstBeat, gridConf: r.gridConf, key: r.key, keyConf: r.keyConf,
    phrases: r.phrases, duration: r.duration, wps: r.wps, frames: r.peak.length,
    wave: { peak: Array.from(r.peak), rms: Array.from(r.rms), low: Array.from(r.low), mid: Array.from(r.mid), high: Array.from(r.high) }, waveSums: [sum(r.peak), sum(r.rms), sum(r.low), sum(r.mid), sum(r.high)] };
  console.log(name, r.bpm, r.firstBeat.toFixed(4), r.key, r.phrases.length);
}
fs.writeFileSync(process.argv[4], JSON.stringify(out));
