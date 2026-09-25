-- ──────────────────────────────────────────────────────────────────────
-- MACHINE-FIRST ATTENDANCE — 25 Sep 2026 (owner decisions D1–D6)
-- ──────────────────────────────────────────────────────────────────────
-- Applied live 25 Sep 2026. Safe to re-run.
--  D1 outpass from the machine: staff press Break-Out (status 2) before
--     scanning out for an outpass and Break-In (3) when back; a plain scan
--     while on outpass also counts as the return.
--  D5 delete an employee: owner only.
--  D6 tablet decommissioned: settings.kiosk_enabled gates every kiosk RPC.
--  + attendance_mark(): HR/owner/admin/manager corrections (missed punch,
--    outpass) with source='manual' and marked_by.
--  + report functions for the Reports page (1M / 6M / any range).
--  + machine views for the Machine page.
-- ──────────────────────────────────────────────────────────────────────

-- ── settings ─────────────────────────────────────────────────────────
insert into public.settings (key, value, description) values
  ('kiosk_enabled', 'true', 'Tablet kiosk accepts scans (false = tablet shows "use the machine")'),
  ('early_cutoff_men', '22:00', 'Check-out before this = left early (men)'),
  ('early_cutoff_women', '20:00', 'Check-out before this = left early (women)')
on conflict (key) do nothing;

-- ── employees: where the code came from; owner-only delete ───────────
alter table public.employees add column if not exists code_source text;   -- 'hr' | 'quanto' | 'quanto_probable' | 'link'
drop policy if exists emp_write on public.employees;
drop policy if exists emp_insert on public.employees;
drop policy if exists emp_update on public.employees;
drop policy if exists emp_delete on public.employees;
create policy emp_insert on public.employees for insert to authenticated with check (app.is_hr_or_admin());
create policy emp_update on public.employees for update to authenticated using (app.is_hr_or_admin()) with check (app.is_hr_or_admin());
create policy emp_delete on public.employees for delete to authenticated using (app.current_user_type() = 'owner');

-- ── Quanto duplicate codes (written by the M1 sync, read by the Machine page)
create table if not exists public.quanto_code_conflicts (
  code        text primary key,
  holders     text not null,          -- "name (id) | name (id)"
  active_n    int  not null,
  seen_at     timestamptz not null default now()
);
alter table public.quanto_code_conflicts enable row level security;
drop policy if exists qcc_read on public.quanto_code_conflicts;
create policy qcc_read on public.quanto_code_conflicts for select to authenticated using (true);

-- ── kiosk gate (tablet decommission switch) ──────────────────────────
create or replace function public.kiosk_event(p_pin text, p_employee_id text, p_action text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_now    timestamp := (now() at time zone 'Asia/Kolkata');
  v_time   text := to_char(v_now, 'HH24:MI');
  v_start  text := coalesce((select value from public.settings where key='checkin_start'), '08:00');
  v_stamp  time := date_trunc('minute', v_now)::time;
  v_shift  date; v_state text; v_actions text[]; v_gender text; v_cut text; v_status text; v_in time;
begin
  if coalesce((select value from public.settings where key='kiosk_enabled'), 'true') <> 'true' then
    raise exception 'Tablet is switched off — use the attendance machine' using errcode='check_violation';
  end if;
  if p_pin is null or p_pin <> coalesce((select value from public.settings where key='kiosk_pin'), '__none__') then
    raise exception 'Invalid kiosk PIN' using errcode='insufficient_privilege';
  end if;
  if not exists (select 1 from public.employees where id=p_employee_id and coalesce(is_active,true)=true) then
    raise exception 'Unknown employee';
  end if;
  select s.shift_date, s.state, s.actions into v_shift, v_state, v_actions from public.kiosk_emp_state(p_employee_id) s;
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
        v_cut := coalesce((select value from public.settings where key='late_cutoff_men'), (select value from public.settings where key='late_cutoff'), '10:00');
      end if;
    end if;
    v_status := case when v_time >= v_cut then 'late' else 'present' end;
    insert into public.attendance (employee_id, date, status, punch_in_time, source)
      values (p_employee_id, v_shift, v_status, v_stamp, 'kiosk')
      on conflict (employee_id, date) do update
        set status=excluded.status, punch_in_time=coalesce(public.attendance.punch_in_time, excluded.punch_in_time), source='kiosk', updated_at=now();
  elsif p_action = 'check_out' then
    if exists (select 1 from public.attendance_events e where e.employee_id=p_employee_id and e.shift_date=v_shift and e.event_type='check_in'
                 and e.at_ts > (v_now at time zone 'UTC') - interval '30 minutes') then
      select status, punch_in_time into v_status, v_in from public.attendance where employee_id=p_employee_id and date=v_shift;
      return jsonb_build_object('action','check_in','time',to_char(coalesce(v_in, v_stamp),'HH24:MI'),'shift_date',v_shift,'status',v_status,'state',v_state,'actions',to_jsonb(v_actions),'note','already_in');
    end if;
    update public.attendance set punch_out_time=v_stamp, source='kiosk', updated_at=now() where employee_id=p_employee_id and date=v_shift;
    if not found then
      insert into public.attendance (employee_id, date, status, punch_out_time, source) values (p_employee_id, v_shift, 'present', v_stamp, 'kiosk')
        on conflict (employee_id, date) do update set punch_out_time=v_stamp, source='kiosk', updated_at=now();
    end if;
    select status into v_status from public.attendance where employee_id=p_employee_id and date=v_shift;
  end if;
  insert into public.attendance_events (employee_id, shift_date, event_type, at, at_ts, source) values (p_employee_id, v_shift, p_action, v_stamp, v_now, 'kiosk');
  select s.state, s.actions into v_state, v_actions from public.kiosk_emp_state(p_employee_id) s;
  return jsonb_build_object('action',p_action,'time',to_char(v_stamp,'HH24:MI'),'shift_date',v_shift,'status',v_status,'state',v_state,'actions',to_jsonb(v_actions));
end $$;

-- ── the shared writer: one function applies an event for any source ──
-- Used by adms_ingest (source 'essl') and attendance_mark (source 'manual').
create or replace function public.attendance_apply(
  p_employee_id text, p_action text, p_ts timestamp, p_source text, p_marked_by text default null, p_note text default null
) returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_start text := coalesce((select value from public.settings where key='checkin_start'), '08:00');
  v_time  text := to_char(p_ts, 'HH24:MI');
  v_stamp time := date_trunc('minute', p_ts)::time;
  v_shift date := case when v_time < v_start then p_ts::date - 1 else p_ts::date end;
  v_gender text; v_cut text; v_status text;
begin
  if p_action = 'check_in' then
    if extract(dow from v_shift) = 0 then
      v_cut := coalesce((select value from public.settings where key='late_cutoff_sunday'), '10:30');
    else
      select lower(coalesce(gender,'')) into v_gender from public.employees where id=p_employee_id;
      if v_gender in ('female','f','woman','women','ladies','lady') then
        v_cut := coalesce((select value from public.settings where key='late_cutoff_women'), '09:30');
      else
        v_cut := coalesce((select value from public.settings where key='late_cutoff_men'), (select value from public.settings where key='late_cutoff'), '10:00');
      end if;
    end if;
    v_status := case when v_time >= v_cut then 'late' else 'present' end;
    insert into public.attendance (employee_id, date, status, punch_in_time, source, marked_by, notes)
      values (p_employee_id, v_shift, v_status, v_stamp, p_source, p_marked_by, p_note)
      on conflict (employee_id, date) do update
        set status = case when public.attendance.status in ('on_leave') then public.attendance.status else excluded.status end,
            punch_in_time = coalesce(public.attendance.punch_in_time, excluded.punch_in_time),
            source = excluded.source, marked_by = coalesce(excluded.marked_by, public.attendance.marked_by),
            notes = coalesce(excluded.notes, public.attendance.notes), updated_at = now();
  elsif p_action = 'check_out' then
    update public.attendance set punch_out_time = v_stamp, source = p_source, marked_by = coalesce(p_marked_by, marked_by),
           notes = coalesce(p_note, notes), updated_at = now()
     where employee_id = p_employee_id and date = v_shift;
    if not found then
      insert into public.attendance (employee_id, date, status, punch_out_time, source, marked_by, notes)
        values (p_employee_id, v_shift, 'present', v_stamp, p_source, p_marked_by, p_note)
        on conflict (employee_id, date) do update set punch_out_time = v_stamp, source = excluded.source, updated_at = now();
    end if;
  end if;
  -- outpass events touch only the event log; the daily row stays as it is
  insert into public.attendance_events (employee_id, shift_date, event_type, at, at_ts, source)
  values (p_employee_id, v_shift, p_action, v_stamp, p_ts, p_source);
  select status into v_status from public.attendance where employee_id = p_employee_id and date = v_shift;
  return jsonb_build_object('action', p_action, 'shift_date', v_shift, 'time', to_char(v_stamp, 'HH24:MI'), 'status', v_status);
end $$;
revoke all on function public.attendance_apply(text, text, timestamp, text, text, text) from public, anon, authenticated;

-- ── HR corrections + outpass from the app ────────────────────────────
create or replace function public.attendance_mark(p_employee_id text, p_action text, p_at timestamp default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_role text := app.current_user_type(); v_by text := app.current_employee_id(); v_ts timestamp := coalesce(p_at, now() at time zone 'Asia/Kolkata');
begin
  if v_role is null or not (v_role in ('owner','admin','hr')
     or (v_role in ('manager','supervisor') and coalesce((select ua.can_edit_attendance from public.user_access ua where ua.auth_uid = auth.uid()), false))) then
    raise exception 'Not allowed' using errcode='insufficient_privilege';
  end if;
  if p_action not in ('check_in','check_out','outpass_out','outpass_in') then
    raise exception 'Unknown action %', p_action;
  end if;
  if not exists (select 1 from public.employees where id = p_employee_id and coalesce(is_active,true)) then
    raise exception 'Unknown employee';
  end if;
  if v_ts > (now() at time zone 'Asia/Kolkata') + interval '5 minutes' then
    raise exception 'Time is in the future';
  end if;
  return public.attendance_apply(p_employee_id, p_action, v_ts, 'manual', v_by, p_note);
end $$;
grant execute on function public.attendance_mark(text, text, timestamp, text) to authenticated;

-- ── the machine: in/out decided by shift state, outpass by the status key
create or replace function public.adms_ingest(
  p_secret text, p_sn text, p_user_id text, p_time text,
  p_status int default null, p_verify int default null, p_raw text default null
) returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_ts timestamp; v_time text; v_emp text; v_start text := coalesce((select value from public.settings where key='checkin_start'), '08:00');
  v_golive timestamp; v_shift date; v_has boolean; v_last text; v_action text; v_id uuid; v_dup boolean; v_res jsonb;
begin
  if p_secret is null or p_secret <> coalesce((select value from public.settings where key='adms_secret'), '__none__') then
    raise exception 'Invalid ADMS secret' using errcode='insufficient_privilege';
  end if;
  if not coalesce((select enabled from public.adms_devices where sn = p_sn), true) then
    return jsonb_build_object('outcome', 'device_disabled');
  end if;
  insert into public.adms_devices (sn, last_seen) values (p_sn, now()) on conflict (sn) do update set last_seen = now();

  v_ts := to_timestamp(p_time, 'YYYY-MM-DD HH24:MI:SS')::timestamp;
  if v_ts is null or v_ts < timestamp '2020-01-01' or v_ts > (now() at time zone 'Asia/Kolkata') + interval '10 minutes' then
    return jsonb_build_object('outcome', 'error:bad_timestamp', 'time', p_time);
  end if;
  v_time := to_char(v_ts, 'HH24:MI');

  insert into public.adms_punches (sn, device_user_id, punched_at, status_code, verify_mode, raw)
  values (p_sn, ltrim(p_user_id, '0'), v_ts, p_status, p_verify, p_raw)
  on conflict (sn, device_user_id, punched_at) do nothing returning id into v_id;
  if v_id is null then return jsonb_build_object('outcome', 'replay'); end if;

  select u.employee_id into v_emp from public.adms_users u where u.device_user_id = ltrim(p_user_id, '0');
  if v_emp is not null then update public.adms_punches set employee_id = v_emp where id = v_id; end if;

  begin v_golive := (select value from public.settings where key='adms_go_live_at')::timestamp;
  exception when others then v_golive := timestamp '2099-01-01'; end;
  if v_ts < coalesce(v_golive, timestamp '2099-01-01') then
    update public.adms_punches set outcome='archived' where id=v_id; return jsonb_build_object('outcome', 'archived');
  end if;
  if v_emp is null then
    update public.adms_punches set outcome='unknown_user' where id=v_id; return jsonb_build_object('outcome', 'unknown_user', 'device_user_id', p_user_id);
  end if;
  if not exists (select 1 from public.employees where id=v_emp and coalesce(is_active,true)=true) then
    update public.adms_punches set outcome='inactive' where id=v_id; return jsonb_build_object('outcome', 'inactive', 'employee_id', v_emp);
  end if;

  v_shift := case when v_time < v_start then v_ts::date - 1 else v_ts::date end;

  -- any recorded event for this person within 2 min = the same scan
  select exists (select 1 from public.attendance_events e where e.employee_id = v_emp
                   and abs(extract(epoch from (e.at_ts - (v_ts at time zone 'UTC')))) < 120) into v_dup;
  if v_dup then
    update public.adms_punches set outcome='duplicate' where id=v_id; return jsonb_build_object('outcome', 'duplicate', 'employee_id', v_emp);
  end if;

  select (a.punch_in_time is not null) into v_has from public.attendance a where a.employee_id=v_emp and a.date=v_shift;
  if not coalesce(v_has, false) then
    v_has := exists (select 1 from public.attendance_events e where e.employee_id=v_emp and e.shift_date=v_shift and e.event_type='check_in');
  end if;
  select e.event_type into v_last from public.attendance_events e where e.employee_id=v_emp and e.shift_date=v_shift order by e.seq desc limit 1;

  if not coalesce(v_has, false) then
    v_action := 'check_in';                                   -- first scan of the shift, whatever key was pressed
  elsif v_last = 'outpass_out' then
    v_action := 'outpass_in';                                 -- back from outpass (Break-In key, or any scan)
  elsif coalesce(p_status, 0) = 2 then
    v_action := 'outpass_out';                                -- Break-Out key: going out, coming back
  elsif exists (select 1 from public.attendance_events e where e.employee_id = v_emp and e.shift_date = v_shift and e.event_type = 'check_in'
                  and abs(extract(epoch from (e.at_ts - (v_ts at time zone 'UTC')))) < 1800) then
    update public.adms_punches set outcome='duplicate' where id=v_id;   -- second scan within 30 min of arrival
    return jsonb_build_object('outcome', 'duplicate', 'employee_id', v_emp);
  else
    v_action := 'check_out';                                  -- last scan wins
  end if;

  v_res := public.attendance_apply(v_emp, v_action, v_ts, 'essl');
  update public.adms_punches set outcome = v_action where id = v_id;
  return jsonb_build_object('outcome', v_action, 'employee_id', v_emp) || v_res;
exception when others then
  if v_id is not null then update public.adms_punches set outcome = 'error:' || sqlerrm where id = v_id; end if;
  return jsonb_build_object('outcome', 'error', 'message', sqlerrm);
end $$;

-- ── reports ──────────────────────────────────────────────────────────
-- Per person per day with timing. Page it from the client (max-rows applies).
create or replace function public.attendance_timing_report(p_from date, p_to date, p_employee_id text default null, p_section_id text default null)
returns table (
  date date, employee_id text, name text, employee_code text, section_id text, role text,
  status text, punch_in time, punch_out time, late_minutes int, early_leave boolean,
  outpasses int, outpass_minutes int, inside_minutes int, source text, marked_by text
) language sql stable security definer set search_path to 'public','pg_temp' as $$
  with s as (select
      coalesce((select value from public.settings where key='late_cutoff_men'), (select value from public.settings where key='late_cutoff'), '10:00')::time cut_m,
      coalesce((select value from public.settings where key='late_cutoff_women'), '09:30')::time cut_w,
      coalesce((select value from public.settings where key='late_cutoff_sunday'), '10:30')::time cut_sun,
      coalesce((select value from public.settings where key='early_cutoff_men'), '22:00')::time early_m,
      coalesce((select value from public.settings where key='early_cutoff_women'), '20:00')::time early_w),
  ops as (
    select employee_id, shift_date, count(*) filter (where event_type='outpass_out') n_out,
      coalesce(sum(case when event_type='outpass_in' then extract(epoch from (at_ts - lag_ts))/60 end),0)::int mins
    from (select e.*, lag(at_ts) over (partition by employee_id, shift_date order by seq) lag_ts,
                 lag(event_type) over (partition by employee_id, shift_date order by seq) lag_type
          from public.attendance_events e where e.shift_date between p_from and p_to) x
    where event_type in ('outpass_out','outpass_in') and (event_type='outpass_out' or lag_type='outpass_out')
    group by 1,2)
  select a.date, a.employee_id, e.name, e.employee_code, e.section_id, e.role, a.status, a.punch_in_time, a.punch_out_time,
    case when a.punch_in_time is null then null else greatest(0, (extract(epoch from (a.punch_in_time -
      case when extract(dow from a.date)=0 then s.cut_sun when lower(coalesce(e.gender,'')) in ('female','f','woman','women','ladies','lady') then s.cut_w else s.cut_m end))/60))::int end,
    (a.punch_out_time is not null and a.punch_out_time < case when lower(coalesce(e.gender,'')) in ('female','f','woman','women','ladies','lady') then s.early_w else s.early_m end and a.status in ('present','late')),
    coalesce(o.n_out,0)::int, coalesce(o.mins,0)::int,
    case when a.punch_in_time is not null and a.punch_out_time is not null then greatest(0, (extract(epoch from (a.punch_out_time - a.punch_in_time))/60)::int - coalesce(o.mins,0)) end,
    a.source, a.marked_by
  from public.attendance a
  join public.employees e on e.id = a.employee_id
  cross join s
  left join ops o on o.employee_id = a.employee_id and o.shift_date = a.date
  where a.date between p_from and p_to
    and (p_employee_id is null or a.employee_id = p_employee_id)
    and (p_section_id is null or e.section_id = p_section_id)
  order by a.employee_id, a.date
$$;
grant execute on function public.attendance_timing_report(date, date, text, text) to authenticated;

-- One row per person for the range: days, present, late, absent, leave, outpasses, timings.
create or replace function public.attendance_summary_report(p_from date, p_to date, p_section_id text default null)
returns table (
  employee_id text, name text, employee_code text, section_id text, role text, company text,
  days_in_range int, present int, late int, on_leave int, absent int, holidays int,
  late_minutes_total int, early_leaves int, outpasses int, outpass_minutes int,
  avg_in time, avg_out time, first_in time, last_out time, hours_inside numeric, days_without_out int
) language sql stable security definer set search_path to 'public','pg_temp' as $$
  with d as (select generate_series(p_from, least(p_to, (now() at time zone 'Asia/Kolkata')::date), '1 day')::date dt),
  hol as (select count(*) n from public.holidays h, d where h.day = d.dt),
  t as (select * from public.attendance_timing_report(p_from, p_to, null, p_section_id))
  select e.id, e.name, e.employee_code, e.section_id, e.role, e.company,
    (select count(*) from d where d.dt >= coalesce(e.joined_date, p_from))::int,
    count(*) filter (where t.status='present')::int,
    count(*) filter (where t.status='late')::int,
    count(*) filter (where t.status='on_leave')::int,
    greatest(0, (select count(*) from d where d.dt >= coalesce(e.joined_date, p_from))::int - (select n from hol)::int
      - count(*) filter (where t.status in ('present','late','on_leave'))::int),
    (select n from hol)::int,
    coalesce(sum(t.late_minutes),0)::int,
    count(*) filter (where t.early_leave)::int,
    coalesce(sum(t.outpasses),0)::int, coalesce(sum(t.outpass_minutes),0)::int,
    (avg(t.punch_in))::time, (avg(t.punch_out))::time, min(t.punch_in), max(t.punch_out),
    round(coalesce(sum(t.inside_minutes),0)/60.0, 1),
    count(*) filter (where t.punch_in is not null and t.punch_out is null and t.status in ('present','late'))::int
  from public.employees e
  left join t on t.employee_id = e.id
  where coalesce(e.is_active, true) and e.user_type <> 'owner'
    and (p_section_id is null or e.section_id = p_section_id)
  group by e.id, e.name, e.employee_code, e.section_id, e.role, e.company, e.joined_date
  order by e.section_id, e.name
$$;
grant execute on function public.attendance_summary_report(date, date, text) to authenticated;

-- ── Machine page views ────────────────────────────────────────────────
create or replace view public.v_machine_staff as
  select e.id, e.name, e.employee_code, e.section_id, e.is_active, e.code_source, e.quanto_employee_id,
    public.adms_pin(e.id) pin,
    (r.pin is not null) on_machine,
    (select max(p.punched_at) from public.adms_punches p where p.employee_id = e.id) last_punch,
    (select count(*) from public.adms_punches p where p.employee_id = e.id and p.punched_at >= (now() at time zone 'Asia/Kolkata')::date - 30) punches_30d
  from public.employees e
  left join public.adms_roster r on r.pin = public.adms_pin(e.id);
grant select on public.v_machine_staff to authenticated;

create or replace view public.v_machine_unknown_pins as
  select p.device_user_id pin, r.name device_name, count(*) punches_30d, max(p.punched_at) last_punch
  from public.adms_punches p left join public.adms_roster r on r.pin = p.device_user_id
  where p.employee_id is null and p.punched_at >= (now() at time zone 'Asia/Kolkata')::date - 30
  group by 1,2 order by 3 desc;
grant select on public.v_machine_unknown_pins to authenticated;

-- settings the app reads live (kiosk_enabled, go-live) are already readable by authenticated.
