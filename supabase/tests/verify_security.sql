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
