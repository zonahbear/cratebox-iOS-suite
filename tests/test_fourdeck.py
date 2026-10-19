"""4-deck mode on a computer, and the interface size zoom on a big screen.

Checks: the 2/4 toggle (and that it's remembered), decks 3 and 4 load, play and sync, the crossfader sends
1 and 3 left and 2 and 4 right, hidden decks are muted, compact decks expand, the 4-channel mixer is in the
order 3 1 2 4, and on a 2560x1440 screen the app is scaled up with controls still landing where you click.

    python tests/test_fourdeck.py [screenshot-folder]
"""
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cratebox as T  # noqa: E402


def load_all(page, n):
    music = os.path.join(T.ROOT, "tests", "music")
    names = sorted(x for x in os.listdir(music) if x.endswith(".wav"))
    page.evaluate("""async (names) => { const files = [];
        for (const n of names) files.push({ file: new File([await (await fetch('tests/music/' + encodeURIComponent(n))).blob()], n, { lastModified: 1 }), rel: 'music/' + n });
        await cratebox.addFiles(files); }""", names)
    page.wait_for_function(f"cratebox.lib.tracks.length === {len(names)}")
    page.evaluate(f"for (let i = 0; i < {n}; i++) {{ cratebox.lib.sel = i; cratebox.loadSelected(i); }}")
    page.wait_for_function(f"cratebox.decks.slice(0, {n}).every(d => d.loaded)", timeout=90000)


def main():
    shots = sys.argv[1] if len(sys.argv) > 1 else None
    T.PORT = 8655
    srv = T.serve()
    check = T.check
    errors = []
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        ctx = b.new_context(viewport={"width": 1440, "height": 900})
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
        page.click("#startBtn")
        page.wait_for_function("window.cratebox && cratebox.A.ctx")
        vis = lambda sel: page.evaluate(f"(() => {{ const e = document.querySelector('{sel}'); return !!e && e.getBoundingClientRect().height > 0; }})()")
        check("starts in 2-deck mode: decks 3/4 and lanes 3/4 hidden", not vis('.deck[data-i="2"]') and not vis("#lane3") and page.inner_text("#fourBtn") == "4 DECKS")
        page.click("#fourBtn")
        check("4 DECKS shows decks 3 and 4, four lanes, a 4-channel mixer", vis('.deck[data-i="2"]') and vis('.deck[data-i="3"]') and vis("#lane3") and vis("#mixer .strip.s3") and page.inner_text("#fourBtn") == "2 DECKS")
        order = page.evaluate("[...document.querySelectorAll('#mixer > .strip')].sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left).map(s => +s.dataset.i + 1)")
        check("mixer channels left to right: 3 1 2 4", order == [3, 1, 2, 4], str(order))
        fo = page.evaluate("[...document.querySelectorAll('#mixer .faders .vslider')].sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left).map(e => e.parentElement.querySelector('.slabel').textContent)")
        check("faders in the same order", fo == ["CH 3", "CH 1", "CH 2", "CH 4"], str(fo))

        load_all(page, 4)
        page.evaluate("cratebox.decks[2].togglePlay(); cratebox.decks[0].togglePlay()")
        page.wait_for_timeout(300)
        # crossfader hard left: decks 1 and 3 open, 2 and 4 shut
        gains = page.evaluate("""new Promise(res => { const C = cratebox;
          // move the crossfader through its widget so the mixer applies it
          const el = document.querySelector('#mixer .xfade .hslider'), r = el.getBoundingClientRect();
          el.dispatchEvent(new PointerEvent('pointerdown', { clientX: r.left + 1, clientY: r.top + r.height / 2, pointerId: 1, bubbles: true }));
          setTimeout(() => res(C.A.decks.map(c => +c.xf.gain.value.toFixed(2))), 200); })""")
        check("crossfader left: decks 1 and 3 audible, 2 and 4 shut", gains[0] > 0.9 and gains[2] > 0.9 and gains[1] < 0.01 and gains[3] < 0.01, str(gains))

        # deck 3 syncs to deck 1 (playing, not synced) and holds the beat
        page.evaluate("cratebox.decks[2].setSync(true)")
        page.wait_for_timeout(2500)
        s3 = page.evaluate("(() => { const d = cratebox.decks[2], m = d.master(); return { m: m && m.i, bpm: d.effBpm(), mb: m && m.effBpm(), mult: d.syncMult, pe: d.phaseErr, lit: document.querySelector('.deck[data-i=\"2\"] .msync').classList.contains('lit') }; })()")
        ratio = s3["bpm"] / s3["mb"] if s3["mb"] else 0
        check("deck 3 SYNC follows deck 1 (half/double time aware) and locks", s3["m"] == 0 and min(abs(ratio - k) for k in (0.5, 1, 2)) < 0.002 and s3["pe"] is not None and abs(s3["pe"]) < 0.01 and s3["lit"], str(s3))

        # compact deck 4 expands to a full deck and back
        page.click('.deck[data-i="3"] .expand')
        full = vis('.deck[data-i="3"] .jog') and vis('.deck[data-i="3"] .pads')
        page.click('.deck[data-i="3"] .expand')
        check("deck 4: ⤢ opens the full deck, again makes it compact", full and not vis('.deck[data-i="3"] .jog'))
        if shots:
            page.screenshot(path=os.path.join(shots, "fourdeck-1440x900.png"))

        # back to 2 decks (once deck 3 is stopped: a playing deck is never cut off): muted, sync off, remembered
        page.evaluate("cratebox.decks[2].togglePlay()")
        page.click("#fourBtn")
        st = page.evaluate("({ playing: cratebox.decks[2].playing, sync: cratebox.decks[2].sync, xf: cratebox.A.decks[2].xf.gain.value, pref: localStorage.getItem('cb.four') })")
        check("2 DECKS: deck 3 muted, sync off, choice saved", not st["playing"] and not st["sync"] and st["pref"] == "0", str(st))
        page.click("#fourBtn")
        page.reload()
        page.click("#startBtn")
        page.wait_for_function("window.cratebox && cratebox.A.ctx")
        check("4-deck mode is remembered after a reload", page.evaluate("document.documentElement.classList.contains('four')"))
        load_all(page, 4)
        # decks 3 and 4 expanded (⤢): the full deck layout, like decks 1 and 2 (tempo | jog | controls,
        # mirrored on deck 4), with nothing on top of anything else
        page.click("#fourBtn") if not page.evaluate("document.documentElement.classList.contains('four')") else None
        for i in (2, 3):
            if page.evaluate(f"document.querySelector('.deck[data-i=\"{i}\"]').classList.contains('compact')"):
                page.click(f'.deck[data-i="{i}"] .expand')
        page.wait_for_timeout(300)
        ex = page.evaluate("""(() => { const out = {}; const r = (e) => e.getBoundingClientRect();
          for (const i of [2, 3]) { const d = document.querySelector(`.deck[data-i="${i}"]`);
            const els = [...d.querySelectorAll('.jog, .pad, .round, .ctrl button, .vslider, .modes button')].filter(e => r(e).width > 0);
            let over = 0; for (let a = 0; a < els.length; a++) for (let b = a + 1; b < els.length; b++) { const A = r(els[a]), B = r(els[b]);
              if (els[a].contains(els[b]) || els[b].contains(els[a])) continue;
              if (Math.min(A.right, B.right) - Math.max(A.left, B.left) > 2 && Math.min(A.bottom, B.bottom) - Math.max(A.top, B.top) > 2) over++; }
            const jog = r(d.querySelector('.jog')), pitch = r(d.querySelector('.pitchwrap .vslider')), ctrl = r(d.querySelector('.ctrl'));
            out[i + 1] = { over, order: i === 2 ? pitch.right <= jog.left && jog.right <= ctrl.left : ctrl.right <= jog.left && jog.right <= pitch.left }; }
          return out; })()""")
        check("expanded decks 3 and 4: full layout (tempo | jog | controls), nothing overlapping", all(v["over"] == 0 and v["order"] for v in ex.values()), str(ex))
        for i in (2, 3): page.click(f'.deck[data-i="{i}"] .expand')
        ctx.close()

        # a 1440p screen: the app is scaled up (interface size Auto), and clicks still land right
        ctx = b.new_context(viewport={"width": 2560, "height": 1440})
        ctx.add_init_script("localStorage.setItem('cb.four', '1')")
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
        page.click("#startBtn")
        page.wait_for_function("window.cratebox && cratebox.A.ctx")
        z = page.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--uiz')")
        app = page.evaluate("(() => { const r = document.querySelector('#app').getBoundingClientRect(); return [r.width, r.height, document.documentElement.scrollHeight]; })()")
        check("1440p: interface scaled up 1.6x and fills the window exactly", z.strip() == "1.6" and abs(app[0] - 2560) < 2 and abs(app[1] - 1440) < 2 and app[2] <= 1441, f"{z} {app}")
        r = page.evaluate("(() => { const r = document.querySelector('#mixer .faders .fcol:first-child .vslider').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()")
        page.mouse.click(r[0] + r[2] / 2, r[1] + 4 + (r[3] - 8) * 0.75)       # a quarter of the way up the fader
        f0 = page.evaluate("cratebox.M.fader[0]")
        check("1440p: clicking a fader sets it where you clicked", abs(f0 - 0.25) < 0.03, f"{f0:.3f}")
        load_all(page, 2)
        page.wait_for_timeout(300)
        lane = page.evaluate("(() => { const c = document.querySelector('#lane0'), r = c.getBoundingClientRect(); return [c.width, Math.round(r.width * devicePixelRatio)]; })()")
        check("1440p: waveforms drawn at full resolution (sharp)", abs(lane[0] - lane[1]) <= 2, str(lane))
        t0 = page.evaluate("cratebox.decks[0].now()")
        lr = page.evaluate("(() => { const r = document.querySelector('#lane0').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()")
        page.mouse.move(lr[0] + lr[2] / 2, lr[1] + lr[3] / 2)
        page.mouse.down()
        page.mouse.move(lr[0] + lr[2] / 2 - lr[2] / 4, lr[1] + lr[3] / 2, steps=8)
        page.mouse.up()
        moved = page.evaluate("cratebox.decks[0].now()") - t0
        check("1440p: dragging the waveform a quarter of its width moves a quarter of the view", abs(moved - 8 / 4) < 0.25, f"{moved:.2f}s")
        if shots:
            page.screenshot(path=os.path.join(shots, "fourdeck-2560x1440.png"))
        ctx.close()
        b.close()
    srv.shutdown()
    check("no JavaScript errors", not errors, "; ".join(errors[:3]))
    failed = [n for n, ok in T.checks if not ok]
    print(f"\n{len(T.checks) - len(failed)}/{len(T.checks)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
