-- Client pages show only published material, also for admins (Omar is an admin). Drafts are previewed with the CLI.
create or replace function public.list_courses() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); adm bool := false; is_adm bool := private.is_admin();
begin
  return jsonb_build_object('server_now', now(), 'admin', is_adm, 'streak', private.streak(v), 'courses', coalesce((
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
declare v uuid := private.require_user(); adm bool := false; is_adm bool := private.is_admin(); c public.courses;
begin
  select * into c from public.courses where slug = p_slug and (published or adm);
  if not found then raise exception 'Course not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('admin', is_adm,
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
declare v uuid := private.require_user(); adm bool := false; is_adm bool := private.is_admin();
        c public.courses; w public.course_weeks; d public.course_days; pr public.day_progress;
begin
  select * into c from public.courses where slug = p_course and (published or adm);
  if found then select * into w from public.course_weeks where course_id = c.id and n = p_week and (published or adm); end if;
  if w.id is not null then select * into d from public.course_days where week_id = w.id and position = p_position; end if;
  if d.id is null or not (adm or private.day_visible(d)) then raise exception 'Day not found' using errcode = 'P0002'; end if;
  insert into public.day_progress as x (user_id, day_id, done, opened_at) values (v, d.id, false, now())
    on conflict (user_id, day_id) do update set opened_at = now();
  select * into pr from public.day_progress where user_id = v and day_id = d.id;
  return jsonb_build_object('admin', is_adm,
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
declare v uuid := private.require_user(); adm bool := false; is_adm bool := private.is_admin(); d public.course_days;
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
declare v uuid := private.require_user(); adm bool := false; is_adm bool := private.is_admin();
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

notify pgrst, 'reload schema';
