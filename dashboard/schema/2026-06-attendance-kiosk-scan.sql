-- ───────────────────────────────────────────────────────────────────────────
-- Attendance: gender-based late cutoffs + smart kiosk scan. APPLIED to prod
-- 2026-06-03. (Recorded after-the-fact; applied via MCP.)
--
-- 1. employees.gender drives the late cutoff (ladies vs men).
-- 2. Settings: checkin_start (08:00), late_cutoff_men (10:00), late_cutoff_women
--    (09:30) — editable by owner/HR in Kiosk settings.
-- 3. kiosk_scan(pin, employee_id): the kiosk now sends only the employee; the
--    server decides check-in vs check-out and returns it:
--      • shift-day boundary = checkin_start. Before it, we're still in the
--        previous day's window (so a check-out at 00:30 closes yesterday).
--      • shift-day row already has a check-in -> CHECK-OUT (latest wins).
--      • else if now >= checkin_start          -> CHECK-IN, late if at/after the
--        employee's gender cutoff (women=late_cutoff_women, else late_cutoff_men).
--      • else (before start, nothing open)      -> record a CHECK-OUT anyway.
--    Replaces kiosk_punch (which also had a text->time bug); kiosk_punch is now
--    unused and can be dropped once the new client is everywhere.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.employees add column if not exists gender text;

insert into public.settings(key, value) values ('checkin_start', '08:00')
  on conflict (key) do nothing;
insert into public.settings(key, value)
  select 'late_cutoff_men', coalesce((select value from public.settings where key='late_cutoff'), '10:00')
  on conflict (key) do nothing;
insert into public.settings(key, value) values ('late_cutoff_women', '09:30')
  on conflict (key) do nothing;

create or replace function public.kiosk_scan(p_pin text, p_employee_id text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_now    timestamp := (now() at time zone 'Asia/Kolkata');
  v_time   text := to_char(v_now, 'HH24:MI');
  v_today  date := v_now::date;
  v_start  text := coalesce((select value from public.settings where key='checkin_start'), '08:00');
  v_shift  date;
  v_row    public.attendance%rowtype;
  v_gender text;
  v_cut    text;
  v_status text;
  v_stamp  time := date_trunc('minute', v_now)::time;
  v_dir    text;
begin
  if p_pin is null or p_pin <> coalesce((select value from public.settings where key='kiosk_pin'), '__none__') then
    raise exception 'Invalid kiosk PIN' using errcode='insufficient_privilege';
  end if;
  if not exists (select 1 from public.employees where id=p_employee_id and coalesce(is_active,true)=true) then
    raise exception 'Unknown employee';
  end if;

  v_shift := case when v_time < v_start then v_today - 1 else v_today end;
  select * into v_row from public.attendance where employee_id=p_employee_id and date=v_shift;

  if v_row.id is not null and v_row.punch_in_time is not null then
    update public.attendance set punch_out_time=v_stamp, source='kiosk', updated_at=now() where id=v_row.id;
    v_dir := 'out'; v_status := v_row.status;
  elsif v_time >= v_start then
    select lower(coalesce(gender,'')) into v_gender from public.employees where id=p_employee_id;
    if v_gender in ('female','f','woman','women','ladies','lady') then
      v_cut := coalesce((select value from public.settings where key='late_cutoff_women'), '09:30');
    else
      v_cut := coalesce((select value from public.settings where key='late_cutoff_men'),
                        (select value from public.settings where key='late_cutoff'), '10:00');
    end if;
    v_status := case when v_time >= v_cut then 'late' else 'present' end;
    insert into public.attendance (employee_id, date, status, punch_in_time, source)
      values (p_employee_id, v_today, v_status, v_stamp, 'kiosk')
      on conflict (employee_id, date) do update
        set status=excluded.status,
            punch_in_time=coalesce(public.attendance.punch_in_time, excluded.punch_in_time),
            source='kiosk', updated_at=now();
    v_dir := 'in';
  else
    insert into public.attendance (employee_id, date, status, punch_out_time, source)
      values (p_employee_id, v_shift, 'present', v_stamp, 'kiosk')
      on conflict (employee_id, date) do update
        set punch_out_time=v_stamp, source='kiosk', updated_at=now();
    v_dir := 'out'; v_status := 'present';
  end if;

  return jsonb_build_object('direction', v_dir, 'status', v_status,
                            'time', to_char(v_stamp, 'HH24:MI'), 'shift_date', v_shift);
end $$;
grant execute on function public.kiosk_scan(text, text) to anon, authenticated;
