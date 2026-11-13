#!/usr/bin/env python3
"""Fetch TestFlight crash reports (the ones sent with "Share" on TestFlight's crash prompt) from the App Store
Connect API and write them to out/ as text files. The tester's email and other personal fields are left out:
this repo is public. Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (the TestFlight upload key) and BUNDLE_ID."""
import json, os, sys, time, urllib.request, urllib.error
import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com"
KEEP = ["createdDate", "comment", "deviceModel", "osVersion", "appPlatform", "devicePlatform", "deviceFamily",
        "architecture", "appUptimeInMilliseconds", "batteryPercentage", "diskBytesAvailable", "connectionType"]
log = []

def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
                      os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})

def get(path):
    req = urllib.request.Request(path if path.startswith("http") else API + path, headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        log.append(f"HTTP {e.code} for {path}: {e.read()[:600].decode('utf-8', 'replace')}")
        return None

def main():
    os.makedirs("out", exist_ok=True)
    apps = get("/v1/apps?filter[bundleId]=" + os.environ["BUNDLE_ID"])
    if not apps or not apps.get("data"):
        log.append("app not found"); return
    app = apps["data"][0]["id"]
    url = f"/v1/apps/{app}/betaFeedbackCrashSubmissions?limit=50&include=build"
    n = 0
    while url and n < 200:
        page = get(url)
        if not page: break
        builds = {b["id"]: b.get("attributes", {}).get("version", "?") for b in page.get("included", []) if b.get("type") == "builds"}
        for s in page.get("data", []):
            a = s.get("attributes", {})
            bid = (((s.get("relationships") or {}).get("build") or {}).get("data") or {}).get("id")
            build = builds.get(bid, "?")
            crash = get(f"/v1/betaFeedbackCrashSubmissions/{s['id']}/crashLog")
            text = ((crash or {}).get("data") or {}).get("attributes", {}).get("logText") or "(no crash log text)"
            head = [f"build: {build}"] + [f"{k}: {a.get(k)}" for k in KEEP if a.get(k) is not None]
            name = f"{(a.get('createdDate') or 'unknown').replace(':', '-')}_build{build}.txt"
            with open(os.path.join("out", name), "w") as f:
                f.write("\n".join(head) + "\n\n" + text)
            n += 1
        url = (page.get("links") or {}).get("next")
    log.append(f"{n} crash report(s) fetched")

try:
    main()
except Exception as e:
    log.append(f"error: {type(e).__name__}: {e}")
os.makedirs("out", exist_ok=True)
with open("out/_run.txt", "w") as f:
    f.write("\n".join(log) + "\n")
print("\n".join(log))
