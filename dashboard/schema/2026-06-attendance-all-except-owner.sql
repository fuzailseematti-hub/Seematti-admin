-- ───────────────────────────────────────────────────────────────────────────
-- Attendance now covers everyone EXCEPT the owner (was: user_type='staff' only).
-- APPLIED to prod 2026-06-03. kiosk_meta's tally/enrolled counts updated to
-- match; the client rosters (dashboard attendance, daily report, monthly leave,
-- PWA attendance) were switched to user_type <> 'owner' in the same change.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.kiosk_meta(p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if p_pin is null or p_pin <> coalesce((select value from public.settings where key = 'kiosk_pin'), '__none__') then
    raise exception 'Invalid kiosk PIN' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'total_staff', (select count(*) from public.employees where user_type <> 'owner' and is_active = true),
    'enrolled',    (select count(distinct fe.employee_id) from public.face_embeddings fe
                    join public.employees em on em.id = fe.employee_id
                    where coalesce(em.is_active, true) = true and em.user_type <> 'owner' and fe.embedding is not null),
    'present',     (select count(*) from public.attendance where date = v_today and status in ('present', 'late')),
    'clocked_in',  coalesce((select jsonb_agg(employee_id) from public.attendance
                             where date = v_today and status in ('present', 'late') and punch_out_time is null), '[]'::jsonb)
  );
end $$;
grant execute on function public.kiosk_meta(text) to anon, authenticated;
