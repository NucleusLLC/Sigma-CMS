-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA — receipt numbers carry the job number (31 Oct 2026)
--
-- Asked for after receipt RCP-2026-065 went out for job 2026-178: "I rather have the
-- receipt have the job number and a numerical additional number following, like
-- 2026-178-R1 style."
--
-- Before: one office-wide series per year, RCP-YYYY-nnn (receipt_counters).
-- After : <invoice number>-R<n>, n = the n-th receipt on THAT invoice (deposit = -R1,
--         remainder = -R2, ...). A re-issued invoice such as 2026-094-2 gives
--         2026-094-2-R1. Receipts already issued (RCP-2026-001 … -065) keep their
--         numbers: they are documents the client holds.
--
-- Concurrency: two payments on the same invoice at the same moment would both count
-- the same existing receipts. A transaction-scoped advisory lock keyed on the invoice
-- number serialises them; the unique index on receipt_number is the backstop.
-- The old sigma_next_receipt_number(int) is kept (still granted) but no longer called.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.sigma_next_receipt_number_for(p_invoice_number text)
returns text language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_invoice_number is null or btrim(p_invoice_number) = '' then
    raise exception 'receipt number needs the invoice number';
  end if;
  perform pg_advisory_xact_lock(hashtext('sigma_receipt:' || p_invoice_number));
  select count(*) + 1 into v_n from public.payment_receipts where invoice_number = p_invoice_number;
  -- never collide with a number that already exists (a reversed-and-corrected payment
  -- keeps its receipt row, so the count can be lower than the highest suffix)
  while exists (select 1 from public.payment_receipts where receipt_number = p_invoice_number || '-R' || v_n) loop
    v_n := v_n + 1;
  end loop;
  return p_invoice_number || '-R' || v_n;
end $$;

grant execute on function public.sigma_next_receipt_number_for(text) to authenticated;
grant execute on function public.sigma_next_receipt_number_for(text) to anon;   -- same as the int one (SIGMA_invoicing_open_access.sql)

-- sigma_post_payment: identical to the live definition except the one numbering line.
create or replace function public.sigma_post_payment(
  p_invoice     uuid,
  p_amount      numeric,
  p_date        date default null,
  p_method      text default 'bank_transfer',
  p_reference   text default null,
  p_notes       text default null,
  p_actor       text default null
) returns jsonb language plpgsql as $$
declare v_inv public.invoices%rowtype; v_pay public.payments%rowtype; v_rcpt text; v_rid uuid;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'payment amount must be positive'; end if;
  select * into v_inv from public.invoices where id = p_invoice;
  if not found then raise exception 'invoice not found'; end if;
  if v_inv.status in ('draft') then raise exception 'finalise invoice % before recording a payment', v_inv.invoice_number; end if;
  if v_inv.status in ('void','credited') then raise exception 'invoice % is % and cannot take a payment', v_inv.invoice_number, v_inv.status; end if;
  insert into public.payments (client_name, payment_date, amount, currency, method, reference, notes, entered_by)
  values (v_inv.client_name, coalesce(p_date, current_date), p_amount, v_inv.currency, p_method, p_reference, p_notes, p_actor)
  returning * into v_pay;
  insert into public.payment_allocations (payment_id, invoice_id, amount) values (v_pay.id, p_invoice, p_amount);
  v_rcpt := public.sigma_next_receipt_number_for(v_inv.invoice_number);   -- was: sigma_next_receipt_number()
  insert into public.payment_receipts (receipt_number, payment_id, invoice_id, invoice_number, amount, created_by)
  values (v_rcpt, v_pay.id, p_invoice, v_inv.invoice_number, p_amount, p_actor) returning id into v_rid;
  insert into public.finance_audit_events (entity, entity_id, invoice_number, action, actor, after_state)
  values ('payment', v_pay.id, v_inv.invoice_number, 'payment_posted', p_actor,
          jsonb_build_object('amount', p_amount, 'method', p_method, 'receipt', v_rcpt));
  return jsonb_build_object('payment_id', v_pay.id, 'receipt_number', v_rcpt, 'receipt_id', v_rid,
    'invoice', (select to_jsonb(i) from public.invoices i where i.id = p_invoice));
end $$;

-- Dry run (reads only): the next receipt on 2026-178 (already has RCP-2026-065) is 2026-178-R2,
-- a job with no receipt yet gets -R1.
-- select public.sigma_next_receipt_number_for('2026-178'), public.sigma_next_receipt_number_for('2026-179');
