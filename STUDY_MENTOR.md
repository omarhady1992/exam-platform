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
  "questions": [
    {"id": "q1", "type": "mcq", "prompt": "Pick the fruit.", "options": ["Carrot", "Apple", "Leek"], "answer": "b", "marks": 1},
    {"id": "q2", "type": "multi", "prompt": "Pick the primes.", "options": ["2", "4", "5"], "answer": ["a", "c"], "marks": 2},
    {"id": "q3", "type": "tf", "prompt": "Water boils at 100 °C at 1 atm.", "answer": true},
    {"id": "q4", "type": "numeric", "prompt": "Area of a 3 × 4 rectangle?", "answer": 12, "unit": "m²", "tolerance_abs": 0.1, "marks": 2},
    {"id": "q5", "type": "short", "prompt": "Explain why…", "answer": "Model answer for the marker", "marks": 3, "image": "images/figure.png"}
  ]
}
```

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
