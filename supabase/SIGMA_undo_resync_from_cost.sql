-- SIGMA_undo_resync_from_cost.sql — undo the field work recorded by "⟳ Resync from Cost"
-- (Consultants tab, v2.604 – v2.617; button removed in v2.618).
--
-- Resync recorded every item through sigma_assign_work with one of these notes:
--   'Resync from Cost'
--   'House job fee (Master Fees) — Resync from Cost'
-- so those notes identify exactly what it created.
--
-- RUN IN TWO STEPS in the Supabase SQL editor (production cimgpycjczatjzltgscf).
-- Do STEP 2 only after reading STEP 1's result.

-- ── STEP 1 · LOOK (read-only) ────────────────────────────────────────────────────
select w.order_number, c.full_name as consultant, w.task_code, w.amount, w.status,
       w.payout_id is not null as on_a_payout, w.notes, w.created_at
  from public.work_items w
  left join public.contractors c on c.id = w.contractor_id
 where w.notes like '%Resync from Cost%'
 order by w.created_at, w.order_number;

-- ── STEP 2 · VOID (same effect and audit trail as sigma_void_work) ────────────────
-- Voids only rows that are NOT paid and NOT on a live payout; those are reported
-- by STEP 1 and must be handled by hand (void the payout first).
-- Rows are voided, never deleted: they stay visible in the audit history.
begin;

with gone as (
  update public.work_items w
     set status = 'void',
         void_reason = 'Undo of Resync from Cost (v2.618)',
         voided_at = now(), voided_by = 'owner (SQL editor)', updated_at = now()
   where w.notes like '%Resync from Cost%'
     and w.status <> 'void'
     and w.status <> 'paid'
     and not exists (select 1 from public.contractor_payouts p
                      where p.id = w.payout_id and p.status <> 'void')
  returning w.*
)
insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, reason)
select 'work_item', g.id, 'work_voided', 'owner (SQL editor)', to_jsonb(g), g.void_reason from gone g;

-- Check, then COMMIT (or ROLLBACK to change nothing):
select order_number, task_code, amount, status from public.work_items
 where notes like '%Resync from Cost%' order by order_number;
-- commit;
-- rollback;
