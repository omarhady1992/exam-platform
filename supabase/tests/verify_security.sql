-- Run after migrations. Fails (non-zero exit) if any client role can read answer keys or call admin RPCs without being admin.
\set ON_ERROR_STOP on
begin;
do $$
declare t text; r text; f text;
begin
  foreach r in array array['anon','authenticated'] loop
    execute format('set local role %I', r);
    foreach t in array array['question_keys','questions','exams','attempts','answers','focus_events','allowed_users','finish_notifications','app_settings'] loop
      begin
        execute format('select 1 from public.%I limit 1', t);
        raise exception 'SECURITY FAIL: role % can read public.%', r, t;
      exception when insufficient_privilege then
        raise notice 'ok: % cannot read %', r, t;
      end;
    end loop;
    foreach f in array array['select public.admin_list()','select public.admin_export(''x'')',
                             'select public.admin_upsert_exam(''{}''::jsonb, false)',
                             'select public.admin_release(''x'', true, null)',
                             'select public.admin_list_finishes(true)',
                             'select public.admin_get_notify_emails(null)'] loop
      begin
        execute f;
        raise exception 'SECURITY FAIL: role % can run %', r, f;
      exception when insufficient_privilege then
        raise notice 'ok: % cannot run admin fn', r;
      when others then
        -- require_admin raises 42501 (insufficient_privilege); any other unexpected success path is a fail above.
        -- Some PostgREST/SQL paths may surface as generic exceptions with that SQLSTATE already handled.
        if SQLSTATE = '42501' then
          raise notice 'ok: % blocked from admin fn (% )', r, SQLERRM;
        else
          raise;
        end if;
      end;
    end loop;
    execute 'reset role';
  end loop;

  -- anon cannot call client RPCs; authenticated-but-not-allowlisted user is rejected
  execute 'set local role anon';
  begin
    perform public.list_my_exams();
    raise exception 'SECURITY FAIL: anon can call list_my_exams';
  exception when insufficient_privilege then raise notice 'ok: anon cannot call list_my_exams';
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  execute 'set local role authenticated';
  begin
    perform public.list_my_exams();
    raise exception 'SECURITY FAIL: non-allowlisted user can list exams';
  exception when insufficient_privilege then raise notice 'ok: non-allowlisted user rejected';
  end;
  if private.can_view_image('x/sheet-0.png') then
    raise exception 'SECURITY FAIL: non-allowlisted user passes can_view_image';
  end if;
  begin
    perform private.sheet_visible(null::public.attempts, null::public.exams);
    raise exception 'SECURITY FAIL: authenticated can call private.sheet_visible';
  exception when insufficient_privilege then raise notice 'ok: sheet_visible is not callable by clients';
  end;
  begin
    perform private.resend_api_key();
    raise exception 'SECURITY FAIL: authenticated can call private.resend_api_key';
  exception when insufficient_privilege then raise notice 'ok: resend_api_key is private';
  end;
  execute 'reset role';
end $$;
rollback;
select 'SECURITY CHECKS PASSED' as result;

-- learning platform (0005): anon has no access; a signed-in but non-allow-listed user sees nothing
begin;
do $$
declare t text; n int;
begin
  execute 'set local role anon';
  foreach t in array array['courses','course_weeks','course_days','day_progress'] loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      raise exception 'SECURITY FAIL: anon can read public.%', t;
    exception when insufficient_privilege then raise notice 'ok: anon cannot read %', t;
    end;
  end loop;
  begin
    perform public.list_courses();
    raise exception 'SECURITY FAIL: anon can call list_courses';
  exception when insufficient_privilege then raise notice 'ok: anon cannot call list_courses';
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  execute 'set local role authenticated';
  foreach t in array array['courses','course_weeks','course_days','day_progress'] loop
    execute format('select count(*) from public.%I', t) into n;
    if n <> 0 then raise exception 'SECURITY FAIL: non-allowlisted user sees % rows of %', n, t; end if;
    raise notice 'ok: non-allowlisted user sees no rows in %', t;
  end loop;
  begin
    perform public.list_courses();
    raise exception 'SECURITY FAIL: non-allowlisted user can list courses';
  exception when insufficient_privilege then raise notice 'ok: non-allowlisted user cannot list courses';
  end;
  begin
    perform public.admin_upsert_course('{"slug":"x-test","title":"x"}'::jsonb);
    raise exception 'SECURITY FAIL: non-admin can upsert a course';
  exception when insufficient_privilege then raise notice 'ok: non-admin cannot upsert course';
  end;
  if private.can_view_course_file('cased-hole/week-1/x.pdf') then
    raise exception 'SECURITY FAIL: non-allowlisted user passes can_view_course_file';
  end if;
  execute 'reset role';
  if not private.forbidden_course_path('re/keys/RE-Week1-Quiz-key.md') or not private.forbidden_course_path('a/Week1-Quiz-Fundamentals-Answer-Key.pdf')
     or not private.forbidden_course_path('a/week1-quiz-answers.pdf') or private.forbidden_course_path('cased-hole/week-4/Week4-Tuesday-Spinner-Flowmeters.pdf') then
    raise exception 'SECURITY FAIL: forbidden_course_path rules are wrong';
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'course-files' and private.forbidden_course_path(name)) then
    raise exception 'SECURITY FAIL: answer-key-like object in course-files bucket';
  end if;
  if exists (select 1 from storage.buckets where id = 'course-files' and public) then
    raise exception 'SECURITY FAIL: course-files bucket is public';
  end if;
end $$;
rollback;
select 'LEARNING SECURITY CHECKS PASSED' as result;
