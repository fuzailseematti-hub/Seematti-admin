-- ──────────────────────────────────────────────────────────────────────
-- Role-elevation guard — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- The dashboard uses Supabase's anon key + a custom user_access table,
-- so RLS can't identify the caller by auth.uid(). This migration adds
-- a DB-side safety net for the most dangerous mutation: promoting an
-- employee to 'owner' or 'admin'.
--
-- How it works
--   • A trigger on public.employees blocks any INSERT or UPDATE that
--     sets user_type to 'owner' or 'admin' unless a per-transaction
--     session flag `app.role_change_ok` is set to '1'. Browser clients
--     cannot set that flag, so direct PATCH/POST calls from the anon
--     key are refused.
--   • A SECURITY DEFINER RPC `admin_change_role()` verifies the actor's
--     username + password hash against user_access, sets the flag for
--     the duration of its execution, and then performs the UPDATE.
--     Only employees whose own user_type = 'owner' can grant 'owner' or
--     'admin' to others.
--
-- Bootstrap note
--   The shared admin password (used for the Owner bootstrap login) does
--   NOT satisfy this RPC. The Owner must first create a user_access row
--   for themselves in Team Access, then use that account to grant Admin
--   to other staff.
-- ──────────────────────────────────────────────────────────────────────

-- ── Trigger: block direct user_type elevation ─────────────────────────
create or replace function public.guard_role_elevation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE'
     and new.user_type is distinct from old.user_type
     and new.user_type in ('owner', 'admin')
     and coalesce(current_setting('app.role_change_ok', true), '') <> '1' then
    raise exception 'Role elevation to % must go through admin_change_role()', new.user_type
      using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'INSERT'
     and new.user_type in ('owner', 'admin')
     and coalesce(current_setting('app.role_change_ok', true), '') <> '1' then
    raise exception 'Cannot create an employee with user_type = % directly', new.user_type
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end
$$;

drop trigger if exists employees_role_guard on public.employees;
create trigger employees_role_guard
  before insert or update on public.employees
  for each row execute function public.guard_role_elevation();

-- ── RPC: the only sanctioned way to change user_type ──────────────────
create or replace function public.admin_change_role(
  p_actor_username       text,
  p_actor_password_sha256 text,
  p_target_employee_id   text,
  p_new_role             text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_type text;
begin
  if p_new_role not in ('owner', 'admin', 'hr', 'manager', 'supervisor', 'staff') then
    raise exception 'Invalid role: %', p_new_role;
  end if;

  -- Who is acting?
  select e.user_type
    into v_actor_type
    from public.user_access ua
    join public.employees   e on e.id = ua.employee_id
   where ua.username = lower(p_actor_username)
     and ua.password_sha256 = p_actor_password_sha256
     and coalesce(e.is_active, true) = true;

  if v_actor_type is null then
    raise exception 'Invalid credentials'
      using errcode = 'insufficient_privilege';
  end if;

  -- Only the Owner can grant Owner or Admin.
  if p_new_role in ('owner', 'admin') and v_actor_type <> 'owner' then
    raise exception 'Only the Owner can grant Owner or Admin rights'
      using errcode = 'insufficient_privilege';
  end if;

  -- Lower-privilege changes (manager / supervisor / hr / staff) are
  -- allowed for any admin-capable role.
  if p_new_role not in ('owner', 'admin')
     and v_actor_type not in ('owner', 'admin', 'hr') then
    raise exception 'Your role cannot change access'
      using errcode = 'insufficient_privilege';
  end if;

  -- Permit the trigger for this statement only.
  perform set_config('app.role_change_ok', '1', true);
  update public.employees
     set user_type = p_new_role
   where id = p_target_employee_id;
  perform set_config('app.role_change_ok', '', true);
end
$$;

revoke all on function public.admin_change_role(text, text, text, text) from public;
grant execute on function public.admin_change_role(text, text, text, text) to anon, authenticated;
