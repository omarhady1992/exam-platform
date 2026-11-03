-- Equation sheet per exam: rendered PNG pages in the private exam-images bucket.
-- exams.equation_sheet = {"title": text, "pages": [{"path": "<slug>/sheet-<hash>.png", "w": px, "h": px}, ...]} or null.
-- Students can only sign URLs for sheet pages while their own attempt is open (until deadline + 30 s grace)
-- or after that attempt's results are released.

alter table public.exams add column if not exists equation_sheet jsonb;

-- true if the current user may see the equation sheet of exam row e for attempt row a
create or replace function private.sheet_visible(a public.attempts, e public.exams) returns bool
language sql stable security definer set search_path = '' as $$
  select e.equation_sheet is not null
     and ((a.status = 'in_progress' and now() <= a.deadline + interval '30 seconds')
          or (a.status = 'submitted' and (a.released or e.results_released)));
$$;

create or replace function private.can_view_image(p_name text) returns bool
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.allowed_users u where u.user_id = auth.uid())
     and (
       exists (
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
      'has_equation_sheet', (e.equation_sheet is not null),
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
    'equation_sheet', case when private.sheet_visible(a, e) then e.equation_sheet else null end,
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
    'equation_sheet', e.equation_sheet,
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

-- admin_upsert_exam: same as 0001 plus equation_sheet (the JSON file is the source of truth: omitted = removed)
create or replace function public.admin_upsert_exam(p jsonb, p_force bool default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_exam uuid; v_has bool; q jsonb; i bigint; v_q uuid; r record; v_pub bool; v_sheet jsonb;
begin
  v_sheet := case when jsonb_typeof(p->'equation_sheet') = 'object'
                   and jsonb_typeof(p->'equation_sheet'->'pages') = 'array'
                   and jsonb_array_length(p->'equation_sheet'->'pages') > 0
                  then p->'equation_sheet' end;
  insert into public.exams as x (slug, title, instructions, time_limit_minutes, opens_at, closes_at, attempts_allowed,
                            shuffle_questions, shuffle_options, log_focus, published, equation_sheet)
  values (p->>'slug', p->>'title', coalesce(p->>'instructions',''), (p->>'time_limit_minutes')::int,
          (p->>'opens_at')::timestamptz, (p->>'closes_at')::timestamptz, coalesce((p->>'attempts_allowed')::int, 1),
          coalesce((p->>'shuffle_questions')::bool, false), coalesce((p->>'shuffle_options')::bool, false),
          coalesce((p->>'log_focus')::bool, true), coalesce((p->>'published')::bool, false), v_sheet)
  on conflict (slug) do update set
    title = excluded.title, instructions = excluded.instructions, time_limit_minutes = excluded.time_limit_minutes,
    opens_at = excluded.opens_at, closes_at = excluded.closes_at, attempts_allowed = excluded.attempts_allowed,
    shuffle_questions = excluded.shuffle_questions, shuffle_options = excluded.shuffle_options,
    log_focus = excluded.log_focus, equation_sheet = excluded.equation_sheet,
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
    'equation_sheet_pages', coalesce(jsonb_array_length(v_sheet->'pages'), 0));
end $$;

create or replace function public.admin_list() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.finalize_expired(null);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'slug', e.slug, 'title', e.title, 'published', e.published, 'results_released', e.results_released,
    'time_limit_minutes', e.time_limit_minutes, 'opens_at', e.opens_at, 'closes_at', e.closes_at,
    'attempts_allowed', e.attempts_allowed,
    'equation_sheet_pages', coalesce(jsonb_array_length(e.equation_sheet->'pages'), 0),
    'questions', (select count(*) from public.questions q where q.exam_id = e.id),
    'total_marks', (select coalesce(sum(marks),0) from public.questions q where q.exam_id = e.id),
    'attempts', (select count(*) from public.attempts a where a.exam_id = e.id),
    'submitted', (select count(*) from public.attempts a where a.exam_id = e.id and a.status = 'submitted'),
    'pending_manual', (select coalesce(sum(pending_manual),0) from public.attempts a where a.exam_id = e.id)
  ) order by e.created_at) from public.exams e), '[]'::jsonb);
end $$;

-- grants: private helpers stay closed except what the storage policy needs
revoke execute on function private.sheet_visible(public.attempts, public.exams) from public, anon, authenticated;
revoke execute on function private.can_view_image(text) from public, anon;
grant  execute on function private.can_view_image(text) to authenticated;
revoke execute on function public.list_my_exams() from public, anon;
revoke execute on function public.get_attempt(uuid) from public, anon;
revoke execute on function public.get_results(uuid) from public, anon;
revoke execute on function public.admin_upsert_exam(jsonb, bool) from public, anon, authenticated;
revoke execute on function public.admin_list() from public, anon, authenticated;
grant execute on function public.list_my_exams() to authenticated;
grant execute on function public.get_attempt(uuid) to authenticated;
grant execute on function public.get_results(uuid) to authenticated;
grant execute on function public.admin_upsert_exam(jsonb, bool) to service_role;
grant execute on function public.admin_list() to service_role;

notify pgrst, 'reload schema';
