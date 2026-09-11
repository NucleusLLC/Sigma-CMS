-- ════════════════════════════════════════════════════════════════════════════════
--  SIGMA — §PAYOUT-LOCK (v2.491)
--  Work that is on a payout cannot be pulled out from under it, and work that was
--  already pulled out is put back.
--
--  PASTE THIS INTO THE SUPABASE SQL EDITOR AND RUN IT.  It is idempotent: running it
--  twice does nothing the second time. It creates no tables and drops nothing.
--
--  ── WHAT WENT WRONG ────────────────────────────────────────────────────────────
--  Reported as "the Job Orders under his Consultancy still show as NOT PAID while
--  they are PAID".
--
--  A payout's TOTAL is frozen when it is created (sigma_create_payout adds up the
--  selected items and stores the sum). Paying it promotes the work with:
--
--      update work_items set status='paid' where payout_id = p_payout AND status='done'
--
--  Only rows still `done`.  Nothing stopped a row from leaving `done` while staying
--  attached to that payout:
--
--    1. sigma_work_done(p_done := false) reopens a `done` row to `assigned` and does
--       not clear payout_id. It refused a `paid` row, but never a row merely sitting
--       on a payout.
--    2. sigma_void_work voids a row and does not clear payout_id either. Same gap.
--    3. sigma_void_payout hands work back only `where status in ('done','paid')`, so
--       a row stranded by (1) or (2) keeps its payout_id even after the payout is
--       voided — and sigma_create_payout then refuses it for ever, because it
--       rejects anything with a payout_id.
--
--  In each case the consultant was paid a total that INCLUDED that work, the sweep
--  skipped the row, and it reads NOT PAID permanently. Paid in money, unpayable in
--  the system. That is an accounting error, not a display one.
--
--  ── WHAT THIS CHANGES ──────────────────────────────────────────────────────────
--    §1  sigma_work_done   — refuses to reopen work that sits on a live payout.
--    §2  sigma_void_work   — refuses to void work that sits on a live payout.
--    §3  sigma_void_payout — releases EVERY row it holds, not just done/paid ones.
--    §4  a repair pass for rows already stranded, and a report of what it found.
--
--  "Live" means a payout that is not void — draft or paid. Voiding the payout is the
--  correct way to change work that is on one, and it still works exactly as before.
-- ════════════════════════════════════════════════════════════════════════════════

begin;

-- ── §1 ──────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_work_done(p_item uuid, p_actor text default null, p_done boolean default true)
returns public.work_items language plpgsql security definer set search_path = public as $$
declare v_row public.work_items; v_mine uuid := public.sigma_my_contractor_id(); v_pay public.contractor_payouts;
begin
  select * into v_row from public.work_items where id = p_item;
  if not found then raise exception 'That work item does not exist.'; end if;
  if not (public.sigma_is_staff() or v_row.contractor_id = v_mine) then
    raise exception 'That is not your work item.';
  end if;
  if v_row.status = 'void' then raise exception 'That work item was voided.'; end if;
  if v_row.status = 'paid' then
    raise exception 'Work item % has already been paid, on payout %. Void the payout first if it was wrong.',
      v_row.order_number, coalesce((select payout_number from public.contractor_payouts where id = v_row.payout_id), '(unknown)');
  end if;

  -- §PAYOUT-LOCK (v2.491) — reopening work that is inside a payout total leaves it
  --   attached while taking it out of the set the payment sweep promotes, so it is
  --   paid for and reads NOT PAID for ever. Void the payout instead: that hands every
  --   piece of work back properly and the payout can be rebuilt.
  if not p_done and v_row.payout_id is not null then
    select * into v_pay from public.contractor_payouts where id = v_row.payout_id;
    if found and v_pay.status <> 'void' then
      raise exception 'Work item % (%) is on payout % (%). Void that payout before reopening this work — otherwise it stays inside the payout total and can never be marked paid.',
        v_row.order_number, v_row.task_code, v_pay.payout_number, v_pay.status;
    end if;
  end if;

  update public.work_items
     set status  = case when p_done then 'done' else 'assigned' end,
         done_at = case when p_done then now() else null end,
         done_by = case when p_done then p_actor else null end,
         updated_at = now()
   where id = p_item
   returning * into v_row;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, metadata)
  values ('work_item', v_row.id, case when p_done then 'work_done' else 'work_reopened' end,
          p_actor, to_jsonb(v_row),
          jsonb_build_object('order', v_row.order_number, 'task', v_row.task_code, 'amount', v_row.amount));
  return v_row;
end $$;

-- ── §2 ──────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_void_work(p_item uuid, p_reason text, p_actor text default null)
returns public.work_items language plpgsql security definer set search_path = public as $$
declare v_row public.work_items; v_pay public.contractor_payouts;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can void work.'; end if;
  select * into v_row from public.work_items where id = p_item;
  if not found then raise exception 'That work item does not exist.'; end if;
  if v_row.status = 'paid' then
    raise exception 'That work item has been paid and cannot be voided. Void its payout first.';
  end if;

  -- §PAYOUT-LOCK (v2.491) — voiding work does not reduce the payout total it is
  --   already inside, so the office pays for work it has just written off.
  if v_row.payout_id is not null then
    select * into v_pay from public.contractor_payouts where id = v_row.payout_id;
    if found and v_pay.status <> 'void' then
      raise exception 'Work item % (%) is on payout % (%) and its amount is part of that total. Void the payout first, then void the work.',
        v_row.order_number, v_row.task_code, v_pay.payout_number, v_pay.status;
    end if;
  end if;

  update public.work_items
     set status = 'void', void_reason = coalesce(nullif(trim(p_reason), ''), '(no reason given)'),
         voided_at = now(), voided_by = p_actor, updated_at = now()
   where id = p_item
   returning * into v_row;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, reason)
  values ('work_item', v_row.id, 'work_voided', p_actor, to_jsonb(v_row), v_row.void_reason);
  return v_row;
end $$;

-- ── §3 ──────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_void_payout(p_payout uuid, p_reason text, p_actor text default null)
returns public.contractor_payouts language plpgsql security definer set search_path = public as $$
declare v_pay public.contractor_payouts;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can void a payout.'; end if;
  select * into v_pay from public.contractor_payouts where id = p_payout;
  if not found then raise exception 'That payout does not exist.'; end if;
  if v_pay.status = 'void' then raise exception 'Payout % is already void.', v_pay.payout_number; end if;

  -- §PAYOUT-LOCK (v2.491) — this was `where payout_id = p_payout and status in
  --   ('done','paid')`, so an `assigned` or `void` row stranded on the payout kept its
  --   link after the payout was voided, and sigma_create_payout refuses anything with
  --   a payout_id. The row could never be paid again by any route. Release them ALL;
  --   a void row stays void, it simply stops belonging to a payout.
  update public.work_items
     set status = case when status = 'void' then 'void'
                       when status = 'assigned' then 'assigned'
                       else 'done' end,
         payout_id = null, updated_at = now()
   where payout_id = p_payout;

  update public.contractor_payouts
     set status = 'void', void_reason = coalesce(nullif(trim(p_reason),''), '(no reason given)'), updated_at = now()
   where id = p_payout returning * into v_pay;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, reason)
  values ('contractor_payout', v_pay.id, 'payout_voided', p_actor, to_jsonb(v_pay), v_pay.void_reason);
  return v_pay;
end $$;

commit;

-- ════════════════════════════════════════════════════════════════════════════════
--  §4  THE REPAIR — run this SECOND, and read its output before you accept it.
--
--  Three different situations, and only the first two should be touched automatically.
--  Run the SELECT first. It changes nothing.
-- ════════════════════════════════════════════════════════════════════════════════

-- 4a. LOOK. Every row whose link to a payout is wrong, and which kind of wrong.
select c.full_name                                as consultant,
       w.order_number, w.task_code, w.amount, w.status as work_status,
       p.payout_number, p.status                  as payout_status, p.payout_date,
       case
         when p.status = 'paid'  then 'PAID OUT, NEVER CLEARED — money has gone, row still reads unpaid'
         when p.status = 'void'  then 'ORPHAN — payout voided, link never released, can never be re-paid'
         else                         'WILL BE MISSED — payout not yet paid, this row would be skipped'
       end                                        as problem
  from public.work_items w
  join public.contractor_payouts p on p.id = w.payout_id
  left join public.contractors c on c.id = w.contractor_id
 where w.status <> 'paid'
 order by p.status, c.full_name, w.order_number;

-- 4b. FIX THE ORPHANS. A voided payout should never still hold work. This only
--     detaches; no status changes, no money moves.
--
-- update public.work_items w
--    set payout_id = null, updated_at = now()
--   from public.contractor_payouts p
--  where p.id = w.payout_id and p.status = 'void';

-- 4c. FIX THE PAID-BUT-NOT-CLEARED. These are rows a consultant has ALREADY been paid
--     for, because the payout total included them. Marking them paid makes the record
--     agree with the bank. Read 4a first and satisfy yourself that each line really
--     was paid — this is the one statement here that asserts money changed hands.
--
-- update public.work_items w
--    set status = 'paid', updated_at = now()
--   from public.contractor_payouts p
--  where p.id = w.payout_id and p.status = 'paid' and w.status in ('assigned','done');
--
-- insert into public.finance_audit_events (entity, entity_id, action, actor, metadata)
-- select 'work_item', w.id, 'work_paid_repair', 'SIGMA v2.491 §PAYOUT-LOCK repair',
--        jsonb_build_object('order', w.order_number, 'task', w.task_code,
--                           'amount', w.amount, 'payout', p.payout_number)
--   from public.work_items w join public.contractor_payouts p on p.id = w.payout_id
--  where p.status = 'paid' and w.status = 'paid';

-- 4d. The third kind — WILL BE MISSED, on a payout that is still draft — is NOT
--     repaired here on purpose. Nothing has been paid yet, so the office still has a
--     free choice: void that payout and create it again from the work as it now
--     stands. Deciding that in SQL would be deciding it for them.
