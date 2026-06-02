-- ───────────────────────────────────────────────────────────────────────────
-- Supabase Auth migration — PHASE 3b (RLS lockdown)
--
-- See docs/auth-migration-plan.md. This is the payoff: it removes the
-- permissive "anyone with the anon key can read/write everything" policies and
-- replaces them with authenticated-only, role-scoped policies.
--
-- Design:
--   • anon gets ZERO table access. The login + kiosk paths use SECURITY DEFINER
--     RPCs (auth_email_for_username, kiosk_match/punch/meta) which bypass RLS,
--     so nothing pre-login needs table access.
--   • Operational tables stay open to ANY authenticated user (the only logins
--     are 5 trusted staff; the client `can()` still gates the UI). This closes
--     the internet-facing hole with minimal breakage risk.
--   • Genuinely sensitive tables are role-scoped:
--       - user_access     : own row, or owner/admin (writes owner/admin only)
--       - payslips         : own, or owner/admin
--       - advances         : own, or owner/admin/hr
--       - bonus_plans/rows : owner/admin
--       - face_embeddings  : owner/admin/hr (kiosk reads via definer RPC)
--       - customers + CRM  : owner/admin/hr/cc
--   • employees stays authenticated-readable (names/sections are needed app-
--     wide); column-level PII hiding (salary/bank) is a follow-up (needs a view
--     + client query changes). Writes are owner/admin/hr.
--
-- Helpers (Phase 0): app.current_user_type(), app.current_employee_id(),
-- app.is_hr_or_admin().
--
-- password_sha256 is intentionally NOT dropped here (a dead login-picker fetch
-- still selects it); that drop is a Phase 4 cleanup. RLS now hides it anyway.
--
-- VALIDATED via in-transaction role impersonation before applying. APPLY ONLY
-- after the kiosk punch is confirmed working on prod.
-- ───────────────────────────────────────────────────────────────────────────

-- 1. Drop every existing policy on public tables (they're all permissive).
do $$
declare r record;
begin
  for r in
    select p.polname, c.relname
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
  loop
    execute format('drop policy if exists %I on public.%I', r.polname, r.relname);
  end loop;
end $$;

-- 2. Operational tables — any authenticated user (UI gated client-side by can()).
create policy op_all on public.attendance         for all to authenticated using (true) with check (true);
create policy op_all on public.leave_requests     for all to authenticated using (true) with check (true);
create policy op_all on public.tasks              for all to authenticated using (true) with check (true);
create policy op_all on public.task_comments      for all to authenticated using (true) with check (true);
create policy op_all on public.announcements      for all to authenticated using (true) with check (true);
create policy op_all on public.announcement_reads for all to authenticated using (true) with check (true);
create policy op_all on public.visitors           for all to authenticated using (true) with check (true);

-- 3. Read-all, scoped-write.
create policy emp_read  on public.employees for select to authenticated using (true);
create policy emp_write on public.employees for all to authenticated
  using (app.is_hr_or_admin()) with check (app.is_hr_or_admin());

create policy sec_read  on public.sections for select to authenticated using (true);
create policy sec_write on public.sections for all to authenticated
  using (app.current_user_type() in ('owner','admin')) with check (app.current_user_type() in ('owner','admin'));

create policy set_read  on public.settings for select to authenticated using (true);
create policy set_write on public.settings for all to authenticated
  using (app.is_hr_or_admin()) with check (app.is_hr_or_admin());

-- app_settings holds UI/theme prefs (not sensitive); any authenticated user
-- may write so per-user preference saves don't break.
create policy aset_read  on public.app_settings for select to authenticated using (true);
create policy aset_write on public.app_settings for all to authenticated using (true) with check (true);

-- 4. Sensitive — scoped both ways.
-- Payroll: an employee sees their own; owner/admin see/manage all.
create policy pay_read  on public.payslips for select to authenticated
  using (app.current_user_type() in ('owner','admin') or employee_id = app.current_employee_id());
create policy pay_write on public.payslips for all to authenticated
  using (app.current_user_type() in ('owner','admin')) with check (app.current_user_type() in ('owner','admin'));

-- Advances: own, plus owner/admin/hr manage.
create policy adv_read  on public.advances for select to authenticated
  using (app.is_hr_or_admin() or employee_id = app.current_employee_id());
create policy adv_write on public.advances for all to authenticated
  using (app.is_hr_or_admin()) with check (app.is_hr_or_admin());

-- Bonus: owner/admin only.
create policy bonus_plans_all on public.bonus_plans for all to authenticated
  using (app.current_user_type() in ('owner','admin')) with check (app.current_user_type() in ('owner','admin'));
create policy bonus_rows_all on public.bonus_plan_rows for all to authenticated
  using (app.current_user_type() in ('owner','admin')) with check (app.current_user_type() in ('owner','admin'));

-- Biometrics: owner/admin/hr (the kiosk matches via SECURITY DEFINER RPC).
create policy face_all on public.face_embeddings for all to authenticated
  using (app.is_hr_or_admin()) with check (app.is_hr_or_admin());

-- Credentials: own row visible; only owner/admin see all + write.
create policy ua_read on public.user_access for select to authenticated
  using (app.current_user_type() in ('owner','admin') or auth_uid = auth.uid());
create policy ua_write on public.user_access for all to authenticated
  using (app.current_user_type() in ('owner','admin')) with check (app.current_user_type() in ('owner','admin'));

-- CRM: owner/admin/hr/cc.
create policy crm_all on public.customers              for all to authenticated
  using (app.current_user_type() in ('owner','admin','hr','cc')) with check (app.current_user_type() in ('owner','admin','hr','cc'));
create policy crm_all on public.customer_interactions  for all to authenticated
  using (app.current_user_type() in ('owner','admin','hr','cc')) with check (app.current_user_type() in ('owner','admin','hr','cc'));
create policy crm_all on public.customer_preferences   for all to authenticated
  using (app.current_user_type() in ('owner','admin','hr','cc')) with check (app.current_user_type() in ('owner','admin','hr','cc'));
create policy crm_all on public.customer_family_members for all to authenticated
  using (app.current_user_type() in ('owner','admin','hr','cc')) with check (app.current_user_type() in ('owner','admin','hr','cc'));
create policy crm_all on public.muhurtham_visits       for all to authenticated
  using (app.current_user_type() in ('owner','admin','hr','cc')) with check (app.current_user_type() in ('owner','admin','hr','cc'));
