-- ═══════════════════════════════════════════════════════════════════════════
-- SIGMA — invoice discount + BBO turnover tax                       (v2.326)
-- ═══════════════════════════════════════════════════════════════════════════
-- Additive only. Every column lands with a default that reproduces today's
-- arithmetic exactly, so an invoice that is never touched again keeps the
-- number it already has.
--
-- THE ONE ARITHMETIC RULE. Aruba's BBO is a turnover tax INCLUDED in the
-- price the client pays. On a AWG 1,000 invoice the tax component is
--
--     1000 * 7 / 107 = 65.42        NOT   1000 * 7% = 70.00
--
-- Getting that backwards overstates the liability by 7% on every filing.
-- Hence rate/(100+rate) for 'inclusive', and rate/100 only for 'added'.
--
-- WHY tax_amount IS STORED RATHER THAN DERIVED AT REPORT TIME. A rate change
-- must not restate invoices that were already issued and filed under the old
-- rate. Freezing the money on the row at the moment the lines are costed is
-- what makes "a 2026 invoice keeps the 2026 rate for ever" true by
-- construction instead of by a date join that a back-dated invoice could
-- silently defeat.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The rate schedule. Effective-dated and per-jurisdiction, because the rate
--    changes over time and the firm may bill from another island.
--    APPEND-ONLY by convention: to change a rate, add a row with a later
--    valid_from. The old row stays as the record of what was charged then.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.tax_rates (
  id           uuid primary key default gen_random_uuid(),
  org_id       text not null default 'sigma',
  jurisdiction text not null default 'AW',      -- AW Aruba, BON, CUR, SXM
  tax_code     text not null default 'BBO',     -- BBO / BAZV / BAVP as separate rows
  label        text not null default 'BBO',     -- what prints on the invoice
  rate         numeric(6,3) not null,           -- percent, e.g. 7.000
  valid_from   date not null,
  valid_to     date,                            -- null = still in force
  note         text,
  created_at   timestamptz not null default now(),
  constraint tax_rates_rate_chk  check (rate >= 0 and rate < 100),
  constraint tax_rates_range_chk check (valid_to is null or valid_to >= valid_from)
);

create index if not exists tax_rates_lookup_idx
  on public.tax_rates (org_id, jurisdiction, tax_code, valid_from desc);

-- Aruba BBO, 7%, open-ended and back-dated far enough to cover every invoice
-- that already exists. Idempotent: re-running this file does not duplicate it.
insert into public.tax_rates (jurisdiction, tax_code, label, rate, valid_from, note)
select 'AW', 'BBO', 'BBO', 7.000, date '2000-01-01',
       'Seeded with the invoicing tax module. Aruba turnover tax, included in price.'
where not exists (
  select 1 from public.tax_rates
   where org_id = 'sigma' and jurisdiction = 'AW' and tax_code = 'BBO'
);

alter table public.tax_rates enable row level security;

-- Readable by the app; append-only for the anon key. Changing history
-- (update/delete) needs a real cloud login. Adding a new rate -- the only
-- operation the Settings panel performs -- does not.
drop policy if exists tax_rates_read   on public.tax_rates;
drop policy if exists tax_rates_append on public.tax_rates;
drop policy if exists tax_rates_amend  on public.tax_rates;
create policy tax_rates_read   on public.tax_rates for select to anon, authenticated using (true);
create policy tax_rates_append on public.tax_rates for insert to anon, authenticated with check (true);
create policy tax_rates_amend  on public.tax_rates for update to authenticated using (true) with check (true);

grant select, insert on public.tax_rates to anon;
grant select, insert, update on public.tax_rates to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. New invoice columns.
--    jurisdiction: liability follows where the SERVICE is supplied, which is
--      not necessarily bill_to_country -- so it is its own column, not derived.
--    discount_*: discount_value is what the appraiser typed, discount_amount is
--      the money it resolved to. Both are kept so a percentage still reads as a
--      percentage after the fact.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.invoices
  add column if not exists jurisdiction    text          not null default 'AW',
  add column if not exists tax_code        text          not null default 'BBO',
  add column if not exists tax_rate        numeric(6,3)  not null default 0,
  add column if not exists tax_label       text          not null default 'BBO',
  add column if not exists discount_type   text          not null default 'none',
  add column if not exists discount_value  numeric(12,2) not null default 0,
  add column if not exists discount_amount numeric(12,2) not null default 0,
  add column if not exists discount_reason text;

do $$ begin
  alter table public.invoices
    add constraint invoices_discount_chk
    check (discount_type in ('none','amount','percent')
           and discount_value  >= 0
           and discount_amount >= 0);
exception when duplicate_object then null; end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Rate lookup. Resolved against the INVOICE's own date, never current_date.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_tax_rate(
  p_jurisdiction text default 'AW',
  p_tax_code     text default 'BBO',
  p_on           date default current_date,
  p_org          text default 'sigma')
returns table (rate numeric, label text)
language sql stable as $$
  select t.rate, t.label
    from public.tax_rates t
   where t.org_id       = coalesce(p_org, 'sigma')
     and t.jurisdiction = coalesce(p_jurisdiction, 'AW')
     and t.tax_code     = coalesce(p_tax_code, 'BBO')
     and t.valid_from  <= coalesce(p_on, current_date)
     and (t.valid_to is null or t.valid_to >= coalesce(p_on, current_date))
   order by t.valid_from desc
   limit 1;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The recalculation. Still the ONLY writer of invoices.subtotal / total --
--    that is what keeps balance, apply_payments, the aging view, the finance
--    summary and the statements all consistent for free.
--
--    Order of operations, and it matters:
--      subtotal  = sum of the lines (each line's own per-line discount already
--                  subtracted by the generated column)
--      discount  = the invoice-level discount, CLAMPED to [0, subtotal]
--      total     = subtotal - discount
--      tax       = computed on the DISCOUNTED figure, because that is the
--                  turnover actually realised
--
--    The clamp is not cosmetic: invoices_money_chk rejects a negative total,
--    so an un-clamped 120% discount would abort the whole transaction.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_invoice_recalc(p_invoice uuid)
returns void language plpgsql as $$
declare
  v_sub   numeric(12,2);
  v_disc  numeric(12,2);
  v_net   numeric(12,2);
  v_total numeric(12,2);
  v_tax   numeric(12,2);
  v_rate  numeric(6,3);
  v_label text;
  v_inv   record;
begin
  select coalesce(sum(line_total), 0) into v_sub
    from public.invoice_lines where invoice_id = p_invoice;

  select discount_type, discount_value, invoice_date, tax_treatment,
         jurisdiction, tax_code, org_id
    into v_inv
    from public.invoices where id = p_invoice;

  if not found then return; end if;

  -- invoice-level discount
  v_disc := case
    when v_inv.discount_type = 'percent' then round(v_sub * coalesce(v_inv.discount_value,0) / 100.0, 2)
    when v_inv.discount_type = 'amount'  then round(coalesce(v_inv.discount_value,0), 2)
    else 0 end;
  if v_disc < 0     then v_disc := 0;     end if;
  if v_disc > v_sub then v_disc := v_sub; end if;

  v_net := v_sub - v_disc;

  select r.rate, r.label into v_rate, v_label
    from public.sigma_tax_rate(v_inv.jurisdiction, v_inv.tax_code,
                               v_inv.invoice_date, v_inv.org_id) r;
  v_rate  := coalesce(v_rate, 0);
  v_label := coalesce(v_label, coalesce(v_inv.tax_code, 'BBO'));

  if v_rate <= 0 or v_inv.tax_treatment in ('exempt','none') then
    v_tax   := 0;
    v_total := v_net;
  elsif v_inv.tax_treatment = 'added' then
    -- Tax on top. No invoice uses this today and no screen can set it, but
    -- leaving it to fall through to the inclusive branch would under-collect.
    v_tax   := round(v_net * v_rate / 100.0, 2);
    v_total := v_net + v_tax;
  else
    -- 'inclusive' -- the Aruba default. The tax is already inside v_net.
    v_tax   := round(v_net * v_rate / (100.0 + v_rate), 2);
    v_total := v_net;
  end if;

  update public.invoices
     set subtotal        = v_sub,
         discount_amount = v_disc,
         tax_rate        = v_rate,
         tax_label       = v_label,
         tax_amount      = v_tax,
         total           = v_total,
         updated_at      = now()
   where id = p_invoice;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Guard. Unchanged in every respect except that the new money fields join
--    the two existing frozen lists -- otherwise a stray UPDATE could discount a
--    void invoice, or move discount_type on a finalised one without the total
--    following it (recalc only fires on LINE changes, so the two would part).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_invoice_guard()
returns trigger language plpgsql as $$
declare
  -- The edit gate. NULL unless sigma_edit_invoice() is running in this very
  -- transaction, and it names the one invoice that call is allowed to touch.
  v_gate text := coalesce(current_setting('sigma.invoice_edit', true), '');
begin
  -- ABSOLUTE. Not relaxed by the gate, not relaxed by anything.
  if new.invoice_number is distinct from old.invoice_number
     or new.order_number is distinct from old.order_number
     or new.order_id     is distinct from old.order_id
     or new.is_primary   is distinct from old.is_primary then
    raise exception 'invoice number / order link is immutable (invoice %)', old.invoice_number;
  end if;

  -- VOID IS TERMINAL.
  if old.status = 'void' then
    if new.invoice_date        is distinct from old.invoice_date
       or new.due_date         is distinct from old.due_date
       or new.subtotal         is distinct from old.subtotal
       or new.tax_amount       is distinct from old.tax_amount
       or new.total            is distinct from old.total
       or new.currency         is distinct from old.currency
       or new.tax_treatment    is distinct from old.tax_treatment
       -- SS TAX-DISCOUNT (v2.326) -- a withdrawn invoice carries no liability
       -- and no discount. Frozen with the rest of the face of the document.
       or new.jurisdiction     is distinct from old.jurisdiction
       or new.tax_code         is distinct from old.tax_code
       or new.tax_rate         is distinct from old.tax_rate
       or new.tax_label        is distinct from old.tax_label
       or new.discount_type    is distinct from old.discount_type
       or new.discount_value   is distinct from old.discount_value
       or new.discount_amount  is distinct from old.discount_amount
       or new.client_name      is distinct from old.client_name
       or new.client_email     is distinct from old.client_email
       or new.client_phone     is distinct from old.client_phone
       or new.bill_to_name     is distinct from old.bill_to_name
       or new.bill_to_address  is distinct from old.bill_to_address
       or new.bill_to_city     is distinct from old.bill_to_city
       or new.bill_to_country  is distinct from old.bill_to_country
       or new.property_address is distinct from old.property_address
       or new.appraiser        is distinct from old.appraiser
       or new.service_description is distinct from old.service_description
       or new.payment_terms    is distinct from old.payment_terms
       or new.public_notes     is distinct from old.public_notes then
      raise exception 'invoice % is void and can never be edited', old.invoice_number;
    end if;
    new.updated_at := now();
    return new;
  end if;

  -- FINALISED.
  if old.status <> 'draft' and v_gate <> old.id::text then
    if new.subtotal is distinct from old.subtotal
       or new.total is distinct from old.total
       -- SS TAX-DISCOUNT (v2.326) -- the discount must travel through the gated
       -- path so that recalc + apply_payments run with it. Set on its own it
       -- would be a stored intent the total never reflects.
       or new.discount_type   is distinct from old.discount_type
       or new.discount_value  is distinct from old.discount_value
       or new.discount_amount is distinct from old.discount_amount
       or new.invoice_date is distinct from old.invoice_date
       or new.client_name  is distinct from old.client_name
       or new.bill_to_address is distinct from old.bill_to_address then
      raise exception 'invoice % is finalised and cannot be edited (void it instead)', old.invoice_number;
    end if;
  end if;

  new.updated_at := now();
  return new;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Setting the discount. A dedicated RPC rather than a raw UPDATE because
--    three things have to happen together or the invoice ends up inconsistent:
--      - the gate must be open, or the guard refuses the total change
--      - recalc must run, or the discount is stored but not charged
--      - apply_payments must run, or a discounted invoice that is already paid
--        keeps a stale status (the classic 'paid' row with a positive balance)
--    sigma_invoice_recalc does NOT call apply_payments -- only sigma_edit_invoice
--    does -- which is exactly the trap this function exists to close.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_set_invoice_discount(
  p_invoice       uuid,
  p_type          text,
  p_value         numeric,
  p_reason        text default null,
  p_allow_overpay boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv    record;
  v_before numeric(12,2);
  v_after  record;
begin
  select * into v_inv from public.invoices where id = p_invoice for update;
  if not found then
    raise exception 'invoice not found';
  end if;
  if v_inv.status = 'void' then
    raise exception 'invoice % is void and can never be edited', v_inv.invoice_number;
  end if;
  if coalesce(p_type,'none') not in ('none','amount','percent') then
    raise exception 'discount type must be none, amount or percent';
  end if;
  if coalesce(p_value,0) < 0 then
    raise exception 'a discount cannot be negative';
  end if;
  if p_type = 'percent' and coalesce(p_value,0) > 100 then
    raise exception 'a percentage discount cannot exceed 100 percent';
  end if;

  v_before := v_inv.total;

  -- Open the gate for this invoice only, transaction-scoped.
  perform set_config('sigma.invoice_edit', p_invoice::text, true);

  update public.invoices
     set discount_type   = coalesce(p_type,'none'),
         discount_value  = case when coalesce(p_type,'none') = 'none' then 0
                                else round(coalesce(p_value,0), 2) end,
         discount_reason = p_reason
   where id = p_invoice;

  perform public.sigma_invoice_recalc(p_invoice);
  perform public.sigma_invoice_apply_payments(p_invoice);

  select * into v_after from public.invoices where id = p_invoice;

  if v_after.balance < 0 and not coalesce(p_allow_overpay, false) then
    raise exception 'that discount takes the invoice below what has already been paid (balance %). Refund or reverse the payment first, or confirm the overpayment.', v_after.balance;
  end if;

  insert into public.finance_audit_events (org_id, entity, entity_id, invoice_number, action, actor, reason, metadata)
  values (v_inv.org_id, 'invoice', p_invoice, v_inv.invoice_number, 'invoice_discounted',
          current_setting('request.jwt.claim.email', true), p_reason,
          jsonb_build_object(
            'discount_type',   v_after.discount_type,
            'discount_value',  v_after.discount_value,
            'discount_amount', v_after.discount_amount,
            'total_before',    v_before,
            'total_after',     v_after.total,
            'tax_after',       v_after.tax_amount));

  return jsonb_build_object(
    'ok', true,
    'subtotal', v_after.subtotal,
    'discount_amount', v_after.discount_amount,
    'tax_amount', v_after.tax_amount,
    'tax_rate', v_after.tax_rate,
    'tax_label', v_after.tax_label,
    'total', v_after.total,
    'amount_paid', v_after.amount_paid,
    'balance', v_after.balance,
    'status', v_after.status);
end $$;

grant execute on function public.sigma_set_invoice_discount(uuid, text, numeric, text, boolean) to anon, authenticated;
grant execute on function public.sigma_tax_rate(text, text, date, text) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. The monthly liability report.
--
--    Accrual basis: the tax is owed on the month the invoice was RAISED, which
--    is the definition sigma_finance_summary already uses (invoice_date, and
--    draft/void excluded). Two panels that disagree about what a month is would
--    be worse than either.
--
--    Grouped by currency AND treatment on purpose. Folding an exempt invoice or
--    a USD invoice into one AWG total produces a plausible-looking wrong number,
--    which is the worst kind on a tax filing.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sigma_bbo_report(
  p_from date default null,
  p_to   date default null,
  p_org  text default 'sigma')
returns jsonb
language sql stable as $$
  with live as (
    select *
      from public.invoices
     where org_id = coalesce(p_org,'sigma')
       and status not in ('draft','void','credited')
       and (p_from is null or invoice_date >= p_from)
       and (p_to   is null or invoice_date <= p_to)
  )
  select jsonb_build_object(
    'from', p_from,
    'to',   p_to,
    'months', coalesce((
      select jsonb_agg(x order by x->>'month')
        from (
          select jsonb_build_object(
                   'month',    to_char(date_trunc('month', invoice_date), 'YYYY-MM'),
                   'currency', currency,
                   'count',    count(*),
                   'gross',    sum(total),
                   'discount', sum(discount_amount),
                   'tax',      sum(tax_amount),
                   'net',      sum(total) - sum(tax_amount),
                   'collected', sum(amount_paid),
                   'tax_on_collected',
                     round(sum(case when total > 0
                                    then tax_amount * (amount_paid / total)
                                    else 0 end), 2)
                 ) as x
            from live
           group by date_trunc('month', invoice_date), currency
        ) s), '[]'::jsonb),
    'totals', coalesce((
      select jsonb_agg(y order by y->>'currency')
        from (
          select jsonb_build_object(
                   'currency', currency,
                   'count',    count(*),
                   'gross',    sum(total),
                   'discount', sum(discount_amount),
                   'tax',      sum(tax_amount),
                   'net',      sum(total) - sum(tax_amount)
                 ) as y
            from live group by currency
        ) t), '[]'::jsonb),
    'exceptions', coalesce((
      select jsonb_agg(z order by z->>'invoice_number')
        from (
          select jsonb_build_object(
                   'invoice_number', invoice_number,
                   'invoice_date',   invoice_date,
                   'currency',       currency,
                   'treatment',      tax_treatment,
                   'rate',           tax_rate,
                   'total',          total,
                   'tax',            tax_amount,
                   'why', case when tax_rate = 0 then 'no rate stamped on this invoice'
                               when tax_treatment <> 'inclusive' then 'not tax-inclusive'
                               else 'unknown' end
                 ) as z
            from live
           where tax_rate = 0 or tax_treatment <> 'inclusive'
        ) e), '[]'::jsonb),
    'draft_pending', coalesce((
      select jsonb_build_object('count', count(*), 'gross', coalesce(sum(total),0))
        from public.invoices
       where org_id = coalesce(p_org,'sigma') and status = 'draft'
         and (p_from is null or invoice_date >= p_from)
         and (p_to   is null or invoice_date <= p_to)
    ), '{}'::jsonb)
  );
$$;

grant execute on function public.sigma_bbo_report(date, date, text) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Backfill. Stamps the rate and the tax onto invoices that already exist.
--
--    Deliberately EXCLUDES void invoices -- the guard freezes tax_amount on
--    them, and a withdrawn invoice owes nothing anyway.
--    Touches only tax_*; subtotal and total are untouched, so the finalised
--    guard has nothing to object to and no client-visible figure moves.
-- ─────────────────────────────────────────────────────────────────────────────
-- The rate is resolved per invoice against that invoice's OWN date, via a LATERAL
-- join in a CTE. sigma_tax_rate() cannot be called directly in an UPDATE ... FROM
-- because a set-returning function there may not reference the update target.
with resolved as (
  select i.id, tr.rate, tr.label
    from public.invoices i
    join lateral (
      select t.rate, t.label
        from public.tax_rates t
       where t.org_id       = i.org_id
         and t.jurisdiction = i.jurisdiction
         and t.tax_code     = i.tax_code
         and t.valid_from  <= i.invoice_date
         and (t.valid_to is null or t.valid_to >= i.invoice_date)
       order by t.valid_from desc
       limit 1
    ) tr on true
   where i.status <> 'void'
     and i.tax_rate = 0
)
update public.invoices i
   set tax_rate   = r.rate,
       tax_label  = r.label,
       tax_amount = case
         when i.tax_treatment in ('exempt','none') or r.rate <= 0 then 0
         when i.tax_treatment = 'added' then round((i.total / (1 + r.rate/100.0)) * r.rate / 100.0, 2)
         else round(i.total * r.rate / (100.0 + r.rate), 2)
       end
  from resolved r
 where r.id = i.id;
