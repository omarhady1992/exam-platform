#!/usr/bin/env python3
"""exam - Study Mentor's command line tool for the exam platform.

Reads SUPABASE_SERVICE_ROLE_KEY (required) and SUPABASE_URL (optional) from the environment.
Never prints secrets. Times are shown in Cairo time (Africa/Cairo).
"""
import argparse, hashlib, json, mimetypes, os, re, sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import requests

CAIRO = ZoneInfo("Africa/Cairo")
DEFAULT_URL = "https://czqtzjkkxpzixiiplvro.supabase.co"
ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "schema" / "exam.schema.json"
BUCKET = "exam-images"
SITE_URL = "https://omarhady1992.github.io/exam-platform/"


class CliError(Exception):
    pass


# ------------------------------------------------------------------ API helpers
def _cfg():
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not key:
        raise CliError("SUPABASE_SERVICE_ROLE_KEY is not set in the environment")
    return os.environ.get("SUPABASE_URL", DEFAULT_URL).rstrip("/"), key


def _headers(key, extra=None):
    h = {"apikey": key, "Authorization": f"Bearer {key}"}
    h.update(extra or {})
    return h


def rpc(name, **params):
    url, key = _cfg()
    r = requests.post(f"{url}/rest/v1/rpc/{name}", headers=_headers(key, {"Content-Type": "application/json"}),
                      data=json.dumps(params), timeout=60)
    if r.status_code >= 300:
        try:
            msg = r.json().get("message") or r.text
        except Exception:
            msg = r.text
        raise CliError(f"{name} failed ({r.status_code}): {msg}")
    return r.json() if r.text else None


def upload_image(local: Path, slug: str) -> str:
    url, key = _cfg()
    data = local.read_bytes()
    ext = local.suffix.lower() or ".bin"
    if ext not in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"):
        raise CliError(f"Unsupported image type: {local.name}")
    # Content-hash name: does not leak the original (possibly answer-revealing) filename.
    path = f"{slug}/{hashlib.sha256(data).hexdigest()[:20]}{ext}"
    ctype = mimetypes.guess_type(local.name)[0] or "application/octet-stream"
    r = requests.post(f"{url}/storage/v1/object/{BUCKET}/{path}",
                      headers=_headers(key, {"Content-Type": ctype, "x-upsert": "true"}), data=data, timeout=120)
    if r.status_code >= 300:
        raise CliError(f"Image upload failed for {local}: {r.status_code} {r.text[:200]}")
    return path


# ------------------------------------------------------------------ time helpers
TS_KEYS = {"opens_at", "closes_at", "released_at", "created_at", "updated_at", "started_at", "deadline",
           "submitted_at", "saved_at", "at", "client_ts", "exported_at"}


def parse_cairo(s):
    if s in (None, ""):
        return None
    try:
        dt = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        raise CliError(f"Bad date-time '{s}'. Use e.g. 2026-11-02 08:00 (Cairo) or 2026-11-02T06:00:00Z")
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=CAIRO)
    return dt.isoformat()


def to_cairo(v):
    if not isinstance(v, str):
        return v
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone(CAIRO).isoformat(timespec="seconds")
    except ValueError:
        return v


def cairo_times(obj):
    if isinstance(obj, dict):
        return {k: (to_cairo(v) if k in TS_KEYS else cairo_times(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [cairo_times(x) for x in obj]
    return obj


def fmt(v):
    if not v:
        return "-"
    return datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone(CAIRO).strftime("%a %d %b %Y %H:%M Cairo")


# ------------------------------------------------------------------ validation
def validate(doc, base: Path):
    errors = []
    try:
        import jsonschema
        schema = json.loads(SCHEMA.read_text())
        v = jsonschema.Draft202012Validator(schema)
        for e in sorted(v.iter_errors(doc), key=lambda e: list(e.path)):
            loc = "/".join(str(p) for p in e.path) or "(root)"
            errors.append(f"{loc}: {e.message}")
    except ImportError:
        print("warning: jsonschema not installed; only basic checks run", file=sys.stderr)
    if errors:
        return errors
    seen = set()
    for i, q in enumerate(doc["questions"]):
        where = f"questions/{i} ({q['id']})"
        if q["id"] in seen:
            errors.append(f"{where}: duplicate question id")
        seen.add(q["id"])
        if q["type"] in ("mcq", "multi"):
            ids = [o["id"] if isinstance(o, dict) else chr(97 + j) for j, o in enumerate(q["options"])]
            if len(set(ids)) != len(ids):
                errors.append(f"{where}: duplicate option ids")
            ans = [q["answer"]] if q["type"] == "mcq" else q["answer"]
            for a in ans:
                if a not in ids:
                    errors.append(f"{where}: answer '{a}' is not one of the option ids {ids}")
        if q["type"] == "numeric" and q.get("tolerance_abs") is None and q.get("tolerance_pct") is None:
            print(f"note: {where} has no tolerance; only an exact match scores", file=sys.stderr)
        if q.get("image"):
            p = (base / q["image"]).expanduser()
            if not p.is_file():
                errors.append(f"{where}: image not found: {p}")
    try:
        o, c = parse_cairo(doc.get("opens_at")), parse_cairo(doc.get("closes_at"))
        if o and c and datetime.fromisoformat(c) <= datetime.fromisoformat(o):
            errors.append("closes_at must be after opens_at")
    except CliError as e:
        errors.append(str(e))
    return errors


def normalise(doc, base: Path, slug_for_images: str, upload=True):
    out = {k: doc.get(k) for k in ("slug", "title", "instructions", "time_limit_minutes", "attempts_allowed",
                                     "shuffle_questions", "shuffle_options", "log_focus") if k in doc}
    out["opens_at"] = parse_cairo(doc.get("opens_at"))
    out["closes_at"] = parse_cairo(doc.get("closes_at"))
    if "published" in doc:
        out["published"] = doc["published"]
    qs = []
    for q in doc["questions"]:
        nq = {"id": q["id"], "type": q["type"], "prompt": q["prompt"], "marks": q.get("marks", 1),
              "unit": q.get("unit"), "explanation": q.get("explanation"),
              "tolerance_abs": q.get("tolerance_abs"), "tolerance_pct": q.get("tolerance_pct"),
              "answer": q.get("answer")}
        if q["type"] in ("mcq", "multi"):
            nq["options"] = [o if isinstance(o, dict) else {"id": chr(97 + j), "text": o}
                             for j, o in enumerate(q["options"])]
        if q.get("image"):
            nq["image_path"] = upload_image((base / q["image"]).expanduser(), slug_for_images) if upload else "(local)"
        qs.append(nq)
    out["questions"] = qs
    return out


def load_exam(path):
    p = Path(path)
    if p.suffix.lower() != ".json":
        raise CliError("Only .json exam files are supported (see schema/exam.schema.json)")
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise CliError(f"{p}: invalid JSON: {e}")
    return doc, p.resolve().parent


# ------------------------------------------------------------------ commands
def cmd_validate(a):
    doc, base = load_exam(a.file)
    errs = validate(doc, base)
    if errs:
        raise CliError("Validation failed:\n  " + "\n  ".join(errs))
    total = sum(q.get("marks", 1) for q in doc["questions"])
    print(f"OK: {doc['slug']} - {len(doc['questions'])} questions, {total:g} marks, {doc['time_limit_minutes']} min")


def cmd_upload(a):
    doc, base = load_exam(a.file)
    errs = validate(doc, base)
    if errs:
        raise CliError("Validation failed:\n  " + "\n  ".join(errs))
    if a.publish:
        doc["published"] = True
    if a.unpublish:
        doc["published"] = False
    payload = normalise(doc, base, doc["slug"])
    res = rpc("admin_upsert_exam", p=payload, p_force=a.force)
    state = "PUBLISHED (visible to Omar)" if res["published"] else "unpublished (hidden)"
    print(f"Uploaded {res['slug']}: {res['questions']} questions, {state}")
    if res.get("had_attempts"):
        print("note: exam already had attempts; submitted attempts were re-marked with the new key")
    print(f"Omar's link: {SITE_URL}#/exam/{res['slug']}")


def cmd_publish(a):
    res = rpc("admin_set_published", p_slug=a.slug, p_published=a.cmd == "publish")
    print(f"{res['slug']}: published={res['published']}")


def cmd_list(a):
    rows = rpc("admin_list")
    if a.json:
        print(json.dumps(cairo_times(rows), indent=2))
        return
    if not rows:
        print("No exams yet.")
        return
    for r in rows:
        print(f"{r['slug']}\n  {r['title']}\n  published={r['published']}  released={r['results_released']}  "
              f"{r['questions']} q / {r['total_marks']:g} marks / {r['time_limit_minutes']} min  attempts allowed={r['attempts_allowed']}\n"
              f"  opens {fmt(r['opens_at'])}  closes {fmt(r['closes_at'])}\n"
              f"  attempts: {r['attempts']} ({r['submitted']} submitted), short answers to mark: {r['pending_manual']}")


def cmd_export(a):
    data = cairo_times(rpc("admin_export", p_slug=a.slug))
    text = json.dumps(data, indent=2, ensure_ascii=False)
    if a.out:
        Path(a.out).write_text(text, encoding="utf-8")
        n = len(data["attempts"])
        print(f"Wrote {a.out}: {n} attempt(s), {len(data['pending_short_answers'])} short answer(s) awaiting marks")
    else:
        print(text)


def cmd_mark(a):
    doc = json.loads(Path(a.file).read_text(encoding="utf-8"))
    items = doc if isinstance(doc, list) else [doc]
    for it in items:
        if not isinstance(it, dict) or not isinstance(it.get("questions", []), list):
            raise CliError("Mark file must be an object (or list of objects) with a 'questions' list")
        res = rpc("admin_mark", p_slug=a.slug, p=it)
        print(f"attempt {res['attempt_id']}: updated {res['updated_questions']} question(s); "
              f"score {res['total_score']:g}/{res['max_score']:g}; short answers still unmarked: {res['pending_manual']}")


def cmd_release(a):
    res = rpc("admin_release", p_slug=a.slug, p_released=a.cmd == "release", p_attempt=a.attempt)
    scope = f"attempt {a.attempt}" if a.attempt else "all attempts"
    print(f"{a.slug}: results {'RELEASED' if res['released'] else 'hidden'} for {scope}")
    if res["released"] and res["pending_manual"]:
        print(f"warning: {res['pending_manual']} short answer(s) are still unmarked (shown to Omar as 'awaiting marking')")


def cmd_delete_attempt(a):
    print(json.dumps(rpc("admin_delete_attempt", p_attempt=a.attempt_id)))


def cmd_delete_exam(a):
    if not a.yes:
        raise CliError("This deletes the exam, its questions, keys, attempts and answers. Re-run with --yes")
    print(json.dumps(rpc("admin_delete_exam", p_slug=a.slug)))
    url, key = _cfg()
    r = requests.post(f"{url}/storage/v1/object/list/exam-images", headers=_headers(key, {"Content-Type": "application/json"}),
                      json={"prefix": f"{a.slug}/", "limit": 1000}, timeout=60)
    names = [f"{a.slug}/{o['name']}" for o in (r.json() if r.ok else []) if o.get("name")]
    if names:
        d = requests.delete(f"{url}/storage/v1/object/exam-images", headers=_headers(key, {"Content-Type": "application/json"}),
                            json={"prefixes": names}, timeout=60)
        print(f"removed {len(names)} image(s)" if d.ok else f"warning: image cleanup failed ({d.status_code})")


def cmd_allow_user(a):
    print(json.dumps(rpc("admin_allow_user", p_email=a.email, p_role=a.role)))


def main(argv=None):
    p = argparse.ArgumentParser(prog="exam", description="Exam platform CLI (Study Mentor)")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("validate", help="check an exam JSON file without uploading"); s.add_argument("file"); s.set_defaults(fn=cmd_validate)
    s = sub.add_parser("upload", help="validate + upload (create or update by slug)")
    s.add_argument("file"); g = s.add_mutually_exclusive_group()
    g.add_argument("--publish", action="store_true", help="make it visible to Omar")
    g.add_argument("--unpublish", action="store_true", help="hide it from Omar")
    s.add_argument("--force", action="store_true", help="allow removing questions from an exam that has attempts")
    s.set_defaults(fn=cmd_upload)
    for c in ("publish", "unpublish"):
        s = sub.add_parser(c); s.add_argument("slug"); s.set_defaults(fn=cmd_publish)
    s = sub.add_parser("list", help="list exams and attempt counts"); s.add_argument("--json", action="store_true"); s.set_defaults(fn=cmd_list)
    s = sub.add_parser("export", help="export exam, key, attempts, answers, marks, focus log")
    s.add_argument("slug"); s.add_argument("--out"); s.set_defaults(fn=cmd_export)
    s = sub.add_parser("mark", help="apply manual marks / feedback from a JSON file")
    s.add_argument("slug"); s.add_argument("--file", required=True); s.set_defaults(fn=cmd_mark)
    for c in ("release", "unrelease"):
        s = sub.add_parser(c, help=f"{c} results to Omar"); s.add_argument("slug")
        s.add_argument("--attempt", help="only this attempt id"); s.set_defaults(fn=cmd_release)
    s = sub.add_parser("delete-attempt", help="delete one attempt (e.g. to allow a retake)"); s.add_argument("attempt_id"); s.set_defaults(fn=cmd_delete_attempt)
    s = sub.add_parser("delete-exam"); s.add_argument("slug"); s.add_argument("--yes", action="store_true"); s.set_defaults(fn=cmd_delete_exam)
    s = sub.add_parser("allow-user", help="allow an existing auth user to use the site")
    s.add_argument("email"); s.add_argument("--role", default="student", choices=["student", "admin"]); s.set_defaults(fn=cmd_allow_user)
    a = p.parse_args(argv)
    try:
        a.fn(a)
    except CliError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except requests.RequestException as e:
        print(f"error: network problem: {e.__class__.__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
