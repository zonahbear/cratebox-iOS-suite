"""TrueCurve mini (HEAT button): a heat curve runs on the simulator while a deck keeps playing, in headless Chromium.

Checks: Quartz Banger is the default curve; curves pasted from TrueCurve show up; a curve started from the panel
preheats, runs and finishes with the panel closed; the HEAT button shows the bowl temperature meanwhile; the
playing deck's position keeps advancing the whole time with no page errors; profile slot 4 and the active slot
are put back afterwards; Stop ends a run early. Also the phone layout keeps the button.

    python tests/test_truecurve.py
"""
import json
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cratebox as T  # noqa: E402
from test_fourdeck import load_all  # noqa: E402

QUICK = {"Quick Test": {"points": [{"t": 0, "f": 500}, {"t": 4, "f": 490}, {"t": 8, "f": 470}], "smooth": True}}


def main():
    T.PORT = 8671
    srv = T.serve()
    check = T.check
    errors = []
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        page = b.new_page(viewport={"width": 1440, "height": 790})
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
        page.click("#startBtn")
        page.wait_for_function("window.cratebox && cratebox.A.ctx")
        check("default curve is Quartz Banger", page.eval_on_selector("#tcCurve", "s => s.value") == "Quartz Banger")
        qb = page.evaluate("(() => { const c = cratebox.TC.makeCurve(cratebox.TC.PRESETS['Quartz Banger'].map(([t, f]) => ({ t, f })), true); return [c.at(0), c.at(30), c.at(c.end), c.end]; })()")
        check("Quartz Banger starts at 520°F and trails off", qb[0] == 520 and qb[0] > qb[1] > qb[2] and qb[2] == 450, str(qb))

        load_all(page, 1)
        page.evaluate("cratebox.decks[0].togglePlay()")

        # paste curves (headless has no clipboard text, so it falls back to the prompt)
        page.click("#tcBtn")
        page.once("dialog", lambda d: d.accept(json.dumps(QUICK)))
        page.click("#tcPaste")
        page.wait_for_function("[...document.querySelectorAll('#tcCurve option')].some(o => o.value === 'Quick Test')")
        check("pasted curve listed", True)
        page.select_option("#tcCurve", "Quick Test")

        page.click("#tcSim")
        page.wait_for_function("cratebox.TC.dev && cratebox.TC.dev.connected")
        # a warm bowl so preheat is quick (the simulator heats in real time)
        page.evaluate("cratebox.TC.dev.y = 495; cratebox.TC.dev.slotIdx = 1")
        page.click("#tcGo")
        page.wait_for_function("cratebox.TC.S.running")
        check("panel closes itself on Start", not page.evaluate("document.querySelector('#tcPanel').matches(':popover-open')"))

        pos, labels = [], set()
        while page.evaluate("cratebox.TC.S.running") and len(pos) < 200:
            page.wait_for_timeout(250)
            pos.append(page.evaluate("cratebox.decks[0].pos"))
            labels.add(page.inner_text("#tcBtn"))
        check("curve finished", not page.evaluate("cratebox.TC.S.running") and len(pos) < 200, f"{len(pos) / 4:.0f} s")
        check("HEAT button showed the bowl temperature", any("°" in l and "/8s" in l for l in labels), ", ".join(sorted(labels)[:4]))
        steps = [b2 - a for a, b2 in zip(pos, pos[1:])]
        check("deck kept playing through the curve", all(s > 0 for s in steps), f"min step {min(steps):.0f} samples")
        dev = page.evaluate("({ slot: cratebox.TC.dev.slotIdx, s3: cratebox.TC.dev.slots[3], state: cratebox.TC.dev.state })")
        check("slot 4 and active slot restored, heater off", dev["slot"] == 1 and dev["s3"]["temp"] == 485 and dev["state"] == 5, str(dev))
        check("result message", "average off the curve" in page.inner_text("#tcMsg"), page.inner_text("#tcMsg"))

        # Stop ends a run early
        page.evaluate("cratebox.TC.dev.y = 515")
        page.click("#tcBtn")
        page.select_option("#tcCurve", "Quartz Banger")
        page.click("#tcGo")
        page.wait_for_function("cratebox.TC.S.phase === 'running'", timeout=30000)
        page.wait_for_timeout(1500)
        page.click("#tcBtn")
        page.click("#tcGo")
        page.wait_for_function("!cratebox.TC.S.running", timeout=10000)
        check("Stop ends the run and turns the heater off", page.evaluate("cratebox.TC.dev.state") == 5)
        check("no page errors", not errors, "; ".join(errors[:3]))
        page.close()

        # phone: the HEAT button stays in the header
        ctx = b.new_context(viewport={"width": 844, "height": 390}, is_mobile=True, has_touch=True,
                            user_agent="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
        ph = ctx.new_page()
        ph.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
        ph.click("#startBtn")
        ph.wait_for_function("window.cratebox && cratebox.A.ctx")
        r = ph.eval_on_selector("#tcBtn", "e => { const r = e.getBoundingClientRect(); return [r.width, r.right]; }")
        check("phone: HEAT button visible in the header", r[0] > 0 and r[1] <= 844, str(r))
        ph.tap("#tcBtn")
        pr = ph.eval_on_selector("#tcPanel", "e => { const r = e.getBoundingClientRect(); return [r.left, r.right, r.bottom, e.matches(':popover-open')]; }")
        check("phone: panel opens on screen", pr[3] and pr[0] >= 0 and pr[1] <= 844, str(pr))
        b.close()
    srv.shutdown()
    failed = [n for n, ok in T.checks if not ok]
    print(f"\n{len(T.checks) - len(failed)}/{len(T.checks)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
