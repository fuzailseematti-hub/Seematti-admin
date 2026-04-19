-- ──────────────────────────────────────────────────────────────────────
-- Payslips: add per-row HRA + W.A. — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- The ESI/PF payslip flow writes the employee's HRA and W.A. onto each
-- payslip so the historical amounts stay accurate even if HR edits the
-- employee master data later. Bulk-generate was failing with
-- "cannot find hra column" because the payslips table never got these
-- columns in the earlier payroll-upgrade migration.
-- ──────────────────────────────────────────────────────────────────────

alter table public.payslips
  add column if not exists hra  numeric(12, 2),
  add column if not exists wa   numeric(12, 2);
