-- ──────────────────────────────────────────────────────────────────────
-- Payslips: fill in every column the dashboard writes — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- The dashboard writes `monthly_salary`, `hra`, `wa`, `deductions`, and
-- `bank_last4` to every payslip, but the earlier payroll-upgrade
-- migration never added them. Bulk generate was failing with
-- "Could not find the 'X' column of 'payslips' in the schema cache".
-- This patch adds all of them so the insert payload lines up with the
-- table schema.
-- ──────────────────────────────────────────────────────────────────────

alter table public.payslips
  add column if not exists monthly_salary  numeric(12, 2),
  add column if not exists hra             numeric(12, 2),
  add column if not exists wa              numeric(12, 2),
  add column if not exists deductions      numeric(12, 2),
  add column if not exists bank_last4      text;
