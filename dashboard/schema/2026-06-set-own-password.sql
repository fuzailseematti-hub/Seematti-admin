-- ───────────────────────────────────────────────────────────────────────────
-- set_own_password — self-service password change that allows short (PIN-style)
-- passwords. APPLIED to prod 2026-06-02.
--
-- Supabase Auth's self-service updateUser enforces a 6-char minimum. The owner
-- wants short numeric passwords, so self-service password changes now go
-- through this SECURITY DEFINER RPC instead: it verifies the current password
-- against the stored bcrypt hash and writes the new hash directly (the same
-- mechanism admin_provision_user uses for owner-set passwords), bypassing the
-- self-service length policy. Minimum enforced here is 4 characters.
--
-- Called by both apps' "change password" screens (dashboard Profile, PWA
-- Settings → Account).
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.set_own_password(p_current_password text, p_new_password text)
returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_ok  boolean;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_new_password is null or length(p_new_password) < 4 then
    raise exception 'Password must be at least 4 characters';
  end if;
  select (encrypted_password = extensions.crypt(p_current_password, encrypted_password))
    into v_ok
  from auth.users where id = v_uid;
  if not coalesce(v_ok, false) then
    raise exception 'Current password is wrong' using errcode = 'insufficient_privilege';
  end if;
  update auth.users
    set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf')),
        updated_at = now()
  where id = v_uid;
end $$;
grant execute on function public.set_own_password(text, text) to authenticated;
