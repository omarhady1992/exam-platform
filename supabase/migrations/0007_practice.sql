-- Stage 2: practice answers on the day pages.
--   * questions + answer fields are readable by allowed users for visible days (no answers in them);
--   * answer keys live in private.practice_keys (no client grants at all; only security-definer code reads them);
--   * submissions/answers/notifications are reachable only through RPCs (no client table access);
--   * marks, scores, expected values and feedback reach the student only after release;
--   * Study Mentor's functions (load keys, queue, mark, release, ack, allow resubmit) are service-role only.
-- Additive only: no drops of existing objects.

create or replace function private.require_service() returns void
language plpgsql stable security definer set search_path = '' as $$
declare jwt_role text;
begin
  begin
    jwt_role := coalesce(auth.role(), auth.jwt() ->> 'role', nullif(current_setting('request.jwt.claim.role', true), ''));
  exception when others then jwt_role := null; end;
  if jwt_role = 'service_role' then
    return;
  end if;
  raise exception 'Not authorized (service role only)' using errcode = '42501';
end $$;
revoke execute on function private.require_service() from public, anon, authenticated;

-- ---------------------------------------------------------------- tables
create table if not exists public.practice_questions (
  id         uuid primary key default gen_random_uuid(),
  day_id     uuid not null references public.course_days(id) on delete cascade,
  qkey       text not null check (qkey ~ '^[A-Za-z0-9.]{1,12}$'),
  section    text,
  prompt     text not null,
  page       int,
  position   int not null default 0,
  updated_at timestamptz not null default now(),
  unique (day_id, qkey)
);
create table if not exists public.practice_fields (
  id          uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.practice_questions(id) on delete cascade,
  fkey        text not null check (fkey ~ '^[A-Za-z0-9.]{1,16}$'),
  label       text,
  kind        text not null check (kind in ('numeric','short','long')),
  unit        text,
  marks       numeric not null default 1 check (marks >= 0),
  position    int not null default 0,
  updated_at  timestamptz not null default now(),
  unique (question_id, fkey)
);
create table if not exists public.practice_days (
  day_id     uuid primary key references public.course_days(id) on delete cascade,
  page       int,
  note       text,
  key_file   text,
  status     text,
  loaded_at  timestamptz not null default now()
);

create table if not exists private.practice_keys (
  field_id   uuid primary key references public.practice_fields(id) on delete cascade,
  answer     numeric,
  tol_abs    numeric check (tol_abs is null or tol_abs >= 0),
  tol_pct    numeric check (tol_pct is null or tol_pct >= 0),
  alts       jsonb not null default '[]'::jsonb,
  reference  text,
  updated_at timestamptz not null default now()
);
revoke all on table private.practice_keys from public, anon, authenticated;

create table if not exists public.practice_submissions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  day_id           uuid not null references public.course_days(id) on delete cascade,
  attempt          int not null default 1 check (attempt >= 1),
  status           text not null default 'draft' check (status in ('draft','submitted')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  submitted_at     timestamptz,
  auto_score       numeric,
  manual_score     numeric,
  score            numeric,
  max_score        numeric,
  pending_manual   int,
  released         bool not null default false,
  released_at      timestamptz,
  feedback         text,
  resubmit_allowed bool not null default false,
  unique (user_id, day_id, attempt)
);
create table if not exists public.practice_answers (
  submission_id uuid not null references public.practice_submissions(id) on delete cascade,
  field_id      uuid not null references public.practice_fields(id) on delete cascade,
  value         text check (value is null or length(value) <= 8000),
  num           numeric,
  auto_correct  bool,
  auto_marks    numeric,
  manual_marks  numeric,
  feedback      text,
  updated_at    timestamptz not null default now(),
  primary key (submission_id, field_id)
);
create table if not exists public.practice_notifications (
  id             uuid primary key default gen_random_uuid(),
  submission_id  uuid not null unique references public.practice_submissions(id) on delete cascade,
  student_email  text,
  student_user_id uuid,
  course_slug    text not null,
  week_n         int not null,
  position       int not null,
  weekday        text,
  day_title      text,
  attempt        int not null default 1,
  submitted_at   timestamptz not null,
  auto_score     numeric,
  max_score      numeric,
  pending_manual int not null default 0,
  created_at     timestamptz not null default now(),
  acked_at       timestamptz,
  acked_by       text
);
create index if not exists practice_notifications_unacked on public.practice_notifications (created_at) where acked_at is null;

alter table public.practice_questions     enable row level security;
alter table public.practice_fields        enable row level security;
alter table public.practice_days          enable row level security;
alter table public.practice_submissions   enable row level security;
alter table public.practice_answers       enable row level security;
alter table public.practice_notifications enable row level security;
revoke all on table public.practice_submissions, public.practice_answers, public.practice_notifications from public, anon, authenticated;
revoke insert, update, delete, truncate on table public.practice_questions, public.practice_fields, public.practice_days from public, anon, authenticated;
revoke all on table public.practice_questions, public.practice_fields, public.practice_days from anon;
grant select on table public.practice_questions, public.practice_fields, public.practice_days to authenticated;

drop policy if exists "practice q: read visible" on public.practice_questions;
create policy "practice q: read visible" on public.practice_questions for select to authenticated
  using (private.is_allowed() and exists (select 1 from public.course_days d where d.id = day_id and private.day_visible(d)));
drop policy if exists "practice f: read visible" on public.practice_fields;
create policy "practice f: read visible" on public.practice_fields for select to authenticated
  using (private.is_allowed() and exists (select 1 from public.practice_questions q join public.course_days d on d.id = q.day_id
                                           where q.id = question_id and private.day_visible(d)));
drop policy if exists "practice days: read visible" on public.practice_days;
create policy "practice days: read visible" on public.practice_days for select to authenticated
  using (private.is_allowed() and exists (select 1 from public.course_days d where d.id = day_id and private.day_visible(d)));

-- ---------------------------------------------------------------- helpers
create or replace function private.practice_day(p_course text, p_week int, p_position int) returns public.course_days
language plpgsql stable security definer set search_path = '' as $$
declare d public.course_days;
begin
  select dd.* into d from public.course_days dd join public.course_weeks w on w.id = dd.week_id join public.courses c on c.id = w.course_id
   where c.slug = p_course and w.n = p_week and dd.position = p_position;
  return d;
end $$;
revoke execute on function private.practice_day(text, int, int) from public, anon, authenticated;

create or replace function private.practice_recompute(p_sub uuid) returns void
language sql security definer set search_path = '' as $$
  update public.practice_submissions s set
    max_score      = (select coalesce(sum(f.marks), 0) from public.practice_fields f join public.practice_questions q on q.id = f.question_id where q.day_id = s.day_id),
    auto_score     = (select coalesce(sum(a.auto_marks), 0) from public.practice_answers a where a.submission_id = s.id),
    manual_score   = (select sum(a.manual_marks) from public.practice_answers a where a.submission_id = s.id),
    score          = (select coalesce(sum(coalesce(a.manual_marks, a.auto_marks)), 0) from public.practice_answers a where a.submission_id = s.id),
    pending_manual = (select count(*) from public.practice_answers a join public.practice_fields f on f.id = a.field_id
                       where a.submission_id = s.id and a.manual_marks is null and a.auto_marks is null and f.marks > 0),
    updated_at     = now()
   where s.id = p_sub;
$$;
revoke execute on function private.practice_recompute(uuid) from public, anon, authenticated;

-- numeric parse: "1,764", "−3.6", "24.9 %", "4.4e3" -> numeric; null when not a number
create or replace function private.practice_num(p text) returns numeric
language plpgsql immutable set search_path = '' as $$
declare t text;
begin
  if p is null then return null; end if;
  t := replace(replace(replace(replace(btrim(p), '−', '-'), ',', ''), ' ', ''), '%', '');
  t := regexp_replace(t, '^[≈~]', '');
  if t ~ '^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$' then return t::numeric; end if;
  return null;
end $$;

create or replace function private.practice_within(p_num numeric, k private.practice_keys) returns bool
language plpgsql immutable set search_path = '' as $$
declare a jsonb;
begin
  if p_num is null or k.answer is null then return false; end if;
  if abs(p_num - k.answer) <= greatest(coalesce(k.tol_abs, 0), abs(k.answer) * coalesce(k.tol_pct, 0) / 100) then return true; end if;
  for a in select * from jsonb_array_elements(coalesce(k.alts, '[]'::jsonb)) loop
    if (a ->> 'answer') is not null and abs(p_num - (a ->> 'answer')::numeric)
         <= greatest(coalesce((a ->> 'tol_abs')::numeric, 0), abs((a ->> 'answer')::numeric) * coalesce((a ->> 'tol_pct')::numeric, 0) / 100) then
      return true;
    end if;
  end loop;
  return false;
end $$;
revoke execute on function private.practice_within(numeric, private.practice_keys) from public, anon, authenticated;

-- student view of one submission (marks/expected only when released)
create or replace function private.practice_view(p_day uuid, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.practice_submissions; n_att int; rel bool; pd public.practice_days;
begin
  select * into s from public.practice_submissions where user_id = p_user and day_id = p_day order by attempt desc limit 1;
  select count(*) into n_att from public.practice_submissions where user_id = p_user and day_id = p_day and status = 'submitted';
  select * into pd from public.practice_days where day_id = p_day;
  rel := coalesce(s.released, false) and s.status = 'submitted';
  return jsonb_build_object(
    'page', pd.page, 'note', pd.note,
    'questions', coalesce((select jsonb_agg(jsonb_build_object('qkey', q.qkey, 'section', q.section, 'prompt', q.prompt, 'page', q.page,
        'fields', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'fkey', f.fkey, 'label', f.label, 'kind', f.kind, 'unit', f.unit, 'marks', f.marks)
                     order by f.position), '[]'::jsonb) from public.practice_fields f where f.question_id = q.id))
        order by q.position) from public.practice_questions q where q.day_id = p_day), '[]'::jsonb),
    'submission', case when s.id is null then null else jsonb_build_object(
        'attempt', s.attempt, 'status', s.status, 'saved_at', s.updated_at, 'submitted_at', s.submitted_at,
        'submitted_count', n_att,
        'can_edit', s.status = 'draft',
        'can_resubmit', s.status = 'submitted' and s.resubmit_allowed,
        'released', rel,
        'score', case when rel then s.score end, 'max_score', case when rel then s.max_score end,
        'feedback', case when rel then s.feedback end,
        'answers', coalesce((select jsonb_object_agg(a.field_id::text, jsonb_strip_nulls(jsonb_build_object('value', a.value,
              'correct', case when rel then coalesce(a.manual_marks, a.auto_marks) >= f.marks and f.marks > 0 end,
              'marks', case when rel then coalesce(a.manual_marks, a.auto_marks) end,
              'max', case when rel then f.marks end,
              'feedback', case when rel then a.feedback end,
              'expected', case when rel and f.kind = 'numeric' then (select k.answer from private.practice_keys k where k.field_id = f.id) end,
              'tolerance', case when rel and f.kind = 'numeric' then (select case when k.tol_pct is not null then
                      greatest(coalesce(k.tol_abs, 0), abs(k.answer) * k.tol_pct / 100) else k.tol_abs end
                    from private.practice_keys k where k.field_id = f.id) end)))
            from public.practice_answers a join public.practice_fields f on f.id = a.field_id where a.submission_id = s.id), '{}'::jsonb)
      ) end);
end $$;
revoke execute on function private.practice_view(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- student RPCs
create or replace function public.get_practice(p_course text, p_week int, p_position int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); d public.course_days;
begin
  d := private.practice_day(p_course, p_week, p_position);
  if d.id is null or not private.day_visible(d) then raise exception 'Day not found' using errcode = 'P0002'; end if;
  return private.practice_view(d.id, v);
end $$;

create or replace function public.save_practice(p_course text, p_week int, p_position int, p_answers jsonb, p_submit bool default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); d public.course_days; s public.practice_submissions; e record; f record;
        k private.practice_keys; num numeric; ok bool; nq int; em text;
begin
  d := private.practice_day(p_course, p_week, p_position);
  if d.id is null or not private.day_visible(d) then raise exception 'Day not found' using errcode = 'P0002'; end if;
  select count(*) into nq from public.practice_fields f join public.practice_questions q on q.id = f.question_id where q.day_id = d.id;
  if nq = 0 then raise exception 'No practice for this day' using errcode = 'P0002'; end if;
  if p_answers is not null and jsonb_typeof(p_answers) <> 'object' then raise exception 'answers must be an object' using errcode = '22023'; end if;

  select * into s from public.practice_submissions where user_id = v and day_id = d.id order by attempt desc limit 1 for update;
  if s.id is null then
    insert into public.practice_submissions (user_id, day_id, attempt) values (v, d.id, 1) returning * into s;
  elsif s.status = 'submitted' then
    if not s.resubmit_allowed then raise exception 'Already submitted' using errcode = '42501'; end if;
    update public.practice_submissions set resubmit_allowed = false where id = s.id;
    insert into public.practice_submissions (user_id, day_id, attempt) values (v, d.id, s.attempt + 1) returning * into s;
    -- start the new attempt from the previous answers
    insert into public.practice_answers (submission_id, field_id, value, num)
      select s.id, a.field_id, a.value, a.num from public.practice_answers a
        join public.practice_submissions ps on ps.id = a.submission_id
       where ps.user_id = v and ps.day_id = d.id and ps.attempt = s.attempt - 1;
  end if;

  for e in select key, value from jsonb_each(coalesce(p_answers, '{}'::jsonb)) loop
    select f2.* into f from public.practice_fields f2 join public.practice_questions q on q.id = f2.question_id
     where q.day_id = d.id and f2.id::text = e.key;
    if not found then continue; end if;
    insert into public.practice_answers as a (submission_id, field_id, value, num, updated_at)
      values (s.id, f.id, left(nullif(btrim(e.value #>> '{}'), ''), 8000),
              case when f.kind = 'numeric' then private.practice_num(e.value #>> '{}') end, now())
      on conflict (submission_id, field_id) do update set value = excluded.value, num = excluded.num, updated_at = now();
  end loop;
  update public.practice_submissions set updated_at = now() where id = s.id;

  if p_submit then
    -- every field gets a row so marking sees blanks too
    insert into public.practice_answers (submission_id, field_id)
      select s.id, f2.id from public.practice_fields f2 join public.practice_questions q on q.id = f2.question_id where q.day_id = d.id
      on conflict do nothing;
    for f in select a.field_id, a.num, a.value, f2.kind, f2.marks from public.practice_answers a join public.practice_fields f2 on f2.id = a.field_id
              where a.submission_id = s.id loop
      if f.kind = 'numeric' then
        select * into k from private.practice_keys where field_id = f.field_id;
        if k.field_id is not null and k.answer is not null then
          ok := private.practice_within(f.num, k);
          update public.practice_answers set auto_correct = ok, auto_marks = case when ok then f.marks else 0 end
           where submission_id = s.id and field_id = f.field_id;
        end if;
      elsif f.marks = 0 then
        update public.practice_answers set auto_marks = 0 where submission_id = s.id and field_id = f.field_id;
      end if;
    end loop;
    update public.practice_submissions set status = 'submitted', submitted_at = now() where id = s.id;
    perform private.practice_recompute(s.id);
    select * into s from public.practice_submissions where id = s.id;
    select email into em from public.allowed_users where user_id = v;
    insert into public.practice_notifications (submission_id, student_email, student_user_id, course_slug, week_n, position, weekday, day_title,
                                               attempt, submitted_at, auto_score, max_score, pending_manual)
      select s.id, em, v, c.slug, w.n, d.position, d.weekday, d.title, s.attempt, s.submitted_at, s.auto_score, s.max_score, coalesce(s.pending_manual, 0)
        from public.course_weeks w join public.courses c on c.id = w.course_id where w.id = d.week_id
      on conflict (submission_id) do nothing;
  end if;
  return private.practice_view(d.id, v);
end $$;

-- per-day practice summary for the Progress page (scores only when released)
create or replace function public.practice_dashboard() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'course', c.slug, 'week', w.n, 'position', d.position, 'weekday', d.weekday, 'title', d.title,
      'questions', (select count(*) from public.practice_questions q where q.day_id = d.id),
      'status', s.status, 'attempt', s.attempt, 'submitted_at', s.submitted_at, 'released', coalesce(s.released, false),
      'score', case when s.released then s.score end, 'max_score', case when s.released then s.max_score end)
      order by c.position, w.n, d.position)
    from public.course_days d join public.course_weeks w on w.id = d.week_id join public.courses c on c.id = w.course_id
    left join lateral (select * from public.practice_submissions ps where ps.user_id = v and ps.day_id = d.id order by ps.attempt desc limit 1) s on true
   where private.day_visible(d) and exists (select 1 from public.practice_questions q where q.day_id = d.id)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- Study Mentor (service role only)
-- p: {course, week, position, page, note, key_file, status, questions:[{qkey,section,prompt,page,position,
--      fields:[{fkey,label,kind,unit,marks,key:{answer,tol_abs,tol_pct,alts,reference}}]}]}
create or replace function public.mentor_load_practice(p jsonb, p_force bool default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.course_days; q jsonb; fl jsonb; qid uuid; fid uuid; nq int := 0; nf int := 0; nk int := 0; nsub int;
        keep_q text[] := '{}'; keep_f uuid[] := '{}'; removed int := 0;
begin
  perform private.require_service();
  d := private.practice_day(p ->> 'course', (p ->> 'week')::int, (p ->> 'position')::int);
  if d.id is null then raise exception 'Day not found' using errcode = 'P0002'; end if;
  select count(*) into nsub from public.practice_submissions where day_id = d.id and status = 'submitted';
  insert into public.practice_days (day_id, page, note, key_file, status, loaded_at)
    values (d.id, (p ->> 'page')::int, p ->> 'note', p ->> 'key_file', p ->> 'status', now())
    on conflict (day_id) do update set page = excluded.page, note = excluded.note, key_file = excluded.key_file,
                                       status = excluded.status, loaded_at = now();
  for q in select * from jsonb_array_elements(coalesce(p -> 'questions', '[]'::jsonb)) loop
    insert into public.practice_questions as x (day_id, qkey, section, prompt, page, position, updated_at)
      values (d.id, q ->> 'qkey', q ->> 'section', q ->> 'prompt', (q ->> 'page')::int, coalesce((q ->> 'position')::int, 0), now())
      on conflict (day_id, qkey) do update set section = excluded.section, prompt = excluded.prompt, page = excluded.page,
                                               position = excluded.position, updated_at = now()
      returning id into qid;
    keep_q := keep_q || (q ->> 'qkey'); nq := nq + 1;
    for fl in select * from jsonb_array_elements(coalesce(q -> 'fields', '[]'::jsonb)) loop
      insert into public.practice_fields as x (question_id, fkey, label, kind, unit, marks, position, updated_at)
        values (qid, fl ->> 'fkey', fl ->> 'label', fl ->> 'kind', fl ->> 'unit', coalesce((fl ->> 'marks')::numeric, 1),
                coalesce((fl ->> 'position')::int, 0), now())
        on conflict (question_id, fkey) do update set label = excluded.label, kind = excluded.kind, unit = excluded.unit,
                                                      marks = excluded.marks, position = excluded.position, updated_at = now()
        returning id into fid;
      keep_f := keep_f || fid; nf := nf + 1;
      if fl ? 'key' and jsonb_typeof(fl -> 'key') = 'object' then
        insert into private.practice_keys as x (field_id, answer, tol_abs, tol_pct, alts, reference, updated_at)
          values (fid, (fl -> 'key' ->> 'answer')::numeric, (fl -> 'key' ->> 'tol_abs')::numeric, (fl -> 'key' ->> 'tol_pct')::numeric,
                  coalesce(fl -> 'key' -> 'alts', '[]'::jsonb), fl -> 'key' ->> 'reference', now())
          on conflict (field_id) do update set answer = excluded.answer, tol_abs = excluded.tol_abs, tol_pct = excluded.tol_pct,
                                               alts = excluded.alts, reference = excluded.reference, updated_at = now();
        if (fl -> 'key' ->> 'answer') is not null or (fl -> 'key' ->> 'reference') is not null then nk := nk + 1; end if;
      end if;
    end loop;
  end loop;
  -- stale fields/questions: removed only when nobody has submitted answers for them (or with p_force)
  if nsub = 0 or p_force then
    with del as (delete from public.practice_fields f using public.practice_questions q
                  where q.id = f.question_id and q.day_id = d.id and not (f.id = any(keep_f)) returning 1)
    select count(*) into removed from del;
    delete from public.practice_questions q where q.day_id = d.id and not (q.qkey = any(keep_q));
  end if;
  return jsonb_build_object('day_id', d.id, 'questions', nq, 'fields', nf, 'keys', nk, 'removed_fields', removed, 'submitted', nsub);
end $$;

create or replace function public.mentor_practice_overview() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_service();
  return coalesce((select jsonb_agg(jsonb_build_object('course', c.slug, 'week', w.n, 'position', d.position, 'weekday', d.weekday,
      'title', d.title, 'published', private.day_visible(d), 'status', pd.status, 'note', pd.note, 'key_file', pd.key_file,
      'questions', (select count(*) from public.practice_questions q where q.day_id = d.id),
      'fields', (select count(*) from public.practice_fields f join public.practice_questions q on q.id = f.question_id where q.day_id = d.id),
      'numeric', (select count(*) from public.practice_fields f join public.practice_questions q on q.id = f.question_id where q.day_id = d.id and f.kind = 'numeric'),
      'keyed', (select count(*) from public.practice_fields f join public.practice_questions q on q.id = f.question_id
                  join private.practice_keys k on k.field_id = f.id where q.day_id = d.id and (k.answer is not null or k.reference is not null)),
      'auto', (select count(*) from public.practice_fields f join public.practice_questions q on q.id = f.question_id
                  join private.practice_keys k on k.field_id = f.id where q.day_id = d.id and f.kind = 'numeric' and k.answer is not null))
      order by c.position, w.n, d.position)
    from public.course_days d join public.course_weeks w on w.id = d.week_id join public.courses c on c.id = w.course_id
    left join public.practice_days pd on pd.day_id = d.id), '[]'::jsonb);
end $$;

create or replace function private.practice_detail(s public.practice_submissions) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('submission_id', s.id, 'attempt', s.attempt, 'status', s.status, 'submitted_at', s.submitted_at,
    'student_email', (select email from public.allowed_users u where u.user_id = s.user_id),
    'course', c.slug, 'week', w.n, 'position', d.position, 'weekday', d.weekday, 'day_title', d.title,
    'auto_score', s.auto_score, 'manual_score', s.manual_score, 'score', s.score, 'max_score', s.max_score,
    'pending_manual', s.pending_manual, 'released', s.released, 'released_at', s.released_at, 'feedback', s.feedback,
    'resubmit_allowed', s.resubmit_allowed,
    'answers', coalesce((select jsonb_agg(jsonb_build_object('fkey', f.fkey, 'qkey', q.qkey, 'label', f.label, 'kind', f.kind, 'unit', f.unit,
        'marks', f.marks, 'prompt', q.prompt, 'value', a.value, 'num', a.num, 'auto_correct', a.auto_correct, 'auto_marks', a.auto_marks,
        'manual_marks', a.manual_marks, 'feedback', a.feedback,
        'key_answer', k.answer, 'key_tol_abs', k.tol_abs, 'key_tol_pct', k.tol_pct, 'key_alts', k.alts, 'key_reference', k.reference,
        'needs_marking', a.manual_marks is null and a.auto_marks is null and f.marks > 0)
        order by q.position, f.position)
      from public.practice_answers a join public.practice_fields f on f.id = a.field_id join public.practice_questions q on q.id = f.question_id
      left join private.practice_keys k on k.field_id = f.id where a.submission_id = s.id), '[]'::jsonb))
  from public.course_days d join public.course_weeks w on w.id = d.week_id join public.courses c on c.id = w.course_id
  where d.id = s.day_id;
$$;
revoke execute on function private.practice_detail(public.practice_submissions) from public, anon, authenticated;

create or replace function public.mentor_practice_submissions(p_all bool default false, p_detail bool default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_service();
  return coalesce((select jsonb_agg(case when p_detail then private.practice_detail(s)
                                    else private.practice_detail(s) - 'answers' end order by s.submitted_at)
    from public.practice_submissions s
   where s.status = 'submitted' and (p_all or not s.released)), '[]'::jsonb);
end $$;

create or replace function public.mentor_practice_queue(p_unacked_only bool default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_service();
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', 'practice', 'submission_id', n.submission_id,
      'course', n.course_slug, 'week', n.week_n, 'position', n.position, 'weekday', n.weekday, 'day_title', n.day_title,
      'attempt', n.attempt, 'student_email', n.student_email, 'submitted_at', n.submitted_at,
      'auto_score', n.auto_score, 'max_score', n.max_score, 'pending_manual', n.pending_manual,
      'released', s.released, 'acked_at', n.acked_at, 'acked_by', n.acked_by,
      'commands', jsonb_build_object(
        'export', format('bin/exam practice-submissions --json --id %s', n.submission_id),
        'mark', format('bin/exam practice-mark --file marks.json   # {"submission_id":"%s","marks":[{"fkey":"..","marks":..,"feedback":".."}]}', n.submission_id),
        'release', format('bin/exam practice-release --id %s', n.submission_id),
        'ack', format('bin/exam practice-ack --id %s', n.id)))
      order by n.created_at)
    from public.practice_notifications n join public.practice_submissions s on s.id = n.submission_id
   where (not p_unacked_only or n.acked_at is null)), '[]'::jsonb);
end $$;

-- p: {submission_id, feedback?, marks:[{fkey, marks, feedback?}]}  (marks: null clears a manual mark)
create or replace function public.mentor_mark_practice(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.practice_submissions; m jsonb; f public.practice_fields; n int := 0; bad text[] := '{}';
begin
  perform private.require_service();
  select * into s from public.practice_submissions where id = (p ->> 'submission_id')::uuid for update;
  if s.id is null then raise exception 'Submission not found' using errcode = 'P0002'; end if;
  if s.status <> 'submitted' then raise exception 'Submission is still a draft' using errcode = '22023'; end if;
  for m in select * from jsonb_array_elements(coalesce(p -> 'marks', '[]'::jsonb)) loop
    select f2.* into f from public.practice_fields f2 join public.practice_questions q on q.id = f2.question_id
     where q.day_id = s.day_id and f2.fkey = m ->> 'fkey';
    if f.id is null then bad := bad || (m ->> 'fkey'); continue; end if;
    if (m ->> 'marks') is not null and ((m ->> 'marks')::numeric < 0 or (m ->> 'marks')::numeric > f.marks) then
      raise exception 'marks for % must be between 0 and %', f.fkey, f.marks using errcode = '22023';
    end if;
    insert into public.practice_answers as a (submission_id, field_id, manual_marks, feedback, updated_at)
      values (s.id, f.id, (m ->> 'marks')::numeric, m ->> 'feedback', now())
      on conflict (submission_id, field_id) do update
        set manual_marks = case when m ? 'marks' then excluded.manual_marks else a.manual_marks end,
            feedback = case when m ? 'feedback' then excluded.feedback else a.feedback end, updated_at = now();
    n := n + 1;
  end loop;
  if p ? 'feedback' then update public.practice_submissions set feedback = p ->> 'feedback' where id = s.id; end if;
  perform private.practice_recompute(s.id);
  select * into s from public.practice_submissions where id = s.id;
  return jsonb_build_object('submission_id', s.id, 'updated', n, 'unknown_fkeys', to_jsonb(bad), 'score', s.score,
                            'max_score', s.max_score, 'pending_manual', s.pending_manual);
end $$;

create or replace function public.mentor_release_practice(p_submission uuid, p_released bool default true, p_force bool default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.practice_submissions;
begin
  perform private.require_service();
  select * into s from public.practice_submissions where id = p_submission for update;
  if s.id is null then raise exception 'Submission not found' using errcode = 'P0002'; end if;
  if p_released and s.status <> 'submitted' then raise exception 'Submission is still a draft' using errcode = '22023'; end if;
  if p_released and coalesce(s.pending_manual, 0) > 0 and not p_force then
    raise exception '% answer(s) still need marking (use --force to release anyway)', s.pending_manual using errcode = '22023';
  end if;
  update public.practice_submissions set released = p_released, released_at = case when p_released then now() end where id = s.id;
  return jsonb_build_object('submission_id', s.id, 'released', p_released);
end $$;

create or replace function public.mentor_ack_practice(p_id uuid default null, p_submission uuid default null, p_by text default 'study-mentor') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  perform private.require_service();
  update public.practice_notifications set acked_at = now(), acked_by = coalesce(p_by, 'study-mentor')
   where acked_at is null and (id = p_id or submission_id = p_submission);
  get diagnostics n = row_count;
  return jsonb_build_object('acked', n);
end $$;

-- allow one more attempt on a day (latest submitted attempt of that student)
create or replace function public.mentor_allow_resubmit(p_course text, p_week int, p_position int, p_email text default null, p_allow bool default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.course_days; s public.practice_submissions; uid uuid;
begin
  perform private.require_service();
  d := private.practice_day(p_course, p_week, p_position);
  if d.id is null then raise exception 'Day not found' using errcode = 'P0002'; end if;
  if p_email is not null then
    select user_id into uid from public.allowed_users where lower(email) = lower(p_email);
    if uid is null then raise exception 'No allowed user %', p_email using errcode = 'P0002'; end if;
  end if;
  select ps.* into s from public.practice_submissions ps
   where ps.day_id = d.id and (uid is null or ps.user_id = uid)
   order by ps.attempt desc, ps.updated_at desc limit 1;
  if s.id is null then raise exception 'No submission for that day' using errcode = 'P0002'; end if;
  if s.status <> 'submitted' then
    return jsonb_build_object('submission_id', s.id, 'note', 'latest attempt is still a draft; the student can already edit it');
  end if;
  update public.practice_submissions set resubmit_allowed = p_allow where id = s.id;
  return jsonb_build_object('submission_id', s.id, 'attempt', s.attempt, 'resubmit_allowed', p_allow);
end $$;

-- grants: students get the three client RPCs; Study Mentor functions are service-role only
revoke execute on function public.get_practice(text, int, int) from public, anon;
revoke execute on function public.save_practice(text, int, int, jsonb, bool) from public, anon;
revoke execute on function public.practice_dashboard() from public, anon;
grant execute on function public.get_practice(text, int, int) to authenticated;
grant execute on function public.save_practice(text, int, int, jsonb, bool) to authenticated;
grant execute on function public.practice_dashboard() to authenticated;
revoke execute on function public.mentor_load_practice(jsonb, bool) from public, anon, authenticated;
revoke execute on function public.mentor_practice_overview() from public, anon, authenticated;
revoke execute on function public.mentor_practice_submissions(bool, bool) from public, anon, authenticated;
revoke execute on function public.mentor_practice_queue(bool) from public, anon, authenticated;
revoke execute on function public.mentor_mark_practice(jsonb) from public, anon, authenticated;
revoke execute on function public.mentor_release_practice(uuid, bool, bool) from public, anon, authenticated;
revoke execute on function public.mentor_ack_practice(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.mentor_allow_resubmit(text, int, int, text, bool) from public, anon, authenticated;
grant execute on function public.mentor_load_practice(jsonb, bool) to service_role;
grant execute on function public.mentor_practice_overview() to service_role;
grant execute on function public.mentor_practice_submissions(bool, bool) to service_role;
grant execute on function public.mentor_practice_queue(bool) to service_role;
grant execute on function public.mentor_mark_practice(jsonb) to service_role;
grant execute on function public.mentor_release_practice(uuid, bool, bool) to service_role;
grant execute on function public.mentor_ack_practice(uuid, uuid, text) to service_role;
grant execute on function public.mentor_allow_resubmit(text, int, int, text, bool) to service_role;
grant select, insert, update, delete on table public.practice_submissions, public.practice_answers, public.practice_notifications,
  public.practice_questions, public.practice_fields, public.practice_days to service_role;
