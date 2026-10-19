"""Loading a track never makes the playing deck stutter, in headless Chromium.

On a 2-core computer (like the 2017 MacBook Air) library analysis competed with the audio for the CPU and
the old track's audio was freed on the audio thread: the playing deck dropped out while a new track loaded.
Checks: with a deck playing, library analysis stops (a job under way is ended at once and its track goes
back in the queue) and starts again when everything stops; the replaced track's audio is handed back to
the page; and a probe on the audio thread sees no dropout while tracks load onto the other deck.

    python tests/test_loadstutter.py
"""
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cratebox as T  # noqa: E402

PROBE = """
class Probe extends AudioWorkletProcessor {
  constructor() { super(); this.last = 0; this.gaps = []; this.port.onmessage = (e) => { if (e.data === 'get') { this.port.postMessage(this.gaps); this.gaps = []; } }; }
  process() { const t = Date.now(); if (this.last && t - this.last > 12) this.gaps.push(t - this.last); this.last = t; return true; }
}
registerProcessor('probe', Probe);"""


def main():
    T.PORT = 8665
    srv = T.serve()
    check = T.check
    errors = []
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        page = b.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.add_init_script("Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 4 })")   # the Air: 2 cores, 4 threads
        page.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
        page.click("#startBtn")
        page.wait_for_function("window.cratebox && cratebox.A.ctx")
        check("a 4-thread computer counts as 2 cores: analysis pauses while playing", page.evaluate("cratebox.PAUSE_ANALYSIS_WHILE_PLAYING") is True)
        page.evaluate("""async (src) => { const c = cratebox.A.ctx;
          await c.audioWorklet.addModule(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
          window.probe = new AudioWorkletNode(c, 'probe'); const g = c.createGain(); g.gain.value = 0; probe.connect(g); g.connect(c.destination);
          window.gaps = () => new Promise(r => { probe.port.onmessage = (e) => r(e.data); probe.port.postMessage('get'); }); }""", PROBE)
        # 8 tracks (the 4 test tracks under two names each), none analysed yet
        names = sorted(os.listdir(os.path.join(T.ROOT, "tests", "music")))
        page.evaluate("""async (names) => { const files = [];
          for (const n of names) { const blob = await (await fetch('tests/music/' + encodeURIComponent(n))).blob();
            for (const k of [0, 1]) files.push({ file: new File([blob], `${k} ${n}`, { lastModified: 1 }), rel: `lib${k}/${n}` }); }
          await cratebox.addFiles(files); }""", names)
        page.wait_for_function("cratebox.lib.tracks.filter(t => t.bpm != null).length >= 1", timeout=60000)
        # load + play deck 1 while the library is being analysed
        page.evaluate("cratebox.lib.sel = 0; cratebox.loadSelected(0)")
        page.wait_for_function("cratebox.decks[0].loaded && !cratebox.decks[0].loading", timeout=60000)
        page.evaluate("cratebox.decks[0].togglePlay()")
        page.wait_for_timeout(300)
        busy = page.evaluate("cratebox.ANALYZERS.filter(w => w.pending > 0).length")
        n0 = page.evaluate("cratebox.lib.tracks.filter(t => t.bpm != null).length")
        page.wait_for_timeout(4000)
        n1 = page.evaluate("cratebox.lib.tracks.filter(t => t.bpm != null).length")
        check("pressing play stops library analysis at once (no worker busy with it)", busy == 0, f"{busy} busy")
        check("...and none runs while the deck plays", n1 == n0, f"{n0} -> {n1} analysed")
        check("...it says so", "paused while playing" in page.inner_text("#progress"), page.inner_text("#progress"))
        # loads onto deck 2 while deck 1 plays: the replaced track's audio comes back to the page
        page.evaluate("""(() => { window.freed = 0; const n = cratebox.A.decks[1].node, f = n.port.onmessage;
          n.port.onmessage = (e) => { if (e && e.data && e.data.freed) window.freed++; return f.call(n.port, e); }; })()""")
        page.evaluate("gaps()")
        worst = 0
        for k in [1, 2, 3, 1, 2]:
            page.evaluate(f"cratebox.lib.sel = {k}; cratebox.loadSelected(1)")
            page.wait_for_function(f"cratebox.decks[1].track && cratebox.decks[1].track.id === cratebox.lib.view[{k}].id && cratebox.decks[1].loaded && !cratebox.decks[1].loading", timeout=60000)
            page.wait_for_timeout(800)
            g = page.evaluate("gaps()")
            worst = max([worst] + g)
        check("the replaced track's audio is handed back (not freed on the audio thread)", page.evaluate("window.freed") >= 4, str(page.evaluate("window.freed")))
        # the probe's floor on a shared cloud machine is ~30-60 ms; the old build dropped out for ~250 ms
        check("no dropout on the playing deck while tracks load (audio thread never held up 120 ms+)", worst < 120, f"worst gap {worst} ms")
        check("deck 1 played on", page.evaluate("cratebox.decks[0].playing"))
        # stop: the library carries on
        page.evaluate("cratebox.decks[0].togglePlay()")
        page.wait_for_function("cratebox.lib.tracks.every(t => t.bpm != null)", timeout=120000)
        check("when everything stops, the library analysis finishes", True)
        b.close()
    srv.shutdown()
    check("no JavaScript errors", not errors, "; ".join(errors[:3]))
    failed = [n for n, ok in T.checks if not ok]
    print(f"\n{len(T.checks) - len(failed)}/{len(T.checks)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
