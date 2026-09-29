-- SIGMA_contractor_task_drone.sql — v2.598 §DRONE-FIELDWORK
--
-- Adds DRONE (Drone Services) as a field-work type, so drone work can be assigned to a
-- consultant and paid out. work_items.task_code and contractor_rates.task_code are foreign
-- keys to contractor_tasks.code, so without this row assigning drone work is refused.
--
-- Placed right after Floorplan and before Measure Building (the Master Fees order).
-- Only adds a row and moves the sort numbers of the tasks after it; nothing is deleted.
-- Safe to run twice.

begin;

-- make room: every task after Floorplan moves down one place (skipped if DRONE is already there)
update public.contractor_tasks t
   set sort = t.sort + 1
 where t.sort > (select sort from public.contractor_tasks where code = 'FLOORPLAN')
   and not exists (select 1 from public.contractor_tasks where code = 'DRONE');

insert into public.contractor_tasks (code, label, sort, active)
select 'DRONE', 'Drone', f.sort + 1, true
  from public.contractor_tasks f
 where f.code = 'FLOORPLAN'
on conflict (code) do update set active = true;

commit;

-- check: DRONE between FLOORPLAN and MEASURE
select code, label, sort, active from public.contractor_tasks order by sort;
