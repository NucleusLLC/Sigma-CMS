-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — Invoicing, Phase 5 (statements & reports)
--
-- Read-mostly. The heavy lifting (balances, statuses) was already done in phases
-- 2-4; this adds a flat payments view for payment reports & statements, an AR
-- aging view, a management-summary function, and a client_statements table that
-- records each statement generated (for history + emailing).
--
-- Access: authenticated only (Option A), like the rest of Finance.
-- ─────────────────────────────────────────────────────────────────────────────

-- Flat payment view: one row per allocation, carrying the payment + the invoice
-- it was applied to. Reversed payments are flagged, not hidden, so payment
-- reports can show them. Money already decimal-safe upstream.
create or replace view public.payments_v as
  select p.id                as payment_id,
         a.id                as allocation_id,
         p.org_id,
         p.payment_date,
         a.amount,
         p.currency,
         p.method,
         p.reference,
         p.bank_reference,
         p.reversed,
         p.entered_by,
         p.created_at,
         i.id                as invoice_id,
         i.invoice_number,
         i.order_number,
         i.client_name,
         i.appraiser
    from public.payment_allocations a
    join public.payments p on p.id = a.payment_id
    join public.invoices i on i.id = a.invoice_id;

-- AR aging: one row per open invoice with its bucket. Uses the server-computed
-- balance and due date, so it is always consistent with the invoice.
create or replace view public.ar_aging_v as
  select i.id,
         i.org_id,
         i.invoice_number,
         i.order_number,
         i.client_name,
         i.appraiser,
         i.currency,
         i.total,
         i.amount_paid,
         i.balance,
         i.due_date,
         case when i.due_date is null then 0 else greatest(0, current_date - i.due_date) end as days_overdue,
         case
           when i.balance <= 0 then 'settled'
           when i.due_date is null or i.due_date >= current_date then 'current'
           when current_date - i.due_date <= 30 then 'd1_30'
           when current_date - i.due_date <= 60 then 'd31_60'
           when current_date - i.due_date <= 90 then 'd61_90'
           else 'd90_plus'
         end as bucket
    from public.invoices i
   where i.status in ('sent','partially_paid','paid','overdue')
     and i.balance > 0;

-- Management summary. Single row of firm-wide figures. 'draft' and 'void' are
-- excluded from invoiced/collected; only real, live invoices count.
create or replace function public.sigma_finance_summary(
  p_from date default null, p_to date default null
) returns jsonb language sql stable as $$
  with live as (
    select * from public.invoices
     where status not in ('draft','void')
       and (p_from is null or invoice_date >= p_from)
       and (p_to   is null or invoice_date <= p_to)
  )
  select jsonb_build_object(
    'total_invoiced',   coalesce((select sum(total) from live), 0),
    'total_collected',  coalesce((select sum(amount_paid) from live), 0),
    'total_outstanding',coalesce((select sum(balance) from live where balance > 0), 0),
    'overdue_amount',   coalesce((select sum(balance) from live
                                   where balance > 0 and due_date is not null and due_date < current_date), 0),
    'invoice_count',    (select count(*) from live),
    'paid_count',       (select count(*) from live where status = 'paid'),
    'draft_count',      (select count(*) from public.invoices where status = 'draft'),
    'orders_without_invoice', (
        select count(*) from public.orders o
         where not exists (select 1 from public.invoices i
                            where i.order_id = o.order_id and i.status <> 'void'))
  );
$$;

-- ── client_statements (history of statements produced) ──────────────────────
create table if not exists public.statement_counters (
  year int primary key, last_seq int not null default 0, updated_at timestamptz not null default now()
);
alter table public.statement_counters enable row level security;   -- definer-only

create table if not exists public.client_statements (
  id                uuid primary key default gen_random_uuid(),
  org_id            text not null default 'sigma',
  statement_number  text not null unique,
  client_name       text not null,
  period_from       date,
  period_to         date,
  total_outstanding numeric(12,2) not null default 0,
  pdf_path          text,
  emailed_to        text,
  created_by        text,
  created_at        timestamptz not null default now()
);
create index if not exists client_statements_client_idx on public.client_statements (client_name, created_at desc);

create or replace function public.sigma_next_statement_number(p_year int default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_year int := coalesce(p_year, extract(year from now())::int); v_next int;
begin
  insert into public.statement_counters (year, last_seq) values (v_year, 1)
  on conflict (year) do update set last_seq = public.statement_counters.last_seq + 1, updated_at = now()
  returning last_seq into v_next;
  return 'STMT-' || v_year || '-' || lpad(v_next::text, 3, '0');
end $$;

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table public.client_statements enable row level security;
drop policy if exists client_statements_auth on public.client_statements;
create policy client_statements_auth on public.client_statements
  for all to authenticated using (true) with check (true);

grant select on public.payments_v to authenticated;
grant select on public.ar_aging_v to authenticated;
grant execute on function public.sigma_finance_summary(date,date) to authenticated;
grant execute on function public.sigma_next_statement_number(int) to authenticated;
