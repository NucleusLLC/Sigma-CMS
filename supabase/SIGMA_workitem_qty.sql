-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SIGMA — quantity on a piece of field work  (§WORK-QTY, v2.397)              ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- ASKED FOR: "under Field Work, under Measurement, add QTY, because we had a double
-- house that had to be measured."
--
-- One job can carry the same work more than once. A double house is two measurements
-- at the agreed rate, not one measurement at a number somebody typed by hand — the
-- distinction matters, because a hand-typed total loses the rate it was built from and
-- nobody can later say whether it was two at 140 or one at 280.
--
-- SO THE ROW KEEPS BOTH. unit_amount is what one of them is worth, quantity is how
-- many, and `amount` stays the TOTAL. That last part is deliberate: every balance,
-- payout and statement in the system already sums `amount`, and none of them needs to
-- learn about quantity for the money to stay right.
--
-- SAFETY. Additive. Existing rows get quantity 1 and unit_amount = amount, which is
-- exactly what they have always meant, so no figure moves.

begin;

alter table public.work_items
  add column if not exists quantity    numeric(10,2) not null default 1,
  add column if not exists unit_amount numeric(12,2);

-- Every row already on the books is one-of, priced at its own amount.
update public.work_items set unit_amount = amount where unit_amount is null;

alter table public.work_items
  add constraint work_items_qty_chk check (quantity > 0);

-- ── sigma_assign_work, now with a quantity ───────────────────────────────────
-- Dropped and recreated rather than overloaded: adding a defaulted parameter would
-- leave TWO functions with compatible signatures, and a six-argument call would be
-- ambiguous. One function, one meaning.
drop function if exists public.sigma_assign_work(uuid, text, text, text, numeric, text);

create or replace function public.sigma_assign_work(
  p_contractor uuid, p_order text, p_task text,
  p_actor text default null, p_amount numeric default null, p_notes text default null,
  p_qty numeric default 1)
returns public.work_items language plpgsql security definer set search_path = public as $$
declare v_rate_id uuid; v_unit numeric; v_qty numeric; v_row public.work_items;
begin
  if not public.sigma_is_staff() then
    raise exception 'Only office staff can assign work.';
  end if;
  if coalesce(trim(p_order), '') = '' then
    raise exception 'A work item must belong to an order.';
  end if;
  perform 1 from public.contractors where id = p_contractor and active;
  if not found then raise exception 'That contractor does not exist, or is not active.'; end if;

  v_qty := coalesce(p_qty, 1);
  if v_qty <= 0 then raise exception 'The quantity must be greater than zero.'; end if;

  select r.id, r.amount into v_rate_id, v_unit
    from public.contractor_rates r
   where r.contractor_id = p_contractor and r.task_code = p_task
     and r.valid_from <= current_date
     and (r.valid_to is null or r.valid_to >= current_date)
   order by r.valid_from desc limit 1;

  v_unit := coalesce(p_amount, v_unit);
  if v_unit is null then
    raise exception 'No rate is set for % on this task, and no amount was given. Set a rate in Finance → Contractors first.',
      (select full_name from public.contractors where id = p_contractor);
  end if;
  if p_amount is not null then v_rate_id := null; end if;   -- a hand-typed price is not a rate

  insert into public.work_items (contractor_id, order_number, task_code,
                                 unit_amount, quantity, amount, rate_id, assigned_by, notes)
  values (p_contractor, trim(p_order), p_task,
          v_unit, v_qty, round(v_unit * v_qty, 2), v_rate_id, p_actor, p_notes)
  returning * into v_row;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, metadata)
  values ('work_item', v_row.id, 'work_assigned', p_actor, to_jsonb(v_row),
          jsonb_build_object('order', v_row.order_number, 'task', p_task,
                             'unit', v_unit, 'qty', v_qty, 'amount', v_row.amount));
  return v_row;
end $$;

-- ── change the quantity on work that has not been paid ───────────────────────
-- A miscount is corrected here rather than by voiding and re-assigning, so the
-- history reads as one piece of work whose count was corrected — which is what
-- happened — instead of two pieces of work, one of them cancelled.
create or replace function public.sigma_set_work_qty(
  p_item uuid, p_qty numeric, p_actor text default null)
returns public.work_items language plpgsql security definer set search_path = public as $$
declare v_row public.work_items; v_before jsonb;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can change a quantity.'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'The quantity must be greater than zero.'; end if;

  select * into v_row from public.work_items where id = p_item;
  if not found then raise exception 'That work item does not exist.'; end if;
  if v_row.status = 'void' then raise exception 'That work item was voided.'; end if;
  if v_row.status = 'paid' then
    raise exception 'Work item % has already been paid and cannot be re-counted. Void its payout first.',
      v_row.order_number;
  end if;
  v_before := to_jsonb(v_row);

  update public.work_items
     set quantity   = p_qty,
         amount     = round(coalesce(unit_amount, amount) * p_qty, 2),
         updated_at = now()
   where id = p_item returning * into v_row;

  insert into public.finance_audit_events (entity, entity_id, action, actor, before_state, after_state, metadata)
  values ('work_item', v_row.id, 'work_qty_changed', p_actor, v_before, to_jsonb(v_row),
          jsonb_build_object('order', v_row.order_number, 'task', v_row.task_code,
                             'qty', p_qty, 'amount', v_row.amount));
  return v_row;
end $$;

grant execute on function public.sigma_assign_work(uuid,text,text,text,numeric,text,numeric) to authenticated;
grant execute on function public.sigma_set_work_qty(uuid,numeric,text)                       to authenticated;
revoke execute on function public.sigma_assign_work(uuid,text,text,text,numeric,text,numeric) from anon;
revoke execute on function public.sigma_set_work_qty(uuid,numeric,text)                       from anon;

commit;
