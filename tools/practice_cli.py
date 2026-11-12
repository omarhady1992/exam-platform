"""Practice (stage 2) commands for bin/exam: load questions+keys, queue, mark, release, ack, allow resubmit.

Keys are parsed from local key folders and sent straight to the database (service role, private.practice_keys).
They are never written to the repo, the site, the storage bucket, or any file. Output of practice-load-keys shows
counts only; key text appears only in `practice-submissions --json` (Study Mentor's marking view, service role).
"""
import json, sys
from pathlib import Path

import course_cli as cc
import practice_parse as pp

CAIRO = None


def _cairo(ts):
    if not ts:
        return ts
    try:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(ZoneInfo("Africa/Cairo")).strftime("%Y-%m-%d %H:%M (Cairo)")
    except Exception:
        return ts


def _round(x):
    return None if x is None else float(f"{x:.6g}")


def _payload(course, n, weekday, position, res):
    qs = []
    for q in res["questions"]:
        fields = []
        for i, f in enumerate(q["fields"]):
            k = dict(f["key"])
            for t in ("answer", "tol_abs", "tol_pct"):
                if t in k:
                    k[t] = _round(k[t])
            k["alts"] = [{**a, "answer": _round(a["answer"]), "tol_abs": _round(a["tol_abs"])} for a in k.get("alts", [])]
            fields.append({**{x: f[x] for x in ("fkey", "label", "kind", "unit", "marks")}, "position": i + 1, "key": k})
        qs.append({"qkey": q["qkey"], "section": q["section"], "prompt": q["prompt"], "page": q["page"],
                   "position": q["position"], "fields": fields})
    note = "; ".join(res.get("notes") or []) or None
    return {"course": course, "week": n, "position": position, "page": res.get("page"), "note": None,
            "key_file": res.get("key_file"), "status": res["status"] + (f": {note}" if note else ""), "questions": qs}


def _local_days(slug):
    man = cc.SOURCES[slug]()
    out = {}
    for w in man["weeks"]:
        days = w["days"].values() if isinstance(w["days"], dict) else w["days"]
        for d in days:
            out[(w["n"], d["weekday"])] = d.get("pack")
    return out


def load_keys(course=None, week=None, day=None, dry=False, include_unpublished=False, force=False, log=print):
    report = []
    for c in cc.rpc("admin_list_courses"):
        if course and c["slug"] != course:
            continue
        if c["slug"] not in pp.KEY_DIRS:
            continue
        pos = cc._position(c, day) if day else None
        local = _local_days(c["slug"])
        for w in c["weeks"]:
            if week and w["n"] != week:
                continue
            for d in w["days"]:
                if pos and d["position"] != pos:
                    continue
                visible = d.get("published") and w.get("published") and c.get("published")
                if not visible and not include_unpublished:
                    continue
                res = pp.parse_day(c["slug"], w["n"], d["weekday"], local.get((w["n"], d["weekday"])))
                nf = sum(len(q["fields"]) for q in res["questions"])
                nn = sum(1 for q in res["questions"] for f in q["fields"] if f["kind"] == "numeric")
                row = {"course": c["slug"], "week": w["n"], "position": d["position"], "weekday": d["weekday"], "title": d["title"],
                       "status": res["status"], "questions": len(res["questions"]), "fields": nf, "auto_marked": nn,
                       "keyed": sum(1 for q in res["questions"] for f in q["fields"] if f["key"].get("reference") or f["key"].get("answer") is not None),
                       "notes": res.get("notes")}
                if res["questions"] and not dry:
                    out = cc.rpc("mentor_load_practice", p=_payload(c["slug"], w["n"], d["weekday"], d["position"], res), p_force=force)
                    row["db"] = out
                report.append(row)
                log(f"{'DRY ' if dry else ''}{c['slug']} W{w['n']} {d['weekday'][:3]}: {res['status']} · {row['questions']} questions, "
                    f"{nf} fields ({nn} auto-marked, {row['keyed']} with a key)" + (f" · {'; '.join(res['notes'])}" if res.get("notes") else ""))
    return report


# ------------------------------------------------------------------ commands
def cmd_load(a):
    rep = load_keys(a.course, a.week, a.day, dry=a.dry_run, include_unpublished=a.include_unpublished, force=a.force,
                    log=(lambda *_: None) if a.json else print)
    if a.json:
        print(json.dumps(rep, indent=2, ensure_ascii=False))
        return
    tot = {}
    for r in rep:
        t = tot.setdefault(r["course"], {"days": 0, "loaded": 0, "questions": 0, "fields": 0, "auto": 0, "keyed": 0, "unparsed": []})
        t["days"] += 1
        if r["questions"]:
            t["loaded"] += 1
        else:
            t["unparsed"].append(f"W{r['week']} {r['weekday'][:3]}")
        for k, src in (("questions", "questions"), ("fields", "fields"), ("auto", "auto_marked"), ("keyed", "keyed")):
            t[k] += r[src]
    print("\nsummary (no key content shown):")
    for c, t in tot.items():
        print(f"  {c}: {t['loaded']}/{t['days']} days loaded · {t['questions']} questions · {t['fields']} answer fields "
              f"({t['auto']} auto-marked numeric, {t['keyed']} with a key)" + (f" · unparsed: {', '.join(t['unparsed'])}" if t["unparsed"] else ""))


def cmd_list(a):
    rows = cc.rpc("mentor_practice_overview")
    if a.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False)); return
    for r in rows:
        if not r["questions"] and not a.all:
            continue
        print(f"{r['course']:22} W{r['week']} {r['weekday'][:3]} {'pub ' if r['published'] else 'hid '} q={r['questions']:<3} fields={r['fields']:<3} "
              f"auto={r['auto']:<3} keyed={r['keyed']:<3} {r.get('status') or ''}")


def cmd_submissions(a):
    rows = cc.rpc("mentor_practice_submissions", p_all=a.all or bool(a.id), p_detail=bool(a.json))
    if a.id:
        rows = [r for r in rows if r["submission_id"] == a.id]
    for r in rows:
        r["submitted_at_cairo"] = _cairo(r.get("submitted_at"))
    if a.json:
        print(json.dumps(rows if not a.id else (rows[0] if rows else None), indent=2, ensure_ascii=False)); return
    if not rows:
        print("No practice submissions" + ("" if a.all else " waiting for release") + "."); return
    for r in rows:
        print(f"{r['submission_id']}\n  {r['course']} W{r['week']} {r['weekday']} · {r['day_title']} · attempt {r['attempt']} · {r.get('student_email')}\n"
              f"  submitted {r['submitted_at_cairo']} · score {r.get('score')}/{r.get('max_score')} (auto {r.get('auto_score')}) · "
              f"pending_manual={r.get('pending_manual')} · {'RELEASED' if r.get('released') else 'not released'}\n"
              f"  bin/exam practice-submissions --json --id {r['submission_id']}")


def cmd_mark(a):
    data = json.loads(Path(a.file).read_text())
    items = data if isinstance(data, list) else [data]
    for it in items:
        if "submission_id" not in it:
            raise cc.CourseError("each mark object needs submission_id")
        res = cc.rpc("mentor_mark_practice", p=it)
        print(json.dumps(res, ensure_ascii=False))
        if a.release:
            print(json.dumps(cc.rpc("mentor_release_practice", p_submission=it["submission_id"], p_released=True, p_force=a.force)))


def cmd_release(a, released=True):
    print(json.dumps(cc.rpc("mentor_release_practice", p_submission=a.id, p_released=released, p_force=getattr(a, "force", False))))


def cmd_ack(a):
    if not (a.id or a.submission):
        raise cc.CourseError("Provide --id <practice notification id> or --submission <submission id>")
    print(json.dumps(cc.rpc("mentor_ack_practice", p_id=a.id, p_submission=a.submission, p_by="study-mentor")))


def cmd_allow(a):
    c = cc._course_days(a.course)
    pos = cc._position(c, a.day)
    print(json.dumps(cc.rpc("mentor_allow_resubmit", p_course=a.course, p_week=a.week, p_position=pos, p_email=a.email, p_allow=not a.revoke)))


def wake_queue(all_=False):
    finishes = cc.rpc("admin_list_finishes", p_unacked_only=not all_) or []
    practice = cc.rpc("mentor_practice_queue", p_unacked_only=not all_) or []
    for n in finishes:
        n.setdefault("kind", "quiz")
    for n in practice:
        n["submitted_at_cairo"] = _cairo(n.get("submitted_at"))
    return {"quiz": finishes, "practice": practice, "total": len(finishes) + len(practice)}


def cmd_wake(a):
    q = wake_queue(a.all)
    if a.json:
        print(json.dumps(q, indent=2, ensure_ascii=False)); return
    if not q["total"]:
        print("Nothing waiting (quiz finishes and practice submissions are all acked)."); return
    for n in q["quiz"]:
        print(f"QUIZ     {n['id']} · {n['exam_slug']} · attempt {n['attempt_id']} · pending_manual={n.get('pending_manual')}")
    for n in q["practice"]:
        print(f"PRACTICE {n['id']} · {n['course']} W{n['week']} {n['weekday']} · attempt {n['attempt']} · auto {n.get('auto_score')}/{n.get('max_score')} "
              f"· pending_manual={n['pending_manual']} · {n['submitted_at_cairo']}\n  {n['commands']['export']}\n  {n['commands']['release']}\n  {n['commands']['ack']}")


def add_parsers(sub):
    s = sub.add_parser("practice-load-keys", help="parse practice questions + answer keys and load them (keys go to the private DB table only)")
    s.add_argument("--course"); s.add_argument("--week", type=int); s.add_argument("--day", help="weekday name or position")
    s.add_argument("--dry-run", action="store_true"); s.add_argument("--json", action="store_true")
    s.add_argument("--include-unpublished", action="store_true", help="also load draft days")
    s.add_argument("--force", action="store_true", help="remove stale questions even if someone already submitted")
    s.set_defaults(fn=cmd_load)
    s = sub.add_parser("practice-list", help="practice question/key counts per day")
    s.add_argument("--json", action="store_true"); s.add_argument("--all", action="store_true", help="include days without practice")
    s.set_defaults(fn=cmd_list)
    s = sub.add_parser("practice-submissions", help="submitted practice (default: not yet released); --json includes answers + key references")
    s.add_argument("--json", action="store_true"); s.add_argument("--all", action="store_true"); s.add_argument("--id", help="one submission id")
    s.set_defaults(fn=cmd_submissions)
    s = sub.add_parser("practice-mark", help="apply marks/feedback from a JSON file")
    s.add_argument("--file", required=True); s.add_argument("--release", action="store_true", help="release after marking")
    s.add_argument("--force", action="store_true"); s.set_defaults(fn=cmd_mark)
    s = sub.add_parser("practice-release", help="release marks/feedback of a submission to the student")
    s.add_argument("--id", required=True, help="submission id"); s.add_argument("--force", action="store_true", help="release with unmarked answers")
    s.set_defaults(fn=cmd_release)
    s = sub.add_parser("practice-unrelease", help="hide a released practice result again")
    s.add_argument("--id", required=True); s.set_defaults(fn=lambda a: cmd_release(a, False))
    s = sub.add_parser("practice-ack", help="acknowledge a practice notification")
    s.add_argument("--id"); s.add_argument("--submission"); s.set_defaults(fn=cmd_ack)
    s = sub.add_parser("practice-allow-resubmit", help="let the student submit a day's practice again")
    s.add_argument("--course", required=True); s.add_argument("--week", type=int, required=True); s.add_argument("--day", required=True)
    s.add_argument("--email"); s.add_argument("--revoke", action="store_true"); s.set_defaults(fn=cmd_allow)
    s = sub.add_parser("wake-queue", help="one poll for Study Mentor: unacked quiz finishes + practice submissions")
    s.add_argument("--json", action="store_true"); s.add_argument("--all", action="store_true"); s.set_defaults(fn=cmd_wake)
