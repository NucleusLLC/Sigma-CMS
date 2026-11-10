-- SIGMA - "Custom" field work for Custom Add (v2.771, CA-CUSTOM)
--
-- ASKED FOR: under Finance > Consultants > Custom Add, a field-work choice called "Custom"
-- where the user types the description and the amount.
--
-- WHY THE DATABASE NEEDS A STEP: work_items.task_code is a foreign key to
-- contractor_tasks(code), so a Custom row needs a CUSTOM code to exist.
--
-- SAFETY: additive, one row. Nothing existing changes. The app keeps CUSTOM out of every
-- other field-work picker (Master Fees, consultant rates, job order field work); it is
-- offered only in Custom Add. The amount and the description go through the existing
-- sigma_custom_add_work (p_unit = amount, p_factor = 1, p_reason = 'Custom: <text>').

begin;

insert into public.contractor_tasks (code, label, sort, active)
values ('CUSTOM', 'Custom', 90, true)
on conflict (code) do nothing;

commit;
