"""iPhone / iPad mode, emulated in headless Chromium: no Web MIDI, no folder access, no output picking,
touch input. Phone: the landscape layout for an iPhone 16 Pro Max (956 x 440). Imports tracks,
reloads to check they persist, loads from the library tab and plays by touch, checks the layout fits.

    python tests/test_ios.py [screenshot-prefix]
"""
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cratebox as T  # noqa: E402  (server + check helpers)

IPHONE_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 "
             "(KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1")
IPAD_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
           "Version/18.5 Safari/605.1.15")
# take away what iOS browsers don't have
STRIP = """
delete Navigator.prototype.requestMIDIAccess;
delete window.showDirectoryPicker;
delete AudioContext.prototype.setSinkId;
navigator.audioSession = { type: "auto" };
"""
LAYOUT = """(() => {
  const W = innerWidth, H = innerHeight, r = (e) => e.getBoundingClientRect();
  const inView = (e) => { const b = r(e); return b.width > 0 && b.left >= -1 && b.top >= -1 && b.right <= W + 1 && b.bottom <= H + 1; };
  const sel = [".deck .round.play", ".deck .round.cue", ".deck .pad", ".deck .jog", ".deck .sync", ".deck .vslider",
               "#mixer .vslider", "#mixer .hslider", "#mixer .cuebtn", "#mixer .knob svg", ".deck .overview", "#lane0", "#lane1"];
  const out = [];
  for (const s of sel) for (const e of document.querySelectorAll(s)) if (!inView(e)) out.push(s + " " + JSON.stringify(r(e)));
  const l0 = r(document.querySelector("#lane0")), l1 = r(document.querySelector("#lane1"));
  // pads must not overlap each other or the transport buttons
  const boxes = [...document.querySelectorAll(".deck .pad, .deck .round, .deck .sq")].filter((e) => r(e).width > 0).map(r);
  let overlaps = 0;
  for (let a = 0; a < boxes.length; a++) for (let b = a + 1; b < boxes.length; b++) {
    const A = boxes[a], B = boxes[b];
    if (A.left < B.right - 1 && B.left < A.right - 1 && A.top < B.bottom - 1 && B.top < A.bottom - 1) overlaps++;
  }
  return { outside: out, lanes: [l0.top, l0.bottom, l1.top, l1.bottom], overlaps,
           scroll: [document.documentElement.scrollWidth, document.documentElement.scrollHeight, W, H],
           padH: r(document.querySelector(".deck .pad")).height, padW: r(document.querySelector(".deck .pad")).width,
           play: r(document.querySelector(".deck .round.play")).width };
})()"""


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else None
    T.PORT = 8623
    srv = T.serve()
    url = f"http://127.0.0.1:{T.PORT}/cratebox.html"
    music = os.path.join(T.ROOT, "tests", "music")
    files = [os.path.join(music, n) for n in sorted(os.listdir(music)) if n.endswith(("126.wav", "140.wav"))]
    errors = []
    check = T.check
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        ctx = b.new_context(viewport={"width": 956, "height": 440}, screen={"width": 440, "height": 956},
                            is_mobile=True, has_touch=True, user_agent=IPHONE_UA, device_scale_factor=3)
        ctx.add_init_script(STRIP)
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("console", lambda m: m.type == "error" and "ERR_TUNNEL" not in m.text and "404" not in m.text and errors.append(m.text))
        page.goto(url)
        start_txt = page.inner_text("#start")
        check("start screen explains there's no MIDI in Safari and names a MIDI browser app", "has no MIDI" in start_txt and "MIDIWeb Browser" in start_txt)
        check("phone layout switched on", page.evaluate("document.documentElement.classList.contains('phone')"))
        page.tap("#startBtn")
        page.wait_for_function("window.cratebox.A.ctx && window.cratebox.A.decks.length >= 2")
        st = page.evaluate("""({ session: navigator.audioSession.type, add: document.querySelector('#addFolder').textContent,
            hp: [...document.querySelectorAll('#hpSel option')].map(o => o.value) })""")
        check("audio plays through the silent switch (audio session = playback)", st["session"] == "playback")
        check("music is imported, not picked as a folder", st["add"] == "Add music", st["add"])
        check("only headphone modes that work on one stereo output", st["hp"] == ["auto", "split", "off"], str(st["hp"]))
        page.tap("#setOpen")
        check("settings sheet opens with the headphone options", page.is_visible("#setSheet #hpSel") and page.is_visible("#setSheet #waveSel"))
        page.tap("#setSheet [data-close]")
        check("settings sheet closes", page.is_hidden("#setSheet"))

        page.tap(".ptabs button[data-tab=lib]")
        page.set_input_files("#filesInput", files)
        page.wait_for_function("cratebox.lib.tracks.length === 2 && cratebox.lib.tracks.every(t => t.bpm != null && t.stored)", timeout=120000)
        check("imported tracks are analysed", page.evaluate("cratebox.lib.tracks.map(t => Math.round(t.bpm)).sort().join()") == "126,140")

        # reload: the library must come back from the browser's own storage
        page.reload()
        page.tap("#startBtn")
        page.wait_for_function("cratebox.lib.tracks.length === 2", timeout=30000)
        back = page.evaluate("cratebox.lib.tracks.filter(t => t.stored && t.bpm).length")
        check("imported library survives a reload", back == 2)

        # crash-loop guard: pretend the tab died (out of memory) while reading a track that still needs analysis
        bad = page.evaluate("""(async () => {
            const t = cratebox.lib.tracks[0];
            await new Promise((res) => { const r = indexedDB.open('cratebox'); r.onsuccess = () => {
                const tx = r.result.transaction('analysis', 'readwrite'); tx.objectStore('analysis').delete(t.id); tx.oncomplete = res; }; });
            localStorage.setItem('cb.inflight', JSON.stringify({ id: t.id, title: t.title }));
            return t.id; })()""")
        page.reload()
        page.tap("#startBtn")
        page.wait_for_function("cratebox.lib.tracks.length === 2", timeout=30000)
        page.wait_for_timeout(3000)
        g = page.evaluate("""(id) => ({ toast: document.querySelector('#toast').textContent, inflight: localStorage.getItem('cb.inflight'),
            t: (t => ({ bpm: t.bpm, ver: t.ver }))(cratebox.lib.tracks.find(t => t.id === id)) })""", bad)
        check("after a crash on a track, it isn't re-analysed in a loop", "stopped while reading" in g["toast"] and not g["inflight"] and not g["t"]["ver"], str(g))

        # library tab: big rows with 1 / 2 load buttons
        page.tap(".ptabs button[data-tab=lib]")
        page.wait_for_timeout(200)
        rowh = page.evaluate("document.querySelector('#list .trow').getBoundingClientRect().height")
        check("library rows are thumb-sized", rowh >= 44, f"{rowh}px")
        if prefix:
            page.screenshot(path=f"{prefix}-iphone-library.png")
        page.tap("#list .trow >> nth=0 >> .ld[data-d='0']")
        page.tap("#list .trow >> nth=1 >> .ld[data-d='1']")
        page.wait_for_function("cratebox.decks[0].loaded && cratebox.decks[1].loaded", timeout=60000)
        page.tap(".ptabs button[data-tab=mix]")
        page.wait_for_timeout(300)
        page.tap(".deck[data-i='0'] .round.play")
        t0 = page.evaluate("cratebox.decks[0].now()")
        page.wait_for_timeout(1200)
        t1 = page.evaluate("cratebox.decks[0].now()")
        check("load from the library tab, tap play: deck 1 plays", page.evaluate("cratebox.decks[0].playing") and t1 - t0 > 0.8, f"advanced {t1 - t0:.2f}s")
        lv = page.evaluate("""(async () => { let m = 0; const a = cratebox.A.decks[0].meterL, buf = new Float32Array(512);
            for (let k = 0; k < 20; k++) { a.getFloatTimeDomainData(buf); for (const v of buf) m = Math.max(m, Math.abs(v)); await new Promise(r => setTimeout(r, 30)); }
            return m; })()""")
        check("16-bit low-memory audio plays at the right level", 0.2 < lv < 1.2, f"peak {lv:.2f}")

        for h in (440, 380):     # full screen (Home Screen app), then Safari with its toolbar
            page.set_viewport_size({"width": 956, "height": h})
            page.wait_for_timeout(400)
            L = page.evaluate(LAYOUT)
            check(f"956x{h}: every control on screen, no scrolling", not L["outside"] and L["scroll"][0] <= L["scroll"][2] + 1 and L["scroll"][1] <= L["scroll"][3] + 1,
                  "; ".join(L["outside"][:3]) + f" scroll {L['scroll']}")
            check(f"956x{h}: waveforms stacked, not overlapping", L["lanes"][1] <= L["lanes"][2] + 0.5 and abs((L["lanes"][1] - L["lanes"][0]) - (L["lanes"][3] - L["lanes"][2])) < 1, str(L["lanes"]))
            check(f"956x{h}: buttons and pads don't overlap", L["overlaps"] == 0, f"{L['overlaps']} overlaps; pad {L['padW']:.0f}x{L['padH']:.0f}, play {L['play']:.0f}")
            if prefix:
                page.screenshot(path=f"{prefix}-iphone-{h}.png")
        # lanes stay put across many frames (the iOS growth bug)
        hs = page.evaluate("new Promise(r => setTimeout(() => r([lane0.clientHeight, lane1.clientHeight]), 1500))")
        check("waveform lanes keep their height", hs[0] == hs[1] and hs[0] < 60, str(hs))
        # channel faders: start at 100%, and the handle is drawn where a touch would put it (0% = bottom)
        geo = "(() => { const sl = document.querySelectorAll('#mixer .faders .vslider')[0], r = sl.getBoundingClientRect(), t = sl.querySelector('.thumb').getBoundingClientRect(); return { x: r.left + r.width / 2, top: r.top, bottom: r.bottom, h: r.height, thumb: t.top + t.height / 2 - r.top }; })()"
        g0 = page.evaluate(geo)
        fd = {"start": page.evaluate("cratebox.M.fader[0]"), "top": g0["thumb"], "h": g0["h"]}
        page.mouse.click(g0["x"], g0["bottom"] - 1)
        fd["zeroVal"] = page.evaluate("cratebox.M.fader[0]"); fd["zeroAt"] = page.evaluate(geo)["thumb"]
        page.mouse.click(g0["x"], g0["top"] + 1)
        fd["fullVal"] = page.evaluate("cratebox.M.fader[0]")
        check("channel faders start at 100%", fd["start"] == 1, str(fd))
        check("fader handle is drawn where the finger is: 0% at the bottom, 100% at the top",
              fd["zeroVal"] < 0.01 and abs(fd["zeroAt"] - (fd["h"] - 4)) < 2 and abs(fd["top"] - 4) < 2 and fd["fullVal"] > 0.99, str(fd))

        # deck extras sheet
        page.tap(".deck[data-i='0'] .pbtns button:has-text('⋯')")
        check("⋯ opens loops, beat jump and the grid editor", page.is_visible("#deckSheet .gridbar") and page.is_visible("#deckSheet button:has-text('RELOOP')"))
        if prefix:
            page.screenshot(path=f"{prefix}-iphone-sheet.png")
        page.tap("#deckSheet [data-close]")

        # hot cue by touch, then hold the pad to delete it
        page.tap(".deck[data-i='0'] .pad >> nth=0")
        had = page.evaluate("cratebox.decks[0].hot[0]") is not None
        page.evaluate("""() => { const b = document.querySelectorAll(".deck[data-i='0'] .pad")[0];
            b.dispatchEvent(new PointerEvent('pointerdown', { pointerType: 'touch', bubbles: true })); }""")
        page.wait_for_timeout(1100)
        page.evaluate("""() => { const b = document.querySelectorAll(".deck[data-i='0'] .pad")[0];
            b.dispatchEvent(new PointerEvent('pointerup', { pointerType: 'touch', bubbles: true })); }""")
        check("tap sets a hot cue, holding the pad deletes it", had and page.evaluate("cratebox.decks[0].hot[0]") is None)

        # a phone call / Siri suspends the audio and holds it (resume fails until the call ends):
        # a banner says so, the app stays usable, and once it can, the audio comes back
        page.evaluate("(() => { const c = cratebox.A.ctx; c._resume = c.resume; c.resume = () => Promise.reject(new Error('interrupted')); c.suspend(); })()")
        page.wait_for_timeout(1500)
        shown = page.is_visible("#resume")
        free = page.evaluate("(() => { const r = document.querySelector('.deck .round.play').getBoundingClientRect(); return !document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2).closest('#resume'); })()")
        page.evaluate("(() => { const c = cratebox.A.ctx; c.resume = c._resume; })()")      # the call ends
        page.tap("#resume button")
        page.wait_for_timeout(500)
        check("audio interruption: banner shows, decks stay usable, tapping resumes", shown and free and page.evaluate("cratebox.A.ctx.state") == "running" and page.is_hidden("#resume"), f"shown {shown}, decks free {free}")

        page.set_viewport_size({"width": 440, "height": 956})
        page.wait_for_timeout(200)
        check("portrait phone asks to turn sideways", page.is_visible("#rotate"))
        if prefix:
            page.screenshot(path=f"{prefix}-iphone-portrait.png")
        page.set_viewport_size({"width": 956, "height": 440})
        sw = page.evaluate("navigator.serviceWorker.getRegistration().then(r => !!r)")
        check("offline support (service worker) registered", sw)
        ctx.close()

        # iPad: the full layout, touch enabled
        ctx = b.new_context(viewport={"width": 1180, "height": 820}, screen={"width": 820, "height": 1180},
                            is_mobile=True, has_touch=True, user_agent=IPAD_UA, device_scale_factor=2)
        ctx.add_init_script(STRIP + "Object.defineProperty(navigator, 'maxTouchPoints', { get: () => 5 });")
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(url)
        page.tap("#startBtn")
        page.wait_for_function("window.cratebox.A.ctx")
        ip = page.evaluate("({ phone: document.documentElement.classList.contains('phone'), w: document.documentElement.scrollWidth, W: innerWidth })")
        check("iPad gets the full layout, nothing sticks out sideways", not ip["phone"] and ip["w"] <= ip["W"] + 1, str(ip))
        if prefix:
            page.screenshot(path=f"{prefix}-ipad.png")
        b.close()
    srv.shutdown()
    check("no JavaScript errors", not errors, "; ".join(errors[:3]))
    failed = [n for n, ok in T.checks if not ok]
    print(f"\n{len(T.checks) - len(failed)}/{len(T.checks)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
