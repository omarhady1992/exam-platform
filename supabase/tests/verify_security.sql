-- Run after migrations. Fails (non-zero exit) if any client role can read answer keys or call admin RPCs.
\set ON_ERROR_STOP on
begin;
do $$
declare t text; r text; f text;
begin
  foreach r in array array['anon','authenticated'] loop
    execute format('set local role %I', r);
    foreach t in array array['question_keys','questions','exams','attempts','answers','focus_events','allowed_users'] loop
      begin
        execute format('select 1 from public.%I limit 1', t);
        raise exception 'SECURITY FAIL: role % can read public.%', r, t;
      exception when insufficient_privilege then
        raise notice 'ok: % cannot read %', r, t;
      end;
    end loop;
    foreach f in array array['select public.admin_list()','select public.admin_export(''x'')',
                             'select public.admin_upsert_exam(''{}''::jsonb, false)',
                             'select public.admin_release(''x'', true, null)'] loop
      begin
        execute f;
        raise exception 'SECURITY FAIL: role % can run %', r, f;
      exception when insufficient_privilege then
        raise notice 'ok: % cannot run admin fn', r;
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
  execute 'reset role';
end $$;
rollback;
select 'SECURITY CHECKS PASSED' as result;
