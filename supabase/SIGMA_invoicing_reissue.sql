-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — Invoicing: re-issue a corrected invoice after a void  (§INVOICE-REISSUE)
--
-- THE BUG. Three rules disagreed with each other, and the disagreement only
-- surfaced the first time an invoice was actually voided (order 2026-094):
--
--   1. invoices_one_primary_per_order — `unique (order_id) where is_primary and
--      status <> 'void'`. Its stated intent: "A voided invoice keeps its number
--      but frees the slot, so a corrected invoice can be raised for the same
--      order." sigma_create_invoice_from_order's own guard agrees — it refuses
--      only when a NON-void primary exists.
--
--   2. invoices_org_number_uk — `unique (org_id, invoice_number)`. The voided
--      invoice still HOLDS 2026-094, so the replacement (also numbered 2026-094,
--      because the RPC copies orders.order_id) collided → duplicate key.
--
--   3. invoices_number_matches_order — `check (invoice_number = order_number)`.
--      Even with (2) resolved, this forbade any number that is not literally the
--      order number, so a suffix was impossible too.
--
-- THE RULE (owner's decision). A re-issued invoice is SUFFIXED against its order
-- number: 2026-094, then 2026-094-2, then 2026-094-3. The invoice stays tied to
-- its order, it is obvious the document replaces an earlier one, and no invoice
-- number is ever reused — the hard rule stated in SIGMA_order_numbering.sql:9.
--
-- order_number is UNCHANGED: it always remains the plain order number, so every
-- report that groups or joins by order keeps working. Only invoice_number moves.
--
-- The suffix is derived SERVER-SIDE from what already exists. It is never passed
-- in, and a client-supplied number is still impossible to set.
--
-- Idempotent: safe to run more than once. Rollback at the foot of this file.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Allow the suffix ─────────────────────────────────────────────────────
-- invoice_number is either the order number exactly, or the order number plus
-- '-<n>'. Deliberately NOT written with LIKE: '_' and '%' are LIKE wildcards and
-- an order number is user-visible data, so the prefix is compared as a literal.
alter table public.invoices drop constraint if exists invoices_number_matches_order;
alter table public.invoices add constraint invoices_number_matches_order check (
  invoice_number = order_number
  or ( left(invoice_number, length(order_number) + 1) = order_number || '-'
       and substring(invoice_number from length(order_number) + 2) ~ '^[0-9]{1,6}$' )
);

-- invoices_org_number_uk and invoices_one_primary_per_order are deliberately
-- LEFT ALONE. The first is now the race backstop (see the concurrency note in
-- the function); the second still enforces "one live invoice per order".

-- ── 2. Derive the number inside the RPC ─────────────────────────────────────
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
  v_ord     public.orders%rowtype;
  v_inv     public.invoices%rowtype;
  v_line    jsonb;
  v_extra   jsonb;
  v_n       int  := 0;
  v_org     text := 'sigma';   -- same value as the invoices.org_id column default;
                               -- named here so the uniqueness scan below is scoped
                               -- to exactly the rows invoices_org_number_uk covers.
  v_base    text;
  v_baselen int;
  v_attempt int;
  v_invno   text;
  v_try     int;
begin
  select * into v_ord from public.orders where order_id = p_order_id;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;

  -- §INVOICE-REISSUE — CONCURRENCY. Everything below (the "already invoiced"
  -- guard, reading the highest suffix, and the insert) has to be one indivisible
  -- decision. Under READ COMMITTED two simultaneous clicks would each read the
  -- committed state, both conclude "next is -2", and one would then fail on a raw
  -- duplicate-key error. A transaction-scoped advisory lock keyed on the ORDER
  -- serialises them: the second caller waits, then sees the first invoice
  -- committed and is refused by the primary-invoice guard with a sentence a human
  -- can read. Only this order is locked, so unrelated invoicing is not blocked,
  -- and the lock is released at commit or rollback either way.
  perform pg_advisory_xact_lock(hashtext('sigma_invoice_from_order'), hashtext(p_order_id));

  if exists (select 1 from public.invoices
              where order_id = p_order_id and is_primary and status <> 'void') then
    raise exception 'order % already has a primary invoice', p_order_id;
  end if;

  begin v_extra := v_ord.extra_data::jsonb; exception when others then v_extra := '{}'::jsonb; end;

  v_base    := v_ord.order_id;
  v_baselen := length(v_base);

  -- The retry loop is a belt-and-braces backstop for a number written by
  -- something OTHER than this function (a manual insert, a restored row) between
  -- the read and the write. In normal operation the advisory lock means the first
  -- pass always succeeds.
  for v_try in 1..5 loop

    -- Highest attempt number already in use for this order, VOIDS INCLUDED.
    -- The bare order number counts as attempt 1, so the first re-issue is -2.
    -- max(), not count(): a gap (…-2 deleted, …-3 present) must still yield -4,
    -- never a number that is already taken.
    select coalesce(max(t.n), 0) into v_attempt from (
      select case
               when i.invoice_number = v_base then 1
               when left(i.invoice_number, v_baselen + 1) = v_base || '-'
                and substring(i.invoice_number from v_baselen + 2) ~ '^[0-9]{1,6}$'
                 then substring(i.invoice_number from v_baselen + 2)::int
               else null
             end as n
        from public.invoices i
       where i.org_id = v_org
         -- both sides of the net: every invoice pointing at this order, AND every
         -- invoice already holding a number in this order's series even if it were
         -- somehow attached elsewhere. The second half is what makes the derived
         -- number agree with what invoices_org_number_uk will actually accept.
         and ( i.order_id = p_order_id
               or i.invoice_number = v_base
               or left(i.invoice_number, v_baselen + 1) = v_base || '-' )
    ) t;

    v_invno := case when v_attempt = 0 then v_base
                    else v_base || '-' || (v_attempt + 1)::text end;

    begin
      insert into public.invoices (
        org_id, order_id, order_number, invoice_number,
        client_name, client_email, client_phone,
        bill_to_name, bill_to_address, bill_to_city, bill_to_country,
        property_address, appraiser, service_description,
        due_date, payment_terms, public_notes,
        company_snapshot, created_by
      ) values (
        v_org, v_ord.order_id, v_ord.order_id, v_invno,   -- number derived server-side
        -- The client snapshot is taken from the ORDER, not from any earlier
        -- invoice. This is the whole point of a re-issue: the previous invoice
        -- named the wrong client, and the order is the corrected record.
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
      exit;                                    -- got the number, done
    exception when unique_violation then
      -- Could be either unique index. If a live primary appeared, say so in
      -- words; otherwise the number was taken — recompute and try again.
      if exists (select 1 from public.invoices
                  where order_id = p_order_id and is_primary and status <> 'void') then
        raise exception 'order % already has a primary invoice', p_order_id;
      end if;
      if v_try >= 5 then raise; end if;
    end;

  end loop;

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
          jsonb_build_object('order_id', p_order_id, 'lines', v_n,
                             'invoice_number', v_inv.invoice_number,
                             'attempt', v_attempt + 1));

  select to_jsonb(x) into v_extra from (
    select i.*, (select coalesce(jsonb_agg(to_jsonb(l) order by l.line_no), '[]'::jsonb)
                   from public.invoice_lines l where l.invoice_id = i.id) as lines
      from public.invoices i where i.id = v_inv.id
  ) x;
  return v_extra;
end $$;

-- CREATE OR REPLACE keeps the existing ACL, so the anon/authenticated grants made
-- in SIGMA_invoicing_open_access.sql survive. Restated here so a fresh deploy in
-- any order still ends up correct.
grant execute on function public.sigma_create_invoice_from_order(text,jsonb,date,text,text,text,jsonb)
  to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK
--
--   alter table public.invoices drop constraint if exists invoices_number_matches_order;
--   alter table public.invoices add  constraint invoices_number_matches_order
--     check (invoice_number = order_number);
--   -- then re-run the sigma_create_invoice_from_order body from
--   -- supabase/SIGMA_invoicing_phase2.sql as it stood before this file.
--
-- NOTE: the constraint rollback will FAIL if a suffixed invoice has already been
-- issued — Postgres validates the tightened CHECK against existing rows. That is
-- correct: a document that has left the building must not be silently invalidated.
-- To roll back after a re-issue, void/remove the suffixed invoice first, or leave
-- the constraint relaxed and only revert the function.
-- ─────────────────────────────────────────────────────────────────────────────
