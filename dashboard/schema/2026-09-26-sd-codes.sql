-- Dresses staff carry SD codes in Quanto and scan the same machine (SD004 punched 20× this month). Accept SA/SS/SD.
create or replace function public.adms_pin(p_employee_id text)
returns text language sql stable set search_path to 'public','pg_temp' as
$$ select case when upper(trim(e.employee_code)) ~ '^T?S[ASD][0-9]+$' then upper(trim(e.employee_code)) end
   from public.employees e where e.id = p_employee_id $$;
select count(public.adms_sync_employee(id, true)) synced from public.employees where employee_code ~* '^T?SD[0-9]+$';
select count(*) as replayed from public.adms_reapply('2026-09-26 00:00'::timestamp);
