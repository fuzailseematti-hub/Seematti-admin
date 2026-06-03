-- Early-leave monitoring. APPLIED to prod 2026-06-03.
-- A check-out before the employee's gender closing time counts as "Left early".
-- Editable in the dashboard's Kiosk/Shift-timings settings. The Daily report
-- page derives early-leavers (checkout < gender cutoff, during the day) and
-- highlights them; late check-in times are shown in red across reports.
insert into public.settings(key, value) values ('early_cutoff_men',   '22:00') on conflict (key) do nothing;
insert into public.settings(key, value) values ('early_cutoff_women', '20:00') on conflict (key) do nothing;
