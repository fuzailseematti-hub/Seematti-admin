-- ───────────────────────────────────────────────────────────────────────────
-- Supabase Auth migration — PHASE 0 (identity plumbing + safe linter fixes)
--
-- See docs/auth-migration-plan.md. This migration is ADDITIVE and SAFE:
--   • No RLS lockdown, no behavioural change to the running apps.
--   • Only adds an unused nullable column, a private helper schema, helper
--     functions used by LATER phases, and two security-linter fixes.
--
-- APPLY ON A SUPABASE BRANCH FIRST, verify both apps still work, then promote.
-- Nothing here should change what the live apps can read or write today.
-- ───────────────────────────────────────────────────────────────────────────

-- 1. Link column: maps a Supabase Auth user to its user_access / employee row.
--    Nullable + unused until Phase 1 backfills it; safe to add now.
alter table public.user_access
  add column if not exists auth_uid uuid unique;

-- 2. Private schema for the auth helper functions RLS will use in Phase 3.
create schema if not exists app;
grant usage on schema app to authenticated;

-- 3. Helper functions. SECURITY DEFINER + pinned search_path so they read the
--    caller's own row by auth.uid() regardless of (future) RLS on user_access.
--    Defined now so Phase 3 policies can reference them; harmless until used.
create or replace function app.current_employee_id()
returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select ua.employee_id
  from public.user_access ua
  where ua.auth_uid = auth.uid();
$$;

create or replace function app.current_user_type()
returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select e.user_type
  from public.user_access ua
  join public.employees e on e.id = ua.employee_id
  where ua.auth_uid = auth.uid();
$$;

create or replace function app.has_all_sections()
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select ua.all_sections from public.user_access ua where ua.auth_uid = auth.uid()),
    false);
$$;

create or replace function app.user_section_ids()
returns text[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select ua.section_ids from public.user_access ua where ua.auth_uid = auth.uid()),
    '{}'::text[]);
$$;

-- Convenience predicate used by several Phase 3 policies.
create or replace function app.is_hr_or_admin()
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select app.current_user_type() in ('owner', 'admin', 'hr');
$$;

grant execute on all functions in schema app to authenticated;

-- 4. Security-linter fixes that are safe to apply now.
-- 4a. Pin search_path on the existing trigger functions (no-arg signatures).
alter function public.touch_updated_at()           set search_path = public, pg_temp;
alter function public.guard_role_elevation()        set search_path = public, pg_temp;
alter function public.customers_touch_updated_at()  set search_path = public, pg_temp;
alter function public.muhurtham_default_reminder()  set search_path = public, pg_temp;

-- 4b. Make the reporting view honour the querying user's RLS (security_invoker).
--     Harmless today (tables are world-readable); correct once Phase 3 lands.
alter view public.attendance_today_by_section set (security_invoker = on);

-- ───────────────────────────────────────────────────────────────────────────
-- Rollback (if needed):
--   drop function if exists app.is_hr_or_admin();
--   drop function if exists app.user_section_ids();
--   drop function if exists app.has_all_sections();
--   drop function if exists app.current_user_type();
--   drop function if exists app.current_employee_id();
--   drop schema if exists app;             -- only if empty
--   alter table public.user_access drop column if exists auth_uid;
--   alter view public.attendance_today_by_section set (security_invoker = off);
-- (The search_path hardening on trigger functions is safe to leave in place.)
-- ───────────────────────────────────────────────────────────────────────────
