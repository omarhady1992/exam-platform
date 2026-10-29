-- Exam platform: schema, security and RPCs.
-- All client access goes through SECURITY DEFINER functions. Tables are RLS-enabled
-- with NO policies and all privileges revoked from anon/authenticated, so answer keys
-- (public.question_keys) can never be read by a browser session.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------- tables
create table if not exists public.allowed_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  role       text not null default 'student' check (role in ('student','admin')),
  created_at timestamptz not null default now()
);

create table if not exists public.exams (
  id                 uuid primary key default gen_random_uuid(),
  slug               text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,80}$'),
  title              text not null,
  instructions       text not null default '',
  time_limit_minutes int  not null check (time_limit_minutes between 1 and 1440),
  opens_at           timestamptz,
  closes_at          timestamptz,
  attempts_allowed   int  not null default 1 check (attempts_allowed >= 1),
  shuffle_questions  bool not null default false,
  shuffle_options    bool not null default false,
  log_focus          bool not null default true,
  published          bool not null default false,
  results_released   bool not null default false,
  released_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table if not exists public.questions (
  id         uuid primary key default gen_random_uuid(),
  exam_id    uuid not null references public.exams(id) on delete cascade,
  qkey       text not null,
  position   int  not null,
  type       text not null check (type in ('mcq','multi','tf','short','numeric')),
  prompt     text not null,
  options    jsonb not null default '[]'::jsonb,
  unit       text,
  image_path text,
  marks      numeric not null default 1 check (marks >= 0),
  unique (exam_id, qkey)
);

create table if not exists public.question_keys (
  question_id   uuid primary key references public.questions(id) on delete cascade,
  answer        jsonb,
  tolerance_abs numeric,
  tolerance_pct numeric,
  explanation   text
);

create table if not exists public.attempts (
  id             uuid primary key default gen_random_uuid(),
  exam_id        uuid not null references public.exams(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  attempt_no     int  not null,
  started_at     timestamptz not null default now(),
  deadline       timestamptz not null,
  submitted_at   timestamptz,
  submit_reason  text,
  status         text not null default 'in_progress' check (status in ('in_progress','submitted')),
  question_order uuid[] not null,
  option_orders  jsonb not null default '{}'::jsonb,
  max_score      numeric,
  auto_score     numeric,
  manual_score   numeric,
  total_score    numeric,
  pending_manual int not null default 0,
  released       bool not null default false,
  feedback       text,
  unique (exam_id, user_id, attempt_no)
);
create unique index if not exists attempts_one_open on public.attempts(exam_id, user_id) where status = 'in_progress';

create table if not exists public.answers (
  attempt_id   uuid not null references public.attempts(id) on delete cascade,
  question_id  uuid not null references public.questions(id) on delete cascade,
  response     jsonb,
  saved_at     timestamptz not null default now(),
  is_correct   bool,
  auto_marks   numeric,
  manual_marks numeric,
  needs_manual bool not null default false,
  feedback     text,
  primary key (attempt_id, question_id)
);

create table if not exists public.focus_events (
  id          bigserial primary key,
  attempt_id  uuid not null references public.attempts(id) on delete cascade,
  event       text not null,
  occurred_at timestamptz not null default now(),
  client_ts   timestamptz,
  detail      jsonb
);
create index if not exists focus_events_attempt on public.focus_events(attempt_id);

alter table public.allowed_users enable row level security;
alter table public.exams         enable row level security;
alter table public.questions     enable row level security;
alter table public.question_keys enable row level security;
alter table public.attempts      enable row level security;
alter table public.answers       enable row level security;
alter table public.focus_events  enable row level security;
alter table public.question_keys force row level security;

revoke all on all tables    in schema public from anon, authenticated, public;
revoke all on all sequences in schema public from anon, authenticated, public;

-- ---------------------------------------------------------------- private helpers
create or replace function private.require_user() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null or not exists (select 1 from public.allowed_users where user_id = v) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return v;
end $$;

create or replace function private.recompute(p_attempt uuid) returns void
language sql security definer set search_path = '' as $$
  update public.attempts a set
    max_score    = (select coalesce(sum(q.marks),0) from public.questions q where q.id = any(a.question_order)),
    auto_score   = (select coalesce(sum(an.auto_marks),0) from public.answers an where an.attempt_id = a.id),
    manual_score = (select sum(an.manual_marks) from public.answers an where an.attempt_id = a.id),
    total_score  = (select coalesce(sum(coalesce(an.manual_marks, an.auto_marks, 0)),0)
                      from public.answers an where an.attempt_id = a.id and an.question_id = any(a.question_order)),
    pending_manual = (select count(*) from public.answers an
                       where an.attempt_id = a.id and an.needs_manual and an.manual_marks is null)
  where a.id = p_attempt;
$$;

create or replace function private.mark_attempt(p_attempt uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r record; v_resp jsonb; v_ok bool; v_num numeric; v_key numeric; v_tol numeric; v_empty bool;
begin
  for r in
    select q.id, q.type, q.marks, k.answer, k.tolerance_abs, k.tolerance_pct
      from public.attempts a
      join public.questions q on q.id = any(a.question_order)
      left join public.question_keys k on k.question_id = q.id
     where a.id = p_attempt
  loop
    insert into public.answers(attempt_id, question_id, response) values (p_attempt, r.id, null)
      on conflict do nothing;
    select response into v_resp from public.answers where attempt_id = p_attempt and question_id = r.id;
    v_empty := v_resp is null or jsonb_typeof(v_resp) = 'null'
               or (jsonb_typeof(v_resp) = 'string' and btrim(v_resp #>> '{}') = '')
               or (jsonb_typeof(v_resp) = 'array' and jsonb_array_length(v_resp) = 0);

    if r.type = 'short' then
      if v_empty then
        update public.answers set is_correct = false, auto_marks = 0, needs_manual = false
         where attempt_id = p_attempt and question_id = r.id;
      else
        update public.answers set auto_marks = null, needs_manual = true
         where attempt_id = p_attempt and question_id = r.id;
      end if;
      continue;
    end if;

    v_ok := false;
    if not v_empty and r.answer is not null then
      if r.type in ('mcq','tf') then
        v_ok := v_resp = r.answer;
      elsif r.type = 'multi' then
        if jsonb_typeof(v_resp) = 'array' then
          v_ok := (select coalesce(array_agg(distinct x order by x), '{}') from jsonb_array_elements_text(v_resp) x)
                = (select coalesce(array_agg(distinct x order by x), '{}') from jsonb_array_elements_text(r.answer) x);
        end if;
      elsif r.type = 'numeric' then
        begin
          v_num := replace(btrim(v_resp #>> '{}'), ',', '')::numeric;
        exception when others then v_num := null;
        end;
        v_key := (r.answer #>> '{}')::numeric;
        if v_num is not null then
          v_tol := greatest(coalesce(r.tolerance_abs,0), abs(v_key) * coalesce(r.tolerance_pct,0) / 100.0, 0.000000001);
          v_ok := abs(v_num - v_key) <= v_tol;
        end if;
      end if;
    end if;
    update public.answers
       set is_correct = v_ok, auto_marks = case when v_ok then r.marks else 0 end, needs_manual = false
     where attempt_id = p_attempt and question_id = r.id;
  end loop;
  perform private.recompute(p_attempt);
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
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function private.can_view_image(p_name text) returns bool
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.questions q
      join public.attempts a on a.exam_id = q.exam_id and q.id = any(a.question_order)
     where q.image_path = p_name and a.user_id = auth.uid()
       and exists (select 1 from public.allowed_users u where u.user_id = auth.uid()));
$$;

-- ---------------------------------------------------------------- client RPCs
create or replace function public.whoami() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user();
begin
  return (select jsonb_build_object('user_id', user_id, 'email', email, 'role', role)
            from public.allowed_users where user_id = v);
end $$;

create or replace function public.list_my_exams() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user();
begin
  perform private.finalize_expired(v);
  return jsonb_build_object('server_now', now(), 'exams', coalesce((
    select jsonb_agg(jsonb_build_object(
      'slug', e.slug, 'title', e.title, 'instructions', e.instructions,
      'time_limit_minutes', e.time_limit_minutes, 'opens_at', e.opens_at, 'closes_at', e.closes_at,
      'attempts_allowed', e.attempts_allowed, 'log_focus', e.log_focus,
      'question_count', (select count(*) from public.questions q where q.exam_id = e.id),
      'total_marks', (select coalesce(sum(q.marks),0) from public.questions q where q.exam_id = e.id),
      'attempts', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', a.id, 'attempt_no', a.attempt_no, 'status', a.status, 'started_at', a.started_at,
          'deadline', a.deadline, 'submitted_at', a.submitted_at,
          'released', (a.released or e.results_released)) order by a.attempt_no), '[]'::jsonb)
        from public.attempts a where a.exam_id = e.id and a.user_id = v)
    ) order by coalesce(e.opens_at, e.created_at) desc)
    from public.exams e where e.published), '[]'::jsonb));
end $$;

create or replace function public.get_attempt(p_attempt uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); a public.attempts; e public.exams;
begin
  select * into a from public.attempts where id = p_attempt and user_id = v;
  if not found then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  if a.status = 'in_progress' and now() > a.deadline + interval '30 seconds' then
    perform private.finalize_expired(v);
    select * into a from public.attempts where id = p_attempt;
  end if;
  select * into e from public.exams where id = a.exam_id;
  return jsonb_build_object(
    'attempt_id', a.id, 'attempt_no', a.attempt_no, 'status', a.status,
    'started_at', a.started_at, 'deadline', a.deadline, 'submitted_at', a.submitted_at,
    'server_now', now(), 'released', (a.released or e.results_released),
    'exam', jsonb_build_object('slug', e.slug, 'title', e.title, 'instructions', e.instructions,
                               'time_limit_minutes', e.time_limit_minutes, 'log_focus', e.log_focus),
    'questions', case when a.status = 'in_progress' then (
      select jsonb_agg(jsonb_build_object(
        'id', q.id, 'n', t.ord, 'type', q.type, 'prompt', q.prompt, 'unit', q.unit,
        'image_path', q.image_path, 'marks', q.marks,
        'options', case when jsonb_array_length(q.options) > 0 then (
            select jsonb_agg(o order by oo.ord)
              from jsonb_array_elements(coalesce(a.option_orders -> (q.id::text), '[]'::jsonb)) with ordinality oo(oid, ord)
              join jsonb_array_elements(q.options) o on o -> 'id' = oo.oid)
          else '[]'::jsonb end,
        'response', an.response) order by t.ord)
      from unnest(a.question_order) with ordinality t(qid, ord)
      join public.questions q on q.id = t.qid
      left join public.answers an on an.attempt_id = a.id and an.question_id = q.id)
    else null end);
end $$;

create or replace function public.start_attempt(p_slug text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); e public.exams; a_id uuid; n int; v_order uuid[]; v_opts jsonb; v_deadline timestamptz;
begin
  perform private.finalize_expired(v);
  select * into e from public.exams where slug = p_slug and published;
  if not found then raise exception 'Exam not found' using errcode = 'P0002'; end if;
  perform pg_advisory_xact_lock(hashtext(e.id::text || v::text));
  select id into a_id from public.attempts where exam_id = e.id and user_id = v and status = 'in_progress';
  if found then return public.get_attempt(a_id); end if;
  if e.opens_at is not null and now() < e.opens_at then raise exception 'This exam is not open yet'; end if;
  if e.closes_at is not null and now() >= e.closes_at then raise exception 'This exam is closed'; end if;
  select count(*) into n from public.attempts where exam_id = e.id and user_id = v;
  if n >= e.attempts_allowed then raise exception 'No attempts left for this exam'; end if;

  select array_agg(q.id order by case when e.shuffle_questions then random() else q.position end)
    into v_order from public.questions q where q.exam_id = e.id;
  if v_order is null then raise exception 'Exam has no questions'; end if;

  select coalesce(jsonb_object_agg(q.id::text, (
           select jsonb_agg(o -> 'id' order by case when e.shuffle_options and q.type in ('mcq','multi') then random() else t.ord end)
             from jsonb_array_elements(q.options) with ordinality t(o, ord))), '{}'::jsonb)
    into v_opts from public.questions q where q.exam_id = e.id and jsonb_array_length(q.options) > 0;

  v_deadline := now() + make_interval(mins => e.time_limit_minutes);
  if e.closes_at is not null and e.closes_at < v_deadline then v_deadline := e.closes_at; end if;

  insert into public.attempts(exam_id, user_id, attempt_no, deadline, question_order, option_orders)
  values (e.id, v, n + 1, v_deadline, v_order, v_opts) returning id into a_id;
  return public.get_attempt(a_id);
end $$;

create or replace function public.save_answer(p_attempt uuid, p_question uuid, p_response jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); a public.attempts;
begin
  select * into a from public.attempts where id = p_attempt and user_id = v for update;
  if not found then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  if a.status <> 'in_progress' then raise exception 'Attempt already submitted' using errcode = 'P0001'; end if;
  if now() > a.deadline + interval '30 seconds' then raise exception 'Time is up: answer not saved' using errcode = 'P0001'; end if;
  if not (p_question = any(a.question_order)) then raise exception 'Question is not part of this attempt'; end if;
  if length(coalesce(p_response::text, '')) > 20000 then raise exception 'Answer too long'; end if;
  insert into public.answers(attempt_id, question_id, response, saved_at)
  values (p_attempt, p_question, p_response, now())
  on conflict (attempt_id, question_id) do update set response = excluded.response, saved_at = now();
  return jsonb_build_object('saved_at', now());
end $$;

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
  return jsonb_build_object('status', 'submitted', 'submitted_at', a.submitted_at);
end $$;

create or replace function public.log_focus_event(p_attempt uuid, p_event text, p_client_ts timestamptz default null, p_detail jsonb default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); a public.attempts; e public.exams;
begin
  select * into a from public.attempts where id = p_attempt and user_id = v;
  if not found then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  select * into e from public.exams where id = a.exam_id;
  if not e.log_focus or a.status <> 'in_progress' or now() > a.deadline + interval '30 seconds' then return; end if;
  if p_event not in ('blur','focus','hidden','visible','pagehide','pageshow','resume','offline','online') then
    raise exception 'Unknown event';
  end if;
  if (select count(*) from public.focus_events where attempt_id = p_attempt) >= 2000 then return; end if;
  insert into public.focus_events(attempt_id, event, client_ts, detail)
  values (p_attempt, p_event, p_client_ts, case when length(coalesce(p_detail::text,'')) <= 2000 then p_detail end);
end $$;

create or replace function public.get_results(p_attempt uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); a public.attempts; e public.exams;
begin
  select * into a from public.attempts where id = p_attempt and user_id = v;
  if not found then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  select * into e from public.exams where id = a.exam_id;
  if a.status <> 'submitted' or not (a.released or e.results_released) then
    raise exception 'Results have not been released yet' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'attempt_id', a.id, 'attempt_no', a.attempt_no, 'started_at', a.started_at, 'submitted_at', a.submitted_at,
    'submit_reason', a.submit_reason, 'max_score', a.max_score, 'total_score', a.total_score,
    'pending_manual', a.pending_manual, 'feedback', a.feedback,
    'exam', jsonb_build_object('slug', e.slug, 'title', e.title),
    'questions', (
      select jsonb_agg(jsonb_build_object(
        'n', t.ord, 'type', q.type, 'prompt', q.prompt, 'options', q.options, 'unit', q.unit,
        'image_path', q.image_path, 'marks', q.marks, 'response', an.response,
        'answer', k.answer, 'tolerance_abs', k.tolerance_abs, 'tolerance_pct', k.tolerance_pct,
        'explanation', k.explanation, 'is_correct', an.is_correct,
        'awarded', coalesce(an.manual_marks, an.auto_marks),
        'pending', (an.needs_manual and an.manual_marks is null), 'feedback', an.feedback) order by t.ord)
      from unnest(a.question_order) with ordinality t(qid, ord)
      join public.questions q on q.id = t.qid
      left join public.question_keys k on k.question_id = q.id
      left join public.answers an on an.attempt_id = a.id and an.question_id = q.id));
end $$;

-- ---------------------------------------------------------------- admin RPCs (service_role only)
create or replace function public.admin_allow_user(p_email text, p_role text default 'student') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  select id into v from auth.users where lower(email) = lower(p_email);
  if v is null then raise exception 'No auth user with email %', p_email; end if;
  insert into public.allowed_users(user_id, email, role) values (v, lower(p_email), p_role)
  on conflict (user_id) do update set role = excluded.role, email = excluded.email;
  return jsonb_build_object('user_id', v, 'email', lower(p_email), 'role', p_role);
end $$;

create or replace function public.admin_upsert_exam(p jsonb, p_force bool default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_exam uuid; v_has bool; q jsonb; i bigint; v_q uuid; r record; v_pub bool;
begin
  insert into public.exams as x (slug, title, instructions, time_limit_minutes, opens_at, closes_at, attempts_allowed,
                            shuffle_questions, shuffle_options, log_focus, published)
  values (p->>'slug', p->>'title', coalesce(p->>'instructions',''), (p->>'time_limit_minutes')::int,
          (p->>'opens_at')::timestamptz, (p->>'closes_at')::timestamptz, coalesce((p->>'attempts_allowed')::int, 1),
          coalesce((p->>'shuffle_questions')::bool, false), coalesce((p->>'shuffle_options')::bool, false),
          coalesce((p->>'log_focus')::bool, true), coalesce((p->>'published')::bool, false))
  on conflict (slug) do update set
    title = excluded.title, instructions = excluded.instructions, time_limit_minutes = excluded.time_limit_minutes,
    opens_at = excluded.opens_at, closes_at = excluded.closes_at, attempts_allowed = excluded.attempts_allowed,
    shuffle_questions = excluded.shuffle_questions, shuffle_options = excluded.shuffle_options,
    log_focus = excluded.log_focus,
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

  -- re-mark already submitted attempts so key fixes apply (manual marks are preserved)
  for r in select id from public.attempts where exam_id = v_exam and status = 'submitted' loop
    perform private.mark_attempt(r.id);
  end loop;

  return jsonb_build_object('exam_id', v_exam, 'slug', p->>'slug', 'published', v_pub,
    'questions', jsonb_array_length(p->'questions'), 'had_attempts', v_has);
end $$;

create or replace function public.admin_set_published(p_slug text, p_published bool) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  update public.exams set published = p_published, updated_at = now() where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  return jsonb_build_object('slug', p_slug, 'published', p_published);
end $$;

create or replace function public.admin_list() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.finalize_expired(null);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'slug', e.slug, 'title', e.title, 'published', e.published, 'results_released', e.results_released,
    'time_limit_minutes', e.time_limit_minutes, 'opens_at', e.opens_at, 'closes_at', e.closes_at,
    'attempts_allowed', e.attempts_allowed,
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

-- p = {"attempt_id": optional uuid, "overall_feedback": optional, "questions": [{"id": "q4", "marks": 2, "feedback": "..."}]}
create or replace function public.admin_mark(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.exams; a_id uuid; m jsonb; q public.questions; v_marks numeric; n int := 0;
begin
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
  delete from public.attempts where id = p_attempt;
  if not found then raise exception 'No attempt %', p_attempt; end if;
  return jsonb_build_object('deleted', p_attempt);
end $$;

create or replace function public.admin_delete_exam(p_slug text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.exams where slug = p_slug;
  if not found then raise exception 'No exam %', p_slug; end if;
  return jsonb_build_object('deleted', p_slug);
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on all functions in schema public  from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.can_view_image(text) to authenticated;

grant execute on function public.whoami()                                   to authenticated;
grant execute on function public.list_my_exams()                            to authenticated;
grant execute on function public.get_attempt(uuid)                          to authenticated;
grant execute on function public.start_attempt(text)                        to authenticated;
grant execute on function public.save_answer(uuid, uuid, jsonb)             to authenticated;
grant execute on function public.submit_attempt(uuid, text)                 to authenticated;
grant execute on function public.log_focus_event(uuid, text, timestamptz, jsonb) to authenticated;
grant execute on function public.get_results(uuid)                          to authenticated;

grant execute on function public.admin_allow_user(text, text)            to service_role;
grant execute on function public.admin_upsert_exam(jsonb, bool)          to service_role;
grant execute on function public.admin_set_published(text, bool)        to service_role;
grant execute on function public.admin_list()                            to service_role;
grant execute on function public.admin_export(text)                      to service_role;
grant execute on function public.admin_mark(text, jsonb)                 to service_role;
grant execute on function public.admin_release(text, bool, uuid)         to service_role;
grant execute on function public.admin_delete_attempt(uuid)              to service_role;
grant execute on function public.admin_delete_exam(text)                 to service_role;

-- ---------------------------------------------------------------- storage (private bucket for question images)
insert into storage.buckets (id, name, public) values ('exam-images', 'exam-images', false)
on conflict (id) do nothing;

drop policy if exists "exam images: read during own attempts" on storage.objects;
create policy "exam images: read during own attempts" on storage.objects
  for select to authenticated
  using (bucket_id = 'exam-images' and private.can_view_image(name));

notify pgrst, 'reload schema';
