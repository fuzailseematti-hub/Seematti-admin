# Supabase Auth migration plan

Status: **proposed — not yet started.** No database or auth changes have been
applied to the live project (`hixhbznbejqfnasvgyid`). This document is the plan
to review and approve before any phase is implemented.

## Why

Today both apps (`index.html` PWA, `dashboard/index.html`) talk to Supabase with
the **publishable anon key**, which is embedded in the page source. Row Level
Security is *enabled* on all 22 public tables, but every table has a policy that
grants the `public` role unrestricted access:

- `SELECT USING (true)` — anyone can read every row
- `ALL USING (true) WITH CHECK (true)` — anyone can insert/update/delete every row

So all access control currently lives only in client JavaScript (`can()` +
hidden UI). Anyone who reads the anon key from the page and calls the REST API
directly bypasses it entirely. Highest-impact consequences:

- **`user_access`** is world-readable **and** world-writable → all password
  hashes (unsalted SHA-256) can be read, or any user's hash overwritten →
  account takeover.
- **`payslips`** → every salary readable by anyone.
- **`employees`** → all PII (phone, bank a/c, ESI/EPF/UAN) readable/writable.

The fix is to introduce real authentication so RLS can key on the signed-in
user, then lock the policies down.

## Current auth model (what we're replacing)

- **Dashboard login** (`dashboard/index.html` ~L715):
  - Path 1 — bootstrap Owner: SHA-256 of the typed password is compared to the
    hardcoded `window.ADMIN_PASSWORD_SHA256` (L600). Default plaintext
    `Seemaatti@2026` is in a source comment.
  - Path 2 — `user_access` row by `username`, hash compared client-side.
  - Session stored in `localStorage` with **no expiry / no revalidation**.
- **PWA login** (`index.html` ~L2206, L2334): loads `user_access` rows (incl.
  `password_sha256`) with the anon key and compares hashes in the browser.
- **`user_access`** columns: `employee_id`, `username`, `password_sha256`,
  `section_ids[]`, `all_sections`, `can_approve_leaves`, `can_edit_attendance`,
  `can_post_announcements`, `can_manage_tasks`, `notes`.
- **`employees.user_type`** ∈ {owner, admin, hr, staff, cc, manager, supervisor}
  drives the role.
- One credential-checked RPC already exists and is the model to follow:
  `admin_change_role(actor_username, actor_password_sha256, target, new_role)`
  (`SECURITY DEFINER`).

## Target auth model

- **Supabase Auth** holds credentials (bcrypt) and issues JWTs; `supabase-js`
  manages the session (auto-refresh + expiry) — replacing the localStorage
  session and all client-side hash comparison.
- Identity: staff don't have emails, so use **synthesized emails**
  `<employee_id>@staff.seematti.local` (e.g. `e001@staff.seematti.local`) with a
  password. (Alternative: phone OTP — staff have phone numbers. Decision needed,
  see "Open questions".)
- Link `auth.users.id` ↔ employee via a new nullable `user_access.auth_uid uuid`.
- SQL helper functions (in a private schema, `SECURITY DEFINER`, fixed
  `search_path`) read the caller's row by `auth.uid()`:
  - `app.current_employee_id() text`
  - `app.current_user_type() text`
  - `app.has_all_sections() boolean`
  - `app.user_section_ids() text[]`
- RLS policies are rewritten per table in terms of those helpers.
- `user_access.password_sha256` is **dropped** (Auth owns passwords).

## Phased rollout

Each phase is independently reviewable and reversible. **All migrations are
first applied and tested on a Supabase _branch_** (via the Supabase MCP
`create_branch` / `merge_branch`) so the live project is never the test bed.

### Phase 0 — Prep (no user-facing change, no lockdown)
- Create `app` schema + helper functions above.
- Add `user_access.auth_uid uuid` (nullable, unique).
- Keep all existing permissive policies in place — nothing breaks.
- Fix the two linter items that are safe now: set `search_path` on existing
  functions; recreate `attendance_today_by_section` as `security_invoker`.

### Phase 1 — Provision auth users (backfill) — ✅ APPLIED 2026-06-02
- For every `user_access` row (and a real Owner account to replace the bootstrap
  hash), create a Supabase Auth user with a **temporary password**, and set
  `user_access.auth_uid`.
- Distribute temp passwords out-of-band; force change on first login.
- Still no lockdown; old login path still works.

**Done:** all 5 `user_access` rows (owner/admin/hr/cc/manager) now have a
confirmed Supabase Auth user at `<employee_id>@staff.seematti.local` and a
linked `auth_uid`. Applied via `dashboard/schema/2026-06-auth-phase1.sql`
(direct `auth.users`/`auth.identities` insert with a pgcrypto bcrypt hash —
the run environment can reach Supabase only over the Postgres channel, not the
GoTrue admin API). Temp passwords were delivered to the owner out-of-band and
are **dormant** — both apps still use the old username/password login until
Phase 2, where login becomes `supabase.auth.signInWithPassword` and a
change-password flow forces a reset on first sign-in. Login itself is verified
in Phase 2 (the Auth REST endpoint isn't reachable from the migration env).

### Phase 2 — Cut the clients over to Auth — 🚧 IN REVIEW
- Replace both login flows with `supabase.auth.signInWithPassword({ email, password })`
  (email resolved from the typed username via `auth_email_for_username`).
- Remove the localStorage/sessionStorage custom session and the bootstrap hash;
  the JWT (supabase-js) is now the source of truth. "Preview as role" kept as an
  in-memory, owner-only client override (no longer persisted).
- Change-password via `supabase.auth.updateUser` (both apps; re-auths with the
  current password first). Optional from settings — no forced first-login gate.

**Supporting RPCs applied to prod** (`dashboard/schema/2026-06-auth-phase2.sql`,
all SECURITY DEFINER, actor verified via `auth.uid()`):
- `auth_email_for_username(username)` — pre-auth username→email (anon).
- `admin_change_role_v2(employee_id, role)` — replaces the username/hash actor
  check in `admin_change_role`.
- `admin_provision_user(employee_id, password)` — create/link the Auth user for a
  Team Access grant or password reset.
- `admin_revoke_auth(employee_id)` — delete the Auth user on revoke.

**Status:** client cutover is in a PR pending owner validation on Vercel previews
(both apps point at prod Supabase; the 5 Phase-1 accounts log in there). Not
merged to `main` until each role is verified. `user_access.password_sha256` is
left in place (read-only/ignored) and dropped in Phase 3. The legacy
`admin_change_role` RPC stays until Phase 3/4 cleanup.

- Validate both apps on the preview URLs with each role before merge.

### Phase 3a — Server-side kiosk matching — ✅ APPLIED & MERGED 2026-06-02
The attendance kiosk runs unauthenticated, so before RLS could drop anon access
its face-match/punch/tally moved into PIN-gated `SECURITY DEFINER` RPCs
(`kiosk_match`/`kiosk_punch`/`kiosk_meta`, `2026-06-auth-phase3a-kiosk.sql`) and
the kiosk client was cut over to them (no more anon table reads).

### Phase 3b — Lock down RLS (the payoff) — ✅ APPLIED 2026-06-02
`dashboard/schema/2026-06-auth-phase3b-rls.sql`. Drops every permissive policy
and replaces with:
- **anon → zero table access** (login + kiosk go through SECURITY DEFINER RPCs).
- Operational tables (attendance, leaves, tasks, task_comments, announcements,
  announcement_reads, visitors) — any authenticated user (UI gated by `can()`).
- `employees`/`sections` read authenticated; writes owner/admin(/hr).
- `payslips`: own, or owner/admin. `advances`: own, or owner/admin/hr.
- `bonus_*`: owner/admin. `face_embeddings`: owner/admin/hr (kiosk via RPC).
- `user_access`: own row, or owner/admin (writes owner/admin only).
- customers + CRM: owner/admin/hr/cc.

**Validated** via in-transaction role impersonation (anon=0 everywhere; manager
sees all employees but only own payslip/access, no CRM/biometrics/bonus; owner
full). **Applied to prod only after** the kiosk punch is confirmed live.

Deferred to Phase 4: column-level employee-PII hiding (salary/bank from non-HR,
needs a restricted view + client query changes) and dropping `password_sha256`
(a dead login-picker fetch still selects it).

### Phase 4 — Cleanup & verify — ✅ MOSTLY DONE 2026-06-02
Done (`dashboard/schema/2026-06-auth-phase4-cleanup.sql`):
- Dropped `user_access.password_sha256` (Auth owns passwords; the dead PWA
  login-picker fetch that still selected it was stripped).
- Dropped the legacy `admin_change_role(username, hash, …)` RPC (no callers;
  `admin_change_role_v2` via `auth.uid()` replaced it).
- Bootstrap hash (`ADMIN_PASSWORD_SHA256`) was removed in Phase 2.
- Write-error surfacing was largely handled in the audit batches.
- Verified the RLS lockdown via in-transaction role impersonation: anon = 0
  everywhere; operational writes open to authenticated; payroll/credentials/
  employees/CRM/biometrics correctly scoped per role.
- `get_advisors` (security): the original world-readable/writable findings are
  gone; remaining warnings are intentional (operational tables open to
  authenticated; PIN/`auth.uid()`-gated `SECURITY DEFINER` RPCs).

Still open (follow-ups):
- **Employee-PII split** — hide salary/bank/statutory columns from non-HR
  (needs a restricted view + client query changes). `employees` is currently
  readable by any authenticated user.
- **Leaked-password protection** — enable in Supabase dashboard (Auth →
  Settings); it's a project toggle, not SQL.

## Testing & rollback
- Every DDL/policy change is applied on a Supabase **branch** first, both apps
  pointed at the branch URL, each role exercised, then `merge_branch` to prod.
- Permissive policies stay until Phase 3 is validated; Phase 3 can be reverted
  by re-adding the old `USING (true)` policies if something regresses.
- Client changes ship per-phase behind their own PRs.

## Open questions (need owner decision before Phase 0)
1. **Identity**: synthesized emails (simplest, owner-managed) vs. phone OTP
   (staff-friendly, needs SMS provider) vs. real emails?
2. **Password reset**: owner sets temp passwords for everyone (small team) vs.
   self-serve reset (needs email/SMS delivery)?
3. **PII in `employees`**: should non-HR roles see salary/bank/statutory columns
   at all? This decides whether we split a restricted view.

## Decisions (locked 2026-06-02)
1. **Identity** → **synthesized emails**: Auth email = `<employee_id>@staff.seematti.local`.
   Users still type their existing username/ID + password; the email is internal.
2. **Password reset** → **owner sets temp passwords** in-app; user changes on
   first login. No email/SMS provider required.
3. **PII** → **hide salary/bank/statutory columns from non-HR**. Only
   owner/admin/hr read those; split a restricted view for everyone else.
4. **Bootstrap Owner password** → **not rotated separately**; the migration
   (Phase 1 provisions a real Owner account, Phase 2 removes the hardcoded hash)
   supersedes it.

## Immediate stopgap (independent of this migration)
Rotate the bootstrap Owner password now: replace `window.ADMIN_PASSWORD_SHA256`
in `dashboard/index.html` (L600 — the only place it exists; the PWA logs in via
`user_access`) with the SHA-256 of a new strong password and redeploy. This only
blocks casual UI login with the known default — it does **not** close the
direct-REST hole, which requires Phase 3.
