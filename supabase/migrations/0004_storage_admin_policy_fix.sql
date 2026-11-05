-- Fix: storage policy must not SELECT public.allowed_users as authenticated
-- (that raises "permission denied for table allowed_users" and breaks image signing).

create or replace function private.is_admin() returns bool
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.allowed_users u
     where u.user_id = auth.uid() and u.role = 'admin');
$$;
revoke execute on function private.is_admin() from public, anon;
grant  execute on function private.is_admin() to authenticated;

drop policy if exists "exam images: admin write" on storage.objects;
create policy "exam images: admin write" on storage.objects
  for all to authenticated
  using (bucket_id = 'exam-images' and private.is_admin())
  with check (bucket_id = 'exam-images' and private.is_admin());

notify pgrst, 'reload schema';
