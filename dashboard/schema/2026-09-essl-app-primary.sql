-- ──────────────────────────────────────────────────────────────────────
-- ESSL machine: the ADMIN APP IS THE MASTER LIST — 25 Sep 2026 (owner)
-- ──────────────────────────────────────────────────────────────────────
-- Applied live 25 Sep 2026. Safe to re-run.
--
--  • Every employee gets a machine PIN derived from their app id
--    (E-143 → E143, MD003 → MD003, 114 → 114). No hand mapping.
--  • The device is told about every employee through the command queue
--    (DATA UPDATE USERINFO); a trigger keeps that true for new staff.
--    Faces/fingers are still enrolled AT the machine, under that PIN.
--  • Legacy machine PINs already linked (SA455 …) keep working: one
--    employee may now hold two PINs.
--  • The tablet kiosk stays primary at the point of scan: a machine punch
--    within 30 min of a recorded check-in is the same arrival, not a
--    check-out — and the tablet applies the same rule the other way.
--  • Go-live: 26 Sep 2026 08:00 IST (shift boundary). Set it back to
--    2099-01-01 00:00:00 to switch the machine off again.
-- ──────────────────────────────────────────────────────────────────────

-- 1. one employee may hold two PINs (legacy + app-id)
alter table public.adms_users drop constraint if exists adms_users_employee_id_key;
create index if not exists adms_users_emp_idx on public.adms_users (employee_id);
alter table public.adms_users add column if not exists origin text not null default 'manual';

-- 2. the PIN rule
create or replace function public.adms_pin(p_employee_id text)
returns text language sql immutable as
$$ select upper(regexp_replace(coalesce(p_employee_id, ''), '[^A-Za-z0-9]', '', 'g')) $$;

-- 3. the USERINFO command, mirroring the device's own USER records
create or replace function public.adms_userinfo_cmd(p_employee_id text)
returns text language sql stable set search_path to 'public','pg_temp' as
$$ select 'DATA UPDATE USERINFO PIN=' || public.adms_pin(e.id)
       || E'\tName=' || left(regexp_replace(coalesce(e.name, ''), '[\t\r\n]', ' ', 'g'), 24)
       || E'\tPri=0\tPasswd=\tCard=\tGrp=1\tTZ=0000000000000000'
   from public.employees e where e.id = p_employee_id $$;

-- 4. link + push one employee (idempotent)
create or replace function public.adms_sync_employee(p_employee_id text, p_push boolean default true)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_pin text := public.adms_pin(p_employee_id); v_dev record;
begin
  if v_pin = '' or v_pin ~ '^0' then return; end if;
  insert into public.adms_users (device_user_id, employee_id, origin)
  values (v_pin, p_employee_id, 'app_id')
  on conflict (device_user_id) do nothing;
  if p_push then
    for v_dev in select sn from public.adms_devices where enabled loop
      insert into public.adms_commands (sn, cmd) values (v_dev.sn, public.adms_userinfo_cmd(p_employee_id));
    end loop;
  end if;
end $$;
revoke all on function public.adms_sync_employee(text, boolean) from public, anon, authenticated;

-- 5. trigger: every new or renamed employee reaches the machine
create or replace function public.adms_employee_trg()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if tg_op = 'INSERT' or new.id is distinct from old.id or new.name is distinct from old.name then
    perform public.adms_sync_employee(new.id, true);
  end if;
  return new;
end $$;
drop trigger if exists adms_employee_sync on public.employees;
create trigger adms_employee_sync after insert or update of id, name on public.employees
for each row execute function public.adms_employee_trg();

-- 6. link every current employee now (pushed to the device separately,
--    after a one-record test)
select count(public.adms_sync_employee(id, false)) from public.employees;

-- 7. the three legacy links that never agreed with the kiosk
delete from public.adms_users
 where (device_user_id, employee_id) in (('SS09','E007'), ('SA310','E077'), ('SA02','E019'));

-- 8. ingester with the cross-source guard
create or replace function public.adms_ingest(
  p_secret  text, p_sn text, p_user_id text, p_time text,
  p_status  int default null, p_verify int default null, p_raw text default null
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

  v_shift := case when v_time < v_start then v_ts::date - 1 else v_ts::date end;

  -- Cross-source guard (the tablet kiosk is primary at the point of scan).
  -- at_ts holds IST wall time written as if UTC (kiosk_event does the same),
  -- so compare v_ts the same way.
  --  (a) any recorded event for this person within 2 min of the punch;
  --  (b) a check-in already on this shift within 30 min of the punch —
  --      gate punch + tablet scan on arrival must never become a check-out.
  select exists (
    select 1 from public.attendance_events e
    where e.employee_id = v_emp
      and abs(extract(epoch from (e.at_ts - (v_ts at time zone 'UTC')))) < 120
  ) into v_dup;
  if not v_dup then
    select exists (
      select 1 from public.attendance_events e
      where e.employee_id = v_emp and e.shift_date = v_shift and e.event_type = 'check_in'
        and abs(extract(epoch from (e.at_ts - (v_ts at time zone 'UTC')))) < 1800
    ) into v_dup;
  end if;
  if v_dup then
    update public.adms_punches set outcome='duplicate', employee_id=v_emp where id=v_id;
    return jsonb_build_object('outcome', 'duplicate', 'employee_id', v_emp);
  end if;

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

-- 9. the tablet applies the same rule the other way: a check-out within
--    30 min of the shift's check-in (any source) is the same arrival.
create or replace function public.kiosk_event(p_pin text, p_employee_id text, p_action text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_now    timestamp := (now() at time zone 'Asia/Kolkata');
  v_time   text := to_char(v_now, 'HH24:MI');
  v_start  text := coalesce((select value from public.settings where key='checkin_start'), '08:00');
  v_stamp  time := date_trunc('minute', v_now)::time;
  v_shift  date;
  v_state  text;
  v_actions text[];
  v_gender text;
  v_cut    text;
  v_status text;
  v_in     time;
begin
  if p_pin is null or p_pin <> coalesce((select value from public.settings where key='kiosk_pin'), '__none__') then
    raise exception 'Invalid kiosk PIN' using errcode='insufficient_privilege';
  end if;
  if not exists (select 1 from public.employees where id=p_employee_id and coalesce(is_active,true)=true) then
    raise exception 'Unknown employee';
  end if;

  select s.shift_date, s.state, s.actions into v_shift, v_state, v_actions
    from public.kiosk_emp_state(p_employee_id) s;

  if not (p_action = any(v_actions)) then
    raise exception 'Action % not allowed (state %)', p_action, v_state using errcode='check_violation';
  end if;

  if p_action = 'check_in' then
    if extract(dow from v_shift) = 0 then
      v_cut := coalesce((select value from public.settings where key='late_cutoff_sunday'), '10:30');
    else
      select lower(coalesce(gender,'')) into v_gender from public.employees where id=p_employee_id;
      if v_gender in ('female','f','woman','women','ladies','lady') then
        v_cut := coalesce((select value from public.settings where key='late_cutoff_women'), '09:30');
      else
        v_cut := coalesce((select value from public.settings where key='late_cutoff_men'),
                          (select value from public.settings where key='late_cutoff'), '10:00');
      end if;
    end if;
    v_status := case when v_time >= v_cut then 'late' else 'present' end;
    insert into public.attendance (employee_id, date, status, punch_in_time, source)
      values (p_employee_id, v_shift, v_status, v_stamp, 'kiosk')
      on conflict (employee_id, date) do update
        set status=excluded.status,
            punch_in_time=coalesce(public.attendance.punch_in_time, excluded.punch_in_time),
            source='kiosk', updated_at=now();
  elsif p_action = 'check_out' then
    -- Same arrival scanned twice (gate machine, then tablet): keep the check-in.
    if exists (select 1 from public.attendance_events e
               where e.employee_id=p_employee_id and e.shift_date=v_shift and e.event_type='check_in'
                 and e.at_ts > (v_now at time zone 'UTC') - interval '30 minutes') then
      select status, punch_in_time into v_status, v_in from public.attendance where employee_id=p_employee_id and date=v_shift;
      return jsonb_build_object(
        'action', 'check_in', 'time', to_char(coalesce(v_in, v_stamp), 'HH24:MI'),
        'shift_date', v_shift, 'status', v_status,
        'state', v_state, 'actions', to_jsonb(v_actions), 'note', 'already_in'
      );
    end if;
    update public.attendance set punch_out_time=v_stamp, source='kiosk', updated_at=now()
      where employee_id=p_employee_id and date=v_shift;
    if not found then
      insert into public.attendance (employee_id, date, status, punch_out_time, source)
        values (p_employee_id, v_shift, 'present', v_stamp, 'kiosk')
        on conflict (employee_id, date) do update set punch_out_time=v_stamp, source='kiosk', updated_at=now();
    end if;
    select status into v_status from public.attendance where employee_id=p_employee_id and date=v_shift;
  end if;

  insert into public.attendance_events (employee_id, shift_date, event_type, at, at_ts, source)
    values (p_employee_id, v_shift, p_action, v_stamp, v_now, 'kiosk');

  select s.state, s.actions into v_state, v_actions from public.kiosk_emp_state(p_employee_id) s;

  return jsonb_build_object(
    'action', p_action, 'time', to_char(v_stamp, 'HH24:MI'),
    'shift_date', v_shift, 'status', v_status,
    'state', v_state, 'actions', to_jsonb(v_actions)
  );
end $$;

-- 10. go-live at the next shift boundary; device re-reads its options
--     (the corrected TimeZone) and one test USERINFO push.
update public.settings set value = '2026-09-26 08:00:00' where key = 'adms_go_live_at';
insert into public.adms_commands (sn, cmd)
select sn, c from public.adms_devices, unnest(array['INFO', 'RELOAD OPTIONS', public.adms_userinfo_cmd('E-244')]) c
where enabled;
