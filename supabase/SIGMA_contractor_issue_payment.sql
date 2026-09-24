-- ─────────────────────────────────────────────────────────────────────────────
-- §ISSUE-PAYMENT (v2.569) — pay a consultant any amount, against the jobs it covers.
--
-- WHY: the payout flow (sigma_create_payout → sigma_pay_payout) only ever pays the
-- exact value of the ticked work. Real payments are not that tidy: part-payments,
-- advances, rounding, a transfer made before the work is signed off. The office asked
-- for one "ISSUE PAYMENT" step that records the money actually paid, who it went to,
-- when and how, and which jobs it covers — and that is allowed to leave the account
-- short (negative) or ahead (positive).
--
-- MODEL: an issued payment is an ordinary contractor_payouts row created straight in
-- status 'paid'.
--   total       = the money actually paid (may differ from the work it covers)
--   work_total  = the value of the jobs it covers (NULL on older payouts = total)
--   paid_to     = the name the money went to, as typed
-- The covered work is marked paid and linked by payout_id, exactly like a paid
-- payout, so every existing screen (NOT PAID TO / WE PAID pills, statements, void)
-- keeps working. Voiding it still hands the work back as owed.
--
-- BALANCE, per consultant (contractor_account_v):
--   balance = money paid − value of the jobs those payments covered
--   > 0  paid ahead (credit to the bureau)     → green
--   < 0  short: still owed on covered jobs      → red
--
-- SAFETY: additive only. Two nullable columns, one function, one view. Alters no
-- existing row; drops nothing. Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────
begin;

alter table public.contractor_payouts add column if not exists work_total numeric(12,2);
alter table public.contractor_payouts add column if not exists paid_to    text;

create or replace function public.sigma_issue_payment(
  p_contractor uuid,
  p_items      uuid[],
  p_amount     numeric,
  p_date       date default null,
  p_method     text default null,
  p_paid_to    text default null,
  p_reference  text default null,
  p_actor      text default null,
  p_notes      text default null)
returns public.contractor_payouts language plpgsql security definer set search_path = public as $$
declare v_pay public.contractor_payouts; v_num text; v_work numeric := 0; v_id uuid;
        v_row public.work_items; v_items uuid[] := coalesce(p_items, '{}');
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can issue a payment.'; end if;
  if not exists (select 1 from public.contractors where id = p_contractor) then
    raise exception 'That consultant does not exist.';
  end if;
  if p_amount is null or p_amount = 0 then raise exception 'Enter the amount paid.'; end if;
  if abs(p_amount) > 1000000 then raise exception 'That amount is not believable - check it.'; end if;
  if nullif(trim(coalesce(p_method, '')), '') is null then raise exception 'Choose how it was paid.'; end if;

  foreach v_id in array v_items loop
    select * into v_row from public.work_items where id = v_id for update;
    if not found then raise exception 'One of the selected jobs no longer exists.'; end if;
    if v_row.contractor_id <> p_contractor then
      raise exception 'Job % (%) belongs to a different consultant.', v_row.order_number, v_row.task_code;
    end if;
    if v_row.status <> 'done' then
      raise exception 'Job % (%) is "%", not done - only completed work can be covered.',
        v_row.order_number, v_row.task_code, v_row.status;
    end if;
    if v_row.payout_id is not null then
      raise exception 'Job % (%) is already on payout %.', v_row.order_number, v_row.task_code,
        (select payout_number from public.contractor_payouts where id = v_row.payout_id);
    end if;
    v_work := v_work + v_row.amount;
  end loop;

  v_num := public.sigma_next_payout_number();
  insert into public.contractor_payouts
    (payout_number, contractor_id, status, total, work_total, currency, payout_date,
     method, reference, paid_to, notes, created_by, paid_at, paid_by)
  values
    (v_num, p_contractor, 'paid', round(p_amount, 2), round(v_work, 2), 'AWG',
     coalesce(p_date, current_date), trim(p_method), nullif(trim(coalesce(p_reference, '')), ''),
     nullif(trim(coalesce(p_paid_to, '')), ''), nullif(trim(coalesce(p_notes, '')), ''),
     p_actor, now(), p_actor)
  returning * into v_pay;

  if array_length(v_items, 1) is not null then
    update public.work_items set status = 'paid', payout_id = v_pay.id, updated_at = now()
     where id = any(v_items);
  end if;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, metadata)
  values ('contractor_payout', v_pay.id, 'payment_issued', p_actor, to_jsonb(v_pay),
          jsonb_build_object('items', coalesce(array_length(v_items, 1), 0), 'amount', p_amount,
                             'work_total', v_work, 'difference', round(p_amount - v_work, 2),
                             'method', p_method, 'paid_to', p_paid_to));
  return v_pay;
end $$;

-- Money paid against the value of the work it covered, per consultant. Void payouts
-- and drafts (not yet paid) are out. Older payouts carry no work_total: they were
-- built to pay exactly their work, so their work value IS their total.
create or replace view public.contractor_account_v with (security_invoker = true) as
select c.id as contractor_id,
       coalesce(sum(p.total), 0)                                as paid_total,
       coalesce(sum(coalesce(p.work_total, p.total)), 0)        as covered_total,
       coalesce(sum(p.total - coalesce(p.work_total, p.total)), 0) as balance,
       count(p.id)                                              as payments
  from public.contractors c
  left join public.contractor_payouts p on p.contractor_id = c.id and p.status = 'paid'
 group by c.id;

grant select on public.contractor_account_v to authenticated;
revoke all on public.contractor_account_v from anon;
grant execute on function public.sigma_issue_payment(uuid,uuid[],numeric,date,text,text,text,text,text) to authenticated;
revoke execute on function public.sigma_issue_payment(uuid,uuid[],numeric,date,text,text,text,text,text) from public;
revoke execute on function public.sigma_issue_payment(uuid,uuid[],numeric,date,text,text,text,text,text) from anon;

commit;
