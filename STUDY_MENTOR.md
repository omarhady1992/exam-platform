# Study Mentor guide: exam platform

Site: https://omarhady1992.github.io/exam-platform/  ·  Repo: https://github.com/omarhady1992/exam-platform
Backend: Supabase project `czqtzjkkxpzixiiplvro` (eu-central-1). All times are shown to Omar in **Africa/Cairo**.

## Requirements
- Run on the box from `/workspace/exam-platform`. The CLI is `bin/exam`, which uses `.venv`.
- Set `SUPABASE_SERVICE_ROLE_KEY` in the environment. Never print it or commit it.
- Keep exam JSON files (they contain answer keys) in `/workspace/exam-platform/exams/`. That folder is gitignored. Never put keys in the public repo.

## Workflow
```bash
cd /workspace/exam-platform
bin/exam validate exams/my-quiz.json                 # schema + logic check, no upload
bin/exam upload   exams/my-quiz.json                 # create/update by slug (stays unpublished unless "published": true)
bin/exam upload   exams/my-quiz.json --publish       # upload and make visible to Omar
bin/exam upload   exams/my-quiz.json --force         # needed if removing questions from an exam that already has attempts
bin/exam publish   my-quiz                           # show on Omar's dashboard
bin/exam unpublish my-quiz                           # hide it
bin/exam list                                        # all exams, attempt counts, short answers awaiting marking
bin/exam list --json
bin/exam export my-quiz                              # print exam + key + attempts + answers + focus log (Cairo times)
bin/exam export my-quiz --out results/my-quiz.json   # results/ is gitignored
bin/exam mark my-quiz --file results/my-quiz-marks.json
bin/exam release   my-quiz                           # Omar sees score, per-question correctness, key, explanation, feedback
bin/exam release   my-quiz --attempt <attempt_id>    # release one attempt only
bin/exam unrelease my-quiz [--attempt <attempt_id>]
bin/exam delete-attempt <attempt_id>                 # e.g. to allow a retake
bin/exam delete-exam my-quiz --yes                   # removes exam, attempts and images
bin/exam allow-user someone@example.com [--role admin]   # allowlist an existing auth user
bin/exam finishes [--all] [--json]                       # poll finish_notifications (quiz queue only)
bin/exam wake-queue --json                               # ONE poll for quizzes + practice: {"quiz": [...], "practice": [...], "total": n}
bin/exam ack --id <finish_id> | --attempt <attempt_id>   # mark a finish as handled
bin/exam notify-emails [--slug SLUG] [--set a@b.com] [--clear-exam]
```

Typical cycle: write JSON, `validate`, `upload --publish`. Omar takes it. Then `list` shows the short answers to mark. `export` to read his answers, `mark` the short answers and add feedback, then `release`.

## Exam JSON format
JSON Schema: `schema/exam.schema.json`.

| field | required | notes |
|---|---|---|
| `slug` | yes | `^[a-z0-9][a-z0-9-]{1,80}$`; the upsert key |
| `title` | yes | |
| `time_limit_minutes` | yes | 1 to 1440 |
| `questions` | yes | non-empty list |
| `instructions` | | supports `**bold**`, `` `code` ``, newlines |
| `opens_at`, `closes_at` | | ISO 8601. Times without an offset are read as **Cairo time**. The deadline is the earlier of start + limit and closes_at |
| `attempts_allowed` | | default 1 (enforced server-side) |
| `shuffle_questions`, `shuffle_options` | | default false; the order is fixed per attempt |
| `log_focus` | | default true; tab switches and blur events are logged and shown in the export |
| `published` | | default false |
| `equation_sheet` | | optional equation/reference sheet; see below. Omitting it on re-upload removes the sheet |

Question fields: `id` (`^[A-Za-z0-9_-]{1,40}$`, unique in the exam, and the key used for marking), `type`, `prompt`, `marks` (default 1), optional `image` (a local path relative to the JSON file, uploaded to private storage), optional `explanation` (shown after release).

| type | `options` | `answer` | marking |
|---|---|---|---|
| `mcq` | list of strings (ids become a, b, c…) or `{id,text}` | option id string | exact |
| `multi` | same | list of option ids | exact set match: full marks or 0 |
| `tf` | none | `true` / `false` | exact |
| `numeric` | none, plus `unit` (label) and `tolerance_abs` and/or `tolerance_pct` | number | correct if \|resp−key\| ≤ max(abs, \|key\|·pct/100) |
| `short` | none | model answer string or null | manual (`bin/exam mark`) |

Generic example (not a real exam):
```json
{
  "slug": "example-quiz",
  "title": "Example quiz",
  "instructions": "Answer all questions. Calculators allowed.",
  "time_limit_minutes": 20,
  "opens_at": "2026-11-02T18:00",
  "closes_at": "2026-11-02T23:00",
  "attempts_allowed": 1,
  "shuffle_questions": true,
  "shuffle_options": true,
  "log_focus": true,
  "equation_sheet": {"title": "Formula sheet", "files": ["sheets/formulas.pdf"]},
  "questions": [
    {"id": "q1", "type": "mcq", "prompt": "Pick the fruit.", "options": ["Carrot", "Apple", "Leek"], "answer": "b", "marks": 1},
    {"id": "q2", "type": "multi", "prompt": "Pick the primes.", "options": ["2", "4", "5"], "answer": ["a", "c"], "marks": 2},
    {"id": "q3", "type": "tf", "prompt": "Water boils at 100 °C at 1 atm.", "answer": true},
    {"id": "q4", "type": "numeric", "prompt": "Area of a 3 × 4 rectangle?", "answer": 12, "unit": "m²", "tolerance_abs": 0.1, "marks": 2},
    {"id": "q5", "type": "short", "prompt": "Explain why…", "answer": "Model answer for the marker", "marks": 3, "image": "images/figure.png"}
  ]
}
```

## Equation sheet (`equation_sheet`)
Paths are relative to the exam JSON file, like question images. Each file is a `.pdf` (every page is used) or a page image (`.png`, `.jpg`, `.jpeg`, `.webp`). Up to 40 pages in total. Three accepted forms:
```json
"equation_sheet": "sheets/formulas.pdf"
"equation_sheet": ["sheets/page1.png", "sheets/page2.png"]
"equation_sheet": {"title": "Formula sheet", "files": ["sheets/formulas.pdf", "sheets/steel-table.png"], "dpi": 150}
```
`title` defaults to "Equation sheet". `dpi` (72–300, default 150) is the render resolution for PDF pages.

- `bin/exam validate` checks that every file exists, that its type is supported, that PDFs are readable (`pdfinfo`), and that the page limit holds.
- `bin/exam upload` renders each PDF page to PNG with `pdftoppm` (poppler-utils) and uploads every page to the private `exam-images` bucket as `<slug>/sheet-<hash>.png`, the same way question images are uploaded. It stores `{"title", "pages": [{"path", "w", "h"}]}` on the exam. `bin/exam list` shows the page count. `delete-exam` removes the pages along with the exam.
- **Viewer:** the student gets an **Equation sheet** button next to the timer. It opens an in-page panel: a side panel on wide screens, full screen on phones. The panel stacks the pages, shows "Page x of n", zooms with − / % / + / Fit, pinch, double-tap or Ctrl+wheel, and mirrors the timer. PDFs are converted to images at upload time instead of embedding a PDF viewer: images render the same on every phone, need no PDF.js download, and the panel has no iframe, so opening it never fires a window blur or a tab switch. **Opening the sheet is not logged as leaving the page, and the timer keeps running.** The panel closes automatically on submit.
- **Access:** the sheet's details come only from `get_attempt`, and only while that attempt is in progress (until the deadline plus 30 s grace), or from `get_results` after the attempt or exam is released. Pages are served by short-lived signed URLs. The storage RLS policy (`private.can_view_image`) only issues them to an allowlisted user who has an attempt on that exam that is currently in progress or released. During an attempt, links expire shortly after the deadline. Submitted-but-unreleased attempts, other users and anonymous visitors can't open the sheet. The intro page says when an exam has a sheet but doesn't show it.

## Mark file (`bin/exam mark`)
```json
{
  "attempt_id": "optional; defaults to the latest submitted attempt",
  "overall_feedback": "Overall comment shown with results",
  "questions": [
    {"id": "q5", "marks": 2, "feedback": "Good, but also mention …"},
    {"id": "q1", "marks": 1, "feedback": "Overrides the auto mark if needed"}
  ]
}
```
A list of such objects is also accepted. Manual marks survive re-uploads. Re-uploading an exam re-marks the auto-marked questions of submitted attempts.

## Guarantees (server-side)
- The browser can never read answer keys, other attempts or tables directly. Everything goes through RPCs, with RLS on and no policies.
- Only allowlisted users (`allowed_users`) can do anything.
- `start_attempt` fixes the deadline and the shuffle order. Saves are rejected after the deadline plus 30 s grace. Expired attempts are auto-submitted and marked.
- Nothing is revealed until `release`.
- The sample exam `sample-cbl-vdl-quiz` (keys in `exams/sample-cbl-vdl-quiz.json`) is uploaded but **unpublished**. Run `bin/exam publish sample-cbl-vdl-quiz` to give it to Omar.

## Database changes
The box can't reach Postgres directly. Add a new numbered file in `supabase/migrations/` and push. The `DB migrate` GitHub Action applies it using the repo secret `SUPABASE_DB_URL`, then runs `supabase/tests/verify_security.sql`.

## Tests
`.venv/bin/python tools/e2e_test.py` runs the full REST test with a temporary user and cleans up after itself.
`.venv/bin/python tools/sheet_test.py` tests equation-sheet access: in progress, submitted, released, other user, and anon. It uses a temporary exam and a temporary user, and removes both afterwards.


## Finish notifications (do not email Study Mentor)
When Omar submits (or time expires), a row is inserted into `finish_notifications` and **Omar** is emailed (`ohady1992@gmail.com` by default) if Resend is configured (`docs/FINISH_EMAIL.md`). Study Mentor is **not** emailed — poll the queue instead:

```bash
bin/exam finishes
bin/exam export <slug>
bin/exam mark <slug> --file results/<slug>-marks.json
bin/exam release <slug> --attempt <attempt_id>
bin/exam ack --id <finish_id>
```

A Grok Bot routine should wake this agent on new rows — see `READY_FOR_ROUTINE.md`. Never use `householdassistant@mail.grokbot.com` as a Mentor address.

## Examiner (browser)
Omar (admin role) can author exams at https://omarhady1992.github.io/exam-platform/#/examiner — create/edit questions, upload images / equation-sheet PDF→PNG, publish, and manage notify emails. CLI workflows above stay unchanged for marking.

## Learning platform (course material)

Omar now has course pages next to his exams: **Courses** (`#/courses`, the home page), **Progress** (`#/progress`),
and one page per course (`#/learn/<course>`), week (`#/learn/<course>/<week>`) and day (`#/learn/<course>/<week>/<position>`).
A day page shows the PDF pack in a built-in viewer (works on phones), the infographic, learning goals, YouTube videos
(privacy-enhanced embeds), readings, the practice description, the week's lecture deck and files, and the week's quiz
with his best score once results are released. He ticks **Mark as done**; the dashboard shows done/total per course, quiz
scores and a day streak (Cairo calendar days).

Courses: `cased-hole` (Mon–Thu), `reservoir-engineering` (Sun–Wed, quiz Thursday), `esp` (Mon–Thu).
Day positions follow the course's study days: cased-hole/esp Monday=1 … Thursday=4; reservoir-engineering Sunday=1 … Wednesday=4.

Files go to the **private** Storage bucket `course-files` (`<course>/week-NN/<file name>`), never to the GitHub repo.
The site gets 1-hour signed URLs, and storage only signs files that belong to a *published* day/week/course.

**Never upload answer keys, textbooks or exam sources.** The CLI refuses (and the database rejects) anything under
`keys/`, `exams/` or `references/`, `/workspace/re/references/`, and any file whose name contains `answer`, `key`,
`solution` or starts with `truth_`. Keys stay on the box, as before.

```bash
cd /workspace/exam-platform
# Publish a new day (the usual 12:00 step). Goals and videos are read from the PDF with --from-pdf
# (numbered "Learning goals" section; YouTube links, titles via YouTube oEmbed).
bin/exam course-publish --course cased-hole --week 5 --day Monday \
    --pdf /workspace/study-pdfs/Week5-Monday-Well-Integrity-and-Leak-Detection.pdf \
    --infographic /workspace/study-pdfs/Week5-Monday-Well-Integrity-and-Leak-Detection-Infographic.png \
    --from-pdf
#   optional: --title "..."  --videos ID 'ID|Title|Channel|12:30' https://youtu.be/ID   --videos-json vids.json
#             --goal "..." (repeat) | --goals-json goals.json    --reading 'Title|https://…' (repeat) | --readings-json r.json
#             --practice "..."  --extra file.zip=Label  --date 2026-11-16  --draft (upload but keep hidden)
#   Videos/readings/goals you pass replace the stored list; anything you don't pass is kept.

# A week: lecture deck, extra files, the quiz link (exam slug), publish state
bin/exam course-week --course cased-hole --week 5 --title "Well integrity, leak detection, case studies" \
    --deck Week5-Lecture-Well-Integrity.pdf --deck-pptx Week5-Lecture-Well-Integrity.pptx \
    --file Week5-Code.zip="Starter code" --quiz week5-well-integrity-quiz --publish
#   --quiz with no slugs clears the link; --replace-files drops the old file list first

# A course (rarely needed): metadata and where Omar is
bin/exam course-set --slug reservoir-engineering --title "Practical Reservoir Engineering" --current-week 2

# Bulk import of everything that already exists on disk (idempotent: unchanged files are skipped)
bin/exam course-import --course all --dry-run
bin/exam course-import --course reservoir-engineering                    # publishes up to where Omar is
bin/exam course-import --course reservoir-engineering --publish-through 2  # or a given week (0 = all built weeks)

bin/exam course-list [--course esp] [--all] [--json]       # weeks/days, P = published, v/r/g = videos/readings/goals
bin/exam course-visibility --course esp --week 5 off        # hide/show a course, week (--week) or day (--week --day)
bin/exam course-progress [--course cased-hole]              # what Omar opened / marked done (Cairo time)
bin/exam course-audit                                       # bucket check: no key-like files, nothing missing
```

Where things come from in `course-import`:
- **cased-hole:** `/workspace/cased-hole-logging-roadmap.md` (goals, readings, practice), packs and infographics in
  `/workspace/study-pdfs/WeekN-<Day>-*.pdf|png` (Week 1 Monday is `/workspace/through-casing-logging-handout.pdf`),
  goals and videos taken from the PDF when it has a numbered goals section / YouTube links. Week 5 days exist as hidden
  drafts (roadmap text only) until their packs are published.
- **reservoir-engineering:** the roadmap `.md` (goals, readings, videos) plus `Reservoir-Engineering-Course/WeekN/`.
  Weeks 2–31 exist as hidden week shells (title and summary only).
- **esp:** `/workspace/esp/roadmap/data.py` (goals, readings, verified video ids) plus `ESP-Course/WeekN-*/`.

## Practice answers (stage 2)
Each day page has a **Practice** section built from the day's Part 6/7 practice questions (A1, B2, …). Omar types
answers, saves drafts (autosave too) and submits **once** per day unless you allow another attempt. Numeric answers
are auto-marked on the server at submit time; written answers wait for you. Nothing about marks, expected values or
feedback reaches Omar until you **release**.

Answer types: `numeric` (fixed unit shown; tolerance = max(abs, % of the answer); default 2 % or half the last digit,
or the key's own range / "accept X–Y"), `short` text, `long` text. Field keys (`fkey`) look like `A4`, `A4.1` (part 1
of a multi-value answer), `A4.c` (comment on a numeric question) or `B1.v` (OK / not OK verdict).

Hard rules (enforced in the database, not just here):
- Keys live only in `private.practice_keys` (no grants to `anon`/`authenticated`; the private schema is not exposed
  by the API). They are parsed from `/workspace/study-pdfs/keys/`, `/workspace/study-pdfs/Reservoir-Engineering-Course/keys/`
  and `/workspace/esp/keys/` and sent straight to the DB with the service role. Never copy a key into the repo, the
  site, the `course-files` bucket or any file.
- Submissions, answers and the practice queue have no client table access; Omar sees them only through
  `get_practice` / `save_practice` / `practice_dashboard`, which hide marks and expected values until release.
- Every `mentor_*` function is **service-role only** (even Omar's admin login can't read keys or marks early).
- After release Omar sees: his score, your overall feedback, and per answer ✓/✗ marks, your feedback and, for numbers,
  the expected value ± tolerance. Key text (`key_reference`) is never shown to him.

```bash
# Load / refresh questions + keys (idempotent; prints counts only, never key content)
bin/exam practice-load-keys                                   # every published day of every course
bin/exam practice-load-keys --course esp --week 5 --day Tuesday [--dry-run] [--json]
#   --include-unpublished also loads hidden draft days; --force removes stale questions even if submitted
bin/exam practice-list [--all] [--json]                       # per day: questions, fields, auto-marked, keyed, parse status

# Wake routine: ONE poll covers quiz finishes and practice submissions
bin/exam wake-queue --json        # {"quiz":[finish rows], "practice":[{id, submission_id, course, week, weekday, attempt,
                                  #   auto_score, max_score, pending_manual, submitted_at, commands{export,mark,release,ack}}], "total": n}

bin/exam practice-submissions [--all]                         # submitted, not yet released (--all: everything)
bin/exam practice-submissions --json --id <submission_id>     # full marking view: answers, auto results, key_answer/
                                                              #   key_reference, needs_marking per field
bin/exam practice-mark --file marks.json [--release] [--force]
bin/exam practice-release --id <submission_id> [--force]      # refused while answers still need marking (unless --force)
bin/exam practice-unrelease --id <submission_id>
bin/exam practice-ack --id <practice notification id>          # or --submission <submission_id>
bin/exam practice-allow-resubmit --course cased-hole --week 4 --day Tuesday [--email ohady1992@gmail.com] [--revoke]
```

`marks.json` (one object or a list):
```json
{"submission_id": "…", "feedback": "Overall comment shown to Omar on release.",
 "marks": [{"fkey": "B2", "marks": 2, "feedback": "Good."},
           {"fkey": "A3", "marks": 1, "feedback": "Give both intercepts."},
           {"fkey": "A5.2", "marks": 1, "feedback": "Accepted: rounding."}]}
```
`marks` must be between 0 and the field's marks. You can override an auto-marked numeric answer the same way
(manual marks win); `"marks": null` clears your mark. Text fields are 2 marks, numeric parts and comments 1.

Typical wake → mark loop:
1. `bin/exam wake-queue --json` → for each `practice` item run its `commands.export`.
2. Mark every field with `needs_marking: true` (use `key_reference`), check the auto results, write `marks.json`.
3. `bin/exam practice-mark --file marks.json --release`, then `bin/exam practice-ack --id <id>`.
4. Send Omar the usual short summary if you want; the site already shows the result.

Parse limits: questions are taken from lettered items (`A1.`, `B2:`) in the PDF practice part and matched to the key
items with the same tag. Days whose practice is only tables/charts (no lettered items) or that have no key file are
reported as `unparsed` and get no Practice form (the day page falls back to "send your answers as usual"). Items in
the PDF with no key item are loaded as text questions without a reference (you mark them from your own notes). A key
answer becomes auto-marked only when it is unambiguous (one bold number, or several bold numbers each with its own
label, or a table "Value" cell); everything else is marked by you.

Tests: `tools/e2e_test.py` includes the practice checks (`tools/practice_e2e.py`); `tools/practice_ui_shots.py
[local|live]` takes the form/result screenshots with a temp account and deletes it.

