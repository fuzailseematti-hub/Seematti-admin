-- ───────────────────────────────────────────────────────────────────────────
-- Monthly free leave. APPLIED to prod 2026-06-03.
--
-- Each employee gets N (default 4) pre-planned "free" leave days per month that
-- don't need a formal leave application. Owner/HR set the specific dates in the
-- dashboard (Monthly leave page). The daily report counts these as On-leave
-- instead of Absent (but attendance wins — if they check in, they're Present).
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists public.free_leaves (
  id          uuid primary key default gen_random_uuid(),
  employee_id text not null references public.employees(id) on delete cascade,
  leave_date  date not null,
  created_by  text,
  created_at  timestamptz default now(),
  unique (employee_id, leave_date)
);

insert into public.settings(key, value) values ('free_leave_per_month', '4')
  on conflict (key) do nothing;

-- Hard cap of N per employee per calendar month (N from the setting).
create or replace function public.free_leave_cap() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cap int; v_count int;
begin
  v_cap := coalesce((select value::int from public.settings where key='free_leave_per_month'), 4);
  select count(*) into v_count from public.free_leaves
    where employee_id = new.employee_id
      and date_trunc('month', leave_date) = date_trunc('month', new.leave_date)
      and id <> new.id;
  if v_count >= v_cap then
    raise exception 'Free-leave limit of % per month reached for this employee', v_cap
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists free_leave_cap_trg on public.free_leaves;
create trigger free_leave_cap_trg before insert on public.free_leaves
  for each row execute function public.free_leave_cap();

-- RLS: authenticated read (daily report needs it); owner/admin/hr manage.
alter table public.free_leaves enable row level security;
drop policy if exists fl_read on public.free_leaves;
drop policy if exists fl_write on public.free_leaves;
create policy fl_read  on public.free_leaves for select to authenticated using (true);
create policy fl_write on public.free_leaves for all to authenticated
  using (app.is_hr_or_admin()) with check (app.is_hr_or_admin());

grant select, insert, update, delete on public.free_leaves to authenticated;
