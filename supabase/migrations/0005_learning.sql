-- Learning platform, stage 1: courses > weeks > days, private course files, per-user progress.
-- Additive only: no existing table, column or policy is dropped or changed.
--
-- Access model
--   * Tables have RLS. Allow-listed users (public.allowed_users) can SELECT published rows; admins can do everything.
--     anon has no privileges at all. The site itself reads through the SECURITY DEFINER RPCs below
--     (one round trip per page), which apply the same rules.
--   * Files live in the PRIVATE storage bucket `course-files`. A signed URL can only be issued to an allow-listed
--     user for an object referenced by a published day/week/course (or to an admin). The service role (CLI) bypasses.
--   * public.day_progress: each user reads and writes only their own rows.
--
-- Stage 2 (typed practice answers, auto-checking) will add:
--   public.practice_items(day_id -> course_days, qkey, type, prompt, unit, marks, position)  -- public part
--   public.practice_keys(item_id, answer, tolerance_abs, tolerance_pct)                      -- locked like question_keys
--   public.practice_submissions(user_id, item_id, response, is_correct, marks, feedback, submitted_at)
-- keyed on course_days.id, which is stable across re-imports (upserts match on course/week/position).

-- ---------------------------------------------------------------- helpers
create or replace function private.is_allowed() returns bool
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.allowed_users u where u.user_id = auth.uid());
$$;
revoke execute on function private.is_allowed() from public, anon;
grant  execute on function private.is_allowed() to authenticated;

-- true if a file path looks like an answer key / textbook / exam source (defence in depth; the CLI also refuses)
create or replace function private.forbidden_course_path(p text) returns bool
language sql immutable set search_path = '' as $$
  select p is null
      or p ~* '(^|/)(keys?|exams|references)/'
      or p ~* 'answer'
      or p ~* '(^|[/_. -])keys?([_. -]|$)'
      or p ~* 'solution'
      or p ~* '(^|/)truth[_-]';
$$;

-- every storage path referenced by a files json array [{path: ...}, ...]
create or replace function private.file_paths(f jsonb) returns setof text
language sql immutable set search_path = '' as $$
  select x ->> 'path' from jsonb_array_elements(case when jsonb_typeof(f) = 'array' then f else '[]'::jsonb end) x
   where x ? 'path';
$$;

-- ---------------------------------------------------------------- tables
create table if not exists public.courses (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,60}$'),
  title        text not null,
  subtitle     text not null default '',
  description  text not null default '',
  color        text not null default '#14b8a6' check (color ~ '^#[0-9a-fA-F]{6}$'),
  position     int  not null default 100,
  study_days   text[] not null default '{}',          -- e.g. {Monday,Tuesday,Wednesday,Thursday}
  total_weeks  int,                                    -- planned length (roadmap), may exceed imported weeks
  current_week int,                                    -- where Omar is (informational)
  files        jsonb not null default '[]'::jsonb,     -- course-level files (roadmap PDF, ...)
  published    bool not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.course_weeks (
  id          uuid primary key default gen_random_uuid(),
  course_id   uuid not null references public.courses(id) on delete cascade,
  n           int  not null check (n between 1 and 99),
  title       text not null,
  summary     text not null default '',
  files       jsonb not null default '[]'::jsonb,   -- [{kind: deck|deck-pptx|code|sheet|guide|extra, label, path, size, mime}]
  exam_slugs  text[] not null default '{}',          -- links to public.exams.slug (loose: the exam may be created later)
  published   bool not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (course_id, n)
);

create table if not exists public.course_days (
  id           uuid primary key default gen_random_uuid(),
  week_id      uuid not null references public.course_weeks(id) on delete cascade,
  position     int  not null check (position between 1 and 7),
  weekday      text not null default '',
  title        text not null,
  scheduled_on date,
  summary      text not null default '',
  goals        jsonb not null default '[]'::jsonb,   -- ["...", ...]
  readings     jsonb not null default '[]'::jsonb,   -- [{title, url?, note?}]
  videos       jsonb not null default '[]'::jsonb,   -- [{title, channel, youtube_id, duration?, note?}]
  files        jsonb not null default '[]'::jsonb,   -- [{kind: pack|infographic|extra, label, path, size, mime, pages?}]
  practice     text not null default '',             -- short description (stage 2 adds structured items)
  published    bool not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (week_id, position)
);

create table if not exists public.day_progress (
  user_id   uuid not null references auth.users(id) on delete cascade,
  day_id    uuid not null references public.course_days(id) on delete cascade,
  done      bool not null default true,
  done_at   timestamptz,
  opened_at timestamptz,
  primary key (user_id, day_id)
);
create index if not exists day_progress_day on public.day_progress(day_id);

-- no answer-key-like paths may ever be referenced
alter table public.courses      drop constraint if exists courses_files_ok;
alter table public.course_weeks drop constraint if exists course_weeks_files_ok;
alter table public.course_days  drop constraint if exists course_days_files_ok;
create or replace function private.files_ok(f jsonb) returns bool
language sql immutable set search_path = '' as $$
  select jsonb_typeof(f) = 'array'
     and not exists (select 1 from private.file_paths(f) p where private.forbidden_course_path(p));
$$;
alter table public.courses      add constraint courses_files_ok      check (private.files_ok(files));
alter table public.course_weeks add constraint course_weeks_files_ok check (private.files_ok(files));
alter table public.course_days  add constraint course_days_files_ok  check (private.files_ok(files));

-- ---------------------------------------------------------------- RLS
alter table public.courses      enable row level security;
alter table public.course_weeks enable row level security;
alter table public.course_days  enable row level security;
alter table public.day_progress enable row level security;

revoke all on public.courses, public.course_weeks, public.course_days, public.day_progress from public, anon, authenticated;
grant select, insert, update, delete on public.courses, public.course_weeks, public.course_days to authenticated;
grant select, insert, update, delete on public.day_progress to authenticated;

drop policy if exists "courses: read published" on public.courses;
create policy "courses: read published" on public.courses for select to authenticated
  using (published and private.is_allowed());
drop policy if exists "courses: admin all" on public.courses;
create policy "courses: admin all" on public.courses for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "weeks: read published" on public.course_weeks;
create policy "weeks: read published" on public.course_weeks for select to authenticated
  using (published and private.is_allowed()
         and exists (select 1 from public.courses c where c.id = course_id and c.published));
drop policy if exists "weeks: admin all" on public.course_weeks;
create policy "weeks: admin all" on public.course_weeks for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "days: read published" on public.course_days;
create policy "days: read published" on public.course_days for select to authenticated
  using (published and private.is_allowed()
         and exists (select 1 from public.course_weeks w join public.courses c on c.id = w.course_id
                      where w.id = week_id and w.published and c.published));
drop policy if exists "days: admin all" on public.course_days;
create policy "days: admin all" on public.course_days for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

drop policy if exists "progress: own rows" on public.day_progress;
create policy "progress: own rows" on public.day_progress for all to authenticated
  using (user_id = auth.uid() and private.is_allowed())
  with check (user_id = auth.uid() and private.is_allowed());

-- ---------------------------------------------------------------- visibility helpers
create or replace function private.day_visible(d public.course_days) returns bool
language sql stable security definer set search_path = '' as $$
  select d.published and exists (
    select 1 from public.course_weeks w join public.courses c on c.id = w.course_id
     where w.id = d.week_id and w.published and c.published);
$$;

create or replace function private.can_view_course_file(p_name text) returns bool
language sql stable security definer set search_path = '' as $$
  select private.is_allowed() and not private.forbidden_course_path(p_name) and (
       private.is_admin()
    or exists (select 1 from public.course_days d where p_name in (select private.file_paths(d.files)) and private.day_visible(d))
    or exists (select 1 from public.course_weeks w join public.courses c on c.id = w.course_id
                where w.published and c.published and p_name in (select private.file_paths(w.files)))
    or exists (select 1 from public.courses c where c.published and p_name in (select private.file_paths(c.files)))
  );
$$;
revoke execute on function private.can_view_course_file(text) from public, anon;
grant  execute on function private.can_view_course_file(text) to authenticated;

-- quiz summary for one exam slug and one user (scores only once released, like the exam pages)
create or replace function private.quiz_summary(p_slug text, p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'slug', e.slug, 'title', e.title, 'attempts_allowed', e.attempts_allowed,
    'attempts_used', (select count(*) from public.attempts a where a.exam_id = e.id and a.user_id = p_user),
    'in_progress', exists (select 1 from public.attempts a where a.exam_id = e.id and a.user_id = p_user and a.status = 'in_progress'),
    'submitted', (select count(*) from public.attempts a where a.exam_id = e.id and a.user_id = p_user and a.status = 'submitted'),
    'best', (select jsonb_build_object('attempt_id', a.id, 'score', a.total_score, 'max', a.max_score,
                                       'pct', case when a.max_score > 0 then round(100 * a.total_score / a.max_score, 1) end,
                                       'submitted_at', a.submitted_at)
               from public.attempts a
              where a.exam_id = e.id and a.user_id = p_user and a.status = 'submitted' and (a.released or e.results_released)
              order by (a.total_score / nullif(a.max_score, 0)) desc nulls last, a.submitted_at desc limit 1),
    'last_submitted_at', (select max(a.submitted_at) from public.attempts a where a.exam_id = e.id and a.user_id = p_user))
  from public.exams e where e.slug = p_slug and e.published;
$$;

create or replace function private.week_quizzes(w public.course_weeks, p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(q order by o), '[]'::jsonb)
    from unnest(w.exam_slugs) with ordinality s(slug, o)
    cross join lateral (select private.quiz_summary(s.slug, p_user) q) x
   where q is not null;
$$;

create or replace function private.file_view(f jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', x->>'kind', 'label', x->>'label', 'path', x->>'path',
                                               'size', x->'size', 'mime', x->>'mime', 'pages', x->'pages')), '[]'::jsonb)
    from jsonb_array_elements(case when jsonb_typeof(f) = 'array' then f else '[]'::jsonb end) x;
$$;

-- day streak (Cairo calendar days with at least one day marked done, ending today or yesterday)
create or replace function private.streak(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare today date := (now() at time zone 'Africa/Cairo')::date; d date; n int := 0; best int := 0; run int := 0; prev date;
begin
  for d in select distinct (p.done_at at time zone 'Africa/Cairo')::date as dd from public.day_progress p
            where p.user_id = p_user and p.done and p.done_at is not null order by dd loop
    if prev is not null and d = prev + 1 then run := run + 1; else run := 1; end if;
    best := greatest(best, run); prev := d;
  end loop;
  if prev is not null and prev >= today - 1 then n := run; end if;
  return jsonb_build_object('current', n, 'best', best, 'last_day', prev, 'today', today,
    'last14', (select coalesce(jsonb_agg(jsonb_build_object('date', g::date,
                 'count', (select count(*) from public.day_progress p where p.user_id = p_user and p.done
                            and (p.done_at at time zone 'Africa/Cairo')::date = g::date)) order by g), '[]'::jsonb)
               from generate_series((today - 13)::timestamp, today::timestamp, interval '1 day') g));
end $$;

-- ---------------------------------------------------------------- client RPCs
create or replace function public.list_courses() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); adm bool := private.is_admin();
begin
  return jsonb_build_object('server_now', now(), 'admin', adm, 'streak', private.streak(v), 'courses', coalesce((
    select jsonb_agg(jsonb_build_object(
      'slug', c.slug, 'title', c.title, 'subtitle', c.subtitle, 'description', c.description, 'color', c.color,
      'published', c.published, 'study_days', c.study_days, 'total_weeks', c.total_weeks, 'current_week', c.current_week,
      'weeks', (select count(*) from public.course_weeks w where w.course_id = c.id and (w.published or adm)),
      'days_total', (select count(*) from public.course_days d join public.course_weeks w on w.id = d.week_id
                      where w.course_id = c.id and (adm or private.day_visible(d))),
      'days_done', (select count(*) from public.course_days d join public.course_weeks w on w.id = d.week_id
                      join public.day_progress p on p.day_id = d.id and p.user_id = v and p.done
                     where w.course_id = c.id and (adm or private.day_visible(d))),
      'next', (select jsonb_build_object('week', w.n, 'position', d.position, 'weekday', d.weekday, 'title', d.title)
                 from public.course_days d join public.course_weeks w on w.id = d.week_id
                where w.course_id = c.id and (adm or private.day_visible(d))
                  and not exists (select 1 from public.day_progress p where p.day_id = d.id and p.user_id = v and p.done)
                order by w.n, d.position limit 1)
    ) order by c.position, c.title)
    from public.courses c where c.published or adm), '[]'::jsonb));
end $$;

create or replace function public.get_course(p_slug text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); adm bool := private.is_admin(); c public.courses;
begin
  select * into c from public.courses where slug = p_slug and (published or adm);
  if not found then raise exception 'Course not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('admin', adm,
    'course', jsonb_build_object('slug', c.slug, 'title', c.title, 'subtitle', c.subtitle, 'description', c.description,
       'color', c.color, 'published', c.published, 'study_days', c.study_days, 'total_weeks', c.total_weeks,
       'current_week', c.current_week, 'files', private.file_view(c.files)),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object(
       'n', w.n, 'title', w.title, 'summary', w.summary, 'published', w.published,
       'files', private.file_view(w.files), 'quizzes', private.week_quizzes(w, v),
       'days', coalesce((select jsonb_agg(jsonb_build_object(
            'position', d.position, 'weekday', d.weekday, 'title', d.title, 'published', d.published,
            'scheduled_on', d.scheduled_on, 'videos', jsonb_array_length(d.videos),
            'has_pack', exists (select 1 from jsonb_array_elements(d.files) f where f->>'kind' = 'pack'),
            'done', coalesce((select p.done from public.day_progress p where p.day_id = d.id and p.user_id = v), false),
            'done_at', (select p.done_at from public.day_progress p where p.day_id = d.id and p.user_id = v and p.done))
          order by d.position) from public.course_days d where d.week_id = w.id and (adm or private.day_visible(d))), '[]'::jsonb)
     ) order by w.n) from public.course_weeks w where w.course_id = c.id and (w.published or adm)), '[]'::jsonb));
end $$;

create or replace function public.get_day(p_course text, p_week int, p_position int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); adm bool := private.is_admin();
        c public.courses; w public.course_weeks; d public.course_days; pr public.day_progress;
begin
  select * into c from public.courses where slug = p_course and (published or adm);
  if found then select * into w from public.course_weeks where course_id = c.id and n = p_week and (published or adm); end if;
  if w.id is not null then select * into d from public.course_days where week_id = w.id and position = p_position; end if;
  if d.id is null or not (adm or private.day_visible(d)) then raise exception 'Day not found' using errcode = 'P0002'; end if;
  insert into public.day_progress as x (user_id, day_id, done, opened_at) values (v, d.id, false, now())
    on conflict (user_id, day_id) do update set opened_at = now();
  select * into pr from public.day_progress where user_id = v and day_id = d.id;
  return jsonb_build_object('admin', adm,
    'course', jsonb_build_object('slug', c.slug, 'title', c.title, 'color', c.color),
    'week', jsonb_build_object('n', w.n, 'title', w.title, 'files', private.file_view(w.files), 'quizzes', private.week_quizzes(w, v)),
    'day', jsonb_build_object('id', d.id, 'position', d.position, 'weekday', d.weekday, 'title', d.title, 'summary', d.summary,
       'scheduled_on', d.scheduled_on, 'goals', d.goals, 'readings', d.readings, 'videos', d.videos,
       'files', private.file_view(d.files), 'practice', d.practice, 'published', d.published,
       'done', pr.done, 'done_at', case when pr.done then pr.done_at end),
    'nav', jsonb_build_object(
       'prev', (select jsonb_build_object('week', w2.n, 'position', d2.position, 'title', d2.title, 'weekday', d2.weekday)
                  from public.course_days d2 join public.course_weeks w2 on w2.id = d2.week_id
                 where w2.course_id = c.id and (adm or private.day_visible(d2)) and (w2.n, d2.position) < (w.n, d.position)
                 order by w2.n desc, d2.position desc limit 1),
       'next', (select jsonb_build_object('week', w2.n, 'position', d2.position, 'title', d2.title, 'weekday', d2.weekday)
                  from public.course_days d2 join public.course_weeks w2 on w2.id = d2.week_id
                 where w2.course_id = c.id and (adm or private.day_visible(d2)) and (w2.n, d2.position) > (w.n, d.position)
                 order by w2.n, d2.position limit 1)));
end $$;

create or replace function public.set_day_done(p_course text, p_week int, p_position int, p_done bool) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); adm bool := private.is_admin(); d public.course_days;
begin
  select dd.* into d from public.course_days dd join public.course_weeks w on w.id = dd.week_id join public.courses c on c.id = w.course_id
   where c.slug = p_course and w.n = p_week and dd.position = p_position;
  if d.id is null or not (adm or private.day_visible(d)) then raise exception 'Day not found' using errcode = 'P0002'; end if;
  insert into public.day_progress as x (user_id, day_id, done, done_at) values (v, d.id, p_done, case when p_done then now() end)
    on conflict (user_id, day_id) do update
      set done = excluded.done, done_at = case when excluded.done then coalesce(case when x.done then x.done_at end, now()) end;
  return jsonb_build_object('done', p_done, 'streak', private.streak(v));
end $$;

create or replace function public.learning_dashboard() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); adm bool := private.is_admin();
begin
  return jsonb_build_object('server_now', now(), 'streak', private.streak(v),
    'courses', (public.list_courses() -> 'courses'),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object(
        'course', c.slug, 'course_title', c.title, 'color', c.color, 'n', w.n, 'title', w.title,
        'days_total', (select count(*) from public.course_days d where d.week_id = w.id and (adm or private.day_visible(d))),
        'days_done', (select count(*) from public.course_days d join public.day_progress p on p.day_id = d.id and p.user_id = v and p.done
                       where d.week_id = w.id and (adm or private.day_visible(d))),
        'quizzes', private.week_quizzes(w, v)) order by c.position, w.n)
      from public.course_weeks w join public.courses c on c.id = w.course_id
     where (adm or (w.published and c.published))
       and exists (select 1 from public.course_days d where d.week_id = w.id and (adm or private.day_visible(d)))), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(x order by x->>'done_at' desc) from (
        select jsonb_build_object('course', c.slug, 'course_title', c.title, 'color', c.color, 'week', w.n, 'position', d.position,
                                  'weekday', d.weekday, 'title', d.title, 'done_at', p.done_at) x
          from public.day_progress p join public.course_days d on d.id = p.day_id
          join public.course_weeks w on w.id = d.week_id join public.courses c on c.id = w.course_id
         where p.user_id = v and p.done order by p.done_at desc limit 8) r), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- admin RPCs (CLI with service role; admins in the browser)
create or replace function public.admin_upsert_course(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.courses;
begin
  perform private.require_admin();
  insert into public.courses as c (slug, title, subtitle, description, color, position, study_days, total_weeks, current_week, files, published)
  values (p->>'slug', p->>'title', coalesce(p->>'subtitle',''), coalesce(p->>'description',''), coalesce(p->>'color','#14b8a6'),
          coalesce((p->>'position')::int, 100),
          coalesce((select array_agg(x) from jsonb_array_elements_text(p->'study_days') x), '{}'),
          (p->>'total_weeks')::int, (p->>'current_week')::int, coalesce(p->'files','[]'::jsonb), coalesce((p->>'published')::bool, false))
  on conflict (slug) do update set
    title = excluded.title,
    subtitle = case when p ? 'subtitle' then excluded.subtitle else c.subtitle end,
    description = case when p ? 'description' then excluded.description else c.description end,
    color = case when p ? 'color' then excluded.color else c.color end,
    position = case when p ? 'position' then excluded.position else c.position end,
    study_days = case when p ? 'study_days' then excluded.study_days else c.study_days end,
    total_weeks = case when p ? 'total_weeks' then excluded.total_weeks else c.total_weeks end,
    current_week = case when p ? 'current_week' then excluded.current_week else c.current_week end,
    files = case when p ? 'files' then excluded.files else c.files end,
    published = case when p ? 'published' then excluded.published else c.published end,
    updated_at = now()
  returning * into r;
  return to_jsonb(r);
end $$;

create or replace function public.admin_upsert_week(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare cid uuid; r public.course_weeks;
begin
  perform private.require_admin();
  select id into cid from public.courses where slug = p->>'course';
  if cid is null then raise exception 'No course %', p->>'course'; end if;
  insert into public.course_weeks as w (course_id, n, title, summary, files, exam_slugs, published)
  values (cid, (p->>'n')::int, coalesce(p->>'title', 'Week ' || (p->>'n')), coalesce(p->>'summary',''),
          coalesce(p->'files','[]'::jsonb), coalesce((select array_agg(x) from jsonb_array_elements_text(p->'exam_slugs') x), '{}'),
          coalesce((p->>'published')::bool, false))
  on conflict (course_id, n) do update set
    title = case when p ? 'title' then excluded.title else w.title end,
    summary = case when p ? 'summary' then excluded.summary else w.summary end,
    files = case when p ? 'files' then excluded.files else w.files end,
    exam_slugs = case when p ? 'exam_slugs' then excluded.exam_slugs else w.exam_slugs end,
    published = case when p ? 'published' then excluded.published else w.published end,
    updated_at = now()
  returning * into r;
  return to_jsonb(r);
end $$;

create or replace function public.admin_upsert_day(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare wid uuid; r public.course_days;
begin
  perform private.require_admin();
  select w.id into wid from public.course_weeks w join public.courses c on c.id = w.course_id
   where c.slug = p->>'course' and w.n = (p->>'week')::int;
  if wid is null then raise exception 'No week % in course %', p->>'week', p->>'course'; end if;
  insert into public.course_days as d (week_id, position, weekday, title, scheduled_on, summary, goals, readings, videos, files, practice, published)
  values (wid, (p->>'position')::int, coalesce(p->>'weekday',''), p->>'title', (p->>'scheduled_on')::date, coalesce(p->>'summary',''),
          coalesce(p->'goals','[]'::jsonb), coalesce(p->'readings','[]'::jsonb), coalesce(p->'videos','[]'::jsonb),
          coalesce(p->'files','[]'::jsonb), coalesce(p->>'practice',''), coalesce((p->>'published')::bool, false))
  on conflict (week_id, position) do update set
    weekday = case when p ? 'weekday' then excluded.weekday else d.weekday end,
    title = excluded.title,
    scheduled_on = case when p ? 'scheduled_on' then excluded.scheduled_on else d.scheduled_on end,
    summary = case when p ? 'summary' then excluded.summary else d.summary end,
    goals = case when p ? 'goals' then excluded.goals else d.goals end,
    readings = case when p ? 'readings' then excluded.readings else d.readings end,
    videos = case when p ? 'videos' then excluded.videos else d.videos end,
    files = case when p ? 'files' then excluded.files else d.files end,
    practice = case when p ? 'practice' then excluded.practice else d.practice end,
    published = case when p ? 'published' then excluded.published else d.published end,
    updated_at = now()
  returning * into r;
  return to_jsonb(r);
end $$;

-- publish/unpublish a course, a week, or a day (p_week/p_position null = the level above)
create or replace function public.admin_set_course_published(p_course text, p_week int, p_position int, p_published bool) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  perform private.require_admin();
  if p_week is null then
    update public.courses set published = p_published, updated_at = now() where slug = p_course;
  elsif p_position is null then
    update public.course_weeks w set published = p_published, updated_at = now() from public.courses c
     where c.id = w.course_id and c.slug = p_course and w.n = p_week;
  else
    update public.course_days d set published = p_published, updated_at = now() from public.course_weeks w, public.courses c
     where w.id = d.week_id and c.id = w.course_id and c.slug = p_course and w.n = p_week and d.position = p_position;
  end if;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Nothing matched'; end if;
  return jsonb_build_object('updated', n, 'published', p_published);
end $$;

create or replace function public.admin_list_courses() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
    'slug', c.slug, 'title', c.title, 'published', c.published, 'current_week', c.current_week, 'total_weeks', c.total_weeks,
    'files', c.files,
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('n', w.n, 'title', w.title, 'published', w.published,
        'exam_slugs', w.exam_slugs, 'files', w.files,
        'days', coalesce((select jsonb_agg(jsonb_build_object('position', d.position, 'weekday', d.weekday, 'title', d.title,
                  'published', d.published, 'videos', jsonb_array_length(d.videos), 'readings', jsonb_array_length(d.readings),
                  'goals', jsonb_array_length(d.goals), 'files', d.files) order by d.position)
              from public.course_days d where d.week_id = w.id), '[]'::jsonb)) order by w.n)
      from public.course_weeks w where w.course_id = c.id), '[]'::jsonb)) order by c.position), '[]'::jsonb)
  from public.courses c;
end $$;

create or replace function public.admin_course_progress() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('email', u.email, 'course', c.slug, 'week', w.n, 'position', d.position,
            'weekday', d.weekday, 'title', d.title, 'done', p.done, 'done_at', p.done_at, 'opened_at', p.opened_at)
          order by u.email, c.position, w.n, d.position)
     from public.day_progress p join public.allowed_users u on u.user_id = p.user_id
     join public.course_days d on d.id = p.day_id join public.course_weeks w on w.id = d.week_id
     join public.courses c on c.id = w.course_id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function private.day_visible(public.course_days) from public, anon, authenticated;
revoke execute on function private.quiz_summary(text, uuid)        from public, anon, authenticated;
revoke execute on function private.week_quizzes(public.course_weeks, uuid) from public, anon, authenticated;
revoke execute on function private.streak(uuid)                    from public, anon, authenticated;
revoke execute on function private.file_view(jsonb)                from public, anon;
grant  execute on function private.file_view(jsonb)                to authenticated;
-- used inside table CHECK constraints and RLS, so authenticated (admin writes) must be able to evaluate them
revoke execute on function private.forbidden_course_path(text) from public, anon;
revoke execute on function private.file_paths(jsonb)           from public, anon;
revoke execute on function private.files_ok(jsonb)             from public, anon;
grant  execute on function private.forbidden_course_path(text) to authenticated;
grant  execute on function private.file_paths(jsonb)           to authenticated;
grant  execute on function private.files_ok(jsonb)             to authenticated;

revoke execute on function public.list_courses()                    from public, anon;
revoke execute on function public.get_course(text)                  from public, anon;
revoke execute on function public.get_day(text, int, int)           from public, anon;
revoke execute on function public.set_day_done(text, int, int, bool) from public, anon;
revoke execute on function public.learning_dashboard()              from public, anon;
grant  execute on function public.list_courses()                    to authenticated;
grant  execute on function public.get_course(text)                  to authenticated;
grant  execute on function public.get_day(text, int, int)           to authenticated;
grant  execute on function public.set_day_done(text, int, int, bool) to authenticated;
grant  execute on function public.learning_dashboard()              to authenticated;

revoke execute on function public.admin_upsert_course(jsonb)                     from public, anon;
revoke execute on function public.admin_upsert_week(jsonb)                       from public, anon;
revoke execute on function public.admin_upsert_day(jsonb)                        from public, anon;
revoke execute on function public.admin_set_course_published(text, int, int, bool) from public, anon;
revoke execute on function public.admin_list_courses()                           from public, anon;
revoke execute on function public.admin_course_progress()                        from public, anon;
grant  execute on function public.admin_upsert_course(jsonb)                     to authenticated, service_role;
grant  execute on function public.admin_upsert_week(jsonb)                       to authenticated, service_role;
grant  execute on function public.admin_upsert_day(jsonb)                        to authenticated, service_role;
grant  execute on function public.admin_set_course_published(text, int, int, bool) to authenticated, service_role;
grant  execute on function public.admin_list_courses()                           to authenticated, service_role;
grant  execute on function public.admin_course_progress()                        to authenticated, service_role;

-- ---------------------------------------------------------------- storage: private bucket for course material
insert into storage.buckets (id, name, public, file_size_limit)
values ('course-files', 'course-files', false, 52428800)
on conflict (id) do update set public = false;

drop policy if exists "course files: read published" on storage.objects;
create policy "course files: read published" on storage.objects
  for select to authenticated
  using (bucket_id = 'course-files' and private.can_view_course_file(name));

drop policy if exists "course files: admin write" on storage.objects;
create policy "course files: admin write" on storage.objects
  for all to authenticated
  using (bucket_id = 'course-files' and private.is_admin())
  with check (bucket_id = 'course-files' and private.is_admin() and not private.forbidden_course_path(name));

notify pgrst, 'reload schema';
