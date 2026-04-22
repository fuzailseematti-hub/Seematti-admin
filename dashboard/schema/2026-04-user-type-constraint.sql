-- ──────────────────────────────────────────────────────────────────────
-- employees.user_type CHECK constraint — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- Prod had an older CHECK constraint `employees_user_type_check` that
-- did not include the 'admin' role. With the DB-side role guard
-- (see 2026-04-role-guard.sql) relying on 'admin' being a valid value,
-- this migration replaces the old constraint with one that accepts the
-- full role set: owner, admin, hr, manager, supervisor, staff.
--
-- Symptom this fixes: Team Access "Grant admin" failed silently because
-- the admin_change_role() RPC's UPDATE tripped the old CHECK constraint,
-- and the UI skipped the user_access upsert on RPC error.
-- ──────────────────────────────────────────────────────────────────────

alter table public.employees
  drop constraint if exists employees_user_type_check;

alter table public.employees
  drop constraint if exists employees_user_type_chk;

alter table public.employees
  add constraint employees_user_type_chk
  check (user_type in ('owner', 'admin', 'hr', 'manager', 'supervisor', 'staff'));
