-- ───────────────────────────────────────────────────────────────────────────
-- Supabase Auth migration — PHASE 3a (server-side kiosk matching)
--
-- See docs/auth-migration-plan.md. APPLIED to prod 2026-06-02. ADDITIVE: the
-- running kiosk still uses anon table reads until its client is cut over to
-- these RPCs (the cutover ships in the same PR as this file).
--
-- Why: the attendance kiosk runs UNAUTHENTICATED (PIN-gated, no login). For the
-- Phase 3b RLS lockdown to remove all anon table access, the kiosk's three
-- needs — match a face, record a punch, show the tally — move into PIN-gated
-- SECURITY DEFINER RPCs. Biometric embeddings then never leave the server.
--
-- Matching mirrors the previous client logic exactly: per-employee best-of-poses
-- (min euclidean distance over enrolled embeddings), similarity = clamp(1 - dist),
-- threshold from settings.match_threshold (default 0.55), and a 0.08 similarity
-- margin over the second-best to reject ambiguous matches.
--
-- Verified via SQL after apply: a real enrolled embedding matches its own
-- employee at similarity 1.0 (matched=true); a random descriptor → 0.0
-- (matched=false); a wrong PIN raises.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.kiosk_match(p_pin text, p_descriptor float8[])
returns table(employee_id text, name text, role text, section_id text,
              similarity float8, matched boolean, ambiguous boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_threshold float8;
  v_margin    float8 := 0.08;
begin
  if p_pin is null or p_pin <> coalesce((select value from public.settings where key = 'kiosk_pin'), '__none__') then
    raise exception 'Invalid kiosk PIN' using errcode = 'insufficient_privilege';
  end if;
  if p_descriptor is null or array_length(p_descriptor, 1) is null then
    raise exception 'No descriptor provided';
  end if;
  v_threshold := coalesce((select value::float8 from public.settings where key = 'match_threshold'), 0.55);

  return query
  with dists as (
    select fe.employee_id,
           min(sqrt((select sum((d.v - e.v) ^ 2)
                     from unnest(p_descriptor) with ordinality d(v, i)
                     join unnest(fe.embedding)  with ordinality e(v, i) using (i)))) as distance
    from public.face_embeddings fe
    join public.employees em on em.id = fe.employee_id
    where coalesce(em.is_active, true) = true
      and fe.embedding is not null
      and array_length(fe.embedding, 1) = array_length(p_descriptor, 1)
    group by fe.employee_id
  ),
  ranked as (
    select d.employee_id, em.name, em.role, em.section_id,
           greatest(0, least(1, 1 - d.distance)) as similarity,
           row_number() over (order by d.distance asc) as rn,
           greatest(0, least(1, 1 - d.distance))
             - lead(greatest(0, least(1, 1 - d.distance))) over (order by d.distance asc) as margin_to_next
    from dists d
    join public.employees em on em.id = d.employee_id
  )
  select r.employee_id, r.name, r.role, r.section_id, r.similarity,
         (r.similarity >= v_threshold and (r.margin_to_next is null or r.margin_to_next >= v_margin)) as matched,
         (r.similarity >= v_threshold and r.margin_to_next is not null and r.margin_to_next < v_margin) as ambiguous
  from ranked r
  where r.rn = 1;
end $$;
grant execute on function public.kiosk_match(text, float8[]) to anon, authenticated;

create or replace function public.kiosk_punch(p_pin text, p_employee_id text, p_dir text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_local timestamp := (now() at time zone 'Asia/Kolkata');
  v_today date      := v_local::date;
  v_stamp text      := to_char(v_local, 'HH24:MI:00');
  v_cut   text;
  v_status text;
begin
  if p_pin is null or p_pin <> coalesce((select value from public.settings where key = 'kiosk_pin'), '__none__') then
    raise exception 'Invalid kiosk PIN' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.employees where id = p_employee_id and coalesce(is_active, true) = true) then
    raise exception 'Unknown employee';
  end if;

  if p_dir = 'in' then
    v_cut := coalesce((select value from public.settings where key = 'late_cutoff'), '10:00');
    v_status := case when to_char(v_local, 'HH24:MI') >= v_cut then 'late' else 'present' end;
    insert into public.attendance (employee_id, date, status, punch_in_time, source)
    values (p_employee_id, v_today, v_status, v_stamp, 'kiosk')
    on conflict (employee_id, date) do update
      set status        = excluded.status,
          punch_in_time = coalesce(public.attendance.punch_in_time, excluded.punch_in_time),
          source        = 'kiosk';
  elsif p_dir = 'out' then
    update public.attendance set punch_out_time = v_stamp
    where employee_id = p_employee_id and date = v_today;
  else
    raise exception 'Invalid direction';
  end if;
end $$;
grant execute on function public.kiosk_punch(text, text, text) to anon, authenticated;

create or replace function public.kiosk_meta(p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if p_pin is null or p_pin <> coalesce((select value from public.settings where key = 'kiosk_pin'), '__none__') then
    raise exception 'Invalid kiosk PIN' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'total_staff', (select count(*) from public.employees where user_type = 'staff' and is_active = true),
    'enrolled',    (select count(distinct fe.employee_id) from public.face_embeddings fe
                    join public.employees em on em.id = fe.employee_id
                    where coalesce(em.is_active, true) = true and fe.embedding is not null),
    'present',     (select count(*) from public.attendance where date = v_today and status in ('present', 'late')),
    'clocked_in',  coalesce((select jsonb_agg(employee_id) from public.attendance
                             where date = v_today and status in ('present', 'late') and punch_out_time is null), '[]'::jsonb)
  );
end $$;
grant execute on function public.kiosk_meta(text) to anon, authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- Rollback:
--   drop function if exists public.kiosk_meta(text);
--   drop function if exists public.kiosk_punch(text, text, text);
--   drop function if exists public.kiosk_match(text, float8[]);
-- ───────────────────────────────────────────────────────────────────────────
