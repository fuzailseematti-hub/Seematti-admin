-- 26 Sep 2026, first machine-only day: every person who punched must be a known employee.
-- (a) app employees whose HR-typed code differs from the ID they actually scan with
update public.employees set employee_code = v.code, code_source = 'quanto'
from (values ('E-120','SS225'), ('E-230','SS415'), ('E-222','SS251'), ('E-247','SA457'), ('E-233','SS420'),
             ('E-183','SA479'), ('R-214','SS366'), ('E-202','SS266'), ('E-237','SS241'), ('E-242','SA432'),
             ('E-160','SA469')) v(id, code)
where employees.id = v.id and not exists (select 1 from public.employees e2 where upper(trim(e2.employee_code)) = v.code and e2.id <> v.id);
-- (b) second machine IDs for people who already have one (old ID still enrolled with their face)
insert into public.adms_users (device_user_id, employee_id, origin) values ('SA03','E020','manual'), ('2','E019','manual'), ('SS414','E-124','manual')
on conflict (device_user_id) do nothing;
update public.adms_punches p set employee_id = u.employee_id from public.adms_users u where u.device_user_id = p.device_user_id and p.employee_id is null and u.device_user_id in ('SA03','2','SS414');
-- (c) Quanto staff who punch the machine but were never in the app (the sync only imported Sep joiners)
insert into public.employees (id, name, role, section_id, user_type, is_active, joined_date, employee_code, quanto_employee_id, company, gender, code_source)
select v.code, v.name, 'Salesman', v.section, 'staff', true, v.joined::date, v.code, v.qid,
       case when v.code like 'SA%' then 'Seematti Sarees' when v.code like 'SS%' then 'Seematti Silks' else 'Seematti Dresses' end,
       v.gender, 'quanto'
from (values
  ('SA20','GOPAL SINGH.K',850,'fancy','male','2022-11-08'), ('SS396','BANUPRIYA',2150,'matching','female','2025-12-07'),
  ('SS95','MANOHAR.M',728,null,'male','2022-07-18'), ('SA427','MOHAMED SALEEM.K-SEASON',2129,null,null,'2025-10-04'),
  ('SA369','SINDHUJA.N',2003,null,null,'2025-07-27'), ('SA368','SHANMUGASUNDARAI',2002,null,null,'2025-07-27'),
  ('SA347','J.RAWOTHAR NAINA MOHAMAD',1953,null,null,'2025-06-19'), ('SS196','BALASUBRAMANIYAN.B',1457,null,null,'2024-02-10'),
  ('SD004','MUBARAK ALI.K.S',869,null,'male','2022-12-02'), ('SS431','MOHAMMEDSALEEM',2276,'matching','male','2026-07-06'),
  ('SS226','SULAIMAN.A',1583,null,null,'2024-06-16'), ('SS440','HARIHARAN',2302,null,'male','2026-07-18'),
  ('SS373','ANAND.K-SEASON',2029,null,null,'2025-09-05'), ('SS376','SAMYDOSS.G-SEASON',2032,null,null,'2025-09-05'),
  ('SS252','MAYAKRISHANA.M',1639,null,'male','2024-07-20'), ('SS209','RAVI.N-SEASON',1497,'cotton',null,'2024-03-11'),
  ('SA391','DHAKSNANAMOORTHY.K-SEASON',2076,null,null,'2025-09-16'), ('SS364','SANTHOSH.S-SEASON',2020,null,null,'2025-09-05'),
  ('SS416','I SUDALAMUTHU',2198,null,'male','2026-04-15'), ('SA316','PREM ANAND.K-SEASON',1781,null,null,'2024-10-07'),
  ('SA451','G.SENTHILKUMAR',2184,'cotton','male','2026-02-23'), ('SS435','M.RAHMATHULLA',2293,null,'male','2026-07-18'),
  ('SS412','R.VELMURUGAN',2185,'matching','male','2026-02-23'), ('SA489','V.BALAMURUGAN',2295,'cotton','male','2026-07-18'),
  ('SA414','KUMAR.V-SEASON',2107,null,null,'2025-09-21'), ('SA386','BEERMOHAMED.AM-SEASON',2065,null,null,'2025-09-12'),
  ('SS284','SANTHOSH KUMAR.B-SEASON',1699,null,null,'2024-09-30'), ('SS391','ARULPANDIYAN.S-SEASON',2048,null,null,'2025-09-05'),
  ('SD008','MOHAMED ISMAIL.K',873,null,'male','2022-12-02'), ('SS374','TAMILVANAN.M-SEASON',2030,null,null,'2025-09-05'),
  ('SD026','NEELAKANDAN.D',891,null,'male','2022-12-02'), ('SS439','S.SILAMBARASAN',2300,null,'male','2026-07-18'),
  ('SA443','M.MAYAKRISHANAN',2171,null,'male','2026-02-13'), ('SS371','RAJKUMAR.R-SEASON',2027,null,null,'2025-09-05'),
  ('SA437','AMUTHAN.A',2176,null,null,'2026-02-14'), ('SA393','NAGAMANI.S-SEASON',2078,null,null,'2025-09-16'),
  ('SS332','R.PARANTHAMAN-SEASON',1898,null,null,'2025-03-12')
) v(code, name, qid, section, gender, joined)
where not exists (select 1 from public.employees e where upper(trim(e.employee_code)) = v.code or e.quanto_employee_id = v.qid or e.id = v.code);
-- (d) turn every punch that arrived before these links into attendance
select count(*) as replayed from public.adms_reapply('2026-09-26 00:00'::timestamp);
-- (e) re-send today's attendance email with the complete data (cron runs every 15 min)
update public.automations set last_sent_on = '2026-09-25' where type = 'daily_attendance' and enabled;
-- state
select (select count(*) from public.attendance where date=current_date and source='essl') essl_rows_today,
       (select count(*) from public.adms_punches where punched_at::date=current_date and outcome='unknown_user') unknown_left_today,
       (select string_agg(distinct device_user_id, ',') from public.adms_punches where punched_at::date=current_date and outcome='unknown_user') unknown_pins,
       (select count(*) from public.employees) employees,
       (select count(*) from public.v_machine_staff where pin is null and is_active) no_code,
       (select count(*) from public.adms_commands where done_at is null) queued;
