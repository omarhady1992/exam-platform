-- 0007's read policies called private.day_visible(), which clients may not execute. Use a dedicated
-- boolean helper (published day in a published week/course, caller allow-listed) instead.
create or replace function private.practice_day_open(p_day uuid) returns bool
language sql stable security definer set search_path = '' as $$
  select private.is_allowed() and exists (
    select 1 from public.course_days d join public.course_weeks w on w.id = d.week_id join public.courses c on c.id = w.course_id
     where d.id = p_day and d.published and w.published and c.published);
$$;
revoke execute on function private.practice_day_open(uuid) from public, anon;
grant execute on function private.practice_day_open(uuid) to authenticated;

drop policy if exists "practice q: read visible" on public.practice_questions;
create policy "practice q: read visible" on public.practice_questions for select to authenticated
  using (private.practice_day_open(day_id));
drop policy if exists "practice f: read visible" on public.practice_fields;
create policy "practice f: read visible" on public.practice_fields for select to authenticated
  using (exists (select 1 from public.practice_questions q where q.id = question_id and private.practice_day_open(q.day_id)));
drop policy if exists "practice days: read visible" on public.practice_days;
create policy "practice days: read visible" on public.practice_days for select to authenticated
  using (private.practice_day_open(day_id));
