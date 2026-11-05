# Finish emails (Omar only) + Study Mentor wake queue

On every successful submit (manual or time-expired), the database:

1. Inserts a row into `public.finish_notifications` (pollable queue for Study Mentor).
2. Emails the configured recipients via **Resend** + `pg_net` (default: `ohady1992@gmail.com`).

**Study Mentor is never emailed.** Wake Mentor with `bin/exam finishes` / a Grok Bot routine (see `READY_FOR_ROUTINE.md`). Do not use `householdassistant@mail.grokbot.com` for Mentor.

## Enable Resend

1. Create an API key at https://resend.com
2. In the Supabase SQL editor (service role), store it:

```sql
insert into private.secrets(name, value)
values ('resend_api_key', 're_xxxxxxxx')
on conflict (name) do update set value = excluded.value, updated_at = now();
```

3. For production, verify your domain in Resend and change the `from` address in
   `private.send_finish_email` (currently `Exam Platform <onboarding@resend.dev>` for testing).

Without the secret, finishes still enqueue; `email_status` becomes `skipped` with a clear error.

## Recipients

```bash
bin/exam notify-emails                     # global default
bin/exam notify-emails --set ohady1992@gmail.com
bin/exam notify-emails --slug my-quiz      # per-exam override (null = inherit)
bin/exam notify-emails --slug my-quiz --set ohady1992@gmail.com
bin/exam notify-emails --slug my-quiz --clear-exam
```

Or set `notify_emails` in the Examiner UI / exam JSON.
