# Exam Room

A personal timed exam and quiz site: a static frontend on GitHub Pages with Supabase (Postgres + Auth + Storage) behind it.

- `site/`: no-build, mobile-first SPA (login, dashboard, timed exam with autosave and navigator, results).
- `supabase/migrations/`: schema, RLS and RPCs. Answer keys never leave the server, and the deadline is enforced server-side.
- `tools/exam_cli.py` (`bin/exam`): admin CLI for uploading, marking and releasing exams (uses the service role key from the environment).
- `schema/exam.schema.json`: the exam file format. See `STUDY_MENTOR.md`.

This repo has no answer keys and no secrets. `site/config.js` contains only the public anon key.
