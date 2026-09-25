-- ──────────────────────────────────────────────────────────────────────
-- ESSL machine: MACHINE ID = the SA/SS STAFF CODE — 25 Sep 2026 (owner)
-- ──────────────────────────────────────────────────────────────────────
-- Supersedes the app-id PIN rule in 2026-09-essl-app-primary.sql (same
-- day). The staff code already lives in employees.employee_code (editable
-- in the desktop console). Applied live 25 Sep 2026. Safe to re-run.
--
--  • PIN = employee_code when it is an SA/SS code (SA455, SS02 …);
--    an employee without a code has no machine ID until HR types one.
--  • Typing or changing the code (or the name) pushes the user record
--    to the machine automatically. Faces are still enrolled AT the
--    machine, under that code.
--  • The 147 E-number users pushed earlier today are deleted from the
--    machine again (no face was ever enrolled under them).
-- ──────────────────────────────────────────────────────────────────────

create or replace function public.adms_pin(p_employee_id text)
returns text language sql stable set search_path to 'public','pg_temp' as
$$ select case when upper(trim(e.employee_code)) ~ '^S[AS][0-9]+$' then upper(trim(e.employee_code)) end
   from public.employees e where e.id = p_employee_id $$;

create or replace function public.adms_sync_employee(p_employee_id text, p_push boolean default true)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_pin text := public.adms_pin(p_employee_id); v_dev record;
begin
  if v_pin is null then return; end if;
  -- the code moved: drop this employee's previous code link
  delete from public.adms_users where employee_id = p_employee_id and origin in ('code','app_id') and device_user_id <> v_pin;
  -- a code already linked to SOMEONE ELSE is left alone (HR resolves it)
  insert into public.adms_users (device_user_id, employee_id, origin)
  values (v_pin, p_employee_id, 'code')
  on conflict (device_user_id) do nothing;
  if p_push then
    for v_dev in select sn from public.adms_devices where enabled loop
      insert into public.adms_commands (sn, cmd) values (v_dev.sn, public.adms_userinfo_cmd(p_employee_id));
    end loop;
  end if;
end $$;
revoke all on function public.adms_sync_employee(text, boolean) from public, anon, authenticated;

create or replace function public.adms_employee_trg()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if tg_op = 'INSERT' or new.employee_code is distinct from old.employee_code or new.name is distinct from old.name then
    perform public.adms_sync_employee(new.id, true);
  end if;
  return new;
end $$;
drop trigger if exists adms_employee_sync on public.employees;
create trigger adms_employee_sync after insert or update of employee_code, name on public.employees
for each row execute function public.adms_employee_trg();

-- remove the E-number users from the machine (E244 already deleted as the test) and their links
insert into public.adms_commands (sn, cmd)
select d.sn, 'DATA DELETE USERINFO PIN=' || u.device_user_id
from public.adms_users u, public.adms_devices d
where u.origin = 'app_id' and d.enabled and u.device_user_id <> 'E244';
delete from public.adms_users where origin = 'app_id';

-- fill the code where the machine already knows the person for certain
-- (a) the 16 verified links whose code field was blank
update public.employees e set employee_code = u.device_user_id
from public.adms_users u
where u.employee_id = e.id and u.origin = 'manual' and coalesce(trim(e.employee_code), '') = '';
-- (b) five re-hires: same name on the machine, punching this month, previously linked
update public.employees set employee_code = v.code
from (values ('E-235','SS398'), ('E-229','SA341'), ('E-223','SA485'), ('E-234','SS349'), ('E-238','SA474')) v(id, code)
where employees.id = v.id and coalesce(trim(employees.employee_code), '') = '';

-- link + push everyone else who has a code (names on the machine follow the app)
select count(public.adms_sync_employee(e.id, true))
from public.employees e
where public.adms_pin(e.id) is not null
  and not exists (select 1 from public.adms_commands c where c.created_at > now() - interval '2 minutes' and c.cmd = public.adms_userinfo_cmd(e.id));
