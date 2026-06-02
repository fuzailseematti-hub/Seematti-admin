-- ───────────────────────────────────────────────────────────────────────────
-- Supabase Auth migration — PHASE 1 (provision auth users + backfill auth_uid)
--
-- See docs/auth-migration-plan.md. APPLIED to the live project on 2026-06-02.
--
-- What this does:
--   • Creates a Supabase Auth user for each existing public.user_access row,
--     using the locked identity scheme: email = <employee_id>@staff.seematti.local
--     (decisions, plan §"Decisions (locked 2026-06-02)").
--   • Marks each email pre-confirmed and adds the matching auth.identities row
--     (the @staff.seematti.local domain cannot receive a confirmation email).
--   • Backfills public.user_access.auth_uid (added in Phase 0) with the new id.
--
-- Why direct SQL (not the Auth Admin API):
--   The migration was run from an environment whose network policy can reach
--   the project only through the Postgres/MCP channel, not the GoTrue admin
--   REST endpoint or Edge Function gateway. Inserting into auth.users +
--   auth.identities with a pgcrypto bcrypt hash is equivalent to what the
--   admin API does for an email/password user. Verified afterwards: aud/role
--   = 'authenticated', encrypted_password is a $2 bcrypt hash, email_confirmed_at
--   set, identity provider='email' with provider_id = user id, and every
--   user_access row linked.
--
-- This file is SANITISED: the real temporary passwords were generated per-user
-- and delivered to the owner out-of-band (never committed). They are dormant
-- until the Phase 2 client cutover and are to be changed on first login.
--
-- NOTE: NOT idempotent as written — auth.users.email is unique, so re-running
-- errors on the existing rows. It is recorded here for audit/reproducibility.
-- ───────────────────────────────────────────────────────────────────────────

with creds(email, pw) as (
  -- One row per user_access record. Passwords redacted; substitute real
  -- temporary passwords (delivered out-of-band) when reproducing.
  values
    ('md003@staff.seematti.local', '<TEMP_PASSWORD>'),  -- owner   (username: fuzail)
    ('e018@staff.seematti.local',  '<TEMP_PASSWORD>'),  -- admin   (username: admin)
    ('e025@staff.seematti.local',  '<TEMP_PASSWORD>'),  -- hr      (username: hr)
    ('e016@staff.seematti.local',  '<TEMP_PASSWORD>'),  -- cc      (username: cc)
    ('e026@staff.seematti.local',  '<TEMP_PASSWORD>')   -- manager (username: fancy)
),
new_users as (
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    is_sso_user, is_anonymous,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, reauthentication_token, phone_change, phone_change_token
  )
  select
    '00000000-0000-0000-0000-000000000000'::uuid,
    gen_random_uuid(),
    'authenticated', 'authenticated',
    c.email,
    extensions.crypt(c.pw, extensions.gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('employee_id', upper(split_part(c.email, '@', 1))),
    false, false,
    '', '', '', '', '', '', '', ''
  from creds c
  returning id, email
),
new_idents as (
  insert into auth.identities (
    provider_id, user_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  )
  select
    u.id::text, u.id,
    jsonb_build_object('sub', u.id::text, 'email', u.email,
                       'email_verified', true, 'phone_verified', false),
    'email', now(), now(), now()
  from new_users u
  returning user_id
)
update public.user_access ua
set auth_uid = nu.id
from new_users nu
where ua.employee_id = upper(split_part(nu.email, '@', 1))
returning ua.employee_id, ua.username, ua.auth_uid;

-- ───────────────────────────────────────────────────────────────────────────
-- Rollback (Phase 1 only — leaves Phase 0 plumbing intact):
--   update public.user_access set auth_uid = null
--     where auth_uid in (select id from auth.users
--                        where email like '%@staff.seematti.local');
--   delete from auth.identities where user_id in
--     (select id from auth.users where email like '%@staff.seematti.local');
--   delete from auth.users where email like '%@staff.seematti.local';
-- ───────────────────────────────────────────────────────────────────────────
