-- save_practice: plpgsql variable `f` shadowed the SQL alias `f`; rename it.
create or replace function public.save_practice(p_course text, p_week int, p_position int, p_answers jsonb, p_submit bool default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := private.require_user(); d public.course_days; s public.practice_submissions; e record; fr public.practice_fields; rw record;
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
    select f2.* into fr from public.practice_fields f2 join public.practice_questions q on q.id = f2.question_id
     where q.day_id = d.id and f2.id::text = e.key;
    if not found then continue; end if;
    insert into public.practice_answers as a (submission_id, field_id, value, num, updated_at)
      values (s.id, fr.id, left(nullif(btrim(e.value #>> '{}'), ''), 8000),
              case when fr.kind = 'numeric' then private.practice_num(e.value #>> '{}') end, now())
      on conflict (submission_id, field_id) do update set value = excluded.value, num = excluded.num, updated_at = now();
  end loop;
  update public.practice_submissions set updated_at = now() where id = s.id;

  if p_submit then
    -- every field gets a row so marking sees blanks too
    insert into public.practice_answers (submission_id, field_id)
      select s.id, f2.id from public.practice_fields f2 join public.practice_questions q on q.id = f2.question_id where q.day_id = d.id
      on conflict do nothing;
    for rw in select a.field_id, a.num, a.value, f2.kind, f2.marks from public.practice_answers a join public.practice_fields f2 on f2.id = a.field_id
              where a.submission_id = s.id loop
      if rw.kind = 'numeric' then
        select * into k from private.practice_keys where field_id = rw.field_id;
        if k.field_id is not null and k.answer is not null then
          ok := private.practice_within(rw.num, k);
          update public.practice_answers set auto_correct = ok, auto_marks = case when ok then rw.marks else 0 end
           where submission_id = s.id and field_id = rw.field_id;
        end if;
      elsif rw.marks = 0 then
        update public.practice_answers set auto_marks = 0 where submission_id = s.id and field_id = rw.field_id;
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

revoke execute on function public.save_practice(text, int, int, jsonb, bool) from public, anon;
grant execute on function public.save_practice(text, int, int, jsonb, bool) to authenticated;
