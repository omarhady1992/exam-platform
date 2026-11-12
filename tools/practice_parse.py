"""Parse a day's Part-6/7 practice questions (from the student PDF) and its answer key (markdown, local only).

Keys are read from local key folders and sent ONLY to the database (service role). Nothing here writes key
content to disk, the repo, or the storage bucket.
"""
import re
from pathlib import Path

KEY_DIRS = {
    "cased-hole": Path("/workspace/study-pdfs/keys"),
    "reservoir-engineering": Path("/workspace/study-pdfs/Reservoir-Engineering-Course/keys"),
    "esp": Path("/workspace/esp/keys"),
}
DEFAULT_TOL_PCT = 2.0
TAG = r"[A-H]\d{1,2}"


def key_file(course, n, weekday):
    d = KEY_DIRS[course]
    if course == "cased-hole":
        return d / f"week{n}-{weekday.lower()}-key.md"
    if course == "reservoir-engineering":
        return d / f"RE-Week{n}-{weekday}-key.md"
    return d / f"W{n}-{weekday[:3]}.md"


# ------------------------------------------------------------------ PDF questions
ITEM = re.compile(rf"^({TAG})[.:)]\s+(.*)$")
SECTION = re.compile(r"^(?:([A-H])\.\s+(.+)|Task ([A-H])\s*[:.·—-]\s*(.+))$")
NOISE = re.compile(r"^(Question|Answer|Working|Your answer|Notes?|Part \d+ · .*|\d+ / \d+|.*· study use only|"
                   r"[A-Z][A-Z0-9 &·,:/()'-]{14,}|Week \d+ · \w+day · .*)$")
STOPLINE = re.compile(r"^(\d\.\d{1,2}$|PART \d+|Table \d|Figure \d|Check yourself|RULES|THE TASK|Reflection)")


def pdf_questions(pdf):
    import pymupdf
    doc = pymupdf.open(str(pdf))
    pages = [p.get_text() for p in doc]
    start = None
    for i, t in enumerate(pages):
        if i > 2 and re.search(r"^PART \d+\s*\nPractice\b", t, re.M):
            start = i
    if start is None:
        return None, None
    qs, order, cur, section = {}, [], None, None
    for pi in range(start, len(pages)):
        t = pages[pi]
        if pi > start and re.search(r"^PART \d+\s*\n(?!Practice)", t, re.M):
            break
        for ln in t.split("\n"):
            s = ln.strip()
            if not s:
                continue
            m = ITEM.match(s)
            if m:
                cur = m.group(1)
                if cur in qs:          # duplicate tag on the page (e.g. answer table): ignore the repeat
                    cur = None
                    continue
                qs[cur] = {"qkey": cur, "section": section, "prompt": m.group(2).strip(), "page": pi + 1}
                order.append(cur)
                continue
            sm = SECTION.match(s)
            if sm and len(s) < 90:
                section = s
                cur = None
                continue
            if STOPLINE.match(s):
                cur = None
                continue
            if cur and not NOISE.match(s) and len(qs[cur]["prompt"]) < 700:
                qs[cur]["prompt"] += " " + s
    out = []
    for k in order:
        q = qs[k]
        t = re.sub(r"\s+", " ", q["prompt"]).strip()
        t = re.split(r"\s(?:Send (?:me )?your|Send the|The answer key|Answers are (?:deliberately )?not|[Ss]ource notes|Sources?:|References?:|\[[A-Z]{3,}[-A-Z0-9]*\])", t, maxsplit=1)[0].strip()
        q["prompt"] = t
        out.append(q)
    return out, start + 1


# ------------------------------------------------------------------ key items
BUL = re.compile(rf"^\s*[-*]\s*\**({TAG})\.?\**\s*[:.)]?\**\s*(.*)$")
ROW = re.compile(rf"^\|\s*\**({TAG})\**\s*([^|]*)\|([^|]*)\|?(.*)$")
INLINE_SPLIT = re.compile(rf"(?:^|(?<=; )|(?<=\. )|(?<=: )|(?<=\) ))({TAG})[:.]?\s+")


def key_items(path):
    items, cur = {}, None
    for raw in Path(path).read_text().split("\n"):
        ln = raw.rstrip()
        if not ln.strip() or ln.startswith("#"):
            cur = None
            continue
        m = ROW.match(ln)
        if m:
            tag = m.group(1)
            if tag not in items:
                items[tag] = {"kind": "row", "label": m.group(2).strip(), "value": m.group(3).strip(),
                              "text": f"{m.group(2).strip()} = {m.group(3).strip()} ({m.group(4).strip(' |')})"}
            cur = None
            continue
        m = BUL.match(ln)
        if m and not raw.startswith("  "):
            tag = m.group(1)
            if tag not in items:
                items[tag] = {"kind": "bullet", "text": m.group(2).strip()}
                cur = tag
            else:
                cur = None
            continue
        if cur and (raw.startswith(" ") or raw.startswith("\t")):
            items[cur]["text"] += "\n" + ln.strip()
            continue
        # inline: "D: D1 3,000 rpm; D2 2.8%." or "A1 30 ft/stage; 5,400 ft pump. A2 ..."
        hits = list(INLINE_SPLIT.finditer(ln))
        if hits:
            for i, h in enumerate(hits):
                seg = ln[h.end(): hits[i + 1].start() if i + 1 < len(hits) else len(ln)].strip().rstrip(";").strip()
                tag = h.group(1)
                if tag not in items and seg:
                    items[tag] = {"kind": "inline", "text": seg}
        cur = None
    return items


# ------------------------------------------------------------------ numbers
NUM = r"[−\-+]?\d[\d,]*(?:\.\d+)?"
VAL = re.compile(rf"^(?:[≈~±]\s*)?({NUM})(?:\s*–\s*({NUM}))?\s*(.*)$")
UNIT_OK = re.compile(r"^[%A-Za-zµμ°/·²³⁻¹Ω()\- .]{0,16}$")


def fnum(s):
    return float(s.replace("−", "-").replace(",", ""))


def decimals(s):
    s = s.replace(",", "")
    return len(s.split(".")[1]) if "." in s else 0


UNIT_STOP = {"OK", "NOT", "ok", "not", "fail", "pass", "Yes", "No", "yes", "no", "is", "the", "of", "so", "but", "at", "in",
             "from", "to", "for", "with", "and", "or", "vs", "than", "if", "per"}
UNIT_TOK = re.compile(r"^[%A-Za-zµμ°/·²³⁻¹Ω.\-]{1,12}$")


def _unit(rest):
    rest = re.split(r"\s*(?:\(|≈|=|;|,\s|→)", rest, maxsplit=1)[0].strip().rstrip(".")
    toks = rest.split()
    if not toks:
        return ""
    if toks[0] in UNIT_STOP or not UNIT_TOK.match(toks[0]):
        return None if toks[0] not in ("OK", "NOT") else ""
    u = toks[0]
    if len(toks) >= 3 and toks[1] == "per" and UNIT_TOK.match(toks[2]):
        u = " ".join(toks[:3])
    return u


def parse_value(txt):
    """'1,764 bbl/d (40%)' -> dict(lo, hi, unit, raw, alts). None if not a clean numeric answer."""
    t = txt.strip().strip("*").strip()
    if re.match(r"^\d{4}-\d\d", t):
        return None
    m = VAL.match(t)
    if not m:
        return None
    unit = _unit(m.group(3))
    if unit is None:
        return None
    alts = []
    for am in re.finditer(rf"(?:=|≈)\s*({NUM})\s*([^\s=≈;,()]*)", m.group(3)):
        au = _unit(am.group(2) or "")
        if au and au != unit:
            alts.append({"answer": fnum(am.group(1)), "unit": au, "raw": am.group(1)})
    lo = fnum(m.group(1))
    hi = fnum(m.group(2)) if m.group(2) else None
    verdict = bool(re.search(r"\b(NOT OK|OK)\b", m.group(3)))
    return {"lo": lo, "hi": hi, "unit": unit, "raw": m.group(1), "alts": alts, "verdict": verdict}


def tolerance(v, raw, hi=None):
    if hi is not None:
        return (v + hi) / 2, abs(hi - v) / 2, None
    half_ulp = 0.5 * 10 ** (-decimals(raw))
    return v, half_ulp, DEFAULT_TOL_PCT


LABEL_BAD = re.compile(r"^[\d(\[−\-+.]|^(so|and|then|i\.e\.|e\.g\.)$", re.I)


def label_before(seg):
    piece = re.split(r"; |, |: |→|\. ", seg)[-1]
    if not re.search(r"[=≈]", piece):
        return None
    lhs = re.split(r"\s*[=≈]", piece, maxsplit=1)[0].strip().strip("*").strip()
    words = []
    for tok in lhs.split():
        if re.match(r"^[\d×−+/–(\[-]", tok):
            break
        words.append(tok)
    while words and words[-1].lower() in ("is", "are", "of", "at", "the", "a", "an", "to", "by", "with", "from", "for", "so"):
        words.pop()
    if words and words[0].lower() in ("the", "a", "an", "so", "then", "and"):
        words = words[1:]
    lhs = " ".join(words)
    if not lhs or len(lhs) > 40 or LABEL_BAD.search(lhs) or not re.search(r"[A-Za-zΔφμσρητθΣ]", lhs):
        return None
    return lhs


WORDY = re.compile(r"\?|\b(why|explain|which|what|comment|is the|are the|justify|compare|discuss|would|should|interpret|"
                   r"describe|reason|state|name|list|identify|suggest|decide|choose|recommend)\b", re.I)
LONG = re.compile(r"\b(why|explain|justify|discuss|describe|write|compare|interpret|recommend|suggest|memo|summar)\w*", re.I)


def text_kind(prompt, ref):
    return "long" if (LONG.search(prompt or "") or len(ref or "") > 160 or len(prompt or "") > 220) else "short"


def build_fields(q, key):
    """Return (fields, numeric_count). Each field: fkey,label,kind,unit,marks,key{answer,tol_abs,tol_pct,reference}."""
    prompt = q["prompt"]
    tag = q["qkey"]
    if key is None:
        return [{"fkey": f"{tag}", "label": "Answer", "kind": text_kind(prompt, ""), "unit": None, "marks": 2,
                 "key": {"reference": None}}], 0
    ref = key["text"]
    nums = []
    if key["kind"] == "row":
        pv = parse_value(key["value"])
        if pv:
            nums.append((key["label"] or "Answer", pv))
    elif key["kind"] == "inline":
        pv = parse_value(ref)
        if pv and not pv["alts"] and re.fullmatch(rf"[≈~]?\s*{NUM}\s*[^\s;,]{{0,12}}(?:\s+(?:NOT )?OK)?\.?", ref.strip()):
            nums.append((None, pv))
    else:
        bolds = list(re.finditer(r"\*\*(.+?)\*\*", ref))
        prev = 0
        cand = []
        for b in bolds:
            pv = parse_value(b.group(1))
            seg = ref[prev:b.start()]
            prev = b.end()
            if pv:
                cand.append((label_before(seg), pv))
        if len(cand) == 1:
            nums = cand
        elif len(cand) > 1:
            labels = [c[0] for c in cand]
            if all(labels) and len(set(labels)) == len(labels) and len(cand) <= 6:
                nums = cand
    fields = []
    if nums:
        acc = re.search(rf"accept\s+({NUM})\s*[–-]\s*({NUM})", ref)
        stem_units = {}
        for lab, pv in nums:
            if lab and pv["unit"]:
                stem_units.setdefault(lab.split("(")[0], pv["unit"])
        verdict = False
        for i, (lab, pv) in enumerate(nums):
            v, hi, unit, raw = pv["lo"], pv["hi"], pv["unit"], pv["raw"]
            if not unit and lab:
                unit = stem_units.get(lab.split("(")[0], "")
            verdict = verdict or pv["verdict"]
            ans, tabs, tpct = tolerance(v, raw, hi)
            if acc and len(nums) == 1:
                lo2, hi2 = fnum(acc.group(1)), fnum(acc.group(2))
                if lo2 <= ans <= hi2:
                    tabs, tpct = max(ans - lo2, hi2 - ans), None
            alts = [{"answer": a["answer"], "unit": a["unit"], "tol_abs": tolerance(a["answer"], a["raw"])[1],
                     "tol_pct": DEFAULT_TOL_PCT} for a in pv["alts"]]
            shown = unit + "".join(f" or {a['unit']}" for a in alts) if unit else None
            fields.append({"fkey": f"{tag}.{i + 1}" if len(nums) > 1 else tag, "label": lab or "Answer", "kind": "numeric",
                           "unit": shown or None, "marks": 1,
                           "key": {"answer": ans, "tol_abs": tabs, "tol_pct": tpct, "reference": ref, "alts": alts}})
        if verdict:
            fields.append({"fkey": f"{tag}.v", "label": "OK / not OK", "kind": "short", "unit": None, "marks": 1,
                           "key": {"reference": ref}})
        elif WORDY.search(prompt):
            fields.append({"fkey": f"{tag}.c", "label": "Comment", "kind": "short", "unit": None, "marks": 1,
                           "key": {"reference": ref}})
        return fields, len(nums)
    return [{"fkey": tag, "label": "Answer", "kind": text_kind(prompt, ref), "unit": None, "marks": 2,
             "key": {"reference": ref}}], 0


def parse_day(course, n, weekday, pdf):
    """-> dict(status, questions, notes). status: ok | partial | unparsed."""
    notes = []
    if not pdf or not Path(pdf).exists():
        return {"status": "unparsed", "questions": [], "notes": ["no student PDF found locally"]}
    qs, page = pdf_questions(pdf)
    if not qs:
        return {"status": "unparsed", "questions": [], "notes": ["no lettered practice questions (A1, B2...) found in the PDF practice part" if qs is not None else "no Practice part found in the PDF"]}
    kf = key_file(course, n, weekday)
    keys = key_items(kf) if kf.exists() else {}
    if not kf.exists():
        return {"status": "unparsed", "questions": [], "notes": [f"no key file ({kf.name}); questions not loaded"]}
    matched = [q for q in qs if q["qkey"] in keys]
    if not matched:
        return {"status": "unparsed", "questions": [], "notes": [f"key file {kf.name} has no items matching the PDF tags"]}
    missing = [q["qkey"] for q in qs if q["qkey"] not in keys]
    out = []
    for pos, q in enumerate(qs):
        fields, _ = build_fields(q, keys.get(q["qkey"]))
        out.append({**q, "position": pos + 1, "fields": fields})
    if missing:
        notes.append("no key item for " + ", ".join(missing) + " (loaded as text, Study Mentor marks without a reference)")
    return {"status": "partial" if missing else "ok", "questions": out, "notes": notes, "page": page, "key_file": kf.name}
