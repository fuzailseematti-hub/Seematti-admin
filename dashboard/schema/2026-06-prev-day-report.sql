-- Allow the 'prev_day_attendance' automation type. APPLIED to prod 2026-06-03.
-- Reports YESTERDAY's complete check-in/out (run early morning), with late
-- check-ins and early check-outs flagged in red in the PDF/HTML report.
alter table public.automations drop constraint if exists automations_type_check;
alter table public.automations add constraint automations_type_check
  check (type in ('daily_attendance', 'next_day_leave', 'prev_day_attendance'));
