-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — Invoicing, Phase 2 (core invoices)
--
-- ACCESS POSTURE (decision: Option A). Unlike every other table in this database,
-- the finance tables are granted to `authenticated` ONLY. The app ships the anon
-- key inside a public page, so anon-readable finance tables would publish the
-- whole receivables ledger to anyone who views source. A real Supabase Auth
-- session is required — see sigma-admin / v2.268 for how staff accounts are made.
--
-- MONEY. numeric(12,2) throughout. Totals are computed by TRIGGER, never by the
-- browser: the browser is untrusted and may only preview.
--
-- TAX. Prices are tax-inclusive with no breakout (confirmed by the firm), so
-- tax_amount is always 0 and total = subtotal. The columns exist so that adding a
-- BBO/BAZV breakout later is a data change, not a migration.
--
-- NUMBERING. invoice_number is copied from orders.order_id by the server and can
-- never be set or changed by a client. See docs/invoicing/ORDER_INVOICE_NUMBERING.md
-- ─────────────────────────────────────────────────────────────────────────────

-- ── invoices ────────────────────────────────────────────────────────────────
create table if not exists public.invoices (
  id                uuid primary key default gen_random_uuid(),
  org_id            text not null default 'sigma',

  -- link + numbering (invoice_number is ALWAYS order_number; kept as separate
  -- columns because the brief requires both to exist)
  order_id          text not null references public.orders(order_id) on update cascade,
  order_number      text not null,
  invoice_number    text not null,
  is_primary        boolean not null default true,

  status            text not null default 'draft',

  -- snapshots, frozen when the invoice is finalised so later edits to the client
  -- record can never alter a historical invoice
  client_name       text,
  client_email      text,
  client_phone      text,
  bill_to_name      text,
  bill_to_address   text,
  bill_to_city      text,
  bill_to_country   text,
  property_address  text,
  appraiser         text,
  service_description text,
  company_snapshot  jsonb,

  invoice_date      date not null default current_date,
  due_date          date,
  finalized_at      timestamptz,

  currency          text not null default 'AWG',
  tax_treatment     text not null default 'inclusive',
  subtotal          numeric(12,2) not null default 0,
  tax_amount        numeric(12,2) not null default 0,
  total             numeric(12,2) not null default 0,
  amount_paid       numeric(12,2) not null default 0,
  balance           numeric(12,2) generated always as (total - amount_paid) stored,

  payment_terms     text,
  public_notes      text,
  internal_notes    text,

  pdf_path          text,
  email_status      text not null default 'not_sent',
  qb_export_status  text not null default 'not_exported',

  created_by        text,
  finalized_by      text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint invoices_status_chk check (status in
    ('draft','sent','partially_paid','paid','overdue','void','credited')),
  constraint invoices_tax_chk check (tax_treatment in
    ('inclusive','added','exempt','none')),
  constraint invoices_money_chk check (subtotal >= 0 and total >= 0 and amount_paid >= 0),
  constraint invoices_number_matches_order check (invoice_number = order_number)
);

-- No two invoices may share a number within the firm.
create unique index if not exists invoices_org_number_uk
  on public.invoices (org_id, invoice_number);

-- At most ONE primary invoice per order. A voided invoice keeps its number but
-- frees the slot, so a corrected invoice can be raised for the same order.
create unique index if not exists invoices_one_primary_per_order
  on public.invoices (order_id)
  where is_primary and status <> 'void';

create index if not exists invoices_status_idx  on public.invoices (status);
create index if not exists invoices_order_idx   on public.invoices (order_id);
create index if not exists invoices_created_idx on public.invoices (created_at desc);

-- ── invoice_lines ───────────────────────────────────────────────────────────
create table if not exists public.invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.invoices(id) on delete cascade,
  line_no      int  not null default 1,
  description  text not null,
  quantity     numeric(12,2) not null default 1,
  unit_price   numeric(12,2) not null default 0,
  discount     numeric(12,2) not null default 0,
  line_total   numeric(12,2) generated always as
                 (round(quantity * unit_price - discount, 2)) stored,
  created_at   timestamptz not null default now()
);
create index if not exists invoice_lines_invoice_idx on public.invoice_lines (invoice_id, line_no);

-- ── finance_audit_events ────────────────────────────────────────────────────
create table if not exists public.finance_audit_events (
  id             uuid primary key default gen_random_uuid(),
  org_id         text not null default 'sigma',
  entity         text not null,
  entity_id      uuid,
  invoice_number text,
  action         text not null,
  actor          text,
  before_state   jsonb,
  after_state    jsonb,
  reason         text,
  metadata       jsonb,
  created_at     timestamptz not null default now()
);
create index if not exists finance_audit_entity_idx  on public.finance_audit_events (entity, entity_id);
create index if not exists finance_audit_created_idx on public.finance_audit_events (created_at desc);

-- ─────────────────────────────────────────────────────────────────────────────
-- Server-side money. The browser may preview; only this runs for real.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_invoice_recalc(p_invoice uuid)
returns void language plpgsql as $$
declare v_sub numeric(12,2);
begin
  select coalesce(sum(line_total), 0) into v_sub
    from public.invoice_lines where invoice_id = p_invoice;

  update public.invoices
     set subtotal   = v_sub,
         tax_amount = 0,            -- tax-inclusive, no breakout
         total      = v_sub,
         updated_at = now()
   where id = p_invoice;
end $$;

create or replace function public.sigma_invoice_lines_touch()
returns trigger language plpgsql as $$
begin
  perform public.sigma_invoice_recalc(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;

drop trigger if exists invoice_lines_recalc on public.invoice_lines;
create trigger invoice_lines_recalc
  after insert or update or delete on public.invoice_lines
  for each row execute function public.sigma_invoice_lines_touch();

-- ─────────────────────────────────────────────────────────────────────────────
-- Immutability. A finalised invoice is a legal document: it is never silently
-- edited and never deleted. Only the fields that legitimately move afterwards
-- (payment state, documents, export/email state) may change.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_invoice_guard()
returns trigger language plpgsql as $$
begin
  -- the number is derived from the order and is never editable
  if new.invoice_number is distinct from old.invoice_number
     or new.order_number is distinct from old.order_number
     or new.order_id     is distinct from old.order_id then
    raise exception 'invoice number / order link is immutable (invoice %)', old.invoice_number;
  end if;

  if old.status <> 'draft' then
    if new.subtotal is distinct from old.subtotal
       or new.total is distinct from old.total
       or new.invoice_date is distinct from old.invoice_date
       or new.client_name  is distinct from old.client_name
       or new.bill_to_address is distinct from old.bill_to_address then
      raise exception 'invoice % is finalised and cannot be edited (void it instead)', old.invoice_number;
    end if;
  end if;

  new.updated_at := now();
  return new;
end $$;

drop trigger if exists invoices_guard on public.invoices;
create trigger invoices_guard before update on public.invoices
  for each row execute function public.sigma_invoice_guard();

create or replace function public.sigma_invoice_no_delete()
returns trigger language plpgsql as $$
begin
  if old.status <> 'draft' then
    raise exception 'invoice % is finalised and cannot be deleted (void it instead)', old.invoice_number;
  end if;
  return old;
end $$;

drop trigger if exists invoices_no_delete on public.invoices;
create trigger invoices_no_delete before delete on public.invoices
  for each row execute function public.sigma_invoice_no_delete();

-- Lines of a finalised invoice are frozen too.
create or replace function public.sigma_invoice_lines_guard()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from public.invoices
   where id = coalesce(new.invoice_id, old.invoice_id);
  if v_status is not null and v_status <> 'draft' then
    raise exception 'invoice is finalised; its line items cannot be changed';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists invoice_lines_guard on public.invoice_lines;
create trigger invoice_lines_guard before insert or update or delete on public.invoice_lines
  for each row execute function public.sigma_invoice_lines_guard();

-- ─────────────────────────────────────────────────────────────────────────────
-- Effective status: 'overdue' is derived from the due date rather than stored,
-- so it is always correct without a scheduled job.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace view public.invoices_v as
  select i.*,
         case
           when i.status in ('void','credited','paid','draft') then i.status
           when i.balance > 0 and i.due_date is not null and i.due_date < current_date then 'overdue'
           else i.status
         end as effective_status,
         case when i.due_date is null or i.balance <= 0 then null
              else (current_date - i.due_date) end as days_overdue
    from public.invoices i;

-- ─────────────────────────────────────────────────────────────────────────────
-- Creating an invoice from an order. The NUMBER is taken from the order row by
-- the server, so a client cannot choose or spoof it.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_create_invoice_from_order(
  p_order_id      text,
  p_lines         jsonb default '[]'::jsonb,
  p_due_date      date  default null,
  p_payment_terms text  default null,
  p_public_notes  text  default null,
  p_actor         text  default null,
  p_company       jsonb default null
) returns jsonb
language plpgsql
security invoker            -- deliberately NOT definer: RLS still applies
as $$
declare
  v_ord   public.orders%rowtype;
  v_inv   public.invoices%rowtype;
  v_line  jsonb;
  v_extra jsonb;
  v_n     int := 0;
begin
  select * into v_ord from public.orders where order_id = p_order_id;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;

  if exists (select 1 from public.invoices
              where order_id = p_order_id and is_primary and status <> 'void') then
    raise exception 'order % already has a primary invoice', p_order_id;
  end if;

  begin v_extra := v_ord.extra_data::jsonb; exception when others then v_extra := '{}'::jsonb; end;

  insert into public.invoices (
    order_id, order_number, invoice_number,
    client_name, client_email, client_phone,
    bill_to_name, bill_to_address, bill_to_city, bill_to_country,
    property_address, appraiser, service_description,
    due_date, payment_terms, public_notes,
    company_snapshot, created_by
  ) values (
    v_ord.order_id, v_ord.order_id, v_ord.order_id,       -- number inherited, server-side
    coalesce(v_ord.client, trim(coalesce(v_extra->>'clientFirst','') || ' ' || coalesce(v_extra->>'clientLast',''))),
    nullif(v_extra->>'clientEmail',''),
    coalesce(nullif(v_extra->>'clientCell',''), nullif(v_extra->>'clientWork','')),
    coalesce(v_ord.client, trim(coalesce(v_extra->>'clientFirst','') || ' ' || coalesce(v_extra->>'clientLast',''))),
    nullif(v_extra->>'clientAddr',''),
    nullif(v_extra->>'city',''),
    nullif(v_extra->>'country',''),
    trim(coalesce(v_ord.address,'') || case when v_ord.city is not null then ', ' || v_ord.city else '' end),
    v_ord.appraiser,
    coalesce(v_ord.property_type, 'Appraisal services'),
    p_due_date, p_payment_terms, p_public_notes,
    p_company, p_actor
  ) returning * into v_inv;

  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_n := v_n + 1;
    insert into public.invoice_lines (invoice_id, line_no, description, quantity, unit_price, discount)
    values (
      v_inv.id, v_n,
      coalesce(v_line->>'description', 'Appraisal services'),
      coalesce((v_line->>'quantity')::numeric, 1),
      coalesce((v_line->>'unit_price')::numeric, 0),
      coalesce((v_line->>'discount')::numeric, 0)
    );
  end loop;

  -- fall back to the order's agreed fee when no lines were supplied
  if v_n = 0 and coalesce(v_ord.fee, 0) > 0 then
    insert into public.invoice_lines (invoice_id, line_no, description, quantity, unit_price)
    values (v_inv.id, 1, 'Appraisal services — ' || v_ord.order_id, 1, v_ord.fee);
  end if;

  perform public.sigma_invoice_recalc(v_inv.id);

  insert into public.finance_audit_events (entity, entity_id, invoice_number, action, actor, after_state)
  values ('invoice', v_inv.id, v_inv.invoice_number, 'invoice_created', p_actor,
          jsonb_build_object('order_id', p_order_id, 'lines', v_n));

  select to_jsonb(x) into v_extra from (
    select i.*, (select coalesce(jsonb_agg(to_jsonb(l) order by l.line_no), '[]'::jsonb)
                   from public.invoice_lines l where l.invoice_id = i.id) as lines
      from public.invoices i where i.id = v_inv.id
  ) x;
  return v_extra;
end $$;

-- Finalise: freeze the invoice and stamp who/when.
create or replace function public.sigma_finalize_invoice(p_invoice uuid, p_actor text default null)
returns jsonb language plpgsql security invoker as $$
declare v_inv public.invoices%rowtype;
begin
  select * into v_inv from public.invoices where id = p_invoice;
  if not found then raise exception 'invoice not found'; end if;
  if v_inv.status <> 'draft' then raise exception 'invoice % is already finalised', v_inv.invoice_number; end if;
  if v_inv.total <= 0 then raise exception 'invoice % has no value to bill', v_inv.invoice_number; end if;

  update public.invoices
     set status = 'sent', finalized_at = now(), finalized_by = p_actor
   where id = p_invoice returning * into v_inv;

  insert into public.finance_audit_events (entity, entity_id, invoice_number, action, actor)
  values ('invoice', p_invoice, v_inv.invoice_number, 'invoice_finalized', p_actor);

  return to_jsonb(v_inv);
end $$;

-- Void: keeps the number, stays visible, never reused.
create or replace function public.sigma_void_invoice(p_invoice uuid, p_reason text, p_actor text default null)
returns jsonb language plpgsql security invoker as $$
declare v_inv public.invoices%rowtype;
begin
  select * into v_inv from public.invoices where id = p_invoice;
  if not found then raise exception 'invoice not found'; end if;
  if v_inv.status = 'void' then raise exception 'invoice % is already void', v_inv.invoice_number; end if;

  update public.invoices set status = 'void', internal_notes =
      coalesce(internal_notes || E'\n', '') || 'VOID: ' || coalesce(p_reason, '(no reason given)')
   where id = p_invoice returning * into v_inv;

  insert into public.finance_audit_events (entity, entity_id, invoice_number, action, actor, reason)
  values ('invoice', p_invoice, v_inv.invoice_number, 'invoice_voided', p_actor, p_reason);

  return to_jsonb(v_inv);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- RLS — authenticated ONLY (Option A). anon is deliberately absent.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.invoices             enable row level security;
alter table public.invoice_lines        enable row level security;
alter table public.finance_audit_events enable row level security;

drop policy if exists invoices_auth      on public.invoices;
drop policy if exists invoice_lines_auth on public.invoice_lines;
drop policy if exists finance_audit_read on public.finance_audit_events;
drop policy if exists finance_audit_ins  on public.finance_audit_events;

create policy invoices_auth on public.invoices
  for all to authenticated using (true) with check (true);
create policy invoice_lines_auth on public.invoice_lines
  for all to authenticated using (true) with check (true);
-- Audit trail is append-only: readable and insertable, never updated or deleted.
create policy finance_audit_read on public.finance_audit_events
  for select to authenticated using (true);
create policy finance_audit_ins on public.finance_audit_events
  for insert to authenticated with check (true);

grant execute on function public.sigma_create_invoice_from_order(text,jsonb,date,text,text,text,jsonb) to authenticated;
grant execute on function public.sigma_finalize_invoice(uuid,text) to authenticated;
grant execute on function public.sigma_void_invoice(uuid,text,text) to authenticated;
grant execute on function public.sigma_invoice_recalc(uuid) to authenticated;
