-- ──────────────────────────────────────────────────────────────────────
-- Payroll upgrade — April 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run this once against the Supabase project (SQL editor or psql).
-- Safe to re-run: every statement is idempotent (IF NOT EXISTS / IF EXISTS).
--
-- Adds the data backing the new Payslips flow:
--   • employees gain a salary_type (esi_pf vs new_joined) plus the
--     statutory identifiers (TMB / ESI / EPF / UAN) and the fixed
--     per-employee components (monthly_salary, HRA, W.A.).
--   • payslips gain per-row P.DAYS / L.DAYS / Amount / Bonus / Dues /
--     Credit / Advance / diff 2% so the two compute engines can
--     persist their inputs without abusing the old earnings JSON.
--   • A tiny `app_settings` table holds the DA constant so HR can
--     update it without a code push.
--   • `bonus_plans` + `bonus_plan_rows` back the new Bonus planning
--     page.
-- ──────────────────────────────────────────────────────────────────────

-- ── Employees ─────────────────────────────────────────────────────────
alter table public.employees
  add column if not exists salary_type     text,
  add column if not exists monthly_salary  numeric(12, 2),
  add column if not exists hra             numeric(12, 2),
  add column if not exists wa              numeric(12, 2),
  add column if not exists tmb_account_no  text,
  add column if not exists esi_no          text,
  add column if not exists epf_no          text,
  add column if not exists uan_no          text;

-- Constrain salary_type. Existing rows get 'new_joined' as the default
-- so the column is never null for an active employee.
update public.employees
   set salary_type = 'new_joined'
 where salary_type is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'employees_salary_type_chk'
  ) then
    alter table public.employees
      add constraint employees_salary_type_chk
      check (salary_type in ('esi_pf', 'new_joined'));
  end if;
end $$;

-- ── App settings (DA etc.) ────────────────────────────────────────────
create table if not exists public.app_settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now()
);

insert into public.app_settings (key, value)
values ('payroll.da', jsonb_build_object('amount', 7313))
on conflict (key) do nothing;

-- ── Payslips ──────────────────────────────────────────────────────────
-- New columns sit alongside the existing earnings/deduct_items JSON so
-- the historical payslips stay readable.
alter table public.payslips
  add column if not exists salary_type    text,
  add column if not exists days_in_month  integer,
  add column if not exists p_days         numeric(5, 2),
  add column if not exists l_days         numeric(5, 2),
  add column if not exists amount         numeric(12, 2),
  add column if not exists bonus          numeric(12, 2) default 0,
  add column if not exists dues           numeric(12, 2) default 0,
  add column if not exists credit         numeric(12, 2) default 0,
  add column if not exists advance_amt    numeric(12, 2) default 0,
  add column if not exists diff_pct       numeric(6, 3)  default 0;

-- ── Bonus planning ────────────────────────────────────────────────────
create table if not exists public.bonus_plans (
  id          uuid primary key default gen_random_uuid(),
  month       date not null unique,                -- first of month
  note        text,
  pushed_at   timestamptz,                         -- null until HR pushes to payslips
  created_at  timestamptz not null default now()
);

create table if not exists public.bonus_plan_rows (
  plan_id       uuid not null references public.bonus_plans(id) on delete cascade,
  employee_id   text not null references public.employees(id)   on delete cascade,
  present_days  numeric(5, 2) default 0,
  late_days     numeric(5, 2) default 0,
  leave_days    numeric(5, 2) default 0,
  bonus_amount  numeric(12, 2) default 0,
  primary key (plan_id, employee_id)
);

-- ── RLS ───────────────────────────────────────────────────────────────
-- Mirrors the permissive anon policies used elsewhere in this project.
-- Tighten later when the app moves to signed-in Supabase users.
alter table public.app_settings      enable row level security;
alter table public.bonus_plans       enable row level security;
alter table public.bonus_plan_rows   enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where policyname = 'app_settings anon all') then
    create policy "app_settings anon all" on public.app_settings for all using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where policyname = 'bonus_plans anon all') then
    create policy "bonus_plans anon all" on public.bonus_plans for all using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where policyname = 'bonus_plan_rows anon all') then
    create policy "bonus_plan_rows anon all" on public.bonus_plan_rows for all using (true) with check (true);
  end if;
end $$;
