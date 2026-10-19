// =====================================================================================
//  rekordbox: USB/SD exports (export.pdb + ANLZ files) and rekordbox XML
// =====================================================================================
// export.pdb ("Device Library") and ANLZ layouts follow Deep Symmetry's reverse-engineering in
// crate-digger (rekordbox_pdb.ksy / rekordbox_anlz.ksy). The only thing Cratebox ever writes to a stick is
// the playlist tables of export.pdb (RB.writePlaylists); tracks, analysis files and everything else stay as
// rekordbox wrote them.

const RB = {};
RB.pdbString = function (dv, pos) {
  const lk = dv.getUint8(pos);
  if (lk === 0x40 || lk === 0x90) {
    const len = dv.getUint16(pos + 1, true);
    const bytes = new Uint8Array(dv.buffer, dv.byteOffset + pos + 4, Math.max(0, len - 4));
    return new TextDecoder(lk === 0x40 ? "latin1" : "utf-16le").decode(bytes).replace(/\0+$/, "");
  }
  const n = (lk >> 1) - 1;
  if (n <= 0) return "";
  return new TextDecoder("latin1").decode(new Uint8Array(dv.buffer, dv.byteOffset + pos + 1, n));
};
RB.PAGE = { tracks: 0, genres: 1, artists: 2, albums: 3, labels: 4, keys: 5, colors: 6, playlistTree: 7, playlistEntries: 8, artwork: 13 };
// every present row of one table: calls fn(dataView, rowOffsetInFile)
RB.pdbRows = function (dv, type, fn) {
  const lenPage = dv.getUint32(4, true), numTables = dv.getUint32(8, true);
  for (let t = 0; t < numTables; t++) {
    const tp = 28 + t * 16;
    if (dv.getUint32(tp, true) !== type) continue;
    let page = dv.getUint32(tp + 8, true);
    const last = dv.getUint32(tp + 12, true), seen = new Set();
    while (!seen.has(page) && (page + 1) * lenPage <= dv.byteLength) {
      seen.add(page);
      const p = page * lenPage;
      if (dv.getUint32(p + 8, true) !== type) break;
      const packed = dv.getUint8(p + 24) | (dv.getUint8(p + 25) << 8) | (dv.getUint8(p + 26) << 16);
      const numOffsets = packed & 0x1fff, flags = dv.getUint8(p + 27);
      if ((flags & 0x40) === 0 && numOffsets > 0) {
        const groups = Math.floor((numOffsets - 1) / 16) + 1;
        for (let g = 0; g < groups; g++) {
          const base = p + lenPage - g * 0x24;
          const present = dv.getUint16(base - 4, true);
          for (let r = 0; r < 16 && g * 16 + r < numOffsets; r++) {
            if (!((present >> r) & 1)) continue;
            const ofs = dv.getUint16(base - (6 + 2 * r), true);
            fn(dv, p + 40 + ofs);
          }
        }
      }
      if (page === last) break;
      page = dv.getUint32(p + 12, true);
    }
  }
};
RB.parsePdb = function (buf) {
  const dv = new DataView(buf), S = RB.pdbString;
  const named = (type, idAt, nameFn) => {
    const m = new Map();
    RB.pdbRows(dv, type, (v, o) => { try { m.set(v.getUint32(o + idAt, true), nameFn(v, o)); } catch (e) {} });
    return m;
  };
  const nearFar = (nearAt, farAt) => (v, o) => {
    const sub = v.getUint16(o, true);
    return S(v, o + ((sub & 0x04) ? v.getUint16(o + farAt, true) : v.getUint8(o + nearAt)));
  };
  const artists = named(RB.PAGE.artists, 4, nearFar(9, 0x0a));
  const albums = named(RB.PAGE.albums, 12, nearFar(21, 0x16));
  const genres = named(RB.PAGE.genres, 0, (v, o) => S(v, o + 4));
  const keys = named(RB.PAGE.keys, 0, (v, o) => S(v, o + 8));
  const labels = named(RB.PAGE.labels, 0, (v, o) => S(v, o + 4));
  const tracks = [];
  RB.pdbRows(dv, RB.PAGE.tracks, (v, o) => {
    try {
      const str = (k) => S(v, o + v.getUint16(o + 94 + 2 * k, true));
      tracks.push({
        id: v.getUint32(o + 72, true), title: str(17), artist: artists.get(v.getUint32(o + 68, true)) || "",
        album: albums.get(v.getUint32(o + 64, true)) || "", genre: genres.get(v.getUint32(o + 60, true)) || "",
        label: labels.get(v.getUint32(o + 40, true)) || "", key: keys.get(v.getUint32(o + 32, true)) || "",
        bpm: v.getUint32(o + 56, true) / 100, duration: v.getUint16(o + 84, true), size: v.getUint32(o + 16, true),
        sampleRate: v.getUint32(o + 8, true), rating: v.getUint8(o + 89), color: v.getUint8(o + 88),
        path: str(20), filename: str(19), anlzPath: str(14), comment: str(16), dateAdded: str(10),
      });
    } catch (e) {}
  });
  const tree = [];
  RB.pdbRows(dv, RB.PAGE.playlistTree, (v, o) => {
    try { tree.push({ parent: v.getUint32(o, true), unk: v.getUint32(o + 4, true), sort: v.getUint32(o + 8, true), id: v.getUint32(o + 12, true), folder: v.getUint32(o + 16, true) !== 0, name: S(v, o + 20) }); } catch (e) {}
  });
  const entries = [];
  RB.pdbRows(dv, RB.PAGE.playlistEntries, (v, o) => {
    try { entries.push({ index: v.getUint32(o, true), track: v.getUint32(o + 4, true), playlist: v.getUint32(o + 8, true) }); } catch (e) {}
  });
  const byList = new Map();
  for (const e of entries) { if (!byList.has(e.playlist)) byList.set(e.playlist, []); byList.get(e.playlist).push(e); }
  for (const n of tree) n.tracks = n.folder ? [] : (byList.get(n.id) || []).sort((a, b) => a.index - b.index).map((e) => e.track);
  tree.sort((a, b) => a.parent - b.parent || a.sort - b.sort);
  return { tracks, playlists: tree };
};

// ANLZ (.DAT/.EXT): beat grid, hot and memory cues, rekordbox's own phrase analysis
// ---- writing playlists back to export.pdb ----
// A DeviceSQL string: short ASCII (up to 126 chars), long ASCII (0x40) or long UTF-16LE (0x90)
RB.pdbStringBytes = function (s) {
  s = String(s == null ? "" : s);
  const ascii = /^[\x00-\x7f]*$/.test(s);
  if (ascii && s.length <= 126) {
    const b = new Uint8Array(1 + s.length); b[0] = ((s.length + 1) << 1) | 1;
    for (let i = 0; i < s.length; i++) b[1 + i] = s.charCodeAt(i);
    return b;
  }
  const n = ascii ? s.length : s.length * 2, b = new Uint8Array(4 + n), v = new DataView(b.buffer);
  b[0] = ascii ? 0x40 : 0x90; v.setUint16(1, n + 4, true); b[3] = 0;
  for (let i = 0; i < s.length; i++) ascii ? (b[4 + i] = s.charCodeAt(i)) : v.setUint16(4 + 2 * i, s.charCodeAt(i), true);
  return b;
};
// Rewrites the playlist tree and playlist entry tables of an export.pdb and returns the new file
// (a new ArrayBuffer; the input is untouched). nodes: [{ id, parent, folder, name, tracks: [rekordbox
// track id], unk? }] in the order they should show (siblings are numbered in that order). Each table's
// rows are packed afresh into the data pages it already has, like a fresh export (no deleted rows);
// when they don't fit, the table grows by a page the way rekordbox grows it (its "empty candidate"
// page becomes the new last page and a new candidate is taken from the header's next unused page).
// The index pages and every other table are left exactly as they were.
RB.writePlaylists = function (buf, nodes) {
  const src = new DataView(buf);
  const PS = src.getUint32(4, true), NT = src.getUint32(8, true);
  if (PS < 512 || PS > 65536 || NT < 9 || NT > 64) throw new Error("not an export.pdb");
  const HEAP = 0x28;
  // rows for each table
  const ids = new Set();
  for (const n of nodes) {
    if (!(n.id > 0) || ids.has(n.id)) throw new Error("bad playlist id " + n.id);
    ids.add(n.id);
  }
  for (const n of nodes) if (n.parent && !ids.has(n.parent)) throw new Error("playlist parent missing");
  const sortOf = new Map(), seenParent = new Map();
  for (const n of nodes) { const k = n.parent || 0, c = seenParent.get(k) || 0; sortOf.set(n.id, c); seenParent.set(k, c + 1); }
  const treeRows = nodes.map((n) => {
    const name = RB.pdbStringBytes(n.name), r = new Uint8Array(20 + name.length), v = new DataView(r.buffer);
    v.setUint32(0, n.parent || 0, true); v.setUint32(4, n.unk || 0, true); v.setUint32(8, sortOf.get(n.id), true);
    v.setUint32(12, n.id, true); v.setUint32(16, n.folder ? 1 : 0, true); r.set(name, 20);
    return r;
  });
  const entryRows = [];
  for (const n of nodes) {
    if (n.folder) continue;
    (n.tracks || []).forEach((tid, i) => {
      const r = new Uint8Array(12), v = new DataView(r.buffer);
      v.setUint32(0, i + 1, true); v.setUint32(4, tid, true); v.setUint32(8, n.id, true);
      entryRows.push(r);
    });
  }
  // the new file: a copy, grown when a table needs a page more
  let out = new Uint8Array(buf.slice(0)), dv = new DataView(out.buffer);
  const grow = (pages) => {
    if (pages * PS <= out.length) return;
    const o = new Uint8Array(pages * PS); o.set(out); out = o; dv = new DataView(out.buffer);
  };
  const seq = () => { const s = dv.getUint32(20, true); dv.setUint32(20, s + 1, true); return s; };
  const pack = (type, rows) => {
    let tp = -1;
    for (let t = 0; t < NT; t++) if (dv.getUint32(28 + t * 16, true) === type) tp = 28 + t * 16;
    if (tp < 0) throw new Error("export.pdb has no table " + type);
    // the table's data pages, in order (its first page is an index page)
    const pages = [], seen = new Set();
    let page = dv.getUint32(tp + 8, true);
    const last = dv.getUint32(tp + 12, true);
    for (;;) {
      if (seen.has(page) || (page + 1) * PS > dv.byteLength || dv.getUint32(page * PS + 8, true) !== type) throw new Error("export.pdb: broken page chain in table " + type);
      seen.add(page);
      if (!(dv.getUint8(page * PS + 27) & 0x40)) pages.push(page);
      if (page === last) break;
      page = dv.getUint32(page * PS + 12, true);
    }
    if (!pages.length) throw new Error("export.pdb: table " + type + " has no data pages");
    // share the rows out over pages: heap from the start, row index (groups of 16) from the end
    const fits = (used, n, len) => {
      const idx = Math.floor((n + 1) / 16) * 36 + ((n + 1) % 16 ? 4 + 2 * ((n + 1) % 16) : 0);
      return HEAP + used + ((len + 3) & ~3) + idx <= PS;
    };
    const plan = [[]];
    let used = 0;
    for (const r of rows) {
      if (r.length + HEAP + 6 > PS) throw new Error("row too big");
      if (!fits(used, plan[plan.length - 1].length, r.length)) { plan.push([]); used = 0; }
      plan[plan.length - 1].push(r); used += (r.length + 3) & ~3;
    }
    while (plan.length > pages.length) {
      // a new last page, the way rekordbox adds one
      const cand = dv.getUint32(tp + 4, true), nextU = dv.getUint32(12, true);
      if (seen.has(cand) || cand <= 0 || cand >= nextU) throw new Error("export.pdb: no free page for table " + type);
      grow(cand + 1);
      const prev = pages[pages.length - 1];
      dv.setUint32(prev * PS + 12, cand, true);
      out.fill(0, cand * PS, (cand + 1) * PS);
      dv.setUint32(cand * PS + 4, cand, true); dv.setUint32(cand * PS + 8, type, true); dv.setUint32(cand * PS + 12, nextU, true);
      dv.setUint32(tp + 4, nextU, true); dv.setUint32(tp + 12, cand, true); dv.setUint32(12, nextU + 1, true);
      pages.push(cand); seen.add(cand);
    }
    pages.forEach((pg, k) => {
      const o = pg * PS, list = plan[k] || [], n = list.length;
      out.fill(0, o + 0x10, o + PS);                     // keep page index, type and next page
      dv.setUint32(o + 0x10, seq(), true);
      const packed = n | (n << 13);
      dv.setUint8(o + 0x18, packed & 0xff); dv.setUint8(o + 0x19, (packed >> 8) & 0xff); dv.setUint8(o + 0x1a, (packed >> 16) & 0xff);
      dv.setUint8(o + 0x1b, 0x24);
      let at = 0;
      list.forEach((r, i) => {
        out.set(r, o + HEAP + at);
        const g = Math.floor(i / 16), j = i % 16, base = o + PS - g * 36;
        dv.setUint16(base - 6 - 2 * j, at, true);
        const bit = dv.getUint16(base - 4, true) | (1 << j);
        dv.setUint16(base - 4, bit, true); dv.setUint16(base - 2, bit, true);
        at += (r.length + 3) & ~3;
      });
      const idx = Math.floor(n / 16) * 36 + (n % 16 ? 4 + 2 * (n % 16) : 0);
      dv.setUint16(o + 0x1c, PS - HEAP - at - idx, true); dv.setUint16(o + 0x1e, at, true);
      dv.setUint16(o + 0x20, n ? n : 0x1fff, true); dv.setUint16(o + 0x22, n ? 0 : 0x1fff, true);
    });
  };
  pack(RB.PAGE.playlistTree, treeRows);
  pack(RB.PAGE.playlistEntries, entryRows);
  // read it back: the playlists must come out as asked and the tracks as they were
  const before = RB.parsePdb(buf), after = RB.parsePdb(out.buffer);
  const want = nodes.map((n) => [n.id, n.parent || 0, !!n.folder, String(n.name == null ? "" : n.name), n.folder ? [] : (n.tracks || []).slice()]);
  const got = new Map(after.playlists.map((p) => [p.id, [p.id, p.parent, p.folder, p.name, p.tracks]]));
  for (const w of want) if (JSON.stringify(got.get(w[0])) !== JSON.stringify(w)) throw new Error("export.pdb: playlist didn't read back: " + w[3]);
  if (after.playlists.length !== nodes.length) throw new Error("export.pdb: playlist count didn't read back");
  if (JSON.stringify(after.tracks) !== JSON.stringify(before.tracks)) throw new Error("export.pdb: tracks changed");
  return out.buffer;
};

RB.parseAnlz = function (buf) {
  const dv = new DataView(buf), out = { beats: [], hot: [], memory: [], phrases: null };
  if (dv.byteLength < 12 || dv.getUint32(0) !== 0x504d4149) return out;            // "PMAI"
  let pos = dv.getUint32(4);
  const tag = (s) => (s.charCodeAt(0) << 24 | s.charCodeAt(1) << 16 | s.charCodeAt(2) << 8 | s.charCodeAt(3)) >>> 0;
  const PQTZ = tag("PQTZ"), PCOB = tag("PCOB"), PCO2 = tag("PCO2"), PSSI = tag("PSSI");
  const cues2 = { hot: [], memory: [] };
  while (pos + 12 <= dv.byteLength) {
    const four = dv.getUint32(pos), lenTag = dv.getUint32(pos + 8), b = pos + 12;
    if (lenTag < 12) break;
    try {
      if (four === PQTZ) {
        const n = dv.getUint32(b + 8);
        for (let i = 0; i < n; i++) {
          const e = b + 12 + i * 8;
          out.beats.push({ n: dv.getUint16(e), bpm: dv.getUint16(e + 2) / 100, ms: dv.getUint32(e + 4) });
        }
      } else if (four === PCOB || four === PCO2) {
        const n = dv.getUint16(b + (four === PCOB ? 6 : 4));
        let e = b + (four === PCOB ? 12 : 8);
        for (let i = 0; i < n && e + 12 <= pos + lenTag; i++) {
          const lenEntry = dv.getUint32(e + 8), hot = dv.getUint32(e + 12);
          const typ = dv.getUint8(e + (four === PCOB ? 28 : 16));
          const ms = dv.getUint32(e + (four === PCOB ? 32 : 20)), loopMs = dv.getUint32(e + (four === PCOB ? 36 : 24));
          // (PCOB's status field only marks an active loop: 0 is an ordinary cue, so it's not a filter)
          const cue = { hot, ms, loopMs: typ === 2 ? loopMs : null };
          (four === PCO2 ? cues2 : out)[hot ? "hot" : "memory"].push(cue);
          e += lenEntry || 56;
        }
      } else if (four === PSSI) {
        const lenEntries = dv.getUint16(b + 4), bodyLen = lenTag - 12 - 6;
        const body = new Uint8Array(buf.slice(b + 6, b + 6 + bodyLen));
        const raw = (body[0] << 8) | body[1];
        if (raw > 20) {
          const m = [0xcb, 0xe1, 0xee, 0xfa, 0xe5, 0xee, 0xad, 0xee, 0xe9, 0xd2, 0xe9, 0xeb, 0xe1, 0xe9, 0xf3, 0xe8, 0xe9, 0xf4, 0xe1];
          for (let i = 0; i < body.length; i++) body[i] ^= (m[i % m.length] + lenEntries) & 0xff;
        }
        const bv = new DataView(body.buffer), mood = bv.getUint16(0), endBeat = bv.getUint16(8);
        const list = [];
        for (let i = 0; i < lenEntries; i++) {
          const e = 14 + i * 24;
          if (e + 6 > body.length) break;
          list.push({ beat: bv.getUint16(e + 2), kind: bv.getUint16(e + 4) });
        }
        out.phrases = { mood, endBeat, list };
      }
    } catch (e) {}
    pos += lenTag;
  }
  // the extended (.EXT) cue lists hold all eight hot cues: prefer them when present
  if (cues2.hot.length) out.hot = cues2.hot;
  if (cues2.memory.length) out.memory = cues2.memory;
  return out;
};
// rekordbox phrase names -> Cratebox's
RB.phraseLabel = function (mood, kind) {
  if (mood === 1) return { 1: "Intro", 2: "Build", 3: "Breakdown", 5: "Drop", 6: "Outro" }[kind] || "Groove";
  return { 1: "Intro", 8: "Breakdown", 9: "Drop", 10: "Outro" }[kind] || "Groove";
};
// beat grid + phrases in Cratebox's terms (constant tempo: first downbeat and the main BPM)
RB.gridFromBeats = function (beats) {
  if (!beats || beats.length < 2) return null;
  // the most common tempo, and the first downbeat
  const count = new Map();
  for (const b of beats) count.set(b.bpm, (count.get(b.bpm) || 0) + 1);
  const bpm = [...count.entries()].sort((a, b) => b[1] - a[1])[0][0];
  const down = beats.find((b) => b.n === 1) || beats[0];
  return { bpm, firstBeat: down.ms / 1000 };
};
RB.phrasesFrom = function (anlz) {
  const p = anlz.phrases, beats = anlz.beats;
  if (!p || !p.list.length || !beats.length) return null;
  const at = (beat) => (beats[Math.max(0, Math.min(beats.length - 1, beat - 1))].ms / 1000);
  return p.list.map((e, i) => {
    const next = i + 1 < p.list.length ? p.list[i + 1].beat : p.endBeat || e.beat + 32;
    return { start: at(e.beat), bars: Math.max(1, Math.round((next - e.beat) / 4)), label: RB.phraseLabel(p.mood, e.kind) };
  });
};

// ---- rekordbox XML (File > Export Collection in xml format) ----
RB.parseXml = function (text) {
  const doc = new DOMParser().parseFromString(text, "application/xml");
  if (doc.querySelector("parsererror") || !doc.querySelector("DJ_PLAYLISTS")) throw new Error("not a rekordbox XML file");
  const tracks = new Map();
  for (const t of doc.querySelectorAll("COLLECTION > TRACK")) {
    const a = (k) => t.getAttribute(k) || "";
    let loc = a("Location");
    try { loc = decodeURI(loc.replace(/^file:\/\/localhost/, "")); } catch (e) {}
    const tempo = t.querySelector("TEMPO");
    const marks = [...t.querySelectorAll("POSITION_MARK")].map((m) => ({
      num: +m.getAttribute("Num"), start: +m.getAttribute("Start"), end: m.getAttribute("End") != null ? +m.getAttribute("End") : null,
      type: +(m.getAttribute("Type") || 0), name: m.getAttribute("Name") || "",
    }));
    tracks.set(a("TrackID"), {
      id: a("TrackID"), title: a("Name"), artist: a("Artist"), album: a("Album"), genre: a("Genre"), key: a("Tonality"),
      bpm: +a("AverageBpm") || 0, duration: +a("TotalTime") || 0, size: +a("Size") || 0, location: loc,
      filename: loc.split(/[\\/]/).pop(), grid: tempo ? { bpm: +tempo.getAttribute("Bpm"), firstBeat: +tempo.getAttribute("Inizio"),
        beat: +(tempo.getAttribute("Battito") || 1) } : null, marks,
    });
  }
  const lists = [];
  const walk = (node, parent) => {
    for (const n of node.children) {
      if (n.tagName !== "NODE") continue;
      const folder = n.getAttribute("Type") === "0", name = n.getAttribute("Name") || "";
      const me = { name, folder, parent, tracks: folder ? [] : [...n.children].filter((c) => c.tagName === "TRACK").map((c) => c.getAttribute("Key")), key: lists.length };
      lists.push(me);
      if (folder) walk(n, me.key);
    }
  };
  const root = doc.querySelector("PLAYLISTS > NODE");
  if (root) walk(root, null);
  return { tracks, playlists: lists };
};
// "Am", "C#m", "Ebm", "F", "8A", "11B" -> Cratebox key index (0-11 major, 12-23 minor)
RB.keyIndex = function (s) {
  if (!s) return -1;
  s = s.trim();
  let m = /^(\d{1,2})\s*([AB])$/i.exec(s);
  if (m) {
    const num = +m[1], minor = m[2].toUpperCase() === "A";
    for (let k = 0; k < 24; k++) { const c = camelot(k); if (c.num === num && (c.letter === "A") === minor) return k; }
    return -1;
  }
  m = /^([A-G])([#♯b♭]?)\s*(m|min|minor)?$/i.exec(s.replace(/maj(or)?$/i, ""));
  if (!m) return -1;
  let pc = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }[m[1].toUpperCase()];
  if (m[2] === "#" || m[2] === "♯") pc++;
  if (m[2] === "b" || m[2] === "♭") pc--;
  pc = (pc + 12) % 12;
  return (m[3] ? 12 : 0) + pc;
};
const KEY_XML = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"];
RB.keyName = (k) => (k == null || k < 0 ? "" : KEY_XML[k % 12] + (k >= 12 ? "m" : ""));
