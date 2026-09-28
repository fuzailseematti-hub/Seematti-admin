-- 28 Sep 2026: weekend loose ends — stale conflict, unnamed device record, second IDs, six more Quanto staff who punch.
delete from public.adms_pin_conflicts where pin = 'SA415' and employee_id = 'E-230';           -- his code is SS415 now
update public.adms_pin_conflicts set resolved_at = now() where pin = 'SD026' and resolved_at is null;  -- device record just had no name
insert into public.adms_users (device_user_id, employee_id, origin) values ('SA12','E022','manual'), ('SA274','E-155','manual'), ('SS328','E-259','manual')
on conflict (device_user_id) do nothing;
update public.adms_punches p set employee_id = u.employee_id from public.adms_users u where u.device_user_id = p.device_user_id and p.employee_id is null and u.device_user_id in ('SA12','SA274','SS328');
insert into public.employees (id, name, role, section_id, user_type, is_active, joined_date, employee_code, quanto_employee_id, company, gender, code_source)
select v.code, v.name, 'Salesman', v.section, 'staff', true, v.joined::date, v.code, v.qid,
       case when v.code like 'SA%' then 'Seematti Sarees' else 'Seematti Silks' end, v.gender, 'quanto'
from (values ('SA459','PADMANABHAN.P',2214,null,null,'2026-06-09'), ('SS278','GANESH.RR-SEASON',1693,null,null,'2024-09-30'),
             ('SS372','CHANDRU.B-SEASON',2028,null,null,'2025-09-05'), ('SS410','K.RAMESH',2180,'matching','male','2026-02-15'),
             ('SS437','D.DEEPANRAJ',2298,'cotton','male','2026-07-18'), ('SS441','A.ARASAN',2303,null,null,'2026-07-18')) v(code,name,qid,section,gender,joined)
where not exists (select 1 from public.employees e where upper(trim(e.employee_code)) = v.code or e.quanto_employee_id = v.qid or e.id = v.code);
select count(*) replayed from public.adms_reapply('2026-09-26 00:00'::timestamp);
select (select count(*) from public.adms_punches where punched_at >= '2026-09-26' and outcome='unknown_user') unknown_since_26,
       (select string_agg(distinct device_user_id, ',') from public.adms_punches where punched_at >= '2026-09-26' and outcome='unknown_user') unknown_pins,
       (select count(*) from public.adms_pin_conflicts where resolved_at is null) conflicts_open,
       (select count(*) from public.attendance where date=current_date) marked_today,
       (select count(*) from public.attendance where date=current_date-1) marked_yesterday,
       (select count(*) from public.v_machine_staff where pin is not null and last_punch is null and is_active) coded_never_punched;
