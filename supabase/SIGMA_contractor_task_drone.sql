-- SIGMA_contractor_task_drone.sql — v2.598 §DRONE-FIELDWORK + v2.604 §INPUT-FIELDWORK
--
-- Adds two field-work types so this work can be assigned to a consultant and paid out:
--   DRONE  'Drone'           — after Floorplan, before Measure Building
--   INPUT  'Upload / Input'  — filling the job out in SIGMA, at the end of the list
-- work_items.task_code and contractor_rates.task_code are foreign keys to
-- contractor_tasks.code, so without these rows assigning that work is refused.
-- Only adds rows and moves sort numbers; nothing is deleted. Safe to run twice.

begin;

-- make room after Floorplan for Drone (skipped if DRONE is already there)
update public.contractor_tasks t
   set sort = t.sort + 1
 where t.sort > (select sort from public.contractor_tasks where code = 'FLOORPLAN')
   and not exists (select 1 from public.contractor_tasks where code = 'DRONE');

insert into public.contractor_tasks (code, label, sort, active)
select 'DRONE', 'Drone', f.sort + 1, true
  from public.contractor_tasks f
 where f.code = 'FLOORPLAN'
on conflict (code) do update set active = true;

insert into public.contractor_tasks (code, label, sort, active)
select 'INPUT', 'Upload / Input', coalesce(max(sort), 0) + 10, true
  from public.contractor_tasks
on conflict (code) do update set active = true;

commit;

-- check: DRONE between FLOORPLAN and MEASURE, INPUT last
select code, label, sort, active from public.contractor_tasks order by sort;
