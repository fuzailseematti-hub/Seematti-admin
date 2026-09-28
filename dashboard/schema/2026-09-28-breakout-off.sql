-- 28 Sep 2026: on Friday evening the machine sent status 2 (Break-Out) for ~85 leaving scans, so those
-- people got "outpass out" instead of "check out" and their day never closed. Outpass is not started
-- yet (owner), so status keys are IGNORED until settings.outpass_from_machine = 'true'.
insert into public.settings (key, value, description) values ('outpass_from_machine', 'false', 'Honour the machine''s Break-Out key as outpass (true) or treat every scan as in/out (false)')
on conflict (key) do nothing;

create or replace function public.adms_ingest(
  p_secret text, p_sn text, p_user_id text, p_time text,
  p_status int default null, p_verify int default null, p_raw text default null
) returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_ts timestamp; v_time text; v_emp text; v_start text := coalesce((select value from public.settings where key='checkin_start'), '08:00');
  v_golive timestamp; v_shift date; v_has boolean; v_last text; v_action text; v_id uuid; v_dup boolean; v_res jsonb;
  v_outpass boolean := coalesce((select value from public.settings where key='outpass_from_machine'), 'false') = 'true';
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
  begin v_golive := (select value from public.settings where key='adms_go_live_at')::timestamp; exception when others then v_golive := timestamp '2099-01-01'; end;
  if v_ts < coalesce(v_golive, timestamp '2099-01-01') then update public.adms_punches set outcome='archived' where id=v_id; return jsonb_build_object('outcome', 'archived'); end if;
  if v_emp is null then update public.adms_punches set outcome='unknown_user' where id=v_id; return jsonb_build_object('outcome', 'unknown_user', 'device_user_id', p_user_id); end if;
  if not exists (select 1 from public.employees where id=v_emp and coalesce(is_active,true)=true) then update public.adms_punches set outcome='inactive' where id=v_id; return jsonb_build_object('outcome', 'inactive', 'employee_id', v_emp); end if;
  v_shift := case when v_time < v_start then v_ts::date - 1 else v_ts::date end;
  select exists (select 1 from public.attendance_events e where e.employee_id = v_emp and abs(extract(epoch from (e.at_ts - (v_ts at time zone 'UTC')))) < 120) into v_dup;
  if v_dup then update public.adms_punches set outcome='duplicate' where id=v_id; return jsonb_build_object('outcome', 'duplicate', 'employee_id', v_emp); end if;
  select (a.punch_in_time is not null) into v_has from public.attendance a where a.employee_id=v_emp and a.date=v_shift;
  if not coalesce(v_has, false) then v_has := exists (select 1 from public.attendance_events e where e.employee_id=v_emp and e.shift_date=v_shift and e.event_type='check_in'); end if;
  select e.event_type into v_last from public.attendance_events e where e.employee_id=v_emp and e.shift_date=v_shift order by e.seq desc limit 1;
  if not coalesce(v_has, false) then v_action := 'check_in';
  elsif v_outpass and v_last = 'outpass_out' then v_action := 'outpass_in';
  elsif v_outpass and coalesce(p_status, 0) = 2 then v_action := 'outpass_out';
  elsif exists (select 1 from public.attendance_events e where e.employee_id = v_emp and e.shift_date = v_shift and e.event_type = 'check_in'
                  and abs(extract(epoch from (e.at_ts - (v_ts at time zone 'UTC')))) < 1800) then
    update public.adms_punches set outcome='duplicate' where id=v_id; return jsonb_build_object('outcome', 'duplicate', 'employee_id', v_emp);
  else v_action := 'check_out'; end if;
  v_res := public.attendance_apply(v_emp, v_action, v_ts, 'essl');
  update public.adms_punches set outcome = v_action where id = v_id;
  return jsonb_build_object('outcome', v_action, 'employee_id', v_emp) || v_res;
exception when others then
  if v_id is not null then update public.adms_punches set outcome = 'error:' || sqlerrm where id = v_id; end if;
  return jsonb_build_object('outcome', 'error', 'message', sqlerrm);
end $$;

-- repair: every "outpass out" since go-live that was never followed by a return is really the day's check-out
with fix as (
  select e.id, e.employee_id, e.shift_date, e.at, e.at_ts from public.attendance_events e
  where e.event_type = 'outpass_out' and e.shift_date >= '2026-09-26'
    and not exists (select 1 from public.attendance_events r where r.employee_id = e.employee_id and r.shift_date = e.shift_date and r.event_type = 'outpass_in' and r.seq > e.seq)
), ev as (update public.attendance_events e set event_type = 'check_out' from fix where e.id = fix.id returning e.employee_id, e.shift_date, e.at),
   att as (update public.attendance a set punch_out_time = fix.at, updated_at = now() from fix where a.employee_id = fix.employee_id and a.date = fix.shift_date and (a.punch_out_time is null or a.punch_out_time < fix.at) returning a.employee_id),
   pun as (update public.adms_punches p set outcome = 'check_out' from fix where p.employee_id = fix.employee_id and p.outcome = 'outpass_out' and date_trunc('minute', p.punched_at) = (fix.shift_date + fix.at) returning p.id)
select (select count(*) from ev) events_fixed, (select count(*) from att) attendance_closed, (select count(*) from pun) punches_relabelled;
select date, count(*) marked, count(*) filter (where punch_out_time is not null) with_out from public.attendance where date >= '2026-09-26' group by 1 order by 1;
