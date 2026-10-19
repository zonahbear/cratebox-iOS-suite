"""Audio that the browser stops by itself comes back by itself, in headless Chromium.

Another app taking the controller's sound (rekordbox), the controller being unplugged or the laptop
sleeping all stop the browser's audio. Checks: it restarts straight away on its own; while it can't
restart (resume hangs or fails) a banner says so without covering the decks, it keeps retrying, and it
recovers as soon as it can; the stops are written down for problem reports.

    python tests/test_resume.py
"""
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cratebox as T  # noqa: E402
from test_fourdeck import load_all  # noqa: E402


def main():
    T.PORT = 8664
    srv = T.serve()
    check = T.check
    errors = []
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        page = b.new_page(viewport={"width": 1440, "height": 900})
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
        page.click("#startBtn")
        page.wait_for_function("window.cratebox && cratebox.A.ctx && cratebox.A.ctx.state === 'running'")
        load_all(page, 1)
        page.evaluate("cratebox.decks[0].togglePlay()")
        state = lambda: page.evaluate("cratebox.A.ctx.state")
        # 1. a short stop (the system borrows the audio): back by itself, no click
        page.evaluate("cratebox.A.ctx.suspend()")
        page.wait_for_function("cratebox.A.ctx.state === 'running'", timeout=5000)
        check("stopped audio restarts by itself", state() == "running")
        # 2. held stop: resume hangs (device gone, e.g. rekordbox has the FLX4) for ~5 s
        page.evaluate("""(() => { const c = cratebox.A.ctx; c._resume = c.resume; window.hangs = 0;
            c.resume = () => { window.hangs++; return new Promise(() => {}); }; c.suspend(); })()""")
        page.wait_for_timeout(2500)
        shown = page.is_visible("#resume")
        free = page.evaluate("(() => { const r = document.querySelector('.deck .round.play').getBoundingClientRect(); const e = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return !!e && !e.closest('#resume'); })()")
        check("while it can't restart: a banner, and the decks stay clickable (no frozen screen)", shown and free, f"banner {shown}, decks free {free}")
        page.wait_for_timeout(3000)
        n = page.evaluate("window.hangs")
        check("a hanging restart isn't waited on: it keeps retrying", n >= 3, f"{n} tries")
        check("after a few tries the banner suggests what to check", "another app" in page.inner_text("#resumeText"), page.inner_text("#resumeText"))
        page.evaluate("(() => { const c = cratebox.A.ctx; c.resume = c._resume; })()")      # rekordbox closed
        page.wait_for_function("cratebox.A.ctx.state === 'running'", timeout=5000)
        page.wait_for_timeout(300)
        check("as soon as it can, the audio comes back by itself and the banner goes", state() == "running" and page.is_hidden("#resume"))
        t0 = page.evaluate("cratebox.decks[0].now()"); page.wait_for_timeout(400)
        check("the deck plays on", page.evaluate("cratebox.decks[0].now()") > t0 + 0.2)
        page.click("#setBtn"); page.click("#reportOpen")
        rep = page.inner_text("#reportPreview")
        check("the stops are in problem reports", "audio: suspended" in rep and "running again" in rep, rep[-300:])
        b.close()
    srv.shutdown()
    check("no JavaScript errors", not errors, "; ".join(errors[:3]))
    failed = [n for n, ok in T.checks if not ok]
    print(f"\n{len(T.checks) - len(failed)}/{len(T.checks)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
