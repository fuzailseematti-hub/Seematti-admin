-- ───────────────────────────────────────────────────────────────────────────
-- Supabase Auth migration — PHASE 2 (client cutover support: RPCs)
--
-- See docs/auth-migration-plan.md. ADDITIVE and SAFE to apply ahead of the
-- client cutover: none of these are called by the pre-cutover apps, so the
-- live login keeps working. The new client (this phase's PR) calls them.
--
-- All actor-verified functions derive the caller from auth.uid() (the JWT),
-- replacing the old username + password_sha256 verification that no longer
-- exists once login goes through Supabase Auth.
-- ───────────────────────────────────────────────────────────────────────────

-- 1. Pre-auth username -> synthesized email. Anon-callable: it only maps a
--    username to <employee_id>@staff.seematti.local (no secret); the password
--    is still required by signInWithPassword. Returns null for unknown/inactive.
create or replace function public.auth_email_for_username(p_username text)
returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select lower(ua.employee_id) || '@staff.seematti.local'
  from public.user_access ua
  join public.employees e on e.id = ua.employee_id
  where ua.username = lower(p_username)
    and coalesce(e.is_active, true) = true
  limit 1;
$$;
grant execute on function public.auth_email_for_username(text) to anon, authenticated;

-- 2. Role change, actor verified via JWT. Mirrors admin_change_role()'s rules
--    but reads the actor's user_type by auth.uid() instead of username/hash.
create or replace function public.admin_change_role_v2(p_target_employee_id text, p_new_role text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor_type text;
begin
  if p_new_role not in ('owner','admin','hr','manager','supervisor','staff','cc') then
    raise exception 'Invalid role: %', p_new_role;
  end if;
  select e.user_type into v_actor_type
    from public.user_access ua
    join public.employees e on e.id = ua.employee_id
    where ua.auth_uid = auth.uid()
      and coalesce(e.is_active, true) = true;
  if v_actor_type is null then
    raise exception 'Not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_new_role in ('owner','admin') and v_actor_type <> 'owner' then
    raise exception 'Only the Owner can grant Owner or Admin rights' using errcode = 'insufficient_privilege';
  end if;
  if p_new_role not in ('owner','admin') and v_actor_type not in ('owner','admin','hr') then
    raise exception 'Your role cannot change access' using errcode = 'insufficient_privilege';
  end if;
  perform set_config('app.role_change_ok', '1', true);
  update public.employees set user_type = p_new_role where id = p_target_employee_id;
  perform set_config('app.role_change_ok', '', true);
end $$;
grant execute on function public.admin_change_role_v2(text, text) to authenticated;

-- 3. Create-or-update the Auth user for an employee and set its password.
--    Owner/Admin only (verified via JWT). Used by Team Access when a password
--    is set on a new or existing grant. Returns the auth user id. The
--    user_access row must already exist (the save flow upserts it first).
create or replace function public.admin_provision_user(p_target_employee_id text, p_password text)
returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_actor_type text;
  v_uid uuid;
  v_email text;
begin
  select e.user_type into v_actor_type
    from public.user_access ua
    join public.employees e on e.id = ua.employee_id
    where ua.auth_uid = auth.uid()
      and coalesce(e.is_active, true) = true;
  if v_actor_type not in ('owner','admin') then
    raise exception 'Only Owner/Admin can set passwords' using errcode = 'insufficient_privilege';
  end if;
  if p_password is null or length(p_password) < 4 then
    raise exception 'Password must be at least 4 characters';
  end if;

  v_email := lower(p_target_employee_id) || '@staff.seematti.local';
  select auth_uid into v_uid from public.user_access where employee_id = p_target_employee_id;

  if v_uid is not null then
    update auth.users
      set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
          updated_at = now()
      where id = v_uid;
    return v_uid;
  end if;

  v_uid := gen_random_uuid();
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
    is_sso_user, is_anonymous, confirmation_token, recovery_token,
    email_change_token_new, email_change, email_change_token_current,
    reauthentication_token, phone_change, phone_change_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
    v_email, extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('employee_id', upper(p_target_employee_id)),
    false, false, '', '', '', '', '', '', '', ''
  );
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (
    v_uid::text, v_uid,
    jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
    'email', now(), now(), now()
  );
  update public.user_access set auth_uid = v_uid where employee_id = p_target_employee_id;
  return v_uid;
end $$;
grant execute on function public.admin_provision_user(text, text) to authenticated;

-- 4. Delete the Auth user for an employee (used when access is revoked).
--    Owner/Admin only. Call BEFORE deleting the user_access row.
create or replace function public.admin_revoke_auth(p_target_employee_id text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor_type text; v_uid uuid;
begin
  select e.user_type into v_actor_type
    from public.user_access ua
    join public.employees e on e.id = ua.employee_id
    where ua.auth_uid = auth.uid()
      and coalesce(e.is_active, true) = true;
  if v_actor_type not in ('owner','admin') then
    raise exception 'Only Owner/Admin can revoke access' using errcode = 'insufficient_privilege';
  end if;
  select auth_uid into v_uid from public.user_access where employee_id = p_target_employee_id;
  if v_uid is not null then
    delete from auth.identities where user_id = v_uid;
    delete from auth.users where id = v_uid;
  end if;
end $$;
grant execute on function public.admin_revoke_auth(text) to authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- Rollback:
--   drop function if exists public.admin_revoke_auth(text);
--   drop function if exists public.admin_provision_user(text, text);
--   drop function if exists public.admin_change_role_v2(text, text);
--   drop function if exists public.auth_email_for_username(text);
-- ───────────────────────────────────────────────────────────────────────────
