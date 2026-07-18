-- ───────────────────────────────────────────────────────────────────────────
-- Kiosk heartbeat — APPLIED to prod 2026-07-18 (via MCP migration
-- `kiosk_heartbeat`).
--
-- Why: on 2026-07-18 the kiosk tablet froze at 09:30 after ~14 days of
-- continuous uptime. HR marked 85 people manually and the whole day's
-- check-outs were lost — nobody noticed the silence until closing time.
--
-- The kiosk now pings kiosk_heartbeat(pin, device_id, loaded_at, ua) every
-- minute. The dashboard reads kiosk_heartbeats to show "last seen X min ago"
-- on the Kiosk settings page and a red warning banner on Attendance + Daily
-- report when the newest heartbeat is older than 5 minutes during store
-- hours (08:00–23:00 IST).
--
-- Writes go only through the PIN-gated SECURITY DEFINER RPC (the kiosk runs
-- unauthenticated, same model as kiosk_match / kiosk_event). Authenticated
-- dashboard users can read.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.kiosk_heartbeats (
  device_id  text primary key,
  last_seen  timestamptz not null default now(),
  loaded_at  timestamptz,          -- when the kiosk page booted (verifies nightly refresh)
  ua         text,
  created_at timestamptz not null default now()
);

alter table public.kiosk_heartbeats enable row level security;
drop policy if exists kh_read on public.kiosk_heartbeats;
create policy kh_read on public.kiosk_heartbeats for select to authenticated using (true);
grant select on public.kiosk_heartbeats to authenticated;

create or replace function public.kiosk_heartbeat(
  p_pin text, p_device_id text, p_loaded_at timestamptz default null, p_ua text default null
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_pin is null or p_pin <> coalesce((select value from public.settings where key='kiosk_pin'), '__none__') then
    raise exception 'Invalid kiosk PIN' using errcode='insufficient_privilege';
  end if;
  if p_device_id is null or length(p_device_id) < 4 or length(p_device_id) > 64 then
    raise exception 'Invalid device id';
  end if;
  insert into public.kiosk_heartbeats (device_id, last_seen, loaded_at, ua)
  values (p_device_id, now(), p_loaded_at, left(p_ua, 300))
  on conflict (device_id) do update
    set last_seen = now(),
        loaded_at = coalesce(excluded.loaded_at, public.kiosk_heartbeats.loaded_at),
        ua        = coalesce(excluded.ua, public.kiosk_heartbeats.ua);
end $$;

revoke all on function public.kiosk_heartbeat(text, text, timestamptz, text) from public;
grant execute on function public.kiosk_heartbeat(text, text, timestamptz, text) to anon, authenticated;
