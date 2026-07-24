-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — Invoicing, Phase 4 (payments, allocations, receipts)
--
-- A payment can be full, partial, a deposit/advance, or unallocated. It is
-- linked to invoices through payment_allocations, so one payment may (later)
-- span invoices, and an invoice accrues many payments. The invoice's
-- amount_paid / balance / status are recomputed by TRIGGER from the allocations
-- of non-reversed payments — the browser never edits an invoice total when a
-- payment is posted (the invoice guard from Phase 2 forbids it anyway).
--
-- Receipts have their OWN sequence (RCP-YYYY-NNN) — deliberately NOT the invoice
-- number.
--
-- Access: authenticated only (Option A), like the rest of Finance.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── payments ────────────────────────────────────────────────────────────────
create table if not exists public.payments (
  id             uuid primary key default gen_random_uuid(),
  org_id         text not null default 'sigma',
  client_name    text,
  payment_date   date not null default current_date,
  amount         numeric(12,2) not null,
  currency       text not null default 'AWG',
  method         text not null default 'bank_transfer',
  reference      text,
  bank_reference text,
  notes          text,
  proof_path     text,
  entered_by     text,
  reconciled     boolean not null default false,
  reconciled_by  text,
  reconciled_at  timestamptz,
  reversed       boolean not null default false,
  reversal_reason text,
  created_at     timestamptz not null default now(),

  constraint payments_amount_chk check (amount > 0),
  constraint payments_method_chk check (method in
    ('cash','bank_transfer','credit_card','debit_card','check','online','other'))
);
create index if not exists payments_date_idx    on public.payments (payment_date desc);
create index if not exists payments_created_idx  on public.payments (created_at desc);

-- ── payment_allocations ─────────────────────────────────────────────────────
create table if not exists public.payment_allocations (
  id          uuid primary key default gen_random_uuid(),
  payment_id  uuid not null references public.payments(id) on delete cascade,
  invoice_id  uuid not null references public.invoices(id) on delete cascade,
  amount      numeric(12,2) not null,
  created_at  timestamptz not null default now(),
  constraint payment_alloc_amount_chk check (amount > 0)
);
create index if not exists payment_alloc_payment_idx on public.payment_allocations (payment_id);
create index if not exists payment_alloc_invoice_idx on public.payment_allocations (invoice_id);

-- ── receipts (own sequence) ─────────────────────────────────────────────────
create table if not exists public.receipt_counters (
  year int primary key, last_seq int not null default 0, updated_at timestamptz not null default now()
);
alter table public.receipt_counters enable row level security;   -- no policy: definer-only

create table if not exists public.payment_receipts (
  id             uuid primary key default gen_random_uuid(),
  org_id         text not null default 'sigma',
  receipt_number text not null unique,
  payment_id     uuid not null references public.payments(id) on delete cascade,
  invoice_id     uuid references public.invoices(id) on delete set null,
  invoice_number text,
  amount         numeric(12,2) not null,
  pdf_path       text,
  created_by     text,
  created_at     timestamptz not null default now()
);
create index if not exists payment_receipts_payment_idx on public.payment_receipts (payment_id);

create or replace function public.sigma_next_receipt_number(p_year int default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_year int := coalesce(p_year, extract(year from now())::int); v_next int;
begin
  insert into public.receipt_counters (year, last_seq) values (v_year, 1)
  on conflict (year) do update set last_seq = public.receipt_counters.last_seq + 1, updated_at = now()
  returning last_seq into v_next;
  return 'RCP-' || v_year || '-' || lpad(v_next::text, 3, '0');
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Recompute an invoice's paid/balance/status from its allocations. Only touches
-- invoices that are in a billable state (sent/partially_paid/paid); a draft, void
-- or credited invoice is left alone. 'overdue' stays a DERIVED view value, so it
-- is never stored here.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_invoice_apply_payments(p_invoice uuid)
returns void language plpgsql as $$
declare v_paid numeric(12,2); v_total numeric(12,2); v_status text; v_new text;
begin
  select coalesce(sum(a.amount), 0) into v_paid
    from public.payment_allocations a
    join public.payments p on p.id = a.payment_id
   where a.invoice_id = p_invoice and p.reversed = false;

  select total, status into v_total, v_status from public.invoices where id = p_invoice;
  if v_status is null or v_status in ('draft','void','credited') then
    -- keep amount_paid in step but do not move the lifecycle status
    update public.invoices set amount_paid = v_paid where id = p_invoice;
    return;
  end if;

  v_new := case when v_paid <= 0 then 'sent'
                when v_paid >= v_total then 'paid'
                else 'partially_paid' end;

  update public.invoices set amount_paid = v_paid, status = v_new where id = p_invoice;
end $$;

create or replace function public.sigma_alloc_touch()
returns trigger language plpgsql as $$
begin
  perform public.sigma_invoice_apply_payments(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;

drop trigger if exists payment_alloc_recalc on public.payment_allocations;
create trigger payment_alloc_recalc
  after insert or update or delete on public.payment_allocations
  for each row execute function public.sigma_alloc_touch();

-- When a payment is reversed, re-apply every invoice it touched.
create or replace function public.sigma_payment_reversed()
returns trigger language plpgsql as $$
declare r record;
begin
  if new.reversed is distinct from old.reversed then
    for r in select distinct invoice_id from public.payment_allocations where payment_id = new.id loop
      perform public.sigma_invoice_apply_payments(r.invoice_id);
    end loop;
  end if;
  return new;
end $$;

drop trigger if exists payments_reversed on public.payments;
create trigger payments_reversed after update on public.payments
  for each row execute function public.sigma_payment_reversed();

-- ─────────────────────────────────────────────────────────────────────────────
-- Post a payment against an invoice, generate a receipt, recalc the invoice.
-- Amount may be partial or exceed the balance (deposit / advance / overpayment).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_post_payment(
  p_invoice     uuid,
  p_amount      numeric,
  p_date        date default null,
  p_method      text default 'bank_transfer',
  p_reference   text default null,
  p_notes       text default null,
  p_actor       text default null
) returns jsonb language plpgsql security invoker as $$
declare
  v_inv public.invoices%rowtype;
  v_pay public.payments%rowtype;
  v_rcpt text;
  v_rid uuid;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'payment amount must be positive'; end if;

  select * into v_inv from public.invoices where id = p_invoice;
  if not found then raise exception 'invoice not found'; end if;
  if v_inv.status in ('draft') then raise exception 'finalise invoice % before recording a payment', v_inv.invoice_number; end if;
  if v_inv.status in ('void','credited') then raise exception 'invoice % is % and cannot take a payment', v_inv.invoice_number, v_inv.status; end if;

  insert into public.payments (client_name, payment_date, amount, currency, method, reference, notes, entered_by)
  values (v_inv.client_name, coalesce(p_date, current_date), p_amount, v_inv.currency, p_method, p_reference, p_notes, p_actor)
  returning * into v_pay;

  insert into public.payment_allocations (payment_id, invoice_id, amount)
  values (v_pay.id, p_invoice, p_amount);   -- fires the recalc trigger

  v_rcpt := public.sigma_next_receipt_number();
  insert into public.payment_receipts (receipt_number, payment_id, invoice_id, invoice_number, amount, created_by)
  values (v_rcpt, v_pay.id, p_invoice, v_inv.invoice_number, p_amount, p_actor)
  returning id into v_rid;

  insert into public.finance_audit_events (entity, entity_id, invoice_number, action, actor, after_state)
  values ('payment', v_pay.id, v_inv.invoice_number, 'payment_posted', p_actor,
          jsonb_build_object('amount', p_amount, 'method', p_method, 'receipt', v_rcpt));

  return jsonb_build_object(
    'payment_id', v_pay.id, 'receipt_number', v_rcpt, 'receipt_id', v_rid,
    'invoice', (select to_jsonb(i) from public.invoices i where i.id = p_invoice));
end $$;

-- Reverse a payment (bounced cheque, error). Keeps the record; undoes its effect.
create or replace function public.sigma_reverse_payment(p_payment uuid, p_reason text, p_actor text default null)
returns jsonb language plpgsql security invoker as $$
declare v_pay public.payments%rowtype;
begin
  select * into v_pay from public.payments where id = p_payment;
  if not found then raise exception 'payment not found'; end if;
  if v_pay.reversed then raise exception 'payment already reversed'; end if;

  update public.payments set reversed = true, reversal_reason = p_reason where id = p_payment;  -- fires recalc

  insert into public.finance_audit_events (entity, entity_id, action, actor, reason, after_state)
  values ('payment', p_payment, 'payment_reversed', p_actor, p_reason, jsonb_build_object('amount', v_pay.amount));

  return jsonb_build_object('ok', true, 'payment_id', p_payment);
end $$;

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table public.payments            enable row level security;
alter table public.payment_allocations enable row level security;
alter table public.payment_receipts    enable row level security;

drop policy if exists payments_auth      on public.payments;
drop policy if exists payment_alloc_auth on public.payment_allocations;
drop policy if exists payment_rcpt_auth  on public.payment_receipts;

create policy payments_auth      on public.payments            for all to authenticated using (true) with check (true);
create policy payment_alloc_auth on public.payment_allocations for all to authenticated using (true) with check (true);
create policy payment_rcpt_auth  on public.payment_receipts    for all to authenticated using (true) with check (true);

grant execute on function public.sigma_post_payment(uuid,numeric,date,text,text,text,text) to authenticated;
grant execute on function public.sigma_reverse_payment(uuid,text,text) to authenticated;
grant execute on function public.sigma_next_receipt_number(int) to authenticated;
grant execute on function public.sigma_invoice_apply_payments(uuid) to authenticated;
