#!/usr/bin/env python3
"""Equation-sheet access test. Creates a temporary exam with a 3-page sheet (2-page PDF + 1 PNG) and two
temporary users, checks who can open the sheet when, then removes the exam, its storage objects, attempts and users.
Student calls use the public anon key from site/config.js with the temp user's JWT. Prints no secrets."""
import json, os, re, secrets, struct, sys, tempfile, time, zlib
from argparse import Namespace
from datetime import datetime, timedelta, timezone
from pathlib import Path
import requests

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import exam_cli as cli  # noqa: E402

URL = os.environ.get("SUPABASE_URL", "https://czqtzjkkxpzixiiplvro.supabase.co")
SK = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
ANON = re.search(r'SUPABASE_ANON_KEY\s*:\s*"([^"]+)"', (ROOT / "site/config.js").read_text()).group(1)
ah = {"apikey": SK, "Authorization": f"Bearer {SK}", "Content-Type": "application/json"}
ok_count = 0


def check(cond, msg):
    global ok_count
    if not cond:
        print("FAIL:", msg); raise SystemExit(1)
    ok_count += 1; print("ok  ", msg)


def admin(name, **p):
    r = requests.post(f"{URL}/rest/v1/rpc/{name}", headers=ah, json=p)
    if r.status_code >= 300: raise RuntimeError(f"{name}: {r.status_code} {r.text[:300]}")
    return r.json()


class Client:
    def __init__(self, jwt=None):
        self.h = {"apikey": ANON, "Authorization": f"Bearer {jwt or ANON}", "Content-Type": "application/json"}
    def rpc(self, name, **p): return requests.post(f"{URL}/rest/v1/rpc/{name}", headers=self.h, json=p)
    def sign(self, path): return requests.post(f"{URL}/storage/v1/object/sign/exam-images/{path}", headers=self.h, json={"expiresIn": 120})
    def can_sign(self, path):
        r = self.sign(path)
        return r.ok and "signedURL" in r.json()


def png(w, h, path):
    raw = b"".join(b"\x00" + b"\xff\xff\xff" * w for _ in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def pdf(path, pages=2):
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", None]
    kids = []
    for i in range(pages):
        content = f"BT /F1 24 Tf 72 720 Td (Sheet page {i + 1}: F = m a) Tj ET".encode()
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 {3 + 2 * pages} 0 R >> >> /Contents {len(objs) + 2} 0 R >>")
        kids.append(f"{len(objs)} 0 R")
        objs.append(f"<< /Length {len(content)} >>\nstream\n{content.decode()}\nendstream")
    objs[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {pages} >>"
    objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    out, offs = b"%PDF-1.4\n", []
    for i, o in enumerate(objs):
        offs.append(len(out)); out += f"{i + 1} 0 obj\n{o}\nendobj\n".encode()
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode() + b"".join(f"{o:010d} 00000 n \n".encode() for o in offs)
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n".encode()
    Path(path).write_bytes(out)


slug = f"zz-sheet-test-{secrets.token_hex(3)}"
users, attempt_ids, made_exam = [], [], False


def new_user(tag):
    email, pw = f"sheet-test-{tag}-{secrets.token_hex(4)}@example.com", secrets.token_urlsafe(24)
    r = requests.post(f"{URL}/auth/v1/admin/users", headers=ah, json={"email": email, "password": pw, "email_confirm": True})
    r.raise_for_status(); users.append(r.json()["id"])
    admin("admin_allow_user", p_email=email, p_role="student")
    tok = requests.post(f"{URL}/auth/v1/token?grant_type=password", headers={"apikey": ANON, "Content-Type": "application/json"},
                        json={"email": email, "password": pw}).json()["access_token"]
    return Client(tok)


try:
    with tempfile.TemporaryDirectory() as tmp:
        pdf(f"{tmp}/sheet.pdf"); png(400, 560, f"{tmp}/extra.png")
        doc = {"slug": slug, "title": "Sheet access test (temporary)", "time_limit_minutes": 5, "attempts_allowed": 2,
               "log_focus": True, "published": True,
               "equation_sheet": {"title": "Test formula sheet", "files": ["sheet.pdf", "extra.png"], "dpi": 72},
               "questions": [{"id": "s1", "type": "tf", "prompt": "Sheet test", "answer": True}]}
        Path(f"{tmp}/t.json").write_text(json.dumps(doc))
        check(cli.validate(doc, Path(tmp)) == [], "validate accepts the sheet")
        bad = dict(doc, equation_sheet=["nope.pdf"])
        check(any("not found" in e for e in cli.validate(bad, Path(tmp))), "validate rejects a missing sheet file")
        payload = cli.normalise(doc, Path(tmp), slug)
    pages = [p["path"] for p in payload["equation_sheet"]["pages"]]
    check(len(pages) == 3 and all(p.startswith(f"{slug}/sheet-") and p.endswith(".png") for p in pages), "PDF rendered + PNG uploaded as 3 sheet pages")
    res = admin("admin_upsert_exam", p=payload, p_force=False); made_exam = True
    check(res.get("equation_sheet_pages") == 3, "admin_upsert_exam stores 3 pages")
    check(any(e["slug"] == slug and e.get("equation_sheet_pages") == 3 for e in admin("admin_list")), "admin_list shows sheet pages")

    anon = Client()
    check(not anon.can_sign(pages[0]), "anon cannot sign a sheet page")
    pub = requests.get(f"{URL}/storage/v1/object/public/exam-images/{pages[0]}")
    check(pub.status_code >= 400, f"public URL is not served ({pub.status_code})")

    a, b = new_user("a"), new_user("b")
    ex = next(e for e in a.rpc("list_my_exams").json()["exams"] if e["slug"] == slug)
    check(ex.get("has_equation_sheet") is True and "equation_sheet" not in ex, "dashboard flags the sheet without exposing it")
    check(not a.can_sign(pages[0]), "user without an attempt cannot sign")

    att = a.rpc("start_attempt", p_slug=slug).json(); aid = att["attempt_id"]; attempt_ids.append(aid)
    g = a.rpc("get_attempt", p_attempt=aid).json()
    sh = g.get("equation_sheet") or {}
    check(sh.get("title") == "Test formula sheet" and [p["path"] for p in sh.get("pages", [])] == pages
          and all(p.get("w") and p.get("h") for p in sh["pages"]), "get_attempt serves the sheet manifest during the attempt")
    check(all(a.can_sign(p) for p in pages), "user can sign every page during the attempt")
    r = a.sign(pages[0]).json(); img = requests.get(URL + "/storage/v1" + r["signedURL"])
    check(img.ok and img.content[:8] == b"\x89PNG\r\n\x1a\n", "signed URL serves the PNG")
    check(not a.can_sign(f"{slug}/sheet-0000000000.png"), "user cannot sign a non-sheet object")
    check(not b.can_sign(pages[0]), "other allowlisted user (no attempt) cannot sign")
    gb = b.rpc("get_attempt", p_attempt=aid)
    check(not gb.ok, "other user cannot read the attempt")

    check(a.rpc("submit_attempt", p_attempt=aid, p_reason="manual").ok, "submitted")
    g = a.rpc("get_attempt", p_attempt=aid).json()
    check(g.get("equation_sheet") is None, "no sheet manifest after submit (not released)")
    check(not a.can_sign(pages[0]), "cannot sign after submit before release")

    admin("admin_release", p_slug=slug, p_released=True, p_attempt=aid)
    rr = a.rpc("get_results", p_attempt=aid).json()
    check((rr.get("equation_sheet") or {}).get("pages") and len(rr["equation_sheet"]["pages"]) == 3, "get_results serves the sheet after release")
    check(a.can_sign(pages[2]), "can sign after release")
    check(not b.can_sign(pages[2]), "other user still cannot sign after release")
    admin("admin_release", p_slug=slug, p_released=False, p_attempt=aid)
    check(not a.can_sign(pages[0]), "unrelease revokes access again")

    # deadline: second attempt ends 5 s from now; after deadline + 30 s grace the sheet can't be signed
    admin("admin_upsert_exam", p=dict(payload, closes_at=(datetime.now(timezone.utc) + timedelta(seconds=5)).isoformat()), p_force=False)
    t = a.rpc("start_attempt", p_slug=slug).json(); attempt_ids.append(t["attempt_id"])
    check(a.can_sign(pages[1]), "can sign during second attempt")
    print("     waiting 40 s for deadline + 30 s grace ...", flush=True); time.sleep(40)
    check(not a.can_sign(pages[1]), "cannot sign after the deadline + grace")

    # removing the field on re-upload removes the sheet
    p2 = dict(payload); p2.pop("equation_sheet")
    check(admin("admin_upsert_exam", p=p2, p_force=True).get("equation_sheet_pages") == 0, "omitting equation_sheet removes it")
    print(f"\nALL {ok_count} CHECKS PASSED")
finally:
    for aid in attempt_ids:
        try: admin("admin_delete_attempt", p_attempt=aid)
        except Exception as e: print("cleanup attempt:", e)
    if made_exam or True:
        try: cli.cmd_delete_exam(Namespace(slug=slug, yes=True))
        except Exception as e: print("cleanup exam:", e)
    for uid in users:
        r = requests.delete(f"{URL}/auth/v1/admin/users/{uid}", headers=ah); print("cleanup: temp user deleted" if r.ok else f"cleanup user failed {r.status_code}")
