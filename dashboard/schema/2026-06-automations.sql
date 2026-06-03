-- ───────────────────────────────────────────────────────────────────────────
-- Email automations. APPLIED to prod 2026-06-03. See docs/email-automation-setup.md.
--
-- Scheduled report emails: a pg_cron job (*/15) calls the run-automations edge
-- function, which builds the report and sends via Resend. Owner/Admin manage
-- rules on the dashboard (Account -> Email automations).
--
-- NOTE: the cron_secret value below is REDACTED — the real value is set in prod
-- and embedded in the cron job + public.app_config. The anon key in the cron
-- headers is the project's publishable key (public).
-- ───────────────────────────────────────────────────────────────────────────
create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.automations (
  id           uuid primary key default gen_random_uuid(),
  type         text not null check (type in ('daily_attendance','next_day_leave')),
  name         text,
  recipients   text[] not null default '{}',
  send_time    time not null default '09:30',
  enabled      boolean not null default true,
  last_sent_on date,
  created_by   text,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now()
);
alter table public.automations enable row level security;
create policy auto_read  on public.automations for select to authenticated using (true);
create policy auto_write on public.automations for all to authenticated
  using (app.current_user_type() in ('owner','admin')) with check (app.current_user_type() in ('owner','admin'));
grant select, insert, update, delete on public.automations to authenticated;

-- Private config: holds the internal cron secret. RLS on + no policies +
-- revoked grants => only the service role (the edge function) can read it.
create table if not exists public.app_config (key text primary key, value text);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;
insert into public.app_config(key, value)
  values ('cron_secret', '<REDACTED>')
  on conflict (key) do nothing;

-- Every 15 minutes -> the edge function (which decides what's due).
select cron.schedule('run-automations', '*/15 * * * *', $cron$
  select net.http_post(
    url := 'https://hixhbznbejqfnasvgyid.supabase.co/functions/v1/run-automations',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', '<PROJECT_ANON_KEY>',
      'Authorization', 'Bearer <PROJECT_ANON_KEY>',
      'x-cron-secret', (select value from public.app_config where key='cron_secret')
    ),
    body := '{}'::jsonb
  );
$cron$);
