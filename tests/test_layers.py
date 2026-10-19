"""Deck layers: a 2-channel controller (the FLX4) playing decks 3 and 4, in headless Chromium.

In 4-deck mode the toggles at the top of the mixer switch the controller's left side between decks 1
and 3 and its right side between 2 and 4. Checks that every kind of control follows (buttons, jog,
load, channel fader and EQ, tempo), that the lights and VU meters show the deck being played, that
faders and knobs only take over once they reach the new deck's setting (no jumps), that the BEAT FX
channel lever follows, that the toggle can be learned onto a hardware button, and that leaving
4-deck mode puts the controller back on decks 1 and 2.

    python tests/test_layers.py [screenshot.png]
"""
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cratebox as T  # noqa: E402
from test_fourdeck import load_all  # noqa: E402

# the FLX4's own messages (from the built-in mapping): [status, data1] for deck 1 / deck 2
FIND = """([a, side]) => { const e = [...cratebox.MIDI.table.values()].find(e => e[2] === a && e[3] === side); return e ? [e[0], e[1], e[4]] : null; }"""


def main():
    T.PORT = 8662
    srv = T.serve()
    check = T.check
    errors = []
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        page = b.new_page(viewport={"width": 1600, "height": 1000})
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
        page.click("#startBtn")
        page.wait_for_function("window.cratebox && cratebox.A.ctx")
        # a stand-in FLX4: its mapping, and an output so lights are sent (and logged)
        page.evaluate("cratebox.useProfile('ddj-flx4'); cratebox.MIDI.name = 'DDJ-FLX4'; cratebox.MIDI.outputs = [{ send() {} }]")
        msg = lambda action, side: page.evaluate(FIND, [action, side])
        midi = lambda *bytes_: page.evaluate(f"cratebox.midiIn({list(bytes_)})")
        play0, play1 = msg("play", 0), msg("play", 1)
        fader0, tempo0, hi0, jog0, load0 = msg("fader", 0), msg("tempo", 0), msg("hi", 0), msg("jogTop", 0), msg("load", 0)
        check("the FLX4 mapping has the deck 1 controls", all([play0, play1, fader0, tempo0, hi0, jog0, load0]), str([play0, fader0, tempo0, hi0, jog0, load0]))

        vis = lambda sel: page.evaluate(f"(() => {{ const e = document.querySelector('{sel}'); return !!e && e.getBoundingClientRect().height > 0; }})()")
        check("2 decks: no layer toggles", not vis("#mixer .layers"))
        page.click("#fourBtn")
        check("4 decks: each deck's number over its own channel strip (3 1 | 2 4), above the knobs", vis("#mixer .layers") and page.evaluate("""(() => {
            const strip = (i) => document.querySelector(`#mixer > .strip[data-i="${i}"]`).getBoundingClientRect();
            return [0, 1, 2, 3].every((d) => { const c = document.querySelector(`#mixer .layercell[data-d="${d}"]`).getBoundingClientRect(), s = strip(d), mid = c.left + c.width / 2;
              return c.width > 0 && mid > s.left && mid < s.right && c.bottom <= s.top + 1; }); })()"""))
        cells = page.evaluate("[...document.querySelectorAll('#mixer .layercell')].sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left).map(c => c.textContent)")
        check("left to right: 3 1 2 4", cells == ["3", "1", "2", "4"], str(cells))
        check("starts on decks 1 and 2, those lit", page.evaluate("cratebox.MIDI.side.join()") == "0,1" and page.evaluate("[...document.querySelectorAll('#mixer .layercell.on')].map(c => c.textContent).sort().join()") == "1,2")
        pulse = page.evaluate("getComputedStyle(document.querySelector('#mixer .layercell.on')).animationName")
        check("the lit ones pulse (gently: brightness, not on/off)", pulse == "layerpulse", pulse)
        load_all(page, 4)

        # ---- left side to deck 3
        page.click("#mixer .layercell[data-side='0']:not(.on)")
        st = page.evaluate("({ side: cratebox.MIDI.side.join(), on: [...document.querySelectorAll('#mixer .layercell.on')].map(c => c.textContent).sort().join(), hw: [...document.querySelectorAll('.deck.hw')].map(e => +e.dataset.i).sort().join() })")
        check("clicking the left toggle: the controller's left side plays deck 3, marked on screen", st == {"side": "2,1", "on": "2,3", "hw": "1,2"}, str(st))
        midi(play0[0], play0[1], 127); midi(play0[0], play0[1], 0)
        page.wait_for_timeout(200)
        pl = page.evaluate("cratebox.decks.map(d => d.playing)")
        check("PLAY on the left plays deck 3, not deck 1", pl == [False, False, True, False], str(pl))
        midi(play1[0], play1[1], 127); midi(play1[0], play1[1], 0)
        check("the right side is still deck 2", page.evaluate("cratebox.decks[1].playing"))
        # lights: the left PLAY lights for deck 3 (playing), and goes back to deck 1's (paused, blinking) on switching back
        page.evaluate("cratebox.MIDI.ledCache.clear(); cratebox.MIDI.log.length = 0"); page.wait_for_timeout(200)
        lit = page.evaluate(f"cratebox.MIDI.log.filter(m => m[0] === {play0[0]} && m[1] === {play0[1]}).map(m => m[2])")
        check("left PLAY light shows deck 3 (on)", lit and all(v == 127 for v in lit), str(lit))
        vu = page.evaluate("new Promise(r => setTimeout(() => r([cratebox.MIDI.log.filter(m => m[0] === 0xB0 && m[1] === 2).map(m => m[2]).pop() || 0, cratebox.MIDI.log.filter(m => m[0] === 0xB1 && m[1] === 2).map(m => m[2]).pop() || 0]), 600))")
        check("left VU meter shows deck 3's level (deck 1 is silent)", vu[0] > 20, str(vu))
        # jog and load
        page.evaluate("cratebox.decks[2].togglePlay()")      # pause deck 3, then nudge it with the jog
        t0 = page.evaluate("[cratebox.decks[0].now(), cratebox.decks[2].now()]")
        for _ in range(20): midi(jog0[0], jog0[1], 64 + 8)
        page.wait_for_timeout(150)
        t1 = page.evaluate("[cratebox.decks[0].now(), cratebox.decks[2].now()]")
        check("the left jog moves deck 3", abs(t1[1] - t0[1]) > 0.05 and abs(t1[0] - t0[0]) < 1e-6, f"{t0} -> {t1}")
        page.evaluate("cratebox.lib.sel = 3")
        want = page.evaluate("cratebox.lib.view[3].id")
        midi(load0[0], load0[1], 127); midi(load0[0], load0[1], 0)
        page.wait_for_function(f"cratebox.decks[2].track && cratebox.decks[2].track.id === {want!r} && cratebox.decks[2].loaded", timeout=30000)
        check("LOAD on the left loads deck 3", page.evaluate("cratebox.decks[0].track.id") != want)

        # ---- soft takeover: deck 3's fader is at 0.2, the hardware fader at the top (deck 1 was full)
        page.evaluate("cratebox.M.fader[2] = 0.2; cratebox.M.fader[0] = 1")
        page.click("#mixer .layercell[data-side='0']:not(.on)"); page.click("#mixer .layercell[data-side='0']:not(.on)")   # 1 then back to 3: takeover armed again
        midi(fader0[0], fader0[1], 120)
        f = page.evaluate("[cratebox.M.fader[0], cratebox.M.fader[2]]")
        check("fader far from deck 3's level: ignored (no jump)", abs(f[1] - 0.2) < 1e-6 and f[0] == 1, str(f))
        for v in (90, 60, 40, 30):          # 0.71 ... 0.24: still above deck 3's 0.2
            midi(fader0[0], fader0[1], v)
        f = page.evaluate("cratebox.M.fader[2]")
        check("coming down but not there yet: still ignored", abs(f - 0.2) < 1e-6, str(f))
        midi(fader0[0], fader0[1], 20)      # 0.16: crossed it
        f = page.evaluate("[cratebox.M.fader[0], cratebox.M.fader[2]]")
        check("past deck 3's level: it takes over and follows (deck 1 keeps its own)", abs(f[1] - 20 / 127) < 0.01 and f[0] == 1, str(f))
        midi(fader0[0], fader0[1], 100)
        check("...and keeps following", abs(page.evaluate("cratebox.M.fader[2]") - 100 / 127) < 0.01)
        # tempo: deck 3 at +0, the hardware tempo fader at -4% (deck 1's): deck 3's pitch must not move until it's crossed
        page.evaluate("cratebox.decks[2].setPitch(0); cratebox.decks[0].setPitch(-0.5)")
        page.click("#mixer .layercell[data-side='0']:not(.on)"); page.click("#mixer .layercell[data-side='0']:not(.on)")
        lsb = tempo0[2]
        def tempo(v14):
            midi(tempo0[0], tempo0[1], v14 >> 7)
            if lsb: midi(tempo0[0], lsb, v14 & 127)
        tempo(int(0.25 * 16383))
        check("tempo fader away from deck 3's tempo: deck 3's pitch doesn't jump", page.evaluate("cratebox.decks[2].pitch") == 0)
        tempo(int(0.45 * 16383)); tempo(int(0.52 * 16383))
        pt = page.evaluate("[cratebox.decks[0].pitch, cratebox.decks[2].pitch]")
        check("past deck 3's tempo it takes over; deck 1 keeps its own", abs(pt[1] - 0.04) < 0.01 and pt[0] == -0.5, str(pt))
        # EQ knob, same idea
        page.evaluate("cratebox.M.hi[2] = 0.5")
        page.click("#mixer .layercell[data-side='0']:not(.on)"); page.click("#mixer .layercell[data-side='0']:not(.on)")
        midi(hi0[0], hi0[1], 10)
        h1 = page.evaluate("cratebox.M.hi[2]")
        midi(hi0[0], hi0[1], 63); midi(hi0[0], hi0[1], 70)
        check("EQ knob: ignored until it reaches deck 3's setting, then follows", h1 == 0.5 and abs(page.evaluate("cratebox.M.hi[2]") - 70 / 127) < 0.01, str(h1))

        # ---- the right side: 4
        page.click("#mixer .layercell[data-side='1']:not(.on)")
        midi(play1[0], play1[1], 127); midi(play1[0], play1[1], 0)
        pl = page.evaluate("cratebox.decks.map(d => d.playing)")
        check("right toggle: PLAY on the right plays deck 4", pl[3] and pl[1], str(pl))
        # BEAT FX CH SELECT lever on CH 1: follows the left side
        lever = msg("fxCh:0", -1)
        midi(lever[0], lever[1], 127)
        check("BEAT FX lever on CH1 picks the deck the left side plays (3)", page.evaluate("cratebox.FX.beat.ch") == 2, str(page.evaluate("cratebox.FX.beat.ch")))
        page.click("#mixer .layercell[data-side='0']:not(.on)")
        check("...and follows when the side switches back to 1", page.evaluate("cratebox.FX.beat.ch") == 0)
        midi(lever[0], lever[1], 0)

        # ---- learn the left toggle onto a spare button (note 0x7A on channel 16)
        page.evaluate("cratebox.startLearn()")
        page.click("#mixer .layercell[data-side='0']:not(.on)")
        midi(0x9F, 0x7A, 127); midi(0x9F, 0x7A, 0)
        page.evaluate("cratebox.stopLearn()")
        before = page.evaluate("cratebox.MIDI.side[0]")
        midi(0x9F, 0x7A, 127); midi(0x9F, 0x7A, 0)
        check("a learned hardware button toggles the left side", page.evaluate("cratebox.MIDI.side[0]") != before, f"{before} -> {page.evaluate('cratebox.MIDI.side[0]')}")
        # ---- SMART CFX / SMART FADER as layer buttons (their real messages aren't published: stand-ins)
        SCFX, SFAD = (0x96, 0x5A), (0x96, 0x5B)
        page.evaluate("cratebox.MIDI.side = [0, 1]; cratebox.setFour(true)")
        page.evaluate("cratebox.setupLayerButtons()")
        check("setup asks for SMART CFX first", "SMART CFX" in page.inner_text("#status"), page.inner_text("#status"))
        midi(play0[0], play0[1], 127); midi(play0[0], play0[1], 0)       # wrong button by mistake
        check("a button that already does something (PLAY) is refused", "already does" in page.inner_text("#status") and not page.evaluate("cratebox.decks[0].playing") is None, page.inner_text("#status")[:80])
        midi(*SCFX, 127); midi(*SCFX, 0)
        check("then SMART FADER", "SMART FADER" in page.inner_text("#status"), page.inner_text("#status"))
        midi(*SFAD, 127); midi(*SFAD, 0)
        check("done, and kept with the learned controls", "Done" in page.inner_text("#status") and page.evaluate("cratebox.MIDI.learned.filter(e => e[2] === 'layer').map(e => e[3]).sort().join()") == "0,1")
        s0 = page.evaluate("cratebox.MIDI.side.join()")
        midi(*SCFX, 127); midi(*SCFX, 0)
        s1 = page.evaluate("cratebox.MIDI.side.join()")
        midi(*SFAD, 127); midi(*SFAD, 0)
        s2 = page.evaluate("cratebox.MIDI.side.join()")
        check("SMART CFX switches the left side 1 -> 3, SMART FADER the right 2 -> 4", (s0, s1, s2) == ("0,1", "2,1", "2,3"), f"{s0} {s1} {s2}")
        lights = lambda: page.evaluate(f"""new Promise(r => {{ cratebox.MIDI.ledCache.clear(); cratebox.MIDI.log.length = 0; setTimeout(() => r(
            [{SCFX[0]}, {SFAD[0]}].map((st, k) => [...new Set(cratebox.MIDI.log.filter(m => m[0] === st && m[1] === [{SCFX[1]}, {SFAD[1]}][k]).map(m => m[2]))].sort())), 1300); }})""")
        check("their lights flash while on deck 3 / 4", lights() == [[0, 127], [0, 127]], str(lights()))
        midi(*SCFX, 127); midi(*SCFX, 0); midi(*SFAD, 127); midi(*SFAD, 0)
        check("...and stay off on decks 1 / 2", lights() == [[0], [0]], str(lights()))
        if len(sys.argv) > 1:
            page.screenshot(path=sys.argv[1])

        # ---- back to 2 decks: the controller is on 1 and 2 again
        page.evaluate("for (const d of cratebox.decks) if (d.playing) d.togglePlay()")
        page.click("#fourBtn")
        st = page.evaluate("({ side: cratebox.MIDI.side.join(), hw: document.querySelectorAll('.deck.hw').length, four: document.documentElement.classList.contains('four') })")
        check("2 DECKS: controller back on decks 1 and 2, no toggles", st == {"side": "0,1", "hw": 0, "four": False} and not vis("#mixer .layers"), str(st))
        midi(play0[0], play0[1], 127); midi(play0[0], play0[1], 0)
        check("...PLAY on the left plays deck 1 again", page.evaluate("cratebox.decks[0].playing"))
        b.close()
    srv.shutdown()
    check("no JavaScript errors", not errors, "; ".join(errors[:3]))
    failed = [n for n, ok in T.checks if not ok]
    print(f"\n{len(T.checks) - len(failed)}/{len(T.checks)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
