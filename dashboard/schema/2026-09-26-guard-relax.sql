-- 26 Sep 2026: the PIN guard blocked 14 of HR's 16 codes because the machine spells the
-- same person differently (B.ABINASH vs ABINASH.B). Relax it to name CORES (initials,
-- '-SEASON', punctuation removed), a trigram similarity, or a shared token; a resolved
-- conflict now LINKS the person (trigger) instead of only closing the row; and a replay
-- function turns punches that arrived as unknown_user before the link into attendance.

create extension if not exists pg_trgm;

create or replace function public.adms_name_core(p text) returns text language sql immutable as $$
  select regexp_replace(
           array_to_string(array(
             select t from unnest(regexp_split_to_array(
               lower(regexp_replace(regexp_replace(coalesce(p,''), '\(.*?\)', ' ', 'g'), '-?\s*(season|security|crm)\b', ' ', 'gi')),
               '[^a-z]+')) t where length(t) > 1), ''),
           '[^a-z]', '', 'g')
$$;

create or replace function public.adms_same_person(p_a text, p_b text) returns boolean language sql immutable as $$
  with c as (select public.adms_name_core(p_a) a, public.adms_name_core(p_b) b)
  select a <> '' and b <> '' and (
    a = b or a like '%'||b||'%' or b like '%'||a||'%'
    or similarity(a, b) >= 0.45
    or exists (select 1 from unnest(regexp_split_to_array(lower(p_a), '[^a-z]+')) x
               join unnest(regexp_split_to_array(lower(p_b), '[^a-z]+')) y on x = y where length(x) >= 4))
  from c
$$;

create or replace function public.adms_sync_employee(p_employee_id text, p_push boolean default true)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_pin text := public.adms_pin(p_employee_id); v_dev record; v_app text; v_devname text;
begin
  if v_pin is null then return; end if;
  select name into v_app from public.employees where id = p_employee_id;
  select name into v_devname from public.adms_roster where pin = v_pin;
  if v_devname is not null and not public.adms_same_person(v_devname, v_app)
     and not exists (select 1 from public.adms_users u where u.device_user_id = v_pin and u.employee_id = p_employee_id) then
    insert into public.adms_pin_conflicts (pin, employee_id, app_name, device_name, reason)
    values (v_pin, p_employee_id, v_app, v_devname, 'machine holds this PIN under another name');
    return;
  end if;
  delete from public.adms_users where employee_id = p_employee_id and origin in ('code','app_id') and device_user_id <> v_pin;
  insert into public.adms_users (device_user_id, employee_id, origin) values (v_pin, p_employee_id, 'code')
  on conflict (device_user_id) do nothing;
  -- punches that arrived before the link belong to the person
  update public.adms_punches set employee_id = p_employee_id where device_user_id = v_pin and employee_id is null;
  if p_push then
    for v_dev in select sn from public.adms_devices where enabled loop
      insert into public.adms_commands (sn, cmd) values (v_dev.sn, public.adms_userinfo_cmd(p_employee_id));
      insert into public.adms_commands (sn, cmd) values (v_dev.sn, 'DATA QUERY USERINFO PIN=' || v_pin);
    end loop;
  end if;
end $$;
revoke all on function public.adms_sync_employee(text, boolean) from public, anon, authenticated;

-- Resolve on the Machine page = "yes, same person": link + push, and replay today's punches.
create or replace function public.adms_conflict_resolved_trg() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.resolved_at is not null and old.resolved_at is null then
    insert into public.adms_users (device_user_id, employee_id, origin) values (new.pin, new.employee_id, 'code')
    on conflict (device_user_id) do nothing;
    update public.adms_punches set employee_id = new.employee_id where device_user_id = new.pin and employee_id is null;
    insert into public.adms_commands (sn, cmd)
      select sn, public.adms_userinfo_cmd(new.employee_id) from public.adms_devices where enabled;
    perform public.adms_reapply((now() at time zone 'Asia/Kolkata')::date::timestamp, new.pin);
  end if;
  return new;
end $$;

-- Replay: punches stored as unknown_user (or archived after go-live) for pins that are linked now.
create or replace function public.adms_reapply(p_from timestamp, p_pin text default null)
returns table (pin text, employee_id text, punched_at timestamp, action text)
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare r record; v_start text := coalesce((select value from public.settings where key='checkin_start'), '08:00');
        v_golive timestamp; v_shift date; v_has boolean; v_last text; v_action text; v_time text;
begin
  begin v_golive := (select value from public.settings where key='adms_go_live_at')::timestamp; exception when others then v_golive := timestamp '2099-01-01'; end;
  for r in
    select p.id, p.device_user_id, u.employee_id, p.punched_at, p.status_code
    from public.adms_punches p join public.adms_users u on u.device_user_id = p.device_user_id
    where p.outcome = 'unknown_user' and p.punched_at >= p_from and p.punched_at >= v_golive
      and (p_pin is null or p.device_user_id = p_pin)
      and exists (select 1 from public.employees e where e.id = u.employee_id and coalesce(e.is_active, true))
    order by p.punched_at
  loop
    v_time := to_char(r.punched_at, 'HH24:MI');
    v_shift := case when v_time < v_start then r.punched_at::date - 1 else r.punched_at::date end;
    if exists (select 1 from public.attendance_events e where e.employee_id = r.employee_id
                 and abs(extract(epoch from (e.at_ts - (r.punched_at at time zone 'UTC')))) < 120) then
      update public.adms_punches set outcome = 'duplicate', employee_id = r.employee_id where id = r.id; continue;
    end if;
    select (a.punch_in_time is not null) into v_has from public.attendance a where a.employee_id = r.employee_id and a.date = v_shift;
    if not coalesce(v_has, false) then
      v_has := exists (select 1 from public.attendance_events e where e.employee_id = r.employee_id and e.shift_date = v_shift and e.event_type = 'check_in');
    end if;
    select e.event_type into v_last from public.attendance_events e where e.employee_id = r.employee_id and e.shift_date = v_shift order by e.seq desc limit 1;
    if not coalesce(v_has, false) then v_action := 'check_in';
    elsif v_last = 'outpass_out' then v_action := 'outpass_in';
    elsif coalesce(r.status_code, 0) = 2 then v_action := 'outpass_out';
    elsif exists (select 1 from public.attendance_events e where e.employee_id = r.employee_id and e.shift_date = v_shift and e.event_type = 'check_in'
                    and abs(extract(epoch from (e.at_ts - (r.punched_at at time zone 'UTC')))) < 1800) then
      update public.adms_punches set outcome = 'duplicate', employee_id = r.employee_id where id = r.id; continue;
    else v_action := 'check_out'; end if;
    perform public.attendance_apply(r.employee_id, v_action, r.punched_at, 'essl');
    update public.adms_punches set outcome = v_action, employee_id = r.employee_id where id = r.id;
    pin := r.device_user_id; employee_id := r.employee_id; punched_at := r.punched_at; action := v_action;
    return next;
  end loop;
end $$;
revoke all on function public.adms_reapply(timestamp, text) from public, anon, authenticated;

drop trigger if exists adms_conflict_resolved on public.adms_pin_conflicts;
create trigger adms_conflict_resolved after update of resolved_at on public.adms_pin_conflicts
for each row execute function public.adms_conflict_resolved_trg();

-- sanity: the 13 names the old guard refused must now read as the same person
select pin, device_name, app_name, public.adms_same_person(device_name, app_name) same
from public.adms_pin_conflicts where resolved_at is not null order by pin;
