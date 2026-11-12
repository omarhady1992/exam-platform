#!/usr/bin/env python3
"""End-to-end test with a temporary user. Creates and then removes the user, its attempts and a timing exam.
Uses the service role only for admin calls; student calls use the temp user's JWT. Prints no secrets."""
import json, os, secrets, sys, time, subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
import requests
sys.path.insert(0, str(Path(__file__).resolve().parent))

URL = os.environ.get("SUPABASE_URL", "https://czqtzjkkxpzixiiplvro.supabase.co")
SK = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
# Gateway key for "client" calls. Use the anon key if provided; otherwise the service key is sent only as the
# gateway apikey while the Authorization header carries the user's JWT, so PostgREST runs as `authenticated`.
GW = os.environ.get("SUPABASE_ANON_KEY") or SK
import re as _re0
ANON = _re0.search(r'SUPABASE_ANON_KEY:\s*"([^"]+)"', (Path(__file__).resolve().parent.parent / "site" / "config.js").read_text()).group(1)
ROOT = Path(__file__).resolve().parent.parent
EXAM = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "exams/sample-cbl-vdl-quiz.json")
ok_count = 0

def check(cond, msg):
    global ok_count
    if not cond:
        print("FAIL:", msg); raise SystemExit(1)
    ok_count += 1; print("ok  ", msg)

def admin(name, **p):
    r = requests.post(f"{URL}/rest/v1/rpc/{name}", headers={"apikey": SK, "Authorization": f"Bearer {SK}", "Content-Type": "application/json"}, json=p)
    if r.status_code >= 300: raise RuntimeError(f"{name}: {r.status_code} {r.text[:300]}")
    return r.json()

class Client:
    def __init__(self, jwt): self.h = {"apikey": GW, "Authorization": f"Bearer {jwt}", "Content-Type": "application/json"}
    def rpc(self, name, **p): return requests.post(f"{URL}/rest/v1/rpc/{name}", headers=self.h, json=p)
    def get(self, path): return requests.get(f"{URL}{path}", headers=self.h)
    def post(self, path, body): return requests.post(f"{URL}{path}", headers=self.h, json=body)

def walk_keys(o):
    if isinstance(o, dict):
        for k, v in o.items():
            yield k; yield from walk_keys(v)
    elif isinstance(o, list):
        for v in o: yield from walk_keys(v)

email = f"e2e-test-{secrets.token_hex(4)}@example.com"
pw = secrets.token_urlsafe(24)
ah = {"apikey": SK, "Authorization": f"Bearer {SK}", "Content-Type": "application/json"}
uid = None
timing_slug = f"e2e-timing-{secrets.token_hex(3)}"
exam_doc = json.loads(Path(EXAM).read_text()); slug = exam_doc["slug"]
was_published = next((e["published"] for e in admin("admin_list") if e["slug"] == slug), False)
attempt_ids = []
try:
    r = requests.post(f"{URL}/auth/v1/admin/users", headers=ah, json={"email": email, "password": pw, "email_confirm": True})
    check(r.status_code == 200, f"temp user created ({r.status_code})"); uid = r.json()["id"]
    tok = requests.post(f"{URL}/auth/v1/token?grant_type=password", headers={"apikey": GW, "Content-Type": "application/json"}, json={"email": email, "password": pw}).json()["access_token"]
    c = Client(tok)

    r = c.rpc("list_my_exams"); check(r.status_code in (401, 403) or "Not authorized" in r.text, "non-allowlisted user is rejected")
    # ---- learning platform: anonymous and non-allow-listed sessions get nothing
    anon = Client(GW if GW != SK else "x"); anon.h = {"apikey": ANON, "Content-Type": "application/json"}
    r = anon.rpc("list_courses"); check(not r.ok, f"anon cannot call list_courses ({r.status_code})")
    for t in ("courses", "course_weeks", "course_days", "day_progress"):
        r = anon.get(f"/rest/v1/{t}?select=*&limit=1"); check(not r.ok or r.json() == [], f"anon cannot read {t} ({r.status_code})")
    lc = admin("admin_list_courses")
    ch = next(x for x in lc if x["slug"] == "cased-hole")
    pub_w = next(w for w in ch["weeks"] if w["published"] and w["days"])
    pub_d = next(d for d in pub_w["days"] if d["published"])
    pack_path = next(f["path"] for f in pub_d["files"] if f["kind"] == "pack")
    r = anon.post(f"/storage/v1/object/sign/course-files/{pack_path}", {"expiresIn": 60}); check(not r.ok, f"anon cannot sign a course file ({r.status_code})")
    r = requests.get(f"{URL}/storage/v1/object/public/course-files/{pack_path}"); check(not r.ok, f"course-files bucket is not public ({r.status_code})")
    r = c.rpc("list_courses"); check(not r.ok, f"non-allowlisted user cannot list courses ({r.status_code})")
    for t in ("courses", "course_days"):
        r = c.get(f"/rest/v1/{t}?select=*&limit=1"); check(not r.ok or r.json() == [], f"non-allowlisted user sees no {t} rows")
    r = c.post(f"/storage/v1/object/sign/course-files/{pack_path}", {"expiresIn": 60}); check(not r.ok, f"non-allowlisted user cannot sign a course file ({r.status_code})")
    admin("admin_allow_user", p_email=email, p_role="student")
    check(c.rpc("whoami").json()["email"] == email, "allowlisted user: whoami works")

    # ---- learning platform: allow-listed user sees published material, signed URLs work, keys never stored
    lst = c.rpc("list_courses"); check(lst.ok, "allowlisted user can list courses"); lst = lst.json()
    slugs = {x["slug"] for x in lst["courses"]}
    check({"cased-hole", "reservoir-engineering", "esp"} <= slugs and all(x["days_total"] > 0 for x in lst["courses"]), f"three courses with published days ({sorted(slugs)})")
    gc = c.rpc("get_course", p_slug="cased-hole").json()
    check(all(w["published"] for w in gc["weeks"]) and all(d["published"] for w in gc["weeks"] for d in w["days"]), "only published weeks/days are served")
    draft_w = [w["n"] for w in ch["weeks"] if not w["published"]]
    check(not any(w["n"] in draft_w for w in gc["weeks"]), f"draft weeks hidden ({draft_w})")
    gd = c.rpc("get_day", p_course="cased-hole", p_week=pub_w["n"], p_position=pub_d["position"])
    check(gd.ok and gd.json()["day"]["files"], "get_day returns the day's files"); gd = gd.json()
    kinds = {f["kind"] for f in gd["day"]["files"]}
    check("pack" in kinds and "infographic" in kinds, f"day has PDF pack and infographic ({sorted(kinds)})")
    check(all("youtube_id" in v and "title" in v for v in gd["day"]["videos"]), f"videos have ids and titles ({len(gd['day']['videos'])})")
    r = c.post(f"/storage/v1/object/sign/course-files/{pack_path}", {"expiresIn": 120})
    check(r.ok and "signedURL" in r.json(), f"allowlisted user can sign the pack URL ({r.status_code})")
    signed = URL + "/storage/v1" + r.json()["signedURL"]
    g = requests.get(signed, headers={"Range": "bytes=0-1023"})
    check(g.status_code in (200, 206) and g.content[:4] == b"%PDF", f"signed URL serves the PDF ({g.status_code}, range ok={g.status_code == 206})")
    ig_path = next(f["path"] for f in gd["day"]["files"] if f["kind"] == "infographic")
    r = c.post(f"/storage/v1/object/sign/course-files/{ig_path}", {"expiresIn": 60})
    g = requests.get(URL + "/storage/v1" + r.json()["signedURL"]) if r.ok else None
    check(g is not None and g.ok and g.content[:8] == b"\x89PNG\r\n\x1a\n", "signed URL serves the infographic PNG")
    r = c.post("/storage/v1/object/sign/course-files/cased-hole/week-04/not-a-real-file.pdf", {"expiresIn": 60})
    check(not r.ok, f"cannot sign an unreferenced path ({r.status_code})")
    r = c.post("/storage/v1/object/sign/course-files/cased-hole/keys/week4-tuesday-key.md", {"expiresIn": 60})
    check(not r.ok, f"cannot sign a key-like path ({r.status_code})")
    r = c.rpc("get_day", p_course="cased-hole", p_week=max(draft_w or [99]), p_position=1); check(not r.ok, "draft day is not served")
    r = c.rpc("set_day_done", p_course="cased-hole", p_week=pub_w["n"], p_position=pub_d["position"], p_done=True)
    check(r.ok and r.json()["done"] and r.json()["streak"]["current"] >= 1, "mark as done works and starts a streak")
    dash = c.rpc("learning_dashboard").json()
    chs = next(x for x in dash["courses"] if x["slug"] == "cased-hole")
    check(chs["days_done"] == 1 and any(x["title"] == pub_d["title"] for x in dash["recent"]), "dashboard counts the done day")
    r = c.rpc("set_day_done", p_course="cased-hole", p_week=pub_w["n"], p_position=pub_d["position"], p_done=False)
    check(r.ok and not r.json()["done"], "undo mark as done")
    r = c.post("/rest/v1/courses", {"slug": "hack-test", "title": "x"}); check(not r.ok, f"student cannot insert courses ({r.status_code})")
    r = c.rpc("admin_upsert_day", p={"course": "cased-hole", "week": 1, "position": 1, "title": "x"}); check(not r.ok, f"student cannot call admin_upsert_day ({r.status_code})")
    r = c.get("/rest/v1/day_progress?select=user_id"); check(r.ok and all(x["user_id"] == uid for x in r.json()), "user reads only own progress rows")
    import re as _re
    def _walk(prefix):
        out = []
        for it in requests.post(f"{URL}/storage/v1/object/list/course-files", headers=ah, json={"prefix": prefix, "limit": 1000}).json():
            pth = f"{prefix}/{it['name']}" if prefix else it["name"]
            out += [pth] if it.get("id") else _walk(pth)
        return out
    allp = _walk("")
    bad = [x for x in allp if _re.search(r"(^|/)(keys?|exams|references)/|answer|(^|[/_. -])keys?([_. -]|$)|solution|(^|/)truth[_-]", x, _re.I)]
    check(len(allp) > 50 and not bad, f"no answer keys / textbooks in the bucket ({len(allp)} objects, {len(bad)} bad)")
    r = requests.post(f"{URL}/storage/v1/object/course-files/cased-hole/week-01/Week1-Quiz-Fundamentals-Answer-Key.pdf", headers={**c.h, "Content-Type": "application/pdf"}, data=b"%PDF-1.4 test")
    check(not r.ok, f"student cannot upload to course-files ({r.status_code})")

    for t in ("question_keys", "questions", "answers", "attempts", "exams", "focus_events", "allowed_users", "finish_notifications", "app_settings"):
        r = c.get(f"/rest/v1/{t}?select=*&limit=1")
        check(r.status_code in (401, 403, 404) or (r.ok and r.json() == []), f"user cannot read table {t} ({r.status_code})")
    for fn in ("admin_list", "admin_export"):
        r = c.rpc(fn, **({"p_slug": slug} if fn == "admin_export" else {}))
        check(r.status_code in (401, 403, 404) or "Not authorized" in r.text,
              f"user cannot call {fn} ({r.status_code})")

    admin("admin_set_published", p_slug=slug, p_published=True)
    lst = c.rpc("list_my_exams").json()
    check(any(e["slug"] == slug for e in lst["exams"]), "published exam is listed")
    r = c.rpc("start_attempt", p_slug=slug); check(r.ok, f"attempt started ({r.status_code})"); att = r.json()
    attempt_ids.append(att["attempt_id"])
    keys = set(walk_keys(att))
    check(not ({"answer", "tolerance_abs", "tolerance_pct", "explanation", "is_correct"} & keys), "attempt payload contains no key/answer fields")
    check(len(att["questions"]) == len(exam_doc["questions"]), "all questions served")
    dl = datetime.fromisoformat(att["deadline"]); st = datetime.fromisoformat(att["started_at"])
    check(abs((dl - st).total_seconds() - exam_doc["time_limit_minutes"] * 60) < 2, "deadline = started_at + time limit")
    r2 = c.rpc("start_attempt", p_slug=slug).json(); check(r2["attempt_id"] == att["attempt_id"], "re-start resumes the same attempt")

    # image access through storage with the user's JWT
    img_q = [q for q in att["questions"] if q.get("image_path")]
    if img_q:
        r = c.post(f"/storage/v1/object/sign/exam-images/{img_q[0]['image_path']}", {"expiresIn": 600})
        check(r.ok and "signedURL" in r.json(), f"user can sign URL for own exam image ({r.status_code})")
        r = c.post(f"/storage/v1/object/sign/exam-images/{slug}/not-real.png", {"expiresIn": 600})
        check(not r.ok, f"user cannot sign arbitrary object ({r.status_code})")

    # answer: correct for numeric/mcq/tf/multi using the local key, plus a short answer
    by_key = {q["id"]: q for q in exam_doc["questions"]}
    served = {q["prompt"]: q for q in att["questions"]}
    expected = 0
    for q in exam_doc["questions"]:
        s = served[q["prompt"]]
        if q["type"] == "numeric": resp = q["answer"] * 1.005
        elif q["type"] == "mcq": resp = [o for o in s["options"] if o["id"] != q["answer"]][0]["id"]  # deliberately wrong
        elif q["type"] == "multi": resp = q["answer"]
        elif q["type"] == "tf": resp = q["answer"]
        else: resp = "Because CBL averages around the pipe while ultrasonic maps impedance by azimuth."
        if q["type"] in ("numeric", "multi", "tf"): expected += q.get("marks", 1)
        r = c.rpc("save_answer", p_attempt=att["attempt_id"], p_question=s["id"], p_response=resp)
        check(r.ok, f"saved {q['id']} ({q['type']})")
    r = c.rpc("log_focus_event", p_attempt=att["attempt_id"], p_event="hidden", p_client_ts=datetime.now(timezone.utc).isoformat(), p_detail={"test": True})
    check(r.ok, "focus event logged")
    r = c.rpc("get_results", p_attempt=att["attempt_id"]); check(not r.ok, "results hidden before submit/release")
    r = c.rpc("submit_attempt", p_attempt=att["attempt_id"], p_reason="manual"); check(r.ok and r.json()["status"] == "submitted", "submitted")
    finishes = admin("admin_list_finishes", p_unacked_only=True)
    mine = [f for f in finishes if f["attempt_id"] == att["attempt_id"]]
    check(len(mine) == 1, "finish_notifications row enqueued on submit")
    check(mine[0]["exam_slug"] == slug and mine[0]["student_email"] == email, "finish row has slug + student email")
    check(mine[0]["email_status"] in ("sent", "skipped", "failed", "pending"), f"email_status set ({mine[0]['email_status']})")
    ack = admin("admin_ack_finish", p_id=mine[0]["id"], p_attempt=None)
    check(ack.get("acked_at"), "finish notification acked")
    r = c.rpc("save_answer", p_attempt=att["attempt_id"], p_question=att["questions"][0]["id"], p_response=1)
    check(not r.ok and "submitted" in r.text, "save after submit rejected")
    g = c.rpc("get_attempt", p_attempt=att["attempt_id"]).json(); check(g["questions"] is None, "submitted attempt no longer serves questions")
    r = c.rpc("get_results", p_attempt=att["attempt_id"]); check(not r.ok and "not been released" in r.text, "results hidden until release")
    r = c.rpc("start_attempt", p_slug=slug); check(not r.ok and "No attempts left" in r.text, "second attempt blocked (1 allowed)")

    exp = admin("admin_export", p_slug=slug)
    a = [x for x in exp["attempts"] if x["attempt_id"] == att["attempt_id"]][0]
    check(float(a["auto_score"]) == expected, f"auto marks correct ({a['auto_score']} == {expected})")
    check(len(a["focus_events"]) == 1, "focus event exported")
    short_ids = [q["id"] for q in exam_doc["questions"] if q["type"] == "short"]
    check(a["pending_manual"] == len(short_ids), "short answer queued for manual marking")
    mk = admin("admin_mark", p_slug=slug, p={"attempt_id": att["attempt_id"], "overall_feedback": "Good work (test)",
               "questions": [{"id": i, "marks": 2, "feedback": "Mention azimuthal coverage."} for i in short_ids]})
    check(mk["pending_manual"] == 0 and float(mk["total_score"]) == expected + 2 * len(short_ids), "manual mark applied")
    admin("admin_release", p_slug=slug, p_released=True, p_attempt=att["attempt_id"])
    res = c.rpc("get_results", p_attempt=att["attempt_id"]); check(res.ok, "results visible after release")
    res = res.json(); check("answer" in res["questions"][0] and res["feedback"] == "Good work (test)", "key + feedback shown after release")

    # practice (stage 2)
    import practice_e2e
    practice_e2e.run(c, anon, email, check, admin, URL, GW, ANON)

    # timing: exam that closes 5 s from now, so the deadline passes quickly
    tdoc = {"slug": timing_slug, "title": "E2E timing test", "time_limit_minutes": 5, "published": True,
            "closes_at": (datetime.now(timezone.utc) + timedelta(seconds=5)).isoformat(),
            "questions": [{"id": "t1", "type": "tf", "prompt": "timing", "answer": True, "marks": 1}]}
    admin("admin_upsert_exam", p=tdoc, p_force=False)
    t = c.rpc("start_attempt", p_slug=timing_slug).json(); attempt_ids.append(t["attempt_id"])
    check(c.rpc("save_answer", p_attempt=t["attempt_id"], p_question=t["questions"][0]["id"], p_response=True).ok, "save before deadline ok")
    print("     waiting 40 s for deadline + 30 s grace ...", flush=True); time.sleep(40)
    r = c.rpc("save_answer", p_attempt=t["attempt_id"], p_question=t["questions"][0]["id"], p_response=False)
    check(not r.ok and "Time is up" in r.text, "late answer rejected by server")
    g = c.rpc("get_attempt", p_attempt=t["attempt_id"]).json()
    check(g["status"] == "submitted", "expired attempt auto-submitted on next access")
    e2 = admin("admin_export", p_slug=timing_slug)["attempts"][0]
    check(e2["submit_reason"] == "time_expired" and float(e2["total_score"]) == 1, "expired attempt marked with saved answer (1/1)")
    print(f"\nALL {ok_count} CHECKS PASSED")
finally:
    for aid in attempt_ids:
        try: admin("admin_delete_attempt", p_attempt=aid)
        except Exception as e: print("cleanup attempt:", e)
    try: admin("admin_delete_exam", p_slug=timing_slug)
    except Exception: pass
    try: admin("admin_set_published", p_slug=slug, p_published=was_published)
    except Exception as e: print("cleanup publish:", e)
    if uid:
        r = requests.delete(f"{URL}/auth/v1/admin/users/{uid}", headers=ah); print("cleanup: temp user deleted" if r.ok else f"cleanup user failed {r.status_code}")
