"""Report a problem: the dialog, device details, the GitHub link and the copy button.

    python tests/test_report.py
"""
import os
import sys
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cratebox as T  # noqa: E402


def main():
    T.PORT = 8657
    srv = T.serve()
    check = T.check
    errors = []
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 1440, "height": 900}, permissions=["clipboard-read", "clipboard-write"])
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:{T.PORT}/cratebox.html")
        page.click("#startBtn")
        page.wait_for_function("window.cratebox && cratebox.A.ctx")
        page.click("#setBtn")
        page.click("#reportOpen")
        check("Report a problem opens from settings", page.is_visible("#reportSheet") and page.is_hidden("#setPanel"))
        pre = page.inner_text("#reportPreview")
        check("device details: version, browser, layout, MIDI, audio, library", all(k in pre for k in ("Cratebox: v", "Browser: Chrome", "Layout: desktop", "Web MIDI:", "Audio: ", "Library: ")), pre[:300])
        # typing doesn't trigger deck shortcuts or the library keys
        page.fill("#reportWhat", "SYNC jumped ahead")
        page.press("#reportWhat", "ArrowDown")
        page.fill("#reportWant", "stay in time")
        page.uncheck("#reportDiag")
        check("details can be left out", page.inner_text("#reportPreview") == "")
        page.check("#reportDiag")
        page.evaluate("window.open = (u) => { window.__opened = u; }")   # catch the link instead of going to GitHub
        page.click("#reportGitHub")
        url = page.evaluate("window.__opened")
        q = parse_qs(urlparse(url).query)
        check("Send on GitHub opens a pre-filled issue in zonahbear/Cratebox",
              url.startswith("https://github.com/zonahbear/Cratebox/issues/new") and q.get("title", [""])[0] == "[Report] SYNC jumped ahead"
              and "stay in time" in q.get("body", [""])[0] and "cratebox-report" in q.get("body", [""])[0] and "Browser:" in q.get("body", [""])[0], url[:200])
        page.click("#reportCopy")
        page.wait_for_timeout(200)
        clip = page.evaluate("navigator.clipboard.readText()")
        check("Copy report puts the report on the clipboard", clip.startswith("What happened:\nSYNC jumped ahead") and "Device details:" in clip and "cratebox-report" not in clip, clip[:120])
        page.fill("#reportWhat", "")
        page.click("#reportGitHub")
        check("empty description: asks for one instead of sending", "Describe what happened" in page.inner_text("#reportNote"))
        page.click("#reportClose")
        check("✕ closes it", page.is_hidden("#reportSheet"))
        # settings and the report are native popover/dialog: Esc closes them, and the report is modal
        page.click("#setBtn")
        page.keyboard.press("Escape")
        check("Esc closes the settings panel", page.is_hidden("#setPanel"))
        page.click("#setBtn")
        page.click("#reportOpen")
        check("the report opens as a modal dialog", page.evaluate("document.querySelector('#reportSheet').matches(':modal')"))
        page.keyboard.press("Escape")
        check("Esc closes the report", page.is_hidden("#reportSheet"))
        page.click("#setBtn")
        page.click("#reportOpen")
        page.mouse.click(10, 10)
        check("a press outside the report closes it", page.is_hidden("#reportSheet"))
        ctx.close()
        b.close()
    srv.shutdown()
    check("no JavaScript errors", not errors, "; ".join(errors[:3]))
    failed = [n for n, ok in T.checks if not ok]
    print(f"\n{len(T.checks) - len(failed)}/{len(T.checks)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
