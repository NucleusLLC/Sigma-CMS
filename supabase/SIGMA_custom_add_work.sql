-- SIGMA - Custom Add: extra field work on a job that was already invoiced (v2.759, CUSTOM-ADD)
--
-- ASKED FOR: under Finance > Consultants, an Administrator can add more field work for a
-- consultant when the job turned out bigger on site than was invoiced. Priced at the
-- Master Fee times a factor (1x, 2x, ...).
--
-- WHY THE DATABASE NEEDS A STEP: work_items_once_idx allows one open row per consultant,
-- job and field-work type. That is the very case this feature exists for: the job already
-- has its Measure row and now needs more. The rule stays for ordinary assignments. Rows
-- marked custom_add sit outside it, so a normal row cannot be doubled by accident.
--
-- SAFETY: additive. No existing row changes (custom_add defaults to false for all of them,
-- so the index covers exactly the same rows as before). Balances, payouts and statements
-- already sum `amount`, so they need no change.

begin;

alter table public.work_items
  add column if not exists custom_add boolean not null default false;

drop index if exists public.work_items_once_idx;
create unique index work_items_once_idx
  on public.work_items (contractor_id, order_number, task_code)
  where status <> 'void' and not custom_add;

create or replace function public.sigma_custom_add_work(
  p_contractor uuid, p_order text, p_task text,
  p_unit numeric, p_factor numeric,
  p_reason text default null, p_admin text default null, p_actor text default null)
returns public.work_items language plpgsql security definer set search_path = public as $$
declare v_row public.work_items; v_notes text;
begin
  if not public.sigma_is_staff() then
    raise exception 'Only office staff can add work.';
  end if;
  if coalesce(trim(p_order), '') = '' then
    raise exception 'A work item must belong to an order.';
  end if;
  if p_unit is null or p_unit <= 0 then
    raise exception 'A Custom Add needs a Master Fee above zero.';
  end if;
  if p_factor is null or p_factor <= 0 then
    raise exception 'The factor must be greater than zero.';
  end if;
  perform 1 from public.contractors where id = p_contractor and active;
  if not found then raise exception 'That consultant does not exist, or is not active.'; end if;

  v_notes := 'Custom Add ' || trim(trailing '.' from to_char(p_factor, 'FM99990.99')) || 'x'
          || case when coalesce(trim(p_reason), '') <> '' then ' - ' || trim(p_reason) else '' end
          || case when coalesce(trim(p_admin), '') <> '' then ' - authorised by ' || trim(p_admin) else '' end;

  insert into public.work_items (contractor_id, order_number, task_code, custom_add,
                                 unit_amount, quantity, amount, rate_id, assigned_by, notes)
  values (p_contractor, trim(p_order), p_task, true,
          p_unit, p_factor, round(p_unit * p_factor, 2), null, p_actor, v_notes)
  returning * into v_row;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, metadata)
  values ('work_item', v_row.id, 'work_custom_add', p_actor, to_jsonb(v_row),
          jsonb_build_object('order', v_row.order_number, 'task', p_task, 'unit', p_unit,
                             'factor', p_factor, 'amount', v_row.amount,
                             'authorised_by', p_admin, 'reason', p_reason));
  return v_row;
end $$;

revoke execute on function public.sigma_custom_add_work(uuid,text,text,numeric,numeric,text,text,text) from public;
revoke execute on function public.sigma_custom_add_work(uuid,text,text,numeric,numeric,text,text,text) from anon;
grant  execute on function public.sigma_custom_add_work(uuid,text,text,numeric,numeric,text,text,text) to authenticated;

commit;
