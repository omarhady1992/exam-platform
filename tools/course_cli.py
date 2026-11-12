"""Course (learning platform) commands for bin/exam.

Stage 1: courses > weeks > days with PDF packs, infographics, readings, YouTube videos and per-user progress.
Files go to the PRIVATE Supabase Storage bucket `course-files`; the site signs short-lived URLs for them.

Hard safety rules enforced here (and again in the database):
  * never upload answer keys (anything under keys/, names containing answer/key/solution, exams/),
  * never upload textbooks from /workspace/re/references/,
  * never print secrets.
"""
import html, json, mimetypes, os, re, sys, zipfile
from pathlib import Path

import requests

BUCKET = "course-files"
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "courses" / "oembed-cache.json"
STUDY = Path("/workspace/study-pdfs")
WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

FORBIDDEN = [
    re.compile(r"(^|/)(keys?|exams|references)/", re.I),
    re.compile(r"answer", re.I),
    re.compile(r"(^|[/_. -])keys?([_. -]|$)", re.I),
    re.compile(r"solution", re.I),
    re.compile(r"(^|/)truth[_-]", re.I),
]
FORBIDDEN_DIRS = [Path("/workspace/re/references"), Path("/workspace/exam-platform/exams"),
                  STUDY / "keys", STUDY / "Reservoir-Engineering-Course" / "keys", Path("/workspace/esp/keys")]


class CourseError(Exception):
    pass


def forbidden(p) -> bool:
    s = str(p)
    if any(r.search(s) for r in FORBIDDEN):
        return True
    try:
        rp = Path(s).resolve()
        return any(rp == d or d in rp.parents for d in FORBIDDEN_DIRS)
    except Exception:
        return True


# ------------------------------------------------------------------ API
def _cfg():
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not key:
        raise CourseError("SUPABASE_SERVICE_ROLE_KEY is not set in the environment")
    return os.environ.get("SUPABASE_URL", "https://czqtzjkkxpzixiiplvro.supabase.co").rstrip("/"), key


def _h(key, extra=None):
    h = {"apikey": key, "Authorization": f"Bearer {key}"}
    h.update(extra or {})
    return h


def rpc(name, **params):
    url, key = _cfg()
    r = requests.post(f"{url}/rest/v1/rpc/{name}", headers=_h(key, {"Content-Type": "application/json"}),
                      data=json.dumps(params), timeout=60)
    if r.status_code >= 300:
        try:
            msg = r.json().get("message") or r.text
        except Exception:
            msg = r.text
        raise CourseError(f"{name} failed ({r.status_code}): {msg[:300]}")
    return r.json() if r.text else None


_listing = {}


def list_prefix(prefix):
    """{name: size} for objects directly under prefix (cached per run)."""
    if prefix in _listing:
        return _listing[prefix]
    url, key = _cfg()
    out, off = {}, 0
    while True:
        r = requests.post(f"{url}/storage/v1/object/list/{BUCKET}", headers=_h(key, {"Content-Type": "application/json"}),
                          json={"prefix": prefix, "limit": 1000, "offset": off}, timeout=60)
        if r.status_code >= 300:
            raise CourseError(f"list failed: {r.status_code} {r.text[:200]}")
        items = r.json()
        for it in items:
            if it.get("id"):
                out[it["name"]] = (it.get("metadata") or {}).get("size")
        if len(items) < 1000:
            break
        off += 1000
    _listing[prefix] = out
    return out


def list_all(prefix=""):
    """Recursive listing of the bucket: [(path, size)]."""
    url, key = _cfg()
    res = []
    r = requests.post(f"{url}/storage/v1/object/list/{BUCKET}", headers=_h(key, {"Content-Type": "application/json"}),
                      json={"prefix": prefix, "limit": 1000, "offset": 0}, timeout=60)
    r.raise_for_status()
    for it in r.json():
        p = f"{prefix}/{it['name']}" if prefix else it["name"]
        if it.get("id"):
            res.append((p, (it.get("metadata") or {}).get("size")))
        else:
            res.extend(list_all(p))
    return res


MIME = {".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp",
        ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ".zip": "application/zip", ".py": "text/x-python", ".ipynb": "application/x-ipynb+json",
        ".md": "text/markdown", ".csv": "text/csv"}


def safe_name(name):
    n = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")
    return n[:150]


def pdf_pages(p: Path):
    try:
        import pymupdf
        with pymupdf.open(str(p)) as d:
            return d.page_count
    except Exception:
        return None


def upload(local, course, folder, kind, label, dry=False, quiet=False):
    """Upload one file (idempotent: skipped if the same size is already there). Returns its files-json entry."""
    local = Path(local)
    if not local.is_file():
        raise CourseError(f"File not found: {local}")
    if forbidden(local) or forbidden(local.name):
        raise CourseError(f"REFUSED (looks like an answer key / textbook / exam source): {local}")
    ext = local.suffix.lower()
    if ext not in MIME:
        raise CourseError(f"Unsupported file type {ext}: {local.name}")
    size = local.stat().st_size
    if size > 50 * 1024 * 1024:
        raise CourseError(f"File over 50 MB (bucket limit): {local.name}")
    prefix = f"{course}/{folder}"
    path = f"{prefix}/{safe_name(local.name)}"
    if forbidden(path):
        raise CourseError(f"REFUSED storage path {path}")
    entry = {"kind": kind, "label": label, "path": path, "size": size, "mime": MIME[ext]}
    if ext == ".pdf":
        entry["pages"] = pdf_pages(local)
    if dry:
        return entry
    existing = list_prefix(prefix)
    if existing.get(path.rsplit("/", 1)[1]) == size:
        if not quiet:
            print(f"  = {path} (already uploaded)")
        return entry
    url, key = _cfg()
    with open(local, "rb") as fh:
        r = requests.post(f"{url}/storage/v1/object/{BUCKET}/{path}",
                          headers=_h(key, {"Content-Type": MIME[ext], "x-upsert": "true", "cache-control": "3600"}),
                          data=fh, timeout=600)
    if r.status_code >= 300:
        raise CourseError(f"Upload failed for {local.name}: {r.status_code} {r.text[:200]}")
    existing[path.rsplit("/", 1)[1]] = size
    if not quiet:
        print(f"  + {path} ({size / 1e6:.1f} MB)")
    return entry


def zip_dir(src: Path, out: Path, root_name: str):
    """Zip a code folder, skipping anything that looks like a key or ground truth."""
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(src.rglob("*")):
            rel = f.relative_to(src)
            if f.is_file() and not forbidden(str(rel)) and "__pycache__" not in rel.parts:
                z.write(f, f"{root_name}/{rel}")
    return out


# ------------------------------------------------------------------ YouTube metadata
def _cache():
    try:
        return json.loads(CACHE.read_text())
    except Exception:
        return {}


def oembed(vid):
    c = _cache()
    if vid in c:
        return c[vid]
    info = None
    try:
        r = requests.get("https://www.youtube.com/oembed", params={"url": f"https://www.youtube.com/watch?v={vid}", "format": "json"},
                         timeout=20)
        if r.ok:
            j = r.json()
            info = {"title": j.get("title"), "channel": j.get("author_name"), "ok": True}
        else:
            info = {"ok": False, "status": r.status_code}
    except requests.RequestException:
        return None
    c[vid] = info
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(c, indent=1, ensure_ascii=False))
    return info


YT = re.compile(r"(?:youtu\.be/|youtube(?:-nocookie)?\.com/(?:watch\?v=|embed/|shorts/))([\w-]{11})")


def pdf_text_links(p: Path):
    import pymupdf
    with pymupdf.open(str(p)) as d:
        pages = [pg.get_text() for pg in d]
        links = [l.get("uri") for pg in d for l in pg.get_links() if l.get("uri")]
    return pages, links


def pdf_videos(p: Path):
    """YouTube videos referenced by a pack PDF, in order, with title/channel (oEmbed), duration and 'watch for' note."""
    pages, links = pdf_text_links(p)
    text = "\n".join(pages)
    ids = []
    for u in links + YT.findall(text):
        m = YT.search(u) if "/" in u else None
        vid = m.group(1) if m else (u if re.fullmatch(r"[\w-]{11}", u) else None)
        if vid and vid not in ids:
            ids.append(vid)
    out = []
    flat = re.sub(r"\s*\n\s*", " ", text)
    for vid in ids:
        v = {"youtube_id": vid}
        k = flat.find(vid)
        if k >= 0:
            before = flat[max(0, k - 160):k]
            m = re.search(r"·\s*((?:about\s+)?\d[\d:]*\s*(?:min)?)\s*·\s*(?:https?://)?(?:www\.)?youtu", before)
            if m:
                v["duration"] = m.group(1).strip()
            after = flat[k + 11:k + 600]
            m = re.search(r"Watch for:\s*(.+?)(?:(?<=[.!?])\s|All links were|$)", after)
            if m:
                v["note"] = m.group(1).strip()[:300]
        info = oembed(vid)
        if info and info.get("ok"):
            v["title"], v["channel"] = info["title"], info["channel"]
        elif info and not info.get("ok"):
            v["unavailable"] = True
        out.append(v)
    return [v for v in out if not v.get("unavailable")]


STOP = re.compile(r"^(\d\.\d+|How to use|Contents|[A-Z][A-Z &·0-9-]{12,}|Part \d)", re.M)


def pdf_goals(p: Path):
    pages, _ = pdf_text_links(p)
    for t in pages[:6]:
        k = t.find("Learning goals\n")
        if k < 0 or t.lstrip().startswith("Contents"):
            continue
        lines = t[k + len("Learning goals\n"):].split("\n")
        goals, cur = [], None
        for ln in lines:
            st = ln.strip()
            if not st:
                continue
            if re.fullmatch(r"\d{1,2}", st):
                if cur:
                    goals.append(cur)
                cur = ""
                continue
            if STOP.match(st) or cur is None:
                break
            cur = (cur + " " + st).strip()
        if cur:
            goals.append(cur)
        goals = [re.sub(r"\s+", " ", g) for g in goals if len(g) > 8]
        if len(goals) >= 2:
            return goals
    return []


def split_sentences(s):
    s = re.sub(r"\s+", " ", s).strip()
    parts = re.split(r"(?<=[.;])\s+(?=[A-Z])", s)
    return [p.strip().rstrip(";") for p in parts if len(p.strip()) > 3]


MDLINK = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+)\)")


def md_readings(lines):
    out = []
    for ln in lines:
        s = ln.strip().lstrip("-* ").strip()
        if not s:
            continue
        links = MDLINK.findall(s)
        angle = re.findall(r"<(https?://[^>\s]+)>", s)
        plain = MDLINK.sub(lambda m: m.group(1), s)
        plain = re.sub(r"\s*<https?://[^>]+>", "", plain).strip()
        plain = re.sub(r"\*+", "", plain)
        if links:
            title, url = links[0]
            note = plain.replace(title, "", 1).strip(" .:-–")
            out.append({"title": re.sub(r"\*+", "", title), "url": url, **({"note": note} if note else {})})
        elif angle:
            out.append({"title": plain.rstrip(" .:"), "url": angle[0]})
        else:
            out.append({"title": plain})
    return out


# ------------------------------------------------------------------ course sources
BOOKS_CH = {"[BAT]": "Bateman, Cased-Hole Log Analysis and Reservoir Performance Monitoring",
            "[SMO]": "Smolen, Cased Hole and Production Log Evaluation", "[HILL]": "Hill, Production Logging (SPE Monograph 14)"}


TITLE_FIX = {
    "GR Neutron CCL Depth Control": "GR, Neutron, CCL and Depth Control",
    "Ultrasonic Cement Tools USI CET CAST": "Ultrasonic Cement Tools: USI, CET and CAST",
    "Multi Finger Calipers MFC": "Multi-Finger Calipers (MFC)",
    "EM Thickness MFL and Ultrasonic Corrosion": "EM Thickness, MFL and Ultrasonic Corrosion",
    "Pulsed Neutron Sigma Saturation": "Pulsed Neutron: Sigma and Saturation",
    "Carbon Oxygen and Spectroscopy": "Carbon/Oxygen and Spectroscopy",
    "PLT Objectives Job Planning and Flow Regimes": "PLT Objectives, Job Planning and Flow Regimes",
    "Fluid ID Density Capacitance Holdup": "Fluid ID: Density, Capacitance and Holdup",
    "RE Job Rock Properties and Heterogeneity": "The RE Job, Rock Properties and Heterogeneity",
    "SCAL Capillary Pressure RelPerm Buckley Leverett": "SCAL: Capillary Pressure, Rel Perm and Buckley-Leverett",
    "Integrated Cement Interpretation and Squeeze": "Integrated Cement Interpretation and Squeeze Decisions",
}


def pretty_title(stem):
    t = re.sub(r"-", " ", stem).strip()
    return TITLE_FIX.get(t, t)


def src_cased_hole():
    md = Path("/workspace/cased-hole-logging-roadmap.md").read_text()
    weeks = {}
    for m in re.finditer(r"^## WEEK (\d+): (.+)$", md, re.M):
        weeks[int(m.group(1))] = {"n": int(m.group(1)), "title": m.group(2).strip(), "days": {}}
    summ = dict(re.findall(r"^\| (\d) \| (.+?) \|$", md, re.M))
    for n, w in weeks.items():
        w["summary"] = summ.get(str(n), "")
    blocks = re.split(r"^### ", md, flags=re.M)
    for b in blocks:
        m = re.match(r"Week (\d+) · (\w+day): (.+)", b)
        if not m:
            continue
        n, wd, title = int(m.group(1)), m.group(2), m.group(3).strip()
        goals = re.search(r"\*\*Goals:\*\*\s*(.+)", b)
        study = re.search(r"\*\*Study:\*\*\n((?:- .+\n?)+)", b)
        prac = re.search(r"\*\*Practice:\*\*\s*(.+)", b)
        vid = re.search(r"\*\*Videos?(?:/course)?:\*\*\s*(.+)", b)
        reads = md_readings(study.group(1).splitlines()) if study else []
        for r in reads:
            for code, book in BOOKS_CH.items():
                if r["title"].startswith(code) or code in r["title"]:
                    r["title"] = r["title"].replace(code, book + ":", 1).replace("/[SMO]", " / Smolen").replace(":]", ":")
                    r["note"] = "book (not on the site)"
        rvids = []
        for t_, u_ in MDLINK.findall(vid.group(1) if vid else ""):
            m_ = YT.search(u_)
            if m_:
                rvids.append({"youtube_id": m_.group(1), "title": t_})
        weeks[n]["days"][wd] = {"weekday": wd, "title": title, "goals": split_sentences(goals.group(1)) if goals else [],
                                "readings": reads, "practice": prac.group(1).strip() if prac else "",
                                "roadmap_videos": rvids}
    # files on disk
    order = ["Monday", "Tuesday", "Wednesday", "Thursday"]
    for n, w in weeks.items():
        for wd in order:
            d = w["days"].setdefault(wd, {"weekday": wd, "title": f"{wd}", "goals": [], "readings": []})
            d["position"] = order.index(wd) + 1
            pdfs = [p for p in STUDY.glob(f"Week{n}-{wd}-*.pdf") if not forbidden(p)]
            if n == 1 and wd == "Monday":
                pdfs = [Path("/workspace/through-casing-logging-handout.pdf")]
            ig = sorted(STUDY.glob(f"Week{n}-{wd}-*Infographic.png"))
            if pdfs:
                p = pdfs[0]
                d["pack"] = str(p)
                t = p.stem.split(f"{wd}-", 1)[-1] if wd in p.stem else ""
                if t:
                    d["title"] = pretty_title(t)
                if n == 1 and wd == "Monday":
                    d["title"] = "Cased Hole Fundamentals"
            if ig:
                d["infographic"] = str(ig[0])
        files = []
        for kind, label, pat in [("deck", "Lecture deck (PDF)", f"Week{n}-Lecture-*.pdf"), ("deck-pptx", "Lecture deck (PowerPoint)", f"Week{n}-Lecture-*.pptx"),
                                 ("sheet", "Quiz equation sheet", f"Week{n}-Quiz-Equation-Sheet.pdf")]:
            for p in sorted(STUDY.glob(pat)):
                if not forbidden(p):
                    files.append((kind, label, str(p)))
        if n == 1 and (STUDY / "Week1-Quiz-Fundamentals.pdf").exists():
            files.append(("quiz-paper", "Week 1 quiz paper (PDF)", str(STUDY / "Week1-Quiz-Fundamentals.pdf")))
        w["files"] = files
    weeks[2]["exam_slugs"] = ["week2-cement-evaluation-quiz"]
    weeks[3]["exam_slugs"] = ["week3-casing-inspection-pulsed-neutron-quiz"]
    course_files = [("roadmap", "Course roadmap (PDF)", "/workspace/cased-hole-logging-roadmap.pdf"),
                    ("bonus", "Bonus: Underbalanced perforating (TCP), Lorcan-6", str(STUDY / "Bonus-Underbalance-Perforating-TCP-Lorcan6.pdf")),
                    ("bonus-infographic", "Bonus infographic: Lorcan-6 TCP", str(STUDY / "Bonus-Underbalance-Perforating-TCP-Lorcan6-Infographic.png"))]
    return {"slug": "cased-hole", "title": "Cased Hole Logging Mastery", "subtitle": "5 weeks · Monday to Thursday",
            "description": "Cement evaluation, casing inspection, pulsed neutron and production logging, from fundamentals to case studies.",
            "color": "#14b8a6", "position": 1, "study_days": order, "total_weeks": 5, "current_week": 4,
            "files": course_files, "weeks": [weeks[k] for k in sorted(weeks)], "video_source": "pdf"}


def src_reservoir():
    base = STUDY / "Reservoir-Engineering-Course"
    md = (base / "00-Roadmap" / "Reservoir-Engineering-Course-Roadmap.md").read_text()
    order = ["Sunday", "Monday", "Tuesday", "Wednesday"]
    weeks = []
    parts = re.split(r"^### Week (\d+): (.+)$", md, flags=re.M)
    for i in range(1, len(parts), 3):
        n, title, body = int(parts[i]), parts[i + 1].strip(), parts[i + 2]
        summ = re.search(r"^\*(.+)\*$", body, re.M)
        w = {"n": n, "title": title, "summary": summ.group(1).strip() if summ else "", "days": {}, "files": []}
        dblocks = re.findall(r"^\*\*(\w+day): (.+?)\*\*\n((?:- .+\n?)+)", body, re.M)
        wdir = base / f"Week{n}"
        for idx, (rwd, dtitle, lines) in enumerate(dblocks[:4]):
            wd = order[idx]
            L = lines.splitlines()
            goals = [l[len("- Goal: "):].strip() for l in L if l.startswith("- Goal: ")]
            reads = md_readings([l[len("- Read: "):] for l in L if l.startswith("- Read: ")])
            for r in reads:
                if "(book; handout)" in r["title"]:
                    r["title"] = r["title"].replace(" (book; handout)", "")
                    r["note"] = "book; covered by the pack's own-words handout"
            vids = []
            for l in L:
                m = re.match(r"- Video: \[(.+?)\]\((\S+?)\)(?: · ([^·]+))?(?: · (.+))?$", l)
                if m and YT.search(m.group(2)):
                    vids.append({"youtube_id": YT.search(m.group(2)).group(1), "title": m.group(1),
                                 **({"channel": m.group(3).strip()} if m.group(3) else {}), **({"duration": m.group(4).strip()} if m.group(4) else {})})
            d = {"weekday": wd, "position": idx + 1, "title": dtitle.strip(), "goals": goals, "readings": reads, "roadmap_videos": vids}
            pdfs = [p for p in sorted(wdir.glob(f"RE-Week{n}-{wd}-*.pdf")) if not forbidden(p)] if wdir.exists() else []
            igs = [p for p in pdfs if False]
            if pdfs:
                p = [x for x in pdfs if "Infographic" not in x.name][0]
                d["pack"] = str(p)
                d["title"] = pretty_title(p.stem.split(f"{wd}-", 1)[1])
                ig = sorted(wdir.glob(f"RE-Week{n}-{wd}-*Infographic.png"))
                if ig:
                    d["infographic"] = str(ig[0])
            w["days"][wd] = d
        prac = re.search(r"^\*\*Practice:\*\*\s*(.+)$", body, re.M)
        w["practice"] = prac.group(1).strip() if prac else ""
        if wdir.exists():
            for kind, label, pat in [("deck", "Lecture deck (PDF)", f"RE-Week{n}-Lecture-*.pdf"), ("deck-pptx", "Lecture deck (PowerPoint)", f"RE-Week{n}-Lecture-*.pptx"),
                                     ("guide", "Revision guide", f"RE-Week{n}-Revision-Guide-*.pdf"), ("sheet", "Quiz equation sheet", f"RE-Week{n}-Quiz-Equation-Sheet.pdf"),
                                     ("code", "Starter code (zip)", f"RE-Week{n}-Starter-Code.zip")]:
                for p in sorted(wdir.glob(pat)):
                    if not forbidden(p):
                        w["files"].append((kind, label, str(p)))
        weeks.append(w)
    weeks[0]["exam_slugs"] = ["re-week1-foundations-quiz"]
    return {"slug": "reservoir-engineering", "title": "Practical Reservoir Engineering", "subtitle": "31 weeks · Sunday to Wednesday, quiz on Thursday",
            "description": "From rock, fluids and well tests to material balance, reserves, simulation, EOR and unconventionals.",
            "color": "#6366f1", "position": 2, "study_days": order, "total_weeks": 31, "current_week": 1,
            "files": [("roadmap", "Course roadmap (PDF)", str(base / "00-Roadmap" / "Reservoir-Engineering-Course-Roadmap.pdf"))],
            "weeks": weeks, "video_source": "pdf+roadmap", "no_drafts": True}


def src_esp():
    sys.path.insert(0, "/workspace/esp/roadmap")
    import importlib
    data = importlib.import_module("data")
    base = STUDY / "ESP-Course"
    order = ["Monday", "Tuesday", "Wednesday", "Thursday"]
    weeks = []
    for W in data.WEEKS:
        n = W["n"]
        wdir = base / W["slug"]
        w = {"n": n, "title": W["title"], "summary": W.get("aim", ""), "days": {}, "files": []}
        for D in W.get("days", []):
            wd = D["wd"]
            reads = [{"title": t, "url": u} for (t, u) in D.get("reads", [])]
            vids = [{"youtube_id": v[0], "title": v[1], "channel": v[2], **({"duration": v[3]} if len(v) > 3 else {})} for v in D.get("vids", [])]
            d = {"weekday": wd, "position": order.index(wd) + 1, "title": D["t"], "goals": D.get("goals", []),
                 "readings": reads, "videos": vids, "practice": D.get("prac", "")}
            pack = wdir / D["file"]
            if pack.exists() and not forbidden(pack):
                d["pack"] = str(pack)
            ig = sorted(wdir.glob(f"Week{n}-{wd}-*Infographic.png"))
            if ig:
                d["infographic"] = str(ig[0])
            w["days"][wd] = d
        for kind, label, pat in [("deck", "Lecture deck (PDF)", f"Week{n}-Lecture-*.pdf"), ("deck-pptx", "Lecture deck (PowerPoint)", f"Week{n}-Lecture-*.pptx")]:
            for p in sorted(wdir.glob(pat)):
                w["files"].append((kind, label, str(p)))
        code = wdir / "code"
        if code.exists():
            if n == 5 and (STUDY / "Week5-Code.zip").exists():
                w["files"].append(("code", "Code and outputs (zip)", str(STUDY / "Week5-Code.zip")))
            else:
                z = zip_dir(code, ROOT / "courses" / "build" / f"ESP-Week{n}-Code.zip", f"ESP-Week{n}-Code")
                w["files"].append(("code", "Code (zip)", str(z)))
        weeks.append(w)
    return {"slug": "esp", "title": "ESP Surveillance & AI/ML Optimization", "subtitle": "5 weeks · Monday to Thursday",
            "description": "ESP design, surveillance data, failures and troubleshooting, digital oilfield and machine learning for ESPs.",
            "color": "#f59e0b", "position": 3, "study_days": order, "total_weeks": 5, "current_week": None,
            "files": [("roadmap", "Course roadmap (PDF)", str(base / "00-Roadmap" / "ESP-Course-Roadmap.pdf"))],
            "weeks": weeks, "video_source": "data.py"}


SOURCES = {"cased-hole": src_cased_hole, "reservoir-engineering": src_reservoir, "esp": src_esp}
# How far Omar is (publish up to and including this week). ESP: not started / unknown -> all built weeks.
PUBLISH_THROUGH = {"cased-hole": 4, "reservoir-engineering": 1, "esp": None}


def merge_videos(primary, extra):
    seen = {v["youtube_id"] for v in primary}
    out = list(primary)
    for v in extra:
        if v["youtube_id"] not in seen:
            out.append(v)
            seen.add(v["youtube_id"])
    return out


def import_course(slug, publish_through="auto", dry=False, log=print):
    src = SOURCES[slug]()
    pt = PUBLISH_THROUGH.get(slug) if publish_through == "auto" else publish_through
    cfiles = [upload(p, slug, "course", k, lbl, dry, quiet=False) for (k, lbl, p) in src["files"] if Path(p).exists()]
    course = {k: src[k] for k in ("slug", "title", "subtitle", "description", "color", "position", "study_days", "total_weeks", "current_week")}
    course.update(files=cfiles, published=True)
    if not dry:
        rpc("admin_upsert_course", p=course)
    stats = {"weeks": 0, "weeks_published": 0, "days_built": 0, "days_published": 0, "days_draft": 0, "files": len(cfiles), "videos": 0}
    for w in src["weeks"]:
        n = w["n"]
        days = [d for d in w["days"].values()]
        built = [d for d in days if d.get("pack")]
        wpub = bool(built) and (pt is None or n <= pt)
        folder = f"week-{n:02d}"
        wfiles = [upload(p, slug, folder, k, lbl, dry) for (k, lbl, p) in w.get("files", [])]
        stats["files"] += len(wfiles)
        wp = {"course": slug, "n": n, "title": w["title"], "summary": w.get("summary", ""), "files": wfiles,
              "exam_slugs": w.get("exam_slugs", []), "published": wpub}
        if not dry:
            rpc("admin_upsert_week", p=wp)
        stats["weeks"] += 1
        stats["weeks_published"] += int(wpub)
        log(f"{slug} week {n}: {w['title']} ({len(built)} built day(s), {'published' if wpub else 'draft'})")
        for d in sorted(days, key=lambda x: x["position"]):
            if not d.get("pack") and (not d.get("goals") or src.get("no_drafts")):
                continue
            files = []
            if d.get("pack"):
                files.append(upload(d["pack"], slug, folder, "pack", "Study pack (PDF)", dry))
            if d.get("infographic"):
                files.append(upload(d["infographic"], slug, folder, "infographic", "Infographic", dry))
            goals = d.get("goals") or []
            vids = d.get("videos") or []
            if d.get("pack") and d["pack"].endswith(".pdf") and src["video_source"] != "data.py":
                pg = pdf_goals(Path(d["pack"]))
                if len(pg) >= 2:
                    goals = pg
                vids = merge_videos(pdf_videos(Path(d["pack"])), d.get("roadmap_videos", []))
                # fill titles/channels the PDF didn't give from the roadmap
                rv = {v["youtube_id"]: v for v in d.get("roadmap_videos", [])}
                for v in vids:
                    for k in ("title", "channel", "duration"):
                        if not v.get(k) and rv.get(v["youtube_id"], {}).get(k):
                            v[k] = rv[v["youtube_id"]][k]
            vids = [v for v in vids if v.get("youtube_id") and v.get("title")]
            dpub = wpub and bool(d.get("pack"))
            dp = {"course": slug, "week": n, "position": d["position"], "weekday": d["weekday"], "title": d["title"],
                  "goals": goals, "readings": d.get("readings", []), "videos": vids, "files": files,
                  "practice": d.get("practice") or w.get("practice", ""), "published": dpub}
            if not dry:
                rpc("admin_upsert_day", p=dp)
            stats["days_built"] += int(bool(d.get("pack")))
            stats["days_published"] += int(dpub)
            stats["days_draft"] += int(not dpub)
            stats["videos"] += len(vids)
            log(f"   {d['weekday']:<9} {d['title'][:60]:<60} goals={len(goals)} reads={len(d.get('readings', []))} "
                f"videos={len(vids)} files={len(files)} {'PUBLISHED' if dpub else 'draft'}")
    return stats


# ------------------------------------------------------------------ commands
def _course_days(slug):
    for c in rpc("admin_list_courses"):
        if c["slug"] == slug:
            return c
    raise CourseError(f"No course '{slug}'. Create it first with: bin/exam course-set --slug {slug} --title ...")


def _position(course, day):
    if day is None:
        return None
    if str(day).isdigit():
        return int(day)
    wd = day.strip().capitalize()
    full = next((w for w in WEEKDAYS if w.lower().startswith(wd.lower()[:3])), None)
    if not full:
        raise CourseError(f"Unknown day '{day}' (use a weekday name or a position number)")
    sd = course.get("study_days") or []
    if full in sd:
        return sd.index(full) + 1
    for w in course["weeks"]:
        for d in w["days"]:
            if d["weekday"] == full:
                return d["position"]
    raise CourseError(f"'{full}' is not a study day of {course['slug']} ({', '.join(sd) or 'none set'}); pass --day as a number")


def parse_video(s):
    """'ID' or 'URL' or 'ID|Title|Channel|Duration'"""
    parts = [p.strip() for p in s.split("|")]
    m = YT.search(parts[0])
    vid = m.group(1) if m else parts[0]
    if not re.fullmatch(r"[\w-]{11}", vid):
        raise CourseError(f"Not a YouTube id or URL: {parts[0]}")
    v = {"youtube_id": vid}
    for k, val in zip(("title", "channel", "duration"), parts[1:]):
        if val:
            v[k] = val
    if not v.get("title") or not v.get("channel"):
        info = oembed(vid)
        if not info or not info.get("ok"):
            raise CourseError(f"YouTube video {vid} is not available (oEmbed check failed)")
        v.setdefault("title", info["title"])
        v.setdefault("channel", info["channel"])
    return v


def _json_arg(path):
    return json.loads(Path(path).read_text()) if path else None


def cmd_course_set(a):
    p = {"slug": a.slug, "title": a.title}
    for k in ("subtitle", "description", "color"):
        if getattr(a, k) is not None:
            p[k] = getattr(a, k)
    if a.position is not None: p["position"] = a.position
    if a.study_days: p["study_days"] = [d.strip().capitalize() for d in a.study_days.split(",")]
    if a.total_weeks is not None: p["total_weeks"] = a.total_weeks
    if a.current_week is not None: p["current_week"] = a.current_week
    if a.publish: p["published"] = True
    if a.draft: p["published"] = False
    r = rpc("admin_upsert_course", p=p)
    print(f"course {r['slug']}: {r['title']} ({'published' if r['published'] else 'draft'})")


def cmd_course_week(a):
    course = _course_days(a.course)
    existing = next((w for w in course["weeks"] if w["n"] == a.week), None)
    p = {"course": a.course, "n": a.week}
    if a.title: p["title"] = a.title
    elif not existing: p["title"] = f"Week {a.week}"
    if a.summary is not None: p["summary"] = a.summary
    folder = f"week-{a.week:02d}"
    files = list(existing["files"]) if existing and not a.replace_files else []
    def add(kind, label, path):
        nonlocal files
        e = upload(path, a.course, folder, kind, label)
        files = [f for f in files if f["path"] != e["path"]] + [e]
    if a.deck: add("deck", "Lecture deck (PDF)", a.deck)
    if a.deck_pptx: add("deck-pptx", "Lecture deck (PowerPoint)", a.deck_pptx)
    for f in a.file or []:
        path, _, label = f.partition("=")
        ext = Path(path).suffix.lower()
        add("code" if ext in (".zip", ".py", ".ipynb") else "extra", label or Path(path).stem.replace("-", " "), path)
    if a.deck or a.deck_pptx or a.file or a.replace_files or not existing:
        p["files"] = files
    if a.quiz is not None:
        p["exam_slugs"] = [s for s in a.quiz if s]
    if a.publish: p["published"] = True
    if a.draft: p["published"] = False
    r = rpc("admin_upsert_week", p=p)
    print(f"{a.course} week {r['n']}: {r['title']} ({'published' if r['published'] else 'draft'}), "
          f"{len(r['files'])} file(s), quizzes: {', '.join(r['exam_slugs']) or 'none'}")


def cmd_course_publish(a):
    course = _course_days(a.course)
    pos = _position(course, a.day)
    week = next((w for w in course["weeks"] if w["n"] == a.week), None)
    if not week:
        rpc("admin_upsert_week", p={"course": a.course, "n": a.week, "title": a.week_title or f"Week {a.week}",
                                   "published": not a.draft})
        week = {"n": a.week, "days": [], "files": [], "published": not a.draft}
    old = next((d for d in week["days"] if d["position"] == pos), None)
    folder = f"week-{a.week:02d}"
    files = list(old["files"]) if old else []
    def put(kind, label, path):
        nonlocal files
        e = upload(path, a.course, folder, kind, label)
        if kind == "extra":
            files = [f for f in files if f["path"] != e["path"]] + [e]
        else:
            files = [f for f in files if f["kind"] != kind] + [e]
    if a.pdf: put("pack", "Study pack (PDF)", a.pdf)
    if a.infographic: put("infographic", "Infographic", a.infographic)
    for f in a.extra or []:
        path, _, label = f.partition("=")
        put("extra", label or Path(path).stem.replace("-", " "), path)
    wd = WEEKDAYS[[w.lower()[:3] for w in WEEKDAYS].index(a.day.lower()[:3])] if not str(a.day).isdigit() else (old or {}).get("weekday", "")
    title = a.title or (old or {}).get("title")
    if not title and a.pdf:
        stem = Path(a.pdf).stem
        title = pretty_title(re.split(r"(?i)(?:sun|mon|tues|wednes|thurs|fri|satur)day-", stem, maxsplit=1)[-1])
    if not title:
        raise CourseError("--title is required for a new day")
    p = {"course": a.course, "week": a.week, "position": pos, "weekday": wd, "title": title, "files": files}
    goals = _json_arg(a.goals_json) or a.goal
    vids = _json_arg(a.videos_json)
    if a.videos:
        vids = (vids or []) + [parse_video(v) for v in a.videos]
    if a.pdf and a.from_pdf:
        if not goals:
            goals = pdf_goals(Path(a.pdf))
        if vids is None:
            vids = pdf_videos(Path(a.pdf))
    if goals is not None: p["goals"] = goals
    if vids is not None:
        for v in vids:
            if not re.fullmatch(r"[\w-]{11}", v.get("youtube_id", "")) or not v.get("title"):
                raise CourseError(f"Each video needs youtube_id (11 chars) and title: {v}")
        p["videos"] = vids
    readings = _json_arg(a.readings_json)
    if a.reading:
        readings = (readings or []) + [dict(zip(("title", "url"), [x.strip() for x in r.split("|", 1)])) for r in a.reading]
    if readings is not None: p["readings"] = readings
    if a.practice is not None: p["practice"] = a.practice
    if a.summary is not None: p["summary"] = a.summary
    if a.date: p["scheduled_on"] = a.date
    p["published"] = not a.draft
    r = rpc("admin_upsert_day", p=p)
    if not a.draft and not week.get("published"):
        rpc("admin_set_course_published", p_course=a.course, p_week=a.week, p_position=None, p_published=True)
    print(f"{a.course} week {a.week} day {pos} ({r['weekday']}): {r['title']} -> {'PUBLISHED' if r['published'] else 'draft'}; "
          f"goals={len(r['goals'])} readings={len(r['readings'])} videos={len(r['videos'])} files={len(r['files'])}")
    print(f"  https://omarhady1992.github.io/exam-platform/#/learn/{a.course}/{a.week}/{pos}")


def cmd_course_import(a):
    slugs = list(SOURCES) if a.course == "all" else [a.course]
    pt = "auto" if a.publish_through is None else (None if a.publish_through == 0 else a.publish_through)
    if a.course == "all" and a.publish_through is not None:
        raise CourseError("--publish-through needs a single --course")
    for s in slugs:
        st = import_course(s, publish_through=pt, dry=a.dry_run)
        print(f"== {s}: {json.dumps(st)}\n")


def cmd_course_list(a):
    cs = rpc("admin_list_courses")
    if a.json:
        print(json.dumps(cs, indent=2, ensure_ascii=False)); return
    for c in cs:
        if a.course and c["slug"] != a.course:
            continue
        print(f"{c['slug']}: {c['title']} ({'published' if c['published'] else 'draft'}), current week {c.get('current_week') or '-'}"
              f" of {c.get('total_weeks') or '?'}")
        for w in c["weeks"]:
            if not w["days"] and not a.all:
                continue
            print(f"  week {w['n']:>2} {'P' if w['published'] else '-'} {w['title'][:70]}  quizzes: {', '.join(w['exam_slugs']) or '-'}  files: {len(w['files'])}")
            for d in w["days"]:
                kinds = ",".join(f["kind"] for f in d["files"]) or "no files"
                print(f"     {d['position']} {d['weekday']:<9} {'P' if d['published'] else '-'} {d['title'][:55]:<55} "
                      f"v{d['videos']} r{d['readings']} g{d['goals']} [{kinds}]")


def cmd_course_visibility(a):
    course = _course_days(a.course)
    pos = _position(course, a.day) if a.day else None
    r = rpc("admin_set_course_published", p_course=a.course, p_week=a.week, p_position=pos, p_published=a.state == "on")
    print(f"updated {r['updated']} row(s): published={r['published']}")


def cmd_course_progress(a):
    rows = rpc("admin_course_progress")
    if a.json:
        print(json.dumps(rows, indent=2)); return
    from datetime import datetime
    from zoneinfo import ZoneInfo
    cz = ZoneInfo("Africa/Cairo")
    f = lambda v: datetime.fromisoformat(v).astimezone(cz).strftime("%a %d %b %H:%M Cairo") if v else "-"
    for r in rows:
        if a.course and r["course"] != a.course:
            continue
        print(f"{r['email']:<28} {r['course']:<22} w{r['week']} {r['weekday']:<9} {'DONE ' if r['done'] else 'open '} "
              f"done {f(r['done_at'])}  opened {f(r['opened_at'])}  {r['title'][:40]}")


def cmd_course_audit(a):
    objs = list_all()
    bad = [p for p, _ in objs if forbidden(p)]
    total = sum(s or 0 for _, s in objs)
    referenced = set()
    for c in rpc("admin_list_courses"):
        referenced |= {f["path"] for f in c["files"]}
        for w in c["weeks"]:
            referenced |= {f["path"] for f in w["files"]}
            for d in w["days"]:
                referenced |= {f["path"] for f in d["files"]}
    orphans = [p for p, _ in objs if p not in referenced]
    missing = sorted(referenced - {p for p, _ in objs})
    print(f"bucket {BUCKET}: {len(objs)} objects, {total / 1e6:.1f} MB")
    print(f"answer-key-like objects: {len(bad)}" + ("".join(f"\n  !! {p}" for p in bad)))
    print(f"referenced but missing: {len(missing)}" + "".join(f"\n  ? {p}" for p in missing))
    print(f"unreferenced objects: {len(orphans)}" + "".join(f"\n  - {p}" for p in orphans[:30]))
    if bad or missing:
        raise CourseError("audit failed")


def add_parsers(sub):
    s = sub.add_parser("course-set", help="create/update a course")
    s.add_argument("--slug", required=True); s.add_argument("--title", required=True)
    s.add_argument("--subtitle"); s.add_argument("--description"); s.add_argument("--color"); s.add_argument("--position", type=int)
    s.add_argument("--study-days", help="e.g. Monday,Tuesday,Wednesday,Thursday")
    s.add_argument("--total-weeks", type=int); s.add_argument("--current-week", type=int)
    g = s.add_mutually_exclusive_group(); g.add_argument("--publish", action="store_true"); g.add_argument("--draft", action="store_true")
    s.set_defaults(fn=cmd_course_set)

    s = sub.add_parser("course-week", help="create/update a week: title, deck, files, linked quiz")
    s.add_argument("--course", required=True); s.add_argument("--week", type=int, required=True)
    s.add_argument("--title"); s.add_argument("--summary")
    s.add_argument("--deck", help="lecture deck PDF"); s.add_argument("--deck-pptx", help="lecture deck .pptx")
    s.add_argument("--file", action="append", help="extra week file, optionally PATH=Label (zip, pdf, py, ipynb)")
    s.add_argument("--replace-files", action="store_true", help="drop the week's existing file list first")
    s.add_argument("--quiz", nargs="*", help="exam slug(s) for this week's quiz (empty to clear)")
    g = s.add_mutually_exclusive_group(); g.add_argument("--publish", action="store_true"); g.add_argument("--draft", action="store_true")
    s.set_defaults(fn=cmd_course_week)

    s = sub.add_parser("course-publish", help="publish one day: PDF pack, infographic, videos, readings, goals")
    s.add_argument("--course", required=True); s.add_argument("--week", type=int, required=True)
    s.add_argument("--day", required=True, help="weekday name (Tuesday) or position (1-7)")
    s.add_argument("--title"); s.add_argument("--week-title", help="title if the week is new")
    s.add_argument("--pdf", help="the day's study pack PDF"); s.add_argument("--infographic", help="the day's infographic PNG")
    s.add_argument("--extra", action="append", help="extra day file PATH[=Label]")
    s.add_argument("--videos", nargs="*", help="YouTube ids/URLs, optionally 'ID|Title|Channel|Duration'")
    s.add_argument("--videos-json", help='file: [{"youtube_id","title","channel","duration","note"}]')
    s.add_argument("--goal", action="append", help="a learning goal (repeat)")
    s.add_argument("--goals-json", help='file: ["goal", ...]')
    s.add_argument("--reading", action="append", help="'Title|https://url' (repeat)")
    s.add_argument("--readings-json", help='file: [{"title","url","note"}]')
    s.add_argument("--from-pdf", action="store_true", help="take goals and videos from the PDF when not given")
    s.add_argument("--practice"); s.add_argument("--summary"); s.add_argument("--date", help="scheduled date YYYY-MM-DD")
    s.add_argument("--draft", action="store_true", help="upload but keep hidden from Omar")
    s.set_defaults(fn=cmd_course_publish)

    s = sub.add_parser("course-import", help="bulk import everything that exists on disk for a course")
    s.add_argument("--course", required=True, choices=list(SOURCES) + ["all"])
    s.add_argument("--publish-through", type=int, help="publish weeks up to N (0 = all built weeks); default = where Omar is")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_course_import)

    s = sub.add_parser("course-list", help="list courses, weeks and days with publish state")
    s.add_argument("--course"); s.add_argument("--all", action="store_true", help="include weeks with no days"); s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_course_list)

    s = sub.add_parser("course-visibility", help="show/hide a course, week or day")
    s.add_argument("--course", required=True); s.add_argument("--week", type=int); s.add_argument("--day")
    s.add_argument("state", choices=["on", "off"])
    s.set_defaults(fn=cmd_course_visibility)

    s = sub.add_parser("course-progress", help="Omar's day progress (done / opened, Cairo time)")
    s.add_argument("--course"); s.add_argument("--json", action="store_true"); s.set_defaults(fn=cmd_course_progress)

    s = sub.add_parser("course-audit", help="check the bucket: no answer keys, nothing missing")
    s.set_defaults(fn=cmd_course_audit)
