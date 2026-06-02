-- ───────────────────────────────────────────────────────────────────────────
-- Supabase Auth migration — PHASE 4 (cleanup) — APPLIED to prod 2026-06-02
--
-- Now that Supabase Auth owns credentials (Phase 2) and RLS is locked down
-- (Phase 3b), remove the leftovers from the old custom-auth scheme:
--   • user_access.password_sha256 — the unsalted SHA-256 store is obsolete
--     (Auth holds the bcrypt password). The client no longer reads or writes
--     it (the dead login-picker fetch was stripped in the same PR).
--   • admin_change_role(actor_username, actor_password_sha256, ...) — the
--     legacy role-change RPC that verified the actor by username+hash. It has
--     no callers; admin_change_role_v2 (verifies via auth.uid()) replaced it.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.user_access drop column if exists password_sha256;
drop function if exists public.admin_change_role(text, text, text, text);

-- ───────────────────────────────────────────────────────────────────────────
-- Still open (not done here):
--   • Employee-PII split: hide salary/bank/statutory columns from non-HR roles
--     (needs a restricted view + client query changes). Today employees is
--     readable by any authenticated user.
--   • Enable Auth "leaked password protection" (HaveIBeenPwned) — a project
--     setting toggled in the Supabase dashboard (Auth → Settings), not SQL.
-- Rollback for this file is intentionally omitted: the dropped hash column held
-- obsolete credentials and should not be recreated.
-- ───────────────────────────────────────────────────────────────────────────
