-- Live updates for the dashboard Daily report. APPLIED to prod 2026-06-05.
-- attendance was already published; add the new tables so outpass events and
-- free leaves also push live changes to the dashboard.
alter publication supabase_realtime add table public.attendance_events;
alter publication supabase_realtime add table public.free_leaves;
