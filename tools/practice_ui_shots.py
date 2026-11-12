#!/usr/bin/env python3
"""Screenshots + UI smoke test of the practice form and a released result, with a temporary student (deleted here).
usage: practice_ui_shots.py [live|local] [outdir]   Prints no secrets or key values."""
import os, re, secrets, sys, time
from pathlib import Path
import requests
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent; SITE = ROOT / "site"
sys.path.insert(0, str(ROOT / "tools"))
import course_cli as cc, practice_parse as pp  # noqa: E402

URL = "https://czqtzjkkxpzixiiplvro.supabase.co"; SK = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
ANON = re.search(r'SUPABASE_ANON_KEY:\s*"([^"]+)"', (SITE / "config.js").read_text()).group(1)
mode = sys.argv[1] if len(sys.argv) > 1 else "local"
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else ROOT / "screenshots" / "learn"); OUT.mkdir(parents=True, exist_ok=True)
ah = {"apikey": SK, "Authorization": f"Bearer {SK}", "Content-Type": "application/json"}
def admin(n, **p):
    r = requests.post(f"{URL}/rest/v1/rpc/{n}", headers=ah, json=p); r.raise_for_status(); return r.json()

man = cc.SOURCES["cased-hole"]()
loc = pp.parse_day("cased-hole", 4, "Tuesday", man["weeks"][3]["days"]["Tuesday"]["pack"])
truth = {f["fkey"]: f for q in loc["questions"] for f in q["fields"]}
# Neutral placeholder text only: nothing here is derived from a key (the repo must never carry key content).
TEXT = {k: "Sample answer typed by the UI test. My working is in my notebook; this checks the form, saving and marking."
        for k in ("A1", "A2.c", "A3", "B2", "B3", "B4")}

def num_answer(fk, f, wrong=False):
    v = f["key"]["answer"]
    v = v * 1.06 if wrong else v
    return f"{v:,.1f}" if abs(v) >= 100 else f"{v:.3g}" if abs(v) < 1 else f"{v:.1f}"

email = f"ui-prac-{secrets.token_hex(4)}@example.com"; pw = secrets.token_urlsafe(20)
uid = requests.post(f"{URL}/auth/v1/admin/users", headers=ah, json={"email": email, "password": pw, "email_confirm": True}).json()["id"]
logs = []
try:
    admin("admin_allow_user", p_email=email)
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
        sid = None
        for label, vp, dsf in [("phone", {"width": 390, "height": 844}, 3), ("desktop", {"width": 1366, "height": 900}, 1)]:
            ctx = b.new_context(viewport=vp, device_scale_factor=dsf, is_mobile=label == "phone", has_touch=label == "phone")
            pg = ctx.new_page()
            pg.on("console", lambda m, l=label: logs.append(f"{l} {m.type}: {m.text}") if m.type in ("error", "warning") else None)
            pg.on("pageerror", lambda e, l=label: logs.append(f"{l} PAGEERROR {e}"))
            if mode != "live": pg.route("http://local.test/**", route)
            pg.goto(base + "#/login"); pg.wait_for_selector("input[name=email]")
            pg.fill("input[name=email]", email); pg.fill("input[name=password]", pw); pg.click("button[type=submit]")
            pg.wait_for_selector(".course")
            if label == "phone":
                pg.goto(base + "#/learn/cased-hole/4/2"); pg.wait_for_selector(".pq", timeout=60000)
                ids = pg.eval_on_selector_all("[data-f]", "els => els.map(e => e.id)")
                fk_by_id = {}
                for q in pg.eval_on_selector_all(".pq", "qs => qs.length"), :
                    pass
                # map input ids to fkeys via the RPC payload
                tok = requests.post(f"{URL}/auth/v1/token?grant_type=password", headers={"apikey": ANON, "Content-Type": "application/json"},
                                    json={"email": email, "password": pw}).json()["access_token"]
                g = requests.post(f"{URL}/rest/v1/rpc/get_practice", headers={"apikey": ANON, "Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
                                  json={"p_course": "cased-hole", "p_week": 4, "p_position": 2}).json()
                fields = {f["id"]: f for q in g["questions"] for f in q["fields"]}
                for fid, f in fields.items():
                    fk = f["fkey"]
                    if f["kind"] == "numeric":
                        val = num_answer(fk, truth[fk], wrong=fk in ("A5.2", "B1.2"))
                    else:
                        val = TEXT.get(fk, "")
                    if val:
                        pg.fill(f"#pf-{fid}", val)
                pg.click("#psave"); pg.wait_for_selector("#psaved:has-text('Draft saved')")
                pg.eval_on_selector("#s-practice", "e => e.scrollIntoView({block:'start'})"); time.sleep(0.6)
                pg.screenshot(path=OUT / "phone-6-practice-form.png")
                pg.locator("#s-practice").screenshot(path=OUT / "phone-6-practice-form-full.png")
                pg.reload(); pg.wait_for_selector(".pq", timeout=60000)
                first = next(iter(fields))
                if not pg.input_value(f"#pf-{first}"): logs.append("draft did not persist after reload")
                pg.click("#psubmit"); pg.wait_for_selector(".modal [data-go]"); time.sleep(0.3); pg.locator(".modal [data-go]").click(); pg.wait_for_selector(".pnote", timeout=30000); time.sleep(1)
                pg.eval_on_selector("#s-practice", "e => e.scrollIntoView({block:'start'})"); time.sleep(0.4)
                pg.screenshot(path=OUT / "phone-7-practice-submitted.png")
                if pg.locator(".pres").count(): logs.append("results visible before release")
                sub = [s for s in admin("mentor_practice_submissions", p_all=False, p_detail=True) if s["student_email"] == email][0]
                sid = sub["submission_id"]
                marks = []
                for a in sub["answers"]:
                    if a["needs_marking"]:
                        full = a["fkey"] not in ("A3", "B3")
                        marks.append({"fkey": a["fkey"], "marks": float(a["marks"]) if full else float(a["marks"]) / 2,
                                      "feedback": "Clear and complete." if full else "Right idea, but give the numbers for both zones and say which branch you used."})
                admin("mentor_mark_practice", p={"submission_id": sid, "marks": marks,
                                                 "feedback": "Solid work on the crossplots. Check your rounding on the zone C velocity and rate."})
                admin("mentor_release_practice", p_submission=sid, p_released=True, p_force=False)
                admin("mentor_ack_practice", p_id=None, p_submission=sid, p_by="ui-test")
                pg.reload(); pg.wait_for_selector(".pscore", timeout=60000); time.sleep(0.8)
                pg.eval_on_selector("#s-practice", "e => e.scrollIntoView({block:'start'})"); time.sleep(0.4)
                pg.screenshot(path=OUT / "phone-8-practice-released.png")
                pg.locator("#s-practice").screenshot(path=OUT / "phone-8-practice-released-full.png")
                nres = pg.locator(".pres").count(); print(f"phone: {len(fields)} fields filled, submitted, released; {nres} result lines")
            else:
                pg.goto(base + "#/learn/cased-hole/4/3"); pg.wait_for_selector(".pq", timeout=60000)
                ins = pg.locator("[data-f]")
                n = ins.count()
                for i in range(min(n, 6)):
                    el = ins.nth(i)
                    el.fill("0.48" if el.get_attribute("data-kind") == "numeric" else "Working on this one.")
                pg.locator("[data-kind=numeric]").nth(min(6, pg.locator('[data-kind=numeric]').count() - 1)).fill("12 ft")  # shows the number-only hint
                pg.click("#psave"); pg.wait_for_selector("#psaved:has-text('Draft saved')")
                pg.eval_on_selector("#s-practice", "e => e.scrollIntoView({block:'start'})"); time.sleep(0.6)
                pg.screenshot(path=OUT / "desktop-6-practice-form.png")
                pg.locator("#s-practice").screenshot(path=OUT / "desktop-6-practice-form-full.png")
                pg.goto(base + "#/learn/cased-hole/4/2"); pg.wait_for_selector(".pscore", timeout=60000); time.sleep(0.8)
                pg.eval_on_selector("#s-practice", "e => e.scrollIntoView({block:'start'})"); time.sleep(0.4)
                pg.screenshot(path=OUT / "desktop-8-practice-released.png")
                pg.locator("#s-practice").screenshot(path=OUT / "desktop-8-practice-released-full.png")
                pg.click("#ptask"); time.sleep(2.5)
                lbl = pg.text_content(".pdfv-pg") or ""
                print(f"desktop: task button -> viewer shows '{lbl.strip()}'")
            pg.goto(base + "#/progress"); pg.wait_for_selector("#s-practice-scores"); time.sleep(1)
            pg.eval_on_selector("#s-practice-scores", "e => e.scrollIntoView({block:'start'})"); time.sleep(0.4)
            pg.screenshot(path=OUT / f"{label}-9-progress-practice.png")
            ctx.close()
        b.close()
finally:
    requests.delete(f"{URL}/auth/v1/admin/users/{uid}", headers=ah)
    print("cleanup: temp user deleted")
print("console issues:" if logs else "console: clean", *logs[:20], sep="\n  ")
