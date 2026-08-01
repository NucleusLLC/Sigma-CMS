-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — Invoicing: EDIT an invoice  (§INVOICE-EDIT)
--
-- WHAT THE OWNER ASKED FOR, AND WHAT WAS DECIDED
--   "Add an EDIT button on the Billing tab so we can change the invoice number or
--    other items on the invoice."
--
--   1. THE INVOICE NUMBER STAYS IMMUTABLE. It is derived from the order, it is
--      never reused (SIGMA_order_numbering.sql:9), and that is precisely what
--      makes these invoices defensible. invoice_number / order_number / order_id
--      / is_primary remain unchangeable by ANY route, including this one. To bill
--      the same order again, void and re-issue — the number is then suffixed
--      (§INVOICE-REISSUE) and no number is ever reused.
--
--   2. EDITING A FINALISED (issued) INVOICE IS ALLOWED. This was the owner's
--      explicit decision, taken after being told that (a) the database guard has
--      to be relaxed for it and (b) a client may already hold a document that no
--      longer matches. It is therefore built — but built so that it can only ever
--      happen deliberately, visibly, and with a record.
--
-- HOW THE GUARD IS RELAXED — AND WHY IT IS NOT SIMPLY DROPPED
--   sigma_invoice_guard / sigma_invoice_lines_guard are NOT removed and their
--   conditions are not widened for the world. They are narrowed by exactly one
--   term: the finalised-invoice block is skipped only while a transaction-local
--   setting names the invoice being edited —
--
--       set_config('sigma.invoice_edit', <invoice uuid>, true)
--
--   Only public.sigma_edit_invoice() ever sets it, and set_config(..., true) is
--   transaction-scoped, so it is gone the instant that call ends. The practical
--   consequence: a plain UPDATE from the browser against a finalised invoice is
--   refused exactly as it is today. The ONLY way to change a finalised invoice is
--   through the one function that also writes the audit row — so an edit without
--   a record is not merely discouraged, it is impossible.
--
-- WHAT STILL CANNOT HAPPEN, EVER
--   • invoice_number, order_number, order_id, is_primary can never change.
--     (is_primary is newly locked here. Nothing in the app or the database has
--      ever updated it — it is only ever set on insert — so this is a tightening
--      with no behavioural cost.)
--   • A VOID invoice can never be edited. Void is terminal. This file locks it
--     harder than before: previously a void invoice's due date, payment terms,
--     public notes and client contact fields were still writable by a direct
--     UPDATE. They are not now.
--   • An invoice can never be deleted once it leaves draft — sigma_invoice_no_delete
--     is untouched.
--
-- MONEY. Unchanged in principle: the browser still never decides what a client
--   owes. sigma_edit_invoice replaces the LINES and lets the existing triggers
--   recompute subtotal/total (sigma_invoice_recalc), then re-derives amount_paid
--   and status from the non-reversed payments (sigma_invoice_apply_payments).
--   balance is a generated column and follows on its own.
--
--   Changing the lines on a PAID invoice therefore MOVES ITS STATUS. Raising the
--   total leaves it partially_paid with a real outstanding balance; lowering it
--   below what has been received leaves a NEGATIVE balance — money owed back.
--   That second case is refused unless the caller passes p_allow_overpay := true,
--   so it can only be reached by someone who has been shown the figures and said
--   yes. The client shows those figures before saving.
--
-- THE DRAFT CLIENT FIELDS ARE DELIBERATELY NOT EDITABLE HERE.
--   §INVOICE-IDENTITY (v2.293) re-stamps a DRAFT's client_name / client_email /
--   client_phone / bill_to_name / bill_to_address from its ORDER every time the
--   Billing tab is drawn — that is the safety mechanism that stopped one client's
--   invoice being offered to another client's inbox. If this function also let a
--   draft's client be typed by hand, the next render would silently undo it. So
--   the two are reconciled by giving them non-overlapping territory: on a DRAFT
--   the client comes from the order and this function REFUSES to change it (with
--   a message saying where to change it instead); on a FINALISED invoice the
--   re-stamp never runs, so the client fields ARE editable here. Neither one can
--   quietly overwrite the other.
--
-- Idempotent: safe to run more than once. Rollback at the foot of this file.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. sigma_invoice_guard — narrowed, not dropped ──────────────────────────
create or replace function public.sigma_invoice_guard()
returns trigger language plpgsql as $$
declare
  -- The edit gate. NULL unless sigma_edit_invoice() is running in this very
  -- transaction, and it names the one invoice that call is allowed to touch.
  v_gate text := coalesce(current_setting('sigma.invoice_edit', true), '');
begin
  -- ── ABSOLUTE. Not relaxed by the gate, not relaxed by anything. ───────────
  -- The number is derived from the order and is never editable, and the invoice
  -- can never be moved to a different order or promoted/demoted as the order's
  -- primary invoice.
  if new.invoice_number is distinct from old.invoice_number
     or new.order_number is distinct from old.order_number
     or new.order_id     is distinct from old.order_id
     or new.is_primary   is distinct from old.is_primary then
    raise exception 'invoice number / order link is immutable (invoice %)', old.invoice_number;
  end if;

  -- ── VOID IS TERMINAL. ─────────────────────────────────────────────────────
  -- A void invoice keeps its number for ever and stays visible as the record of
  -- what was withdrawn. Nothing on the face of it may move again. Deliberately
  -- NOT a blanket "no updates": amount_paid still has to be able to follow a
  -- payment reversal (sigma_invoice_apply_payments), internal_notes still has to
  -- take the VOID reason sigma_void_invoice appends, and pdf_path / email_status
  -- are bookkeeping, not the document.
  if old.status = 'void' then
    if new.invoice_date        is distinct from old.invoice_date
       or new.due_date         is distinct from old.due_date
       or new.subtotal         is distinct from old.subtotal
       or new.tax_amount       is distinct from old.tax_amount
       or new.total            is distinct from old.total
       or new.currency         is distinct from old.currency
       or new.tax_treatment    is distinct from old.tax_treatment
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

  -- ── FINALISED. ────────────────────────────────────────────────────────────
  -- Identical to the rule that has always been here, with ONE new term: it is
  -- skipped while sigma_edit_invoice() is editing THIS invoice. Outside that
  -- function the behaviour is byte-for-byte what it was, including the wording
  -- of the error — a stray UPDATE from the browser is refused exactly as before.
  if old.status <> 'draft' and v_gate <> old.id::text then
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


-- ── 2. sigma_invoice_lines_guard — narrowed, not dropped ────────────────────
create or replace function public.sigma_invoice_lines_guard()
returns trigger language plpgsql as $$
declare
  v_id     uuid := coalesce(new.invoice_id, old.invoice_id);
  v_status text;
  v_gate   text := coalesce(current_setting('sigma.invoice_edit', true), '');
begin
  select status into v_status from public.invoices where id = v_id;

  -- Void first, and unconditionally — the gate can never open a void invoice.
  if v_status = 'void' then
    raise exception 'invoice is void; its line items can never be changed';
  end if;

  if v_status is not null and v_status <> 'draft' and v_gate <> v_id::text then
    raise exception 'invoice is finalised; its line items cannot be changed';
  end if;

  return coalesce(new, old);
end $$;


-- ── 3. sigma_edit_invoice — the ONLY way a finalised invoice ever changes ───
--
-- p_patch   header fields, as a jsonb object. A key that is ABSENT is left
--           alone; a key present with a null/empty value clears that field
--           (except invoice_date, which is not nullable and is refused empty).
--           Anything outside the whitelist is refused by name, not ignored.
-- p_lines   null  = leave the line items completely alone.
--           array = replace the whole line set with this one.
-- p_allow_overpay
--           the second key on the overpayment door. Lowering the total below
--           what has already been received is refused unless this is true, so
--           the figures have to have been put in front of somebody first.
--
-- security invoker, matching every other function in this module: RLS still
-- applies and this grants no privilege the caller does not already have. The
-- protection here is the audit row and the whitelist, not a privilege boundary.
create or replace function public.sigma_edit_invoice(
  p_invoice       uuid,
  p_patch         jsonb   default '{}'::jsonb,
  p_lines         jsonb   default null,
  p_actor         text    default null,
  p_reason        text    default null,
  p_allow_overpay boolean default false
) returns jsonb
language plpgsql
security invoker
as $$
declare
  v_before public.invoices%rowtype;
  v_after  public.invoices%rowtype;
  v_bj     jsonb;
  v_aj     jsonb;
  v_was    jsonb := '{}'::jsonb;
  v_now    jsonb := '{}'::jsonb;
  v_lines_before jsonb;
  v_lines_after  jsonb;
  v_lines_changed boolean := false;
  v_line   jsonb;
  v_n      int := 0;
  k        text;
  v_patch  jsonb := coalesce(p_patch, '{}'::jsonb);

  -- Editable on any non-void invoice.
  v_common text[] := array[
    'invoice_date','due_date','payment_terms','public_notes','internal_notes',
    'service_description','property_address','appraiser'
  ];
  -- Editable ONLY on a finalised invoice. On a draft these follow the order —
  -- see the §INVOICE-IDENTITY note at the head of this file.
  v_client text[] := array[
    'client_name','client_email','client_phone',
    'bill_to_name','bill_to_address','bill_to_city','bill_to_country'
  ];
begin
  if p_invoice is null then
    raise exception 'no invoice was identified, so nothing was changed';
  end if;

  -- One editor at a time per invoice. Two people saving different line sets at
  -- once would otherwise interleave the delete/insert and leave a mixture of
  -- both. Only this invoice is locked; it is released at commit or rollback.
  perform pg_advisory_xact_lock(hashtext('sigma_invoice_edit'), hashtext(p_invoice::text));

  select * into v_before from public.invoices where id = p_invoice for update;
  if not found then
    raise exception 'invoice not found';
  end if;
  if v_before.status = 'void' then
    raise exception 'invoice % is void and can never be edited. Raise a corrected invoice for the order instead.',
      v_before.invoice_number;
  end if;

  -- ── Refuse anything outside the whitelist BY NAME, before touching a row.
  for k in select jsonb_object_keys(v_patch) loop
    if k = any (array['invoice_number','order_number','order_id','is_primary']) then
      raise exception 'the invoice number and its link to order % can never be changed (field %)',
        v_before.order_id, k;
    end if;
    if k = any (v_client) then
      if v_before.status = 'draft' then
        raise exception 'the client on a DRAFT invoice always follows its job order — change the client on order %, and the draft follows it. (field %)',
          v_before.order_id, k;
      end if;
    elsif not (k = any (v_common)) then
      raise exception 'field % is not editable on an invoice', k;
    end if;
  end loop;

  if v_patch ? 'invoice_date' and coalesce(nullif(v_patch->>'invoice_date',''), '') = '' then
    raise exception 'an invoice must have a date';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', line_no, 'description', description, 'quantity', quantity,
           'unit_price', unit_price, 'discount', discount) order by line_no), '[]'::jsonb)
    into v_lines_before
    from public.invoice_lines where invoice_id = p_invoice;

  -- ── OPEN THE GATE. Transaction-local; it disappears when this call ends.
  perform set_config('sigma.invoice_edit', p_invoice::text, true);

  -- ── Header fields. No dynamic SQL: every column is named in full, so there is
  --    nothing here that a value could be smuggled through.
  if v_patch <> '{}'::jsonb then
    update public.invoices i set
      invoice_date        = case when v_patch ? 'invoice_date'        then (v_patch->>'invoice_date')::date            else i.invoice_date end,
      due_date            = case when v_patch ? 'due_date'            then nullif(v_patch->>'due_date','')::date       else i.due_date end,
      payment_terms       = case when v_patch ? 'payment_terms'       then nullif(v_patch->>'payment_terms','')        else i.payment_terms end,
      public_notes        = case when v_patch ? 'public_notes'        then nullif(v_patch->>'public_notes','')         else i.public_notes end,
      internal_notes      = case when v_patch ? 'internal_notes'      then nullif(v_patch->>'internal_notes','')       else i.internal_notes end,
      service_description = case when v_patch ? 'service_description' then nullif(v_patch->>'service_description','')  else i.service_description end,
      property_address    = case when v_patch ? 'property_address'    then nullif(v_patch->>'property_address','')     else i.property_address end,
      appraiser           = case when v_patch ? 'appraiser'           then nullif(v_patch->>'appraiser','')            else i.appraiser end,
      client_name         = case when v_patch ? 'client_name'         then nullif(v_patch->>'client_name','')          else i.client_name end,
      client_email        = case when v_patch ? 'client_email'        then nullif(v_patch->>'client_email','')         else i.client_email end,
      client_phone        = case when v_patch ? 'client_phone'        then nullif(v_patch->>'client_phone','')         else i.client_phone end,
      bill_to_name        = case when v_patch ? 'bill_to_name'        then nullif(v_patch->>'bill_to_name','')         else i.bill_to_name end,
      bill_to_address     = case when v_patch ? 'bill_to_address'     then nullif(v_patch->>'bill_to_address','')      else i.bill_to_address end,
      bill_to_city        = case when v_patch ? 'bill_to_city'        then nullif(v_patch->>'bill_to_city','')         else i.bill_to_city end,
      bill_to_country     = case when v_patch ? 'bill_to_country'     then nullif(v_patch->>'bill_to_country','')      else i.bill_to_country end
    where i.id = p_invoice;
  end if;

  -- ── Line items. Whole-set replacement, exactly the shape the app already uses
  --    when it re-syncs a draft to the Cost tab.
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' then
      raise exception 'the line items must be supplied as a list';
    end if;
    if jsonb_array_length(p_lines) = 0 and v_before.status <> 'draft' then
      raise exception 'invoice % has already been issued and cannot be left with nothing on it',
        v_before.invoice_number;
    end if;

    for v_line in select * from jsonb_array_elements(p_lines) loop
      if coalesce(trim(v_line->>'description'), '') = '' then
        raise exception 'every line item needs a description';
      end if;
      if coalesce((v_line->>'quantity')::numeric, 1) <= 0 then
        raise exception 'line "%" has a quantity of zero or less', v_line->>'description';
      end if;
      if coalesce((v_line->>'unit_price')::numeric, 0) < 0
         or coalesce((v_line->>'discount')::numeric, 0) < 0 then
        raise exception 'line "%" has a negative price or discount', v_line->>'description';
      end if;
    end loop;

    delete from public.invoice_lines where invoice_id = p_invoice;
    for v_line in select * from jsonb_array_elements(p_lines) loop
      v_n := v_n + 1;
      insert into public.invoice_lines (invoice_id, line_no, description, quantity, unit_price, discount)
      values (p_invoice, v_n,
              trim(v_line->>'description'),
              coalesce((v_line->>'quantity')::numeric, 1),
              coalesce((v_line->>'unit_price')::numeric, 0),
              coalesce((v_line->>'discount')::numeric, 0));
    end loop;

    -- The line triggers already ran sigma_invoice_recalc row by row; run it once
    -- more so the figure is right even if the whole set was removed.
    perform public.sigma_invoice_recalc(p_invoice);
  end if;

  -- ── The money consequence, checked BEFORE this transaction is allowed to end.
  select * into v_after from public.invoices where id = p_invoice;

  if v_after.total < v_after.amount_paid and not coalesce(p_allow_overpay, false) then
    raise exception 'this change would bring invoice % down to % while % has already been received — % would be owed back to the client. Nothing has been changed.',
      v_before.invoice_number,
      to_char(v_after.total, 'FM999G999G990D00'),
      to_char(v_after.amount_paid, 'FM999G999G990D00'),
      to_char(v_after.amount_paid - v_after.total, 'FM999G999G990D00');
  end if;

  -- Re-derive amount_paid and the lifecycle status from the non-reversed
  -- payments. This is what turns a settled invoice back into partially_paid when
  -- its total goes up, instead of leaving it reading "Paid" with money owing.
  perform public.sigma_invoice_apply_payments(p_invoice);

  select * into v_after from public.invoices where id = p_invoice;
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', line_no, 'description', description, 'quantity', quantity,
           'unit_price', unit_price, 'discount', discount) order by line_no), '[]'::jsonb)
    into v_lines_after
    from public.invoice_lines where invoice_id = p_invoice;
  v_lines_changed := (v_lines_before is distinct from v_lines_after);

  -- ── THE AUDIT ROW. Only the fields that actually moved, on both sides, so the
  --    record answers "what changed, from what, to what, by whom, when" without
  --    anyone having to diff two whole rows by eye.
  v_bj := to_jsonb(v_before);
  v_aj := to_jsonb(v_after);
  for k in select jsonb_object_keys(v_aj) loop
    if k <> 'updated_at' and (v_bj->k) is distinct from (v_aj->k) then
      v_was := v_was || jsonb_build_object(k, v_bj->k);
      v_now := v_now || jsonb_build_object(k, v_aj->k);
    end if;
  end loop;
  if v_lines_changed then
    v_was := v_was || jsonb_build_object('lines', v_lines_before);
    v_now := v_now || jsonb_build_object('lines', v_lines_after);
  end if;

  -- Nothing moved. Say so rather than writing a meaningless audit row.
  if v_was = '{}'::jsonb then
    return jsonb_build_object('changed', false, 'invoice', v_aj, 'lines', v_lines_after);
  end if;

  insert into public.finance_audit_events
    (entity, entity_id, invoice_number, action, actor, before_state, after_state, reason, metadata)
  values
    ('invoice', p_invoice, v_before.invoice_number, 'invoice_edited', p_actor,
     v_was, v_now, p_reason,
     jsonb_build_object(
       'status_at_edit', v_before.status,
       'was_finalised',  (v_before.status <> 'draft'),
       'lines_changed',  v_lines_changed,
       'fields_changed', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_object_keys(v_was) x),
       'total_before',   v_before.total,
       'total_after',    v_after.total,
       'balance_before', v_before.balance,
       'balance_after',  v_after.balance,
       'overpay_confirmed', coalesce(p_allow_overpay, false)
     ));

  return jsonb_build_object('changed', true, 'invoice', v_aj, 'lines', v_lines_after,
                            'before', v_was, 'after', v_now);
end $$;


-- ── 4. sigma_invoice_follow_costs — hand a DRAFT back to the Cost tab ───────
--
-- §BILLING-SYNC (v2.287) rewrites a draft's line items from the order's Cost tab
-- every time the Billing tab is drawn. Once a draft has been edited by hand that
-- auto-rewrite would silently undo the edit, so the app stops doing it — it reads
-- the audit trail to find out (newest of 'invoice_edited' with lines_changed vs
-- 'invoice_edit_released' wins). This function writes the release row, which is
-- what the Billing tab's "follow the Cost tab again" button calls. Append-only,
-- consistent with the rest of the audit posture: nothing is ever un-written.
create or replace function public.sigma_invoice_follow_costs(
  p_invoice uuid,
  p_actor   text default null
) returns jsonb
language plpgsql
security invoker
as $$
declare v_inv public.invoices%rowtype;
begin
  select * into v_inv from public.invoices where id = p_invoice;
  if not found then raise exception 'invoice not found'; end if;
  if v_inv.status <> 'draft' then
    raise exception 'invoice % is not a draft, so it does not follow the Cost tab', v_inv.invoice_number;
  end if;

  insert into public.finance_audit_events
    (entity, entity_id, invoice_number, action, actor, metadata)
  values
    ('invoice', p_invoice, v_inv.invoice_number, 'invoice_edit_released', p_actor,
     jsonb_build_object('effect', 'draft follows the order cost data again'));

  return jsonb_build_object('ok', true);
end $$;


-- ── 5. Grants — same posture as the rest of Finance (§FINANCE-OPEN v2.278) ──
grant execute on function public.sigma_edit_invoice(uuid,jsonb,jsonb,text,text,boolean) to anon, authenticated;
grant execute on function public.sigma_invoice_follow_costs(uuid,text)                  to anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFY (read-only — safe to run on production)
-- ─────────────────────────────────────────────────────────────────────────────
-- select p.proname, pg_get_functiondef(p.oid)
--   from pg_proc p
--  where p.proname in ('sigma_invoice_guard','sigma_invoice_lines_guard',
--                      'sigma_edit_invoice','sigma_invoice_follow_costs');
--
-- Expect all four triggers still present and unchanged in shape:
-- select c.relname, t.tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid
--  where not t.tgisinternal and c.relname in ('invoices','invoice_lines');
--   invoices      | invoices_guard
--   invoices      | invoices_no_delete      <- untouched by this file
--   invoice_lines | invoice_lines_guard
--   invoice_lines | invoice_lines_recalc


-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK
--
-- Restores both guards to their pre-§INVOICE-EDIT definitions exactly as they are
-- deployed today, and removes the two new functions. Run the whole block.
--
-- WHAT THE ROLLBACK CANNOT UNDO — stated plainly:
--   • Any edit already made to a finalised invoice. The rows are changed; putting
--     the guard back only stops the NEXT one. The finance_audit_events rows are
--     the record of what was changed and are deliberately left in place — they
--     are append-only by policy and are the only trace of those edits.
--   • The is_primary lock is dropped along with the rest, because it lives in the
--     same function body. Nothing has ever written is_primary, so this has no
--     practical effect, but it is a real narrowing that goes away.
--   • The extra protection this file added to VOID invoices (their due date,
--     terms, notes and client fields can no longer be changed by a direct UPDATE)
--     also goes away. The rollback is strictly LESS safe than the state this file
--     leaves behind, not more.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- drop function if exists public.sigma_edit_invoice(uuid,jsonb,jsonb,text,text,boolean);
-- drop function if exists public.sigma_invoice_follow_costs(uuid,text);
--
-- create or replace function public.sigma_invoice_guard()
-- returns trigger language plpgsql as $$
-- begin
--   if new.invoice_number is distinct from old.invoice_number
--      or new.order_number is distinct from old.order_number
--      or new.order_id     is distinct from old.order_id then
--     raise exception 'invoice number / order link is immutable (invoice %)', old.invoice_number;
--   end if;
--
--   if old.status <> 'draft' then
--     if new.subtotal is distinct from old.subtotal
--        or new.total is distinct from old.total
--        or new.invoice_date is distinct from old.invoice_date
--        or new.client_name  is distinct from old.client_name
--        or new.bill_to_address is distinct from old.bill_to_address then
--       raise exception 'invoice % is finalised and cannot be edited (void it instead)', old.invoice_number;
--     end if;
--   end if;
--
--   new.updated_at := now();
--   return new;
-- end $$;
--
-- create or replace function public.sigma_invoice_lines_guard()
-- returns trigger language plpgsql as $$
-- declare v_status text;
-- begin
--   select status into v_status from public.invoices
--    where id = coalesce(new.invoice_id, old.invoice_id);
--   if v_status is not null and v_status <> 'draft' then
--     raise exception 'invoice is finalised; its line items cannot be changed';
--   end if;
--   return coalesce(new, old);
-- end $$;
