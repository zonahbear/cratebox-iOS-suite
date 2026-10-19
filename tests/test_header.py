"""Deck headers hold still during playback, in headless Chromium.

The worst case for the deck's info row: deck 2 synced to deck 1 (so deck 1 shows MASTER and both show
a running sync offset), master tempo off and deck 1 pitched a semitone down and back up (its key shows
as "x (y)"), a phrase counter ticking. At the MacBook Air's width (1440 px), in 2- and 4-deck mode and
both looks, GRID / MT / Q must not move at all and the row must stay on one line.

    python tests/test_header.py
"""
import os
import sys

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cratebox as T  # noqa: E402
from test_fourdeck import load_all  # noqa: E402

SAMPLE = """() => { const out = {};
  for (const d of document.querySelectorAll('.deck')) { if (!d.getBoundingClientRect().height) continue;
    const row = d.querySelector('.dinfo'); if (!row) continue;
    const vis = [...row.children].filter(e => getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0);
    // one line: every item's vertical span overlaps every other's (buttons and text sit at different tops)
    const rs = vis.map(e => e.getBoundingClientRect());
    out['deck' + (+d.dataset.i + 1) + ' lines'] = Math.max(...rs.map(r => r.top)) < Math.min(...rs.map(r => r.bottom)) ? 1 : 2;
    for (const b of row.querySelectorAll('button')) { const r = b.getBoundingClientRect(); if (r.width) out['deck' + (+d.dataset.i + 1) + ' ' + b.textContent.trim()] = Math.round(r.left * 2) / 2; } }
  return out; }"""


def main():
    T.PORT = 8663
    srv = T.serve()
    check = T.check
    errors = []
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        for theme in ("booth", "default"):
            for four in ("0", "1"):
                page = b.new_page(viewport={"width": 1440, "height": 790})
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.add_init_script(f"localStorage.setItem('cb.theme','{theme}'); localStorage.setItem('cb.themeChosen','1'); localStorage.setItem('cb.four','{four}')")
                page.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
                page.click("#startBtn")
                page.wait_for_function("window.cratebox && cratebox.A.ctx")
                n = 4 if four == "1" else 2
                load_all(page, n)
                page.evaluate("for (const d of cratebox.decks.slice(0, 2)) if (d.mt) d.setMT(false)")
                page.evaluate("cratebox.decks[0].seek(14.5); cratebox.decks[1].seek(9.0); cratebox.decks[1].setSync(true)")
                for i in range(n):
                    page.evaluate(f"cratebox.decks[{i}].togglePlay()")
                samples = []
                for k in range(40):
                    page.wait_for_timeout(100)
                    if k == 12: page.evaluate("cratebox.decks[0].setPitch(-0.6)")    # a semitone down: key shows "x (y)"
                    if k == 26: page.evaluate("cratebox.decks[0].setPitch(0.15)")
                    samples.append(page.evaluate(SAMPLE))
                label = f"{'Booth' if theme == 'booth' else 'classic'}, {n} decks"
                keys = sorted(k for k in set().union(*samples) if not k.endswith("lines"))
                moved = [f"{k} {min(s[k] for s in samples if k in s)}..{max(s[k] for s in samples if k in s)}" for k in keys
                         if max(s[k] for s in samples if k in s) != min(s[k] for s in samples if k in s)]
                check(f"{label}: GRID / MT / Q don't move during playback", keys and not moved, "; ".join(moved[:4]) or f"{len(keys)} buttons steady")
                lines = max(v for s in samples for k, v in s.items() if k.endswith("lines"))
                check(f"{label}: info row stays on one line", lines == 1, f"{lines} lines")
                page.close()
        b.close()
    srv.shutdown()
    check("no JavaScript errors", not errors, "; ".join(errors[:3]))
    failed = [n for n, ok in T.checks if not ok]
    print(f"\n{len(T.checks) - len(failed)}/{len(T.checks)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
