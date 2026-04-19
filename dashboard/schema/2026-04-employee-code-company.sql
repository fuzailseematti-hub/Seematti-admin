-- ──────────────────────────────────────────────────────────────────────
-- Employee code + company — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- Adds two new columns to `employees`:
--   • employee_code — HR-assigned code (e.g. E001, N042).
--   • company       — Which company/division the employee belongs to
--                     (e.g. Seematti Silks, Seematti Boutique).
-- ──────────────────────────────────────────────────────────────────────

alter table public.employees
  add column if not exists employee_code  text,
  add column if not exists company        text;
