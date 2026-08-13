-- ──────────────────────────────────────────────────────────────────────
-- ESSL uFace302 (ADMS push) ingestion — August 2026
-- ──────────────────────────────────────────────────────────────────────
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).
--
-- Architecture
--   uFace302 ──HTTP (ADMS push)──▶ Cloudflare Worker bridge (adms-bridge/)
--             ──HTTPS RPC───────▶ adms_ingest() below
--   Server → device commands (e.g. USERINFO queries) ride the device's
--   getrequest poll: queue in adms_commands, replies in adms_oplogs.
--
-- The device pushes raw punches (numeric user id + local timestamp).
-- All attendance rules stay server-side, mirroring kiosk_event():
--   • first punch of a shift  = check_in  (late cutoffs: women 09:30,
--     men 10:00, Sunday 10:30 — read from settings, same keys)
--   • later punches           = check_out (last punch wins)
--   • shift date rolls at settings.checkin_start (08:00)
-- Outpasses are NOT inferred from device punches in v1 — HR marks them
-- in the app as before.
--
-- Timestamps: the device clock is IST. ATTLOG times arrive as naive
-- 'YYYY-MM-DD HH24:MI:SS' strings and are treated exactly like
-- kiosk_event treats (now() at time zone 'Asia/Kolkata') — inserted
-- as-is so essl rows compare 1:1 with kiosk rows.
-- ──────────────────────────────────────────────────────────────────────

-- ── Allow 'essl' as an attendance source ──────────────────────────────
alter table public.attendance drop constraint if exists attendance_source_check;
alter table public.attendance add constraint attendance_source_check
  check (source = any (array['manual'::text, 'kiosk'::text, 'self'::text, 'essl'::text]));

-- ── Device registry (serial-number allowlist + heartbeat) ─────────────
create table if not exists public.adms_devices (
  sn         text primary key,
  name       text,
  enabled    boolean not null default true,
  last_seen  timestamptz,
  created_at timestamptz not null default now()
);

-- ── Device-user-id ↔ employee mapping ─────────────────────────────────
-- Device user ids are alphanumeric PINs as enrolled on the device
-- ('SA455', 'SS225', '377'…). employee ids are free-text ('E024',
-- '115', 'E-143'…), so this table is the single source of truth for
-- the mapping. (The original numeric-only check was relaxed on 4 Aug
-- once the real device roster showed alphanumeric PINs.)
create table if not exists public.adms_users (
  device_user_id text primary key,
  employee_id    text not null unique references public.employees(id) on delete cascade,
  created_at     timestamptz not null default now()
);
alter table public.adms_users drop constraint if exists adms_users_device_user_id_check;
alter table public.adms_users add constraint adms_users_device_user_id_check
  check (device_user_id ~ '^[A-Za-z0-9]+$' and device_user_id !~ '^0');

-- ── Raw punch log (every push stored as-received, forever) ────────────
create table if not exists public.adms_punches (
  id             uuid primary key default gen_random_uuid(),
  sn             text not null,
  device_user_id text not null,
  punched_at     timestamp not null,          -- device-local (IST), naive
  status_code    int,
  verify_mode    int,
  employee_id    text,                        -- resolved at ingest time
  outcome        text,                        -- check_in / check_out / duplicate / replay / unknown_user / inactive / device_disabled / error:*
  raw            text,
  received_at    timestamptz not null default now(),
  unique (sn, device_user_id, punched_at)     -- replay-proof
);
create index if not exists adms_punches_emp_idx on public.adms_punches (employee_id, punched_at desc);

-- ── Lock the new tables down like the rest of the project ─────────────
alter table public.adms_devices enable row level security;
alter table public.adms_users   enable row level security;
alter table public.adms_punches enable row level security;
drop policy if exists adms_devices_auth on public.adms_devices;
drop policy if exists adms_users_auth   on public.adms_users;
drop policy if exists adms_punches_auth on public.adms_punches;
create policy adms_devices_auth on public.adms_devices for select to authenticated using (true);
create policy adms_users_auth   on public.adms_users   for select to authenticated using (true);
create policy adms_punches_auth on public.adms_punches for select to authenticated using (true);

-- ── Bridge secret (generated once; read it from settings and put the
--    same value into the Worker's ADMS_SECRET env var) ─────────────────
insert into public.settings (key, value, description)
values ('adms_secret', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
        'Shared secret between the ADMS bridge worker and adms_ingest()')
on conflict (key) do nothing;

-- ── Go-live gate ──────────────────────────────────────────────────────
-- The device is live in the store and holds months of stored punches;
-- on first cloud connect it uploads ALL of them. Punches earlier than
-- this IST timestamp are archived in adms_punches (outcome='archived')
-- but never applied to attendance. Starts in the far future =
-- archive-everything; set it to now() at cutover.
insert into public.settings (key, value, description)
values ('adms_go_live_at', '2099-01-01 00:00:00',
        'ESSL punches before this IST timestamp are archived, not applied to attendance')
on conflict (key) do nothing;

-- ── One-time mapping generator ────────────────────────────────────────
-- Digits-of-id where unambiguous ('E024'→24, 'E-143'→143, '115'→115),
-- sequential ids from 500 upward for collisions/blank. Re-runnable:
-- only fills employees that have no mapping yet.
create or replace function public.adms_generate_mappings()
returns table(device_user_id text, employee_id text, method text)
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
declare v_next int;
begin
  -- pass 1: digit extraction, only when it yields a unique, unclaimed id
  return query
  with cand as (
    select e.id as emp_id,
           ltrim(regexp_replace(e.id, '\D', '', 'g'), '0') as digits
    from public.employees e
    where coalesce(e.is_active, true) = true
      and not exists (select 1 from public.adms_users u where u.employee_id = e.id)
  ),
  uniq as (
    select c.emp_id, c.digits
    from cand c
    where c.digits <> ''
      and not exists (select 1 from public.adms_users u where u.device_user_id = c.digits)
      and (select count(*) from cand c2 where c2.digits = c.digits) = 1
  ),
  ins as (
    insert into public.adms_users (device_user_id, employee_id)
    select u.digits, u.emp_id from uniq u
    returning adms_users.device_user_id, adms_users.employee_id
  )
  select ins.device_user_id, ins.employee_id, 'digits'::text from ins;

  -- pass 2: sequential fallback for whoever is left
  select coalesce(max(u.device_user_id::int), 499) + 1 into v_next from public.adms_users u
    where u.device_user_id::int >= 500;
  return query
  with rest as (
    select e.id as emp_id,
           row_number() over (order by e.created_at, e.id) - 1 as rn
    from public.employees e
    where coalesce(e.is_active, true) = true
      and not exists (select 1 from public.adms_users u where u.employee_id = e.id)
  ),
  ins as (
    insert into public.adms_users (device_user_id, employee_id)
    select (v_next + r.rn)::text, r.emp_id from rest r
    returning adms_users.device_user_id, adms_users.employee_id
  )
  select ins.device_user_id, ins.employee_id, 'sequential'::text from ins;
end $$;
revoke all on function public.adms_generate_mappings() from public, anon, authenticated;

-- ── Heartbeat from the bridge (device polls every few seconds) ────────
create or replace function public.adms_heartbeat(p_secret text, p_sn text)
returns void
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
begin
  if p_secret is null or p_secret <> coalesce((select value from public.settings where key='adms_secret'), '__none__') then
    raise exception 'Invalid ADMS secret' using errcode='insufficient_privilege';
  end if;
  if p_sn is null or length(p_sn) < 4 or length(p_sn) > 64 then
    raise exception 'Invalid device SN';
  end if;
  insert into public.adms_devices (sn, last_seen) values (p_sn, now())
  on conflict (sn) do update set last_seen = now();
end $$;
grant execute on function public.adms_heartbeat(text, text) to anon, authenticated;

-- ── The ingester: one raw device punch in, attendance rules applied ───
create or replace function public.adms_ingest(
  p_secret  text,
  p_sn      text,
  p_user_id text,          -- device user id, digits
  p_time    text,          -- 'YYYY-MM-DD HH24:MI:SS', device-local (IST)
  p_status  int default null,
  p_verify  int default null,
  p_raw     text default null
) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
declare
  v_ts      timestamp;
  v_stamp   time;
  v_time    text;
  v_emp     text;
  v_start   text := coalesce((select value from public.settings where key='checkin_start'), '08:00');
  v_golive  timestamp;
  v_shift   date;
  v_has     boolean;
  v_gender  text;
  v_cut     text;
  v_status  text;
  v_action  text;
  v_id      uuid;
  v_dup     boolean;
begin
  if p_secret is null or p_secret <> coalesce((select value from public.settings where key='adms_secret'), '__none__') then
    raise exception 'Invalid ADMS secret' using errcode='insufficient_privilege';
  end if;

  if not coalesce((select enabled from public.adms_devices where sn = p_sn), true) then
    return jsonb_build_object('outcome', 'device_disabled');
  end if;
  insert into public.adms_devices (sn, last_seen) values (p_sn, now())
  on conflict (sn) do update set last_seen = now();

  v_ts := to_timestamp(p_time, 'YYYY-MM-DD HH24:MI:SS')::timestamp;
  if v_ts is null or v_ts < timestamp '2020-01-01'
     or v_ts > (now() at time zone 'Asia/Kolkata') + interval '10 minutes' then
    return jsonb_build_object('outcome', 'error:bad_timestamp', 'time', p_time);
  end if;
  v_stamp := date_trunc('minute', v_ts)::time;
  v_time  := to_char(v_ts, 'HH24:MI');

  -- raw log first; a replayed upload (same sn+user+second) stops here
  insert into public.adms_punches (sn, device_user_id, punched_at, status_code, verify_mode, raw)
  values (p_sn, ltrim(p_user_id, '0'), v_ts, p_status, p_verify, p_raw)
  on conflict (sn, device_user_id, punched_at) do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('outcome', 'replay');
  end if;

  select u.employee_id into v_emp from public.adms_users u where u.device_user_id = ltrim(p_user_id, '0');
  if v_emp is not null then
    update public.adms_punches set employee_id = v_emp where id = v_id;
  end if;

  -- go-live gate: historical uploads are archived, never applied
  begin
    v_golive := (select value from public.settings where key='adms_go_live_at')::timestamp;
  exception when others then
    v_golive := timestamp '2099-01-01';
  end;
  if v_ts < coalesce(v_golive, timestamp '2099-01-01') then
    update public.adms_punches set outcome='archived' where id=v_id;
    return jsonb_build_object('outcome', 'archived');
  end if;

  if v_emp is null then
    update public.adms_punches set outcome='unknown_user' where id=v_id;
    return jsonb_build_object('outcome', 'unknown_user', 'device_user_id', p_user_id);
  end if;

  if not exists (select 1 from public.employees where id=v_emp and coalesce(is_active,true)=true) then
    update public.adms_punches set outcome='inactive' where id=v_id;
    return jsonb_build_object('outcome', 'inactive', 'employee_id', v_emp);
  end if;

  -- double-scan guard: an applied punch for this person within 2 minutes
  select exists (
    select 1 from public.adms_punches p
    where p.employee_id = v_emp and p.outcome in ('check_in','check_out')
      and p.id <> v_id
      and abs(extract(epoch from (p.punched_at - v_ts))) < 120
  ) into v_dup;
  if v_dup then
    update public.adms_punches set outcome='duplicate' where id=v_id;
    return jsonb_build_object('outcome', 'duplicate', 'employee_id', v_emp);
  end if;

  -- shift + state as-of the punch time (mirrors kiosk_emp_state)
  v_shift := case when v_time < v_start then v_ts::date - 1 else v_ts::date end;

  select (a.punch_in_time is not null) into v_has
    from public.attendance a where a.employee_id=v_emp and a.date=v_shift;
  if not coalesce(v_has, false) then
    v_has := exists (select 1 from public.attendance_events e
                     where e.employee_id=v_emp and e.shift_date=v_shift and e.event_type='check_in');
  end if;

  if not coalesce(v_has, false) then
    v_action := 'check_in';
    if extract(dow from v_shift) = 0 then
      v_cut := coalesce((select value from public.settings where key='late_cutoff_sunday'), '10:30');
    else
      select lower(coalesce(gender,'')) into v_gender from public.employees where id=v_emp;
      if v_gender in ('female','f','woman','women','ladies','lady') then
        v_cut := coalesce((select value from public.settings where key='late_cutoff_women'), '09:30');
      else
        v_cut := coalesce((select value from public.settings where key='late_cutoff_men'),
                          (select value from public.settings where key='late_cutoff'), '10:00');
      end if;
    end if;
    v_status := case when v_time >= v_cut then 'late' else 'present' end;
    insert into public.attendance (employee_id, date, status, punch_in_time, source)
      values (v_emp, v_shift, v_status, v_stamp, 'essl')
      on conflict (employee_id, date) do update
        set status=excluded.status,
            punch_in_time=coalesce(public.attendance.punch_in_time, excluded.punch_in_time),
            source='essl', updated_at=now();
  else
    v_action := 'check_out';
    update public.attendance set punch_out_time=v_stamp, source='essl', updated_at=now()
      where employee_id=v_emp and date=v_shift;
    if not found then
      insert into public.attendance (employee_id, date, status, punch_out_time, source)
        values (v_emp, v_shift, 'present', v_stamp, 'essl')
        on conflict (employee_id, date) do update set punch_out_time=v_stamp, source='essl', updated_at=now();
    end if;
    select status into v_status from public.attendance where employee_id=v_emp and date=v_shift;
  end if;

  insert into public.attendance_events (employee_id, shift_date, event_type, at, at_ts, source)
  values (v_emp, v_shift, v_action, v_stamp, v_ts, 'essl');

  update public.adms_punches set outcome=v_action where id=v_id;

  return jsonb_build_object(
    'outcome', v_action, 'employee_id', v_emp, 'shift_date', v_shift,
    'time', to_char(v_stamp, 'HH24:MI'), 'status', v_status
  );
exception when others then
  if v_id is not null then
    update public.adms_punches set outcome = 'error:' || sqlerrm where id = v_id;
  end if;
  return jsonb_build_object('outcome', 'error', 'message', sqlerrm);
end $$;
grant execute on function public.adms_ingest(text, text, text, text, int, int, text) to anon, authenticated;

-- ── Raw non-ATTLOG uploads (user records, op-logs, command replies) ───
-- The bridge stores every non-punch upload here verbatim. USERINFO
-- replies ("USER PIN=…\tName=…") land here too — that is where the
-- device's own user roster (id + name) can be read back from.
create table if not exists public.adms_oplogs (
  id          uuid primary key default gen_random_uuid(),
  sn          text not null,
  kind        text not null,
  body        text,
  received_at timestamptz not null default now()
);

-- ── Command queue (server → device, over the getrequest poll) ─────────
-- Queue a row (e.g. cmd = 'DATA QUERY USERINFO PIN=SA455'); the device
-- picks it up on its next poll via adms_next_command and its reply is
-- matched back onto the row by adms_store_upload.
create table if not exists public.adms_commands (
  id         bigint generated always as identity primary key,
  sn         text not null,
  cmd        text not null,
  sent_at    timestamptz,
  result     text,
  done_at    timestamptz,
  created_at timestamptz not null default now()
);

alter table public.adms_oplogs   enable row level security;
alter table public.adms_commands enable row level security;
drop policy if exists adms_oplogs_auth   on public.adms_oplogs;
drop policy if exists adms_commands_auth on public.adms_commands;
create policy adms_oplogs_auth   on public.adms_oplogs   for select to authenticated using (true);
create policy adms_commands_auth on public.adms_commands for select to authenticated using (true);

-- ── Store a raw upload; match devicecmd replies onto their command ────
create or replace function public.adms_store_upload(p_secret text, p_sn text, p_kind text, p_body text)
returns void
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
declare v_id bigint;
begin
  if p_secret is null or p_secret <> coalesce((select value from public.settings where key='adms_secret'), '__none__') then
    raise exception 'Invalid ADMS secret' using errcode='insufficient_privilege';
  end if;
  insert into public.adms_oplogs (sn, kind, body) values (p_sn, p_kind, left(p_body, 200000));
  -- devicecmd bodies look like: ID=<id>&Return=<code>&CMD=<...>
  if p_kind = 'devicecmd' and p_body ~ 'ID=[0-9]+' then
    v_id := (regexp_match(p_body, 'ID=([0-9]+)'))[1]::bigint;
    update public.adms_commands set result = left(p_body, 2000), done_at = now()
     where id = v_id and sn = p_sn;
  end if;
end $$;
grant execute on function public.adms_store_upload(text, text, text, text) to anon, authenticated;

-- ── Hand the device its next queued command (or 'OK') ─────────────────
create or replace function public.adms_next_command(p_secret text, p_sn text)
returns text
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
declare v_id bigint; v_cmd text;
begin
  if p_secret is null or p_secret <> coalesce((select value from public.settings where key='adms_secret'), '__none__') then
    raise exception 'Invalid ADMS secret' using errcode='insufficient_privilege';
  end if;
  insert into public.adms_devices (sn, last_seen) values (p_sn, now())
  on conflict (sn) do update set last_seen = now();

  select id, cmd into v_id, v_cmd from public.adms_commands
   where sn = p_sn and sent_at is null
   order by id limit 1;
  if v_id is null then
    return 'OK';
  end if;
  update public.adms_commands set sent_at = now() where id = v_id;
  return 'C:' || v_id || ':' || v_cmd;
end $$;
grant execute on function public.adms_next_command(text, text) to anon, authenticated;
