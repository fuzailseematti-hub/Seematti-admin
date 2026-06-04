-- Outpass system — APPLIED to prod 2026-06-04.
-- Event log + state machine so the kiosk offers check-in, then check-out OR
-- outpass, return-from-outpass, etc. The daily `attendance` row is still kept
-- in sync (first check-in / last check-out / status) so existing reports work.

create table if not exists public.attendance_events (
  id          uuid primary key default gen_random_uuid(),
  employee_id text not null,
  shift_date  date not null,
  event_type  text not null check (event_type in ('check_in','check_out','outpass_out','outpass_in')),
  at          time without time zone not null,   -- IST wall-clock minute
  at_ts       timestamptz not null default now(),
  source      text default 'kiosk',
  created_at  timestamptz not null default now(),
  seq         bigint generated always as identity  -- monotonic; orders events even within a tick
);
create index if not exists attendance_events_emp_date_idx     on public.attendance_events (employee_id, shift_date, at_ts);
create index if not exists attendance_events_date_idx         on public.attendance_events (shift_date);
create index if not exists attendance_events_emp_date_seq_idx on public.attendance_events (employee_id, shift_date, seq);

alter table public.attendance_events enable row level security;
drop policy if exists op_all on public.attendance_events;
create policy op_all on public.attendance_events for all to authenticated using (true) with check (true);
grant select, insert, update, delete on public.attendance_events to authenticated;

-- See the live DB for the function bodies (kiosk_emp_state, kiosk_event, and the
-- extended kiosk_match that returns state + actions). Summary of states:
--   needs_checkin -> [check_in]
--   inside        -> [check_out, outpass_out]   (also after a check_out: re-opens)
--   on_outpass    -> [outpass_in]
-- kiosk_event(pin, employee_id, action) validates the action against the current
-- state, logs the event, and syncs the attendance summary row.
