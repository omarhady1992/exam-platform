#!/usr/bin/env python3
"""Screenshots + UI smoke test of the learning pages with a temporary student user (created and deleted here).
usage: learn_ui_shots.py [live|local] [outdir]   Prints no secrets."""
import json, os, re, secrets, sys, time
from datetime import datetime, timedelta, timezone
from pathlib import Path
import requests
from playwright.sync_api import sync_playwright

URL = "https://czqtzjkkxpzixiiplvro.supabase.co"; SK = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
ROOT = Path(__file__).resolve().parent.parent; SITE = ROOT / "site"
ANON = re.search(r'SUPABASE_ANON_KEY:\s*"([^"]+)"', (SITE / "config.js").read_text()).group(1)
mode = sys.argv[1] if len(sys.argv) > 1 else "local"
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else ROOT / "screenshots" / "learn"); OUT.mkdir(parents=True, exist_ok=True)
ah = {"apikey": SK, "Authorization": f"Bearer {SK}", "Content-Type": "application/json"}
def admin(n, **p):
    r = requests.post(f"{URL}/rest/v1/rpc/{n}", headers=ah, json=p); r.raise_for_status(); return r.json()
email = f"ui-learn-{secrets.token_hex(4)}@example.com"; pw = secrets.token_urlsafe(20)
uid = requests.post(f"{URL}/auth/v1/admin/users", headers=ah, json={"email": email, "password": pw, "email_confirm": True}).json()["id"]
admin("admin_allow_user", p_email=email)
tok = requests.post(f"{URL}/auth/v1/token?grant_type=password", headers={"apikey": ANON, "Content-Type": "application/json"},
                    json={"email": email, "password": pw}).json()["access_token"]
uh = {"apikey": ANON, "Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
def urpc(n, **p):
    r = requests.post(f"{URL}/rest/v1/rpc/{n}", headers=uh, json=p); r.raise_for_status(); return r.json()
# realistic progress: cased hole weeks 1-3 + Mon of week 4, RE Sunday; done on consecutive days ending today
done = [("cased-hole", w, d) for w in (1, 2, 3) for d in (1, 2, 3, 4)] + [("cased-hole", 4, 1), ("reservoir-engineering", 1, 1)]
for c, w, d in done: urpc("set_day_done", p_course=c, p_week=w, p_position=d, p_done=True)
now = datetime.now(timezone.utc)
for i, (c, w, d) in enumerate(reversed(done)):
    when = (now - timedelta(days=i // 2, hours=1)).isoformat()
    r = requests.get(f"{URL}/rest/v1/course_days?select=id,course_weeks!inner(n,courses!inner(slug))&position=eq.{d}&course_weeks.n=eq.{w}&course_weeks.courses.slug=eq.{c}", headers=ah)
    did = r.json()[0]["id"]
    requests.patch(f"{URL}/rest/v1/day_progress?user_id=eq.{uid}&day_id=eq.{did}", headers=ah, json={"done_at": when}).raise_for_status()
logs = []; ok = True
try:
    with sync_playwright() as p:
        b = p.chromium.launch(channel="chrome", headless=True)
        def route(r):
            f = r.request.url.split("/site/")[-1].split("#")[0].split("?")[0] or "index.html"
            path = SITE / f
            if not path.is_file(): return r.fulfill(status=404, body="nf")
            ext = f.rsplit(".", 1)[-1]
            ct = {"js": "application/javascript", "mjs": "application/javascript", "css": "text/css", "html": "text/html", "png": "image/png"}.get(ext, "application/octet-stream")
            return r.fulfill(body=path.read_bytes(), content_type=ct)
        base = "https://omarhady1992.github.io/exam-platform/" if mode == "live" else "http://local.test/site/"
        for label, vp, dsf in [("phone", {"width": 390, "height": 844}, 3), ("desktop", {"width": 1366, "height": 900}, 1)]:
            ctx = b.new_context(viewport=vp, device_scale_factor=dsf, is_mobile=label == "phone", has_touch=label == "phone")
            pg = ctx.new_page()
            pg.on("console", lambda m: logs.append(f"{label} {m.type}: {m.text}") if m.type in ("error", "warning") else None)
            pg.on("pageerror", lambda e: logs.append(f"{label} PAGEERROR {e}"))
            if mode != "live": pg.route("http://local.test/**", route)
            pg.goto(base + "#/login"); pg.wait_for_selector("input[name=email]")
            pg.fill("input[name=email]", email); pg.fill("input[name=password]", pw); pg.click("button[type=submit]")
            pg.wait_for_selector(".course"); time.sleep(1)
            pg.screenshot(path=OUT / f"{label}-1-courses.png", full_page=True)
            pg.goto(base + "#/learn/cased-hole"); pg.wait_for_selector(".week"); time.sleep(0.8)
            pg.screenshot(path=OUT / f"{label}-2-course.png", full_page=label == "desktop")
            pg.goto(base + "#/learn/cased-hole/4/2"); pg.wait_for_selector(".pdfv-page canvas", timeout=60000)
            pg.wait_for_selector(".igbox img", timeout=60000); time.sleep(2.5)
            pg.screenshot(path=OUT / f"{label}-3-day.png")
            pg.screenshot(path=OUT / f"{label}-3-day-full.png", full_page=True)
            links = pg.eval_on_selector_all(".pdfv-links a", "els => els.length")
            nvid = pg.eval_on_selector_all(".vid", "els => els.length")
            pg.click(".yt >> nth=0"); pg.wait_for_selector(".vid-frame iframe")
            src = pg.get_attribute(".vid-frame iframe", "src")
            if "youtube-nocookie.com/embed/" not in src: ok = False; logs.append("video iframe not nocookie")
            pg.click("#donebtn"); pg.wait_for_selector("#donebtn[aria-pressed=true]")
            pg.click("#donebtn"); pg.wait_for_selector("#donebtn[aria-pressed=false]")
            time.sleep(3); pg.goto(base + "#/progress"); pg.wait_for_selector(".qtable, .statgrid"); time.sleep(1)
            pg.screenshot(path=OUT / f"{label}-4-progress.png", full_page=True)
            pg.goto(base + "#/learn/reservoir-engineering/1"); pg.wait_for_selector(".daylist"); pg.wait_for_selector("#deck .pdfv-page canvas", timeout=60000); time.sleep(1)
            pg.screenshot(path=OUT / f"{label}-5-week.png", full_page=label == "desktop")
            pg.goto(base + "#/exams"); pg.wait_for_selector("h1:has-text('Your exams')")
            print(f"{label}: pdf links on visible pages={links}, videos={nvid}, nocookie iframe ok")
            ctx.close()
        b.close()
finally:
    requests.delete(f"{URL}/auth/v1/admin/users/{uid}", headers=ah)
    print("cleanup: temp user deleted")
errs = [l for l in logs if "PAGEERROR" in l or " error:" in l]
print("\n".join(logs[:40]) or "no console errors")
print("UI OK" if ok and not errs else "UI PROBLEMS")
