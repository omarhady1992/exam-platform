# READY_FOR_ROUTINE — wake Study Mentor on exam finish

Paste this into **UpdateRoutine** (parent / Programmer and Designer). Do **not** email Study Mentor.
Do **not** use `householdassistant@mail.grokbot.com` for Study Mentor.

## Goal
When Omar (or any student) submits an exam, `finish_notifications` gets a new row (and Omar is emailed via Resend if configured). A Grok Bot routine should poll that queue and **SendToAgent** Study Mentor.

## Study Mentor agent id
`3d64d246-e9e6-4f1b-b729-a36bf85b0a7f`

## Suggested routine
- **Name:** Exam finish → Study Mentor
- **Owner bot:** Programmer and Designer (or whoever owns UpdateRoutine)
- **Schedule:** every 3–5 minutes (cron / interval)
- **Priority wake:** true

### Prompt (paste)

```
You are polling the exam platform finish queue so Study Mentor can mark short answers.

Working directory: /workspace/exam-platform
Requires env: SUPABASE_SERVICE_ROLE_KEY (never print it).

1) Run:  bin/exam finishes --json
2) If the JSON array is empty, stop (nothing to do).
3) For each UNACKED item (acked_at is null), SendToAgent Study Mentor
   (id 3d64d246-e9e6-4f1b-b729-a36bf85b0a7f) with priority true, message:

---
Exam finished — please mark / release.

slug: {exam_slug}
title: {exam_title}
student: {student_email}
attempt_id: {attempt_id}
pending_manual (short answers): {pending_manual}
submit_reason: {submit_reason}
submitted_at (UTC from API; show Omar in Africa/Cairo): {submitted_at}
email_status (Omar only): {email_status}

Commands:
  cd /workspace/exam-platform
  bin/exam export {exam_slug}
  bin/exam mark {exam_slug} --file results/{exam_slug}-marks.json
  bin/exam release {exam_slug} --attempt {attempt_id}

When done marking+releasing, ack the queue row:
  bin/exam ack --id {id}
  # or: bin/exam ack --attempt {attempt_id}
---

4) Do not ack yourself unless Study Mentor confirms done; leaving rows unacked is fine so the next poll still wakes Mentor until they ack.
5) Never email Study Mentor. Never use householdassistant@mail.grokbot.com for Mentor.
```

## CLI equivalents (manual poll)
```bash
cd /workspace/exam-platform
bin/exam finishes          # unacked only
bin/exam finishes --all
bin/exam ack --id <uuid>
bin/exam ack --attempt <attempt_uuid>
```

## Optional local watcher
`tools/finish_watcher.py` prints a wake payload for each new unacked row (for debugging on the box). Prefer the Grok Bot routine above for production.
