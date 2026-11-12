"""Practice (stage 2) end-to-end checks, run from e2e_test.py with its temp student. Prints no keys or secrets.
Expected key values are computed locally from the key files (box only) to build right/wrong answers."""
import json, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import course_cli as cc  # noqa: E402
import practice_parse as pp  # noqa: E402

COURSE, WEEK, WD, POS = "cased-hole", 4, "Tuesday", 2
SECRET_KEYS = {"answer", "reference", "tol_abs", "tol_pct", "alts", "key", "key_answer", "key_reference", "expected", "tolerance",
               "auto_correct", "auto_marks", "manual_marks", "score", "marks_awarded", "correct"}


def walk(o):
    """keys that carry a value (null placeholders don't leak anything)"""
    if isinstance(o, dict):
        for k, v in o.items():
            if v is not None:
                yield k
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)


def cli(*args):
    r = subprocess.run([str(ROOT / "bin" / "exam"), *args], capture_output=True, text=True, timeout=180)
    return r.returncode, r.stdout, r.stderr


def run(c, anon, email, check, admin, URL, GW, ANON):
    import requests
    # ---- no key route for anon / student
    for t in ("practice_keys", "practice_submissions", "practice_answers", "practice_notifications"):
        r = anon.get(f"/rest/v1/{t}?select=*&limit=1"); check(not r.ok or r.json() == [], f"anon cannot read {t} ({r.status_code})")
        r = c.get(f"/rest/v1/{t}?select=*&limit=1"); check(not r.ok or r.json() == [], f"student cannot read {t} ({r.status_code})")
    r = requests.get(f"{URL}/rest/v1/practice_keys?select=*", headers={**c.h, "Accept-Profile": "private"})
    check(not r.ok, f"student cannot read private.practice_keys via schema header ({r.status_code})")
    r = requests.post(f"{URL}/graphql/v1", headers=c.h, json={"query": "{ __schema { types { name } } }"})
    names = json.dumps(r.json()) if r.ok else ""
    check("practice_keys" not in names.lower() and "PracticeKeys" not in names, "practice_keys not exposed via GraphQL")
    for fn, p in [("mentor_practice_queue", {"p_unacked_only": False}), ("mentor_practice_submissions", {"p_all": True, "p_detail": True}),
                  ("mentor_practice_overview", {}), ("mentor_load_practice", {"p": {}, "p_force": False}),
                  ("mentor_mark_practice", {"p": {}}), ("mentor_release_practice", {"p_submission": "00000000-0000-0000-0000-000000000000"}),
                  ("mentor_allow_resubmit", {"p_course": COURSE, "p_week": WEEK, "p_position": POS})]:
        r = c.rpc(fn, **p); check(not r.ok, f"student cannot call {fn} ({r.status_code})")
        r = anon.rpc(fn, **p); check(not r.ok, f"anon cannot call {fn} ({r.status_code})")
    r = anon.rpc("get_practice", p_course=COURSE, p_week=WEEK, p_position=POS); check(not r.ok, f"anon cannot call get_practice ({r.status_code})")
    r = c.get("/rest/v1/practice_fields?select=*&limit=500")
    check(r.ok and r.json() and not (set(walk(r.json())) & {"answer", "reference", "tol_abs", "tol_pct"}), f"practice_fields rows carry no key data ({len(r.json())} rows)")

    # ---- form payload has no key fields
    g = c.rpc("get_practice", p_course=COURSE, p_week=WEEK, p_position=POS); check(g.ok, "get_practice works for a published day")
    g = g.json(); qs = g["questions"]
    check(len(qs) >= 5 and g["submission"] is None, f"practice questions served ({len(qs)}), no submission yet")
    check(not (set(walk(g)) & SECRET_KEYS - {"score"}), "practice payload contains no key / mark fields")
    fields = {f["fkey"]: f for q in qs for f in q["fields"]}

    # ---- expected values (local key parse, never printed)
    pack = cc.SOURCES[COURSE]()["weeks"][WEEK - 1]["days"][WD]["pack"]
    loc = pp.parse_day(COURSE, WEEK, WD, pack)
    keyed = [(f["fkey"], f) for q in loc["questions"] for f in q["fields"] if f["kind"] == "numeric" and f["key"].get("answer") is not None]
    check(len(keyed) >= 5, f"enough auto-marked fields for the test ({len(keyed)})")
    plan = {}
    (k0, f0), (k1, f1), (k2, f2), (k3, f3), (k4, f4) = keyed[:5]
    tol = lambda f: max(f["key"]["tol_abs"] or 0, abs(f["key"]["answer"]) * (f["key"]["tol_pct"] or 0) / 100)
    plan[k0] = (f"{f0['key']['answer']:,}", True)                         # exact, with thousands separators
    plan[k1] = (str(f1["key"]["answer"] + 0.8 * tol(f1)), True)            # inside tolerance
    plan[k2] = (str(f2["key"]["answer"] + 3 * tol(f2) + 1e-9), False)      # outside tolerance
    plan[k3] = ("", False)                                                 # blank
    plan[k4] = ("not a number", False)
    for k, f in keyed[5:]:
        plan[k] = (str(f["key"]["answer"]).replace("-", "−"), True)        # unicode minus is accepted
    answers = {fields[k]["id"]: v for k, (v, _) in plan.items()}
    texts = [f for f in fields.values() if f["kind"] != "numeric"]
    for f in texts:
        answers[f["id"]] = f"Test answer for {f['fkey']}"
    want = sum(float(fields[k]["marks"]) for k, (_, okk) in plan.items() if okk)

    # ---- draft, then submit
    r = c.rpc("save_practice", p_course=COURSE, p_week=WEEK, p_position=POS, p_answers={fields[k0]["id"]: plan[k0][0]}, p_submit=False)
    check(r.ok and r.json()["submission"]["status"] == "draft", "draft saved")
    g = c.rpc("get_practice", p_course=COURSE, p_week=WEEK, p_position=POS).json()
    check(g["submission"]["answers"][fields[k0]["id"]]["value"] == plan[k0][0], "draft answer persists")
    check(not (set(walk(g["submission"])) & SECRET_KEYS), "draft view has no marks")
    r = c.rpc("save_practice", p_course=COURSE, p_week=WEEK, p_position=POS, p_answers=answers, p_submit=True)
    check(r.ok and r.json()["submission"]["status"] == "submitted", "practice submitted")
    sv = r.json()["submission"]
    check(not sv["released"] and sv.get("score") is None and not (set(walk(sv)) & SECRET_KEYS), "score/marks/expected hidden before release")
    r = c.rpc("save_practice", p_course=COURSE, p_week=WEEK, p_position=POS, p_answers=answers, p_submit=True)
    check(not r.ok and "Already submitted" in r.text, "second submission blocked by default")
    dash = c.rpc("practice_dashboard").json()
    row = next(x for x in dash if x["course"] == COURSE and x["week"] == WEEK and x["position"] == POS)
    check(row["status"] == "submitted" and row["score"] is None, "progress shows submitted, no score before release")

    # ---- queue + CLI
    rc, out, err = cli("wake-queue", "--json"); check(rc == 0, f"bin/exam wake-queue --json runs ({err[-200:]})")
    q = json.loads(out); mine = [n for n in q["practice"] if n["student_email"] == email]
    check(len(mine) == 1 and "quiz" in q, "practice submission queued (wake-queue covers quiz + practice)")
    note = mine[0]
    check(float(note["auto_score"]) == want, f"auto-marking within tolerance is correct ({note['auto_score']} == {want})")
    check(note["pending_manual"] == len([f for f in texts if float(f["marks"]) > 0]), f"text answers pending manual marking ({note['pending_manual']})")
    sid = note["submission_id"]
    rc, out, err = cli("practice-submissions", "--json", "--id", sid); check(rc == 0, "bin/exam practice-submissions --json --id")
    det = json.loads(out); by = {a["fkey"]: a for a in det["answers"]}
    check(all(bool(by[k]["auto_correct"]) == okk for k, (_, okk) in plan.items()), "per-answer auto results right (exact, within tol, outside, blank, text-in-number)")
    rc, out, err = cli("practice-release", "--id", sid); check(rc != 0 and "need marking" in (out + err), "release refused while answers still need marking")
    marks = {"submission_id": sid, "feedback": "E2E overall feedback",
             "marks": [{"fkey": f["fkey"], "marks": float(f["marks"]), "feedback": "Good (test)"} for f in texts]}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(marks, fh); mf = fh.name
    rc, out, err = cli("practice-mark", "--file", mf); Path(mf).unlink(missing_ok=True)
    check(rc == 0 and json.loads(out.splitlines()[0])["pending_manual"] == 0, "bin/exam practice-mark applied text marks")
    g = c.rpc("get_practice", p_course=COURSE, p_week=WEEK, p_position=POS).json()
    check(g["submission"].get("score") is None and not (set(walk(g["submission"])) & SECRET_KEYS), "still hidden after marking, before release")
    rc, out, err = cli("practice-release", "--id", sid); check(rc == 0, "bin/exam practice-release")
    g = c.rpc("get_practice", p_course=COURSE, p_week=WEEK, p_position=POS).json()["submission"]
    total = want + sum(float(f["marks"]) for f in texts)
    check(g["released"] and float(g["score"]) == total and g["feedback"] == "E2E overall feedback", f"released score shown ({g['score']} == {total})")
    a0 = g["answers"][fields[k2]["id"]]
    check(a0["correct"] is False and a0.get("expected") is not None and "reference" not in json.dumps(g), "released: per-answer result + expected value, no key text")
    rc, out, err = cli("practice-unrelease", "--id", sid); check(rc == 0, "bin/exam practice-unrelease")
    g = c.rpc("get_practice", p_course=COURSE, p_week=WEEK, p_position=POS).json()["submission"]
    check(not g["released"] and g.get("score") is None and not (set(walk(g)) & SECRET_KEYS), "unrelease hides the score again")
    cli("practice-release", "--id", sid)
    dash = c.rpc("practice_dashboard").json()
    row = next(x for x in dash if x["course"] == COURSE and x["week"] == WEEK and x["position"] == POS)
    check(row["released"] and float(row["score"]) == total, "progress shows the released practice score")
    rc, out, err = cli("practice-allow-resubmit", "--course", COURSE, "--week", str(WEEK), "--day", WD, "--email", email)
    check(rc == 0 and json.loads(out)["resubmit_allowed"], "bin/exam practice-allow-resubmit")
    r = c.rpc("save_practice", p_course=COURSE, p_week=WEEK, p_position=POS, p_answers={}, p_submit=False)
    check(r.ok and r.json()["submission"]["attempt"] == 2 and r.json()["submission"]["status"] == "draft"
          and r.json()["submission"]["answers"][fields[k0]["id"]]["value"] == plan[k0][0], "resubmission opens attempt 2 with previous answers")
    rc, out, err = cli("practice-ack", "--id", note["id"]); check(rc == 0 and json.loads(out)["acked"] == 1, "bin/exam practice-ack")
    rc, out, err = cli("wake-queue", "--json")
    check(rc == 0 and not [n for n in json.loads(out)["practice"] if n["id"] == note["id"]], "acked notification leaves the wake queue")
