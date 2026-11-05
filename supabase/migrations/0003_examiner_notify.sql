-- Examiner (browser admin) + finish notification queue + Omar-only email via Resend/pg_net.
-- Study Mentor is woken by polling finish_notifications (CLI / Grok Bot routine), NOT by email.

-- ---------------------------------------------------------------- extensions / secrets
create extension if not exists pg_net;

create table if not exists private.secrets (
  name  text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
revoke all on table private.secrets from public, anon, authenticated;
-- no grants: only security definer helpers / superuser / service_role via SQL editor

create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
revoke all on table public.app_settings from public, anon, authenticated;

insert into public.app_settings(key, value) values
  ('notify_emails', '{"emails":["ohady1992@gmail.com"]}'::jsonb)
on conflict (key) do nothing;

alter table public.exams
  add column if not exists notify_emails text[];  -- null = use global default

-- ---------------------------------------------------------------- finish queue
create table if not exists public.finish_notifications (
  id              uuid primary key default gen_random_uuid(),
  attempt_id      uuid not null unique references public.attempts(id) on delete cascade,
  exam_id         uuid not null references public.exams(id) on delete cascade,
  exam_slug       text not null,
  exam_title      text not null,
  student_email   text,
  student_user_id uuid,
  submit_reason   text,
  submitted_at    timestamptz not null,
  pending_manual  int not null default 0,
  auto_score      numeric,
  max_score       numeric,
  created_at      timestamptz not null default now(),
  email_status    text not null default 'pending'
                    check (email_status in ('pending','sent','skipped','failed')),
  email_error     text,
  email_sent_at   timestamptz,
  email_to        text[],
  acked_at        timestamptz,
  acked_by        text
);
create index if not exists finish_notifications_unacked
  on public.finish_notifications (created_at) where acked_at is null;
alter table public.finish_notifications enable row level security;
revoke all on table public.finish_notifications from public, anon, authenticated;

-- ---------------------------------------------------------------- admin gate
create or replace function private.require_admin() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  v uuid := auth.uid();
  jwt_role text;
begin
  begin
    jwt_role := coalesce(auth.role(), auth.jwt() ->> 'role',
                         nullif(current_setting('request.jwt.claim.role', true), ''));
  exception when others then
    jwt_role := null;
  end;
  -- CLI uses the service_role key (PostgREST sets role=service_role)
  if jwt_role = 'service_role' then
    return coalesce(v, '00000000-0000-0000-0000-000000000000'::uuid);
  end if;
  if v is not null and exists (
       select 1 from public.allowed_users
        where user_id = v and role = 'admin') then
    return v;
  end if;
  raise exception 'Not authorized' using errcode = '42501';
end $$;

revoke execute on function private.require_admin() from public, anon, authenticated;

-- ---------------------------------------------------------------- notify helpers
create or replace function private.effective_notify_emails(p_exam public.exams)
returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  v text[];
  g jsonb;
begin
  if p_exam.notify_emails is not null and cardinality(p_exam.notify_emails) > 0 then
    return (select array_agg(distinct lower(x)) from unnest(p_exam.notify_emails) x
             where x is not null and btrim(x) <> '');
  end if;
  select value into g from public.app_settings where key = 'notify_emails';
  if g is null then return array['ohady1992@gmail.com']; end if;
  select array_agg(distinct lower(x #>> '{}')) into v
    from jsonb_array_elements(coalesce(g->'emails', '[]'::jsonb)) x
   where btrim(x #>> '{}') <> '';
  if v is null or cardinality(v) = 0 then
    return array['ohady1992@gmail.com'];
  end if;
  return v;
end $$;

revoke execute on function private.effective_notify_emails(public.exams) from public, anon, authenticated;

create or replace function private.resend_api_key() returns text
language sql stable security definer set search_path = '' as $$
  select value from private.secrets where name = 'resend_api_key' limit 1;
$$;
revoke execute on function private.resend_api_key() from public, anon, authenticated;

create or replace function private.send_finish_email(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  n public.finish_notifications;
  key text;
  body jsonb;
  subj text;
  html text;
  req_id bigint;
begin
  select * into n from public.finish_notifications where id = p_id for update;
  if not found then return; end if;
  if n.email_status = 'sent' then return; end if;
  if n.email_to is null or cardinality(n.email_to) = 0 then
    update public.finish_notifications
       set email_status = 'skipped', email_error = 'no recipients'
     where id = p_id;
    return;
  end if;

  key := private.resend_api_key();
  if key is null or btrim(key) = '' then
    update public.finish_notifications
       set email_status = 'skipped',
           email_error = 'RESEND_API_KEY not set in private.secrets (name=resend_api_key)'
     where id = p_id;
    return;
  end if;

  subj := format('Exam finished: %s (%s)', n.exam_title, n.exam_slug);
  html := format(
    '<p><b>%s</b> submitted <b>%s</b> (<code>%s</code>).</p>'
    '<ul>'
    '<li>Attempt: <code>%s</code></li>'
    '<li>Submitted: %s</li>'
    '<li>Reason: %s</li>'
    '<li>Auto score: %s / %s</li>'
    '<li>Short answers awaiting mark: %s</li>'
    '</ul>'
    '<p>Study Mentor is notified via the finish_notifications queue (not email).'
    ' Mark / release with the CLI:</p>'
    '<pre>bin/exam export %s&#10;bin/exam mark %s --file …&#10;bin/exam release %s</pre>',
    coalesce(n.student_email, 'student'),
    n.exam_title,
    n.exam_slug,
    n.attempt_id::text,
    n.submitted_at::text,
    coalesce(n.submit_reason, ''),
    coalesce(n.auto_score::text, '—'),
    coalesce(n.max_score::text, '—'),
    n.pending_manual::text,
    n.exam_slug, n.exam_slug, n.exam_slug
  );

  body := jsonb_build_object(
    'from', 'Exam Platform <onboarding@resend.dev>',
    'to', to_jsonb(n.email_to),
    'subject', subj,
    'html', html
  );

  begin
    select net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || key,
        'Content-Type', 'application/json'
      ),
      body := body
    ) into req_id;
    update public.finish_notifications
       set email_status = 'sent', email_sent_at = now(), email_error = null
     where id = p_id;
  exception when others then
    update public.finish_notifications
       set email_status = 'failed', email_error = left(SQLERRM, 500)
     where id = p_id;
  end;
end $$;

revoke execute on function private.send_finish_email(uuid) from public, anon, authenticated;

create or replace function private.enqueue_finish(p_attempt uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  a public.attempts;
  e public.exams;
  u public.allowed_users;
  nid uuid;
  emails text[];
begin
  select * into a from public.attempts where id = p_attempt;
  if not found or a.status <> 'submitted' then return null; end if;
  select * into e from public.exams where id = a.exam_id;
  select * into u from public.allowed_users where user_id = a.user_id;
  emails := private.effective_notify_emails(e);

  insert into public.finish_notifications as fn (
    attempt_id, exam_id, exam_slug, exam_title, student_email, student_user_id,
    submit_reason, submitted_at, pending_manual, auto_score, max_score, email_to
  ) values (
    a.id, e.id, e.slug, e.title, u.email, a.user_id,
    a.submit_reason, coalesce(a.submitted_at, now()),
    coalesce(a.pending_manual, 0), a.auto_score, a.max_score, emails
  )
  on conflict (attempt_id) do update set
    pending_manual = excluded.pending_manual,
    auto_score = excluded.auto_score,
    max_score = excluded.max_score
  returning id into nid;

  begin
    perform private.send_finish_email(nid);
  exception when others then
    update public.finish_notifications
       set email_status = 'failed', email_error = left(SQLERRM, 500)
     where id = nid and email_status = 'pending';
  end;
  return nid;
end $$;

revoke execute on function private.enqueue_finish(uuid) from public, anon, authenticated;

-- Hook submit + auto-submit
create or replace function public.submit_attempt(p_attempt uuid, p_reason text default 'manual') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); a public.attempts;
begin
  select * into a from public.attempts where id = p_attempt and user_id = v for update;
  if not found then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  if a.status = 'submitted' then
    return jsonb_build_object('status', 'submitted', 'submitted_at', a.submitted_at);
  end if;
  update public.attempts set status = 'submitted',
    submitted_at  = least(now(), a.deadline + interval '30 seconds'),
    submit_reason = case when now() > a.deadline + interval '30 seconds' then 'time_expired'
                         when p_reason in ('manual','timer') then p_reason else 'manual' end
   where id = p_attempt returning * into a;
  perform private.mark_attempt(p_attempt);
  perform private.enqueue_finish(p_attempt);
  return jsonb_build_object('status', 'submitted', 'submitted_at', a.submitted_at);
end $$;

create or replace function private.finalize_expired(p_user uuid default null) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select id from public.attempts
            where status = 'in_progress' and now() > deadline + interval '30 seconds'
              and (p_user is null or user_id = p_user)
            for update
  loop
    update public.attempts set status = 'submitted', submitted_at = deadline, submit_reason = 'time_expired'
     where id = r.id;
    perform private.mark_attempt(r.id);
    perform private.enqueue_finish(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- admin RPCs: gate + notify_emails on upsert
create or replace function public.admin_allow_user(p_email text, p_role text default 'student') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform private.require_admin();
  if p_role not in ('student','admin') then raise exception 'role must be student or admin'; end if;
  select id into v from auth.users where lower(email) = lower(p_email);
  if v is null then raise exception 'No auth user with email %', p_email; end if;
  insert into public.allowed_users(user_id, email, role) values (v, lower(p_email), p_role)
  on conflict (user_id) do update set role = excluded.role, email = excluded.email;
  return jsonb_build_object('user_id', v, 'email', lower(p_email), 'role', p_role);
end $$;

create or replace function public.admin_upsert_exam(p jsonb, p_force bool default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_exam uuid; v_has bool; q jsonb; i bigint; v_q uuid; r record; v_pub bool; v_sheet jsonb; v_emails text[];
begin
  perform private.require_admin();
  v_sheet := case when jsonb_typeof(p->'equation_sheet') = 'object'
                   and jsonb_typeof(p->'equation_sheet'->'pages') = 'array'
                   and jsonb_array_length(p->'equation_sheet'->'pages') > 0
                  then p->'equation_sheet' end;
  if p ? 'notify_emails' and p->'notify_emails' is not null and p->'notify_emails' <> 'null'::jsonb then
    if jsonb_typeof(p->'notify_emails') = 'array' then
      select array_agg(distinct lower(x #>> '{}')) into v_emails
        from jsonb_array_elements(p->'notify_emails') x
       where btrim(coalesce(x #>> '{}','')) <> '';
      if v_emails is null then v_emails := '{}'; end if;
    else
      raise exception 'notify_emails must be a JSON array of emails';
    end if;
  end if;

  insert into public.exams as x (slug, title, instructions, time_limit_minutes, opens_at, closes_at, attempts_allowed,
                            shuffle_questions, shuffle_options, log_focus, published, equation_sheet, notify_emails)
  values (p->>'slug', p->>'title', coalesce(p->>'instructions',''), (p->>'time_limit_minutes')::int,
          (p->>'opens_at')::timestamptz, (p->>'closes_at')::timestamptz, coalesce((p->>'attempts_allowed')::int, 1),
          coalesce((p->>'shuffle_questions')::bool, false), coalesce((p->>'shuffle_options')::bool, false),
          coalesce((p->>'log_focus')::bool, true), coalesce((p->>'published')::bool, false), v_sheet, v_emails)
  on conflict (slug) do update set
    title = excluded.title, instructions = excluded.instructions, time_limit_minutes = excluded.time_limit_minutes,
    opens_at = excluded.opens_at, closes_at = excluded.closes_at, attempts_allowed = excluded.attempts_allowed,
    shuffle_questions = excluded.shuffle_questions, shuffle_options = excluded.shuffle_options,
    log_focus = excluded.log_focus, equation_sheet = excluded.equation_sheet,
    notify_emails = case when p ? 'notify_emails' then excluded.notify_emails else x.notify_emails end,
    published = case when p ? 'published' and p->'published' <> 'null'::jsonb then excluded.published else x.published end,
    updated_at = now()
  returning id, published into v_exam, v_pub;

  v_has := exists (select 1 from public.attempts where exam_id = v_exam);
  if exists (select 1 from public.questions where exam_id = v_exam
              and qkey not in (select x->>'id' from jsonb_array_elements(p->'questions') x)) then
    if v_has and not p_force then
      raise exception 'Exam % already has attempts; removing questions needs --force', p->>'slug';
    end if;
    delete from public.questions where exam_id = v_exam
       and qkey not in (select x->>'id' from jsonb_array_elements(p->'questions') x);
  end if;

  for q, i in select x, o from jsonb_array_elements(p->'questions') with ordinality t(x, o) loop
    insert into public.questions(exam_id, qkey, position, type, prompt, options, unit, image_path, marks)
    values (v_exam, q->>'id', i, q->>'type', q->>'prompt', coalesce(q->'options','[]'::jsonb), q->>'unit',
            q->>'image_path', coalesce((q->>'marks')::numeric, 1))
    on conflict (exam_id, qkey) do update set position = excluded.position, type = excluded.type,
      prompt = excluded.prompt, options = excluded.options, unit = excluded.unit,
      image_path = excluded.image_path, marks = excluded.marks
    returning id into v_q;
    insert into public.question_keys(question_id, answer, tolerance_abs, tolerance_pct, explanation)
    values (v_q, q->'answer', (q->>'tolerance_abs')::numeric, (q->>'tolerance_pct')::numeric, q->>'explanation')
    on conflict (question_id) do update set answer = excluded.answer, tolerance_abs = excluded.tolerance_abs,
      tolerance_pct = excluded.tolerance_pct, explanation = excluded.explanation;
  end loop;

  for r in select id from public.attempts where exam_id = v_exam and status = 'submitted' loop
    perform private.mark_attempt(r.id);
  end loop;

  return jsonb_build_object('exam_id', v_exam, 'slug', p->>'slug', 'published', v_pub,
    'questions', jsonb_array_length(p->'questions'), 'had_attempts', v_has,
    'equation_sheet_pages', coalesce(jsonb_array_length(v_sheet->'pages'), 0),
    'notify_emails', (select notify_emails from public.exams where id = v_exam));
end $$;

create or replace function public.admin_set_published(p_slug text, p_published bool) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  update public.exams set published = p_published, updated_at = now() where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  return jsonb_build_object('slug', p_slug, 'published', p_published);
end $$;

create or replace function public.admin_list() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  perform private.finalize_expired(null);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'slug', e.slug, 'title', e.title, 'published', e.published, 'results_released', e.results_released,
    'time_limit_minutes', e.time_limit_minutes, 'opens_at', e.opens_at, 'closes_at', e.closes_at,
    'attempts_allowed', e.attempts_allowed,
    'equation_sheet_pages', coalesce(jsonb_array_length(e.equation_sheet->'pages'), 0),
    'notify_emails', e.notify_emails,
    'questions', (select count(*) from public.questions q where q.exam_id = e.id),
    'total_marks', (select coalesce(sum(marks),0) from public.questions q where q.exam_id = e.id),
    'attempts', (select count(*) from public.attempts a where a.exam_id = e.id),
    'submitted', (select count(*) from public.attempts a where a.exam_id = e.id and a.status = 'submitted'),
    'pending_manual', (select coalesce(sum(pending_manual),0) from public.attempts a where a.exam_id = e.id)
  ) order by e.created_at) from public.exams e), '[]'::jsonb);
end $$;

create or replace function public.admin_export(p_slug text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.exams;
begin
  perform private.require_admin();
  perform private.finalize_expired(null);
  select * into e from public.exams where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  return jsonb_build_object(
    'exported_at', now(),
    'exam', to_jsonb(e) - 'id',
    'questions', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', q.qkey, 'position', q.position, 'type', q.type, 'prompt', q.prompt, 'options', q.options,
        'unit', q.unit, 'image_path', q.image_path, 'marks', q.marks, 'answer', k.answer,
        'tolerance_abs', k.tolerance_abs, 'tolerance_pct', k.tolerance_pct, 'explanation', k.explanation)
        order by q.position), '[]'::jsonb)
      from public.questions q left join public.question_keys k on k.question_id = q.id where q.exam_id = e.id),
    'attempts', (select coalesce(jsonb_agg(jsonb_build_object(
        'attempt_id', a.id, 'attempt_no', a.attempt_no, 'user_email', u.email, 'status', a.status,
        'started_at', a.started_at, 'deadline', a.deadline, 'submitted_at', a.submitted_at,
        'submit_reason', a.submit_reason, 'released', (a.released or e.results_released),
        'max_score', a.max_score, 'auto_score', a.auto_score, 'manual_score', a.manual_score,
        'total_score', a.total_score, 'pending_manual', a.pending_manual, 'feedback', a.feedback,
        'question_order', (select jsonb_agg(q.qkey order by t.ord) from unnest(a.question_order) with ordinality t(qid, ord)
                             join public.questions q on q.id = t.qid),
        'answers', (select coalesce(jsonb_agg(jsonb_build_object(
            'question', q.qkey, 'type', q.type, 'marks', q.marks, 'response', an.response, 'saved_at', an.saved_at,
            'is_correct', an.is_correct, 'auto_marks', an.auto_marks, 'manual_marks', an.manual_marks,
            'awarded', coalesce(an.manual_marks, an.auto_marks),
            'needs_manual', (an.needs_manual and an.manual_marks is null), 'feedback', an.feedback)
            order by q.position), '[]'::jsonb)
          from public.answers an join public.questions q on q.id = an.question_id where an.attempt_id = a.id),
        'focus_events', (select coalesce(jsonb_agg(jsonb_build_object('event', f.event, 'at', f.occurred_at,
            'client_ts', f.client_ts, 'detail', f.detail) order by f.id), '[]'::jsonb)
          from public.focus_events f where f.attempt_id = a.id)
      ) order by a.started_at), '[]'::jsonb)
      from public.attempts a left join public.allowed_users u on u.user_id = a.user_id where a.exam_id = e.id),
    'pending_short_answers', (select coalesce(jsonb_agg(jsonb_build_object(
        'attempt_id', a.id, 'question', q.qkey, 'prompt', q.prompt, 'marks', q.marks,
        'response', an.response, 'model_answer', k.answer) order by a.started_at, q.position), '[]'::jsonb)
      from public.answers an join public.attempts a on a.id = an.attempt_id
      join public.questions q on q.id = an.question_id left join public.question_keys k on k.question_id = q.id
      where a.exam_id = e.id and an.needs_manual and an.manual_marks is null));
end $$;

create or replace function public.admin_mark(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.exams; a_id uuid; m jsonb; q public.questions; v_marks numeric; n int := 0;
begin
  perform private.require_admin();
  select * into e from public.exams where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  perform private.finalize_expired(null);
  if p ? 'attempt_id' and p->>'attempt_id' is not null then
    select id into a_id from public.attempts where id = (p->>'attempt_id')::uuid and exam_id = e.id;
  else
    select id into a_id from public.attempts where exam_id = e.id and status = 'submitted'
     order by submitted_at desc limit 1;
  end if;
  if a_id is null then raise exception 'No matching submitted attempt for %', p_slug; end if;
  if (select status from public.attempts where id = a_id) <> 'submitted' then
    raise exception 'Attempt % is still in progress', a_id;
  end if;
  for m in select * from jsonb_array_elements(coalesce(p->'questions','[]'::jsonb)) loop
    select * into q from public.questions where exam_id = e.id and qkey = m->>'id';
    if not found then raise exception 'No question "%" in %', m->>'id', p_slug; end if;
    insert into public.answers(attempt_id, question_id, response) values (a_id, q.id, null) on conflict do nothing;
    if m ? 'marks' and m->'marks' <> 'null'::jsonb then
      v_marks := (m->>'marks')::numeric;
      if v_marks < 0 or v_marks > q.marks then
        raise exception 'Marks for % must be between 0 and %', q.qkey, q.marks;
      end if;
      update public.answers set manual_marks = v_marks,
        is_correct = case when v_marks >= q.marks then true when v_marks = 0 then false else null end
       where attempt_id = a_id and question_id = q.id;
    end if;
    if m ? 'feedback' then
      update public.answers set feedback = m->>'feedback' where attempt_id = a_id and question_id = q.id;
    end if;
    n := n + 1;
  end loop;
  if p ? 'overall_feedback' then
    update public.attempts set feedback = p->>'overall_feedback' where id = a_id;
  end if;
  perform private.recompute(a_id);
  return (select jsonb_build_object('attempt_id', a.id, 'updated_questions', n, 'total_score', a.total_score,
            'max_score', a.max_score, 'pending_manual', a.pending_manual) from public.attempts a where a.id = a_id);
end $$;

create or replace function public.admin_release(p_slug text, p_released bool default true, p_attempt uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.exams;
begin
  perform private.require_admin();
  select * into e from public.exams where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  perform private.finalize_expired(null);
  if p_attempt is null then
    update public.exams set results_released = p_released, released_at = case when p_released then now() end
     where id = e.id;
    if not p_released then update public.attempts set released = false where exam_id = e.id; end if;
  else
    update public.attempts set released = p_released where id = p_attempt and exam_id = e.id;
    if not found then raise exception 'No attempt % in %', p_attempt, p_slug; end if;
  end if;
  return jsonb_build_object('slug', p_slug, 'released', p_released, 'attempt_id', p_attempt,
    'pending_manual', (select coalesce(sum(pending_manual),0) from public.attempts
                        where exam_id = e.id and (p_attempt is null or id = p_attempt)));
end $$;

create or replace function public.admin_delete_attempt(p_attempt uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  delete from public.attempts where id = p_attempt;
  if not found then raise exception 'No attempt %', p_attempt; end if;
  return jsonb_build_object('deleted', p_attempt);
end $$;

create or replace function public.admin_delete_exam(p_slug text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  delete from public.exams where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  return jsonb_build_object('deleted', p_slug);
end $$;

-- ---------------------------------------------------------------- notify / finishes RPCs
create or replace function public.admin_get_notify_emails(p_slug text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.exams; g jsonb;
begin
  perform private.require_admin();
  select value into g from public.app_settings where key = 'notify_emails';
  if p_slug is null then
    return jsonb_build_object(
      'scope', 'global',
      'emails', coalesce(g->'emails', '["ohady1992@gmail.com"]'::jsonb),
      'note', 'Study Mentor is NOT emailed; wake via finish_notifications queue / routine.'
    );
  end if;
  select * into e from public.exams where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  return jsonb_build_object(
    'scope', 'exam', 'slug', p_slug,
    'emails', to_jsonb(e.notify_emails),
    'effective', to_jsonb(private.effective_notify_emails(e)),
    'inherits_global', (e.notify_emails is null)
  );
end $$;

create or replace function public.admin_set_notify_emails(p_emails text[], p_slug text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare cleaned text[];
begin
  perform private.require_admin();
  if p_emails is null then
    cleaned := null;
  else
    select array_agg(distinct lower(btrim(x))) into cleaned
      from unnest(p_emails) x where btrim(coalesce(x,'')) <> '';
    if cleaned is null then cleaned := '{}'; end if;
  end if;
  if p_slug is null then
    if cleaned is null or cardinality(cleaned) = 0 then
      raise exception 'Global notify_emails needs at least one address';
    end if;
    insert into public.app_settings(key, value) values
      ('notify_emails', jsonb_build_object('emails', to_jsonb(cleaned)))
    on conflict (key) do update set value = excluded.value, updated_at = now();
    return jsonb_build_object('scope', 'global', 'emails', to_jsonb(cleaned));
  end if;
  update public.exams set notify_emails = cleaned, updated_at = now() where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  return public.admin_get_notify_emails(p_slug);
end $$;

create or replace function public.admin_list_finishes(p_unacked_only bool default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  perform private.finalize_expired(null);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', n.id,
      'attempt_id', n.attempt_id,
      'exam_slug', n.exam_slug,
      'exam_title', n.exam_title,
      'student_email', n.student_email,
      'submit_reason', n.submit_reason,
      'submitted_at', n.submitted_at,
      'pending_manual', n.pending_manual,
      'auto_score', n.auto_score,
      'max_score', n.max_score,
      'email_status', n.email_status,
      'email_to', n.email_to,
      'email_error', n.email_error,
      'created_at', n.created_at,
      'acked_at', n.acked_at,
      'commands', jsonb_build_object(
        'export', format('bin/exam export %s', n.exam_slug),
        'mark', format('bin/exam mark %s --file results/%s-marks.json', n.exam_slug, n.exam_slug),
        'release', format('bin/exam release %s --attempt %s', n.exam_slug, n.attempt_id)
      )
    ) order by n.created_at)
    from public.finish_notifications n
    where (not p_unacked_only) or n.acked_at is null), '[]'::jsonb);
end $$;

create or replace function public.admin_ack_finish(p_id uuid default null, p_attempt uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n public.finish_notifications; who text;
begin
  perform private.require_admin();
  who := coalesce(
    (select email from public.allowed_users where user_id = auth.uid()),
    'service_role'
  );
  if p_id is not null then
    update public.finish_notifications set acked_at = now(), acked_by = who
     where id = p_id returning * into n;
  elsif p_attempt is not null then
    update public.finish_notifications set acked_at = now(), acked_by = who
     where attempt_id = p_attempt returning * into n;
  else
    raise exception 'Provide p_id or p_attempt';
  end if;
  if not found then raise exception 'Finish notification not found'; end if;
  return jsonb_build_object('id', n.id, 'attempt_id', n.attempt_id, 'acked_at', n.acked_at, 'acked_by', n.acked_by);
end $$;

-- Signed upload helper for Examiner (returns path; client uses storage upload with user JWT)
create or replace function public.admin_is_admin() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then return jsonb_build_object('admin', false); end if;
  return jsonb_build_object(
    'admin', exists (select 1 from public.allowed_users where user_id = v and role = 'admin'),
    'email', (select email from public.allowed_users where user_id = v),
    'role', (select role from public.allowed_users where user_id = v)
  );
end $$;

-- ---------------------------------------------------------------- storage: admin write (via SECURITY DEFINER helper)
create or replace function private.is_admin() returns bool
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.allowed_users u
     where u.user_id = auth.uid() and u.role = 'admin');
$$;
revoke execute on function private.is_admin() from public, anon;
grant  execute on function private.is_admin() to authenticated;

drop policy if exists "exam images: admin write" on storage.objects;
create policy "exam images: admin write" on storage.objects
  for all to authenticated
  using (bucket_id = 'exam-images' and private.is_admin())
  with check (bucket_id = 'exam-images' and private.is_admin());

-- Admins may also sign any exam-images object (for preview while authoring)
create or replace function private.can_view_image(p_name text) returns bool
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.allowed_users u where u.user_id = auth.uid())
     and (
       exists (select 1 from public.allowed_users u
                where u.user_id = auth.uid() and u.role = 'admin')
       or exists (
         select 1 from public.questions q
           join public.attempts a on a.exam_id = q.exam_id and q.id = any(a.question_order)
          where q.image_path = p_name and a.user_id = auth.uid())
       or exists (
         select 1 from public.exams e
           join public.attempts a on a.exam_id = e.id and a.user_id = auth.uid()
           cross join lateral jsonb_array_elements(coalesce(e.equation_sheet -> 'pages', '[]'::jsonb)) pg
          where pg ->> 'path' = p_name and private.sheet_visible(a, e))
     );
$$;

-- ---------------------------------------------------------------- grants
revoke execute on function public.submit_attempt(uuid, text) from public, anon;
grant  execute on function public.submit_attempt(uuid, text) to authenticated;

revoke execute on function public.admin_allow_user(text, text) from public, anon;
revoke execute on function public.admin_upsert_exam(jsonb, bool) from public, anon;
revoke execute on function public.admin_set_published(text, bool) from public, anon;
revoke execute on function public.admin_list() from public, anon;
revoke execute on function public.admin_export(text) from public, anon;
revoke execute on function public.admin_mark(text, jsonb) from public, anon;
revoke execute on function public.admin_release(text, bool, uuid) from public, anon;
revoke execute on function public.admin_delete_attempt(uuid) from public, anon;
revoke execute on function public.admin_delete_exam(text) from public, anon;
revoke execute on function public.admin_get_notify_emails(text) from public, anon;
revoke execute on function public.admin_set_notify_emails(text[], text) from public, anon;
revoke execute on function public.admin_list_finishes(bool) from public, anon;
revoke execute on function public.admin_ack_finish(uuid, uuid) from public, anon;
revoke execute on function public.admin_is_admin() from public, anon;

grant execute on function public.admin_allow_user(text, text)            to authenticated, service_role;
grant execute on function public.admin_upsert_exam(jsonb, bool)          to authenticated, service_role;
grant execute on function public.admin_set_published(text, bool)         to authenticated, service_role;
grant execute on function public.admin_list()                            to authenticated, service_role;
grant execute on function public.admin_export(text)                      to authenticated, service_role;
grant execute on function public.admin_mark(text, jsonb)                 to authenticated, service_role;
grant execute on function public.admin_release(text, bool, uuid)         to authenticated, service_role;
grant execute on function public.admin_delete_attempt(uuid)              to authenticated, service_role;
grant execute on function public.admin_delete_exam(text)                 to authenticated, service_role;
grant execute on function public.admin_get_notify_emails(text)           to authenticated, service_role;
grant execute on function public.admin_set_notify_emails(text[], text)   to authenticated, service_role;
grant execute on function public.admin_list_finishes(bool)               to authenticated, service_role;
grant execute on function public.admin_ack_finish(uuid, uuid)            to authenticated, service_role;
grant execute on function public.admin_is_admin()                        to authenticated, service_role;

revoke execute on function private.can_view_image(text) from public, anon;
grant  execute on function private.can_view_image(text) to authenticated;

notify pgrst, 'reload schema';
