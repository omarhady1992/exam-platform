-- mentor_load_practice: avoid SQL aliases that share names with plpgsql variables (q).
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
    with del as (delete from public.practice_fields pf using public.practice_questions pq
                  where pq.id = pf.question_id and pq.day_id = d.id and not (pf.id = any(keep_f)) returning 1)
    select count(*) into removed from del;
    delete from public.practice_questions pq where pq.day_id = d.id and not (pq.qkey = any(keep_q));
  end if;
  return jsonb_build_object('day_id', d.id, 'questions', nq, 'fields', nf, 'keys', nk, 'removed_fields', removed, 'submitted', nsub);
end $$;

revoke execute on function public.mentor_load_practice(jsonb, bool) from public, anon, authenticated;
grant execute on function public.mentor_load_practice(jsonb, bool) to service_role;
