-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — §INVOICE-PROPERTY (v2.668): PROPOSED correction of issued invoices
--
-- NOT RUN. Written for the owner to review and run by hand (Supabase SQL editor).
-- Nothing in the app runs this file.
--
-- WHAT WAS FOUND (production, read 13 Oct 2026)
--   invoice    status  created (UTC)        finalised   property_address on invoice    orders.address / orders.city NOW
--   2026-166   sent    2026-10-10 18:37:45  18:39:52    Monpos 1M, St.Cruz, na         Monpos 1M / St.Cruz, na   → agrees
--   2026-167   sent    2026-10-10 18:45:37  18:47:34    Monpos 1M, St.Cruz, na         Monpos 1L / St.Cruz, na   → WRONG on the invoice
--   2026-168   sent    2026-10-10 18:51:37  18:52:08    Monpos 1M, St.Cruz, na         Monpos 1M / St.Cruz, na   → agrees with Project Data
--
--   All three were emailed to the client on 10 Oct. Each invoice points at its own
--   order; the address is a snapshot taken when the invoice was raised.
--
--   2026-168: its Project Data STILL says "Monpos 1M" — the same as 2026-166. If that
--   job is a different property, the Street Address has to be corrected in Project
--   Data first (Parcel › Street Address); the Billing tab then flags the invoice,
--   and block 2 below (or ✎ Edit on the invoice) brings the invoice into line.
--   No address for 2026-168 is proposed here because none is recorded anywhere.
--
-- THE SANCTIONED PATH
--   public.sigma_edit_invoice() is the one audited way to change an issued invoice:
--   property_address and appraiser are on its whitelist for any non-void invoice,
--   and it writes a finance_audit_events row (action 'invoice_edited', before/after,
--   actor, reason). The app's ✎ Edit button on the Billing tab calls this same
--   function — doing the correction THERE is equivalent and needs no SQL at all.
--
--   Guard trigger sigma_invoice_guard (latest definition in this repo:
--   SIGMA_invoicing_tax_discount.sql): on a FINALISED invoice it refuses changes to
--   subtotal / total / discount_* / invoice_date / client_name / bill_to_address.
--   property_address and appraiser are NOT in that list, so a plain UPDATE would not
--   be refused — but it would leave no audit row, so it is not what is proposed.
--   On a VOID invoice both fields are frozen and nothing can change them.
--   (The DEPLOYED trigger body was not read — pg_proc is not exposed to the anon
--   key. Going through sigma_edit_invoice is correct whichever version is live.)
--
-- Each statement only acts while the invoice still holds the OLD value, so running
-- it twice, or after a correction made in the app, changes nothing.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── 1. Invoice 2026-167  (id b8bc11ed-25e2-4e2a-a64f-e826a9196f4b, status sent)
--      property_address:  'Monpos 1M, St.Cruz, na'  →  'Monpos 1L, St.Cruz'
--      (Project Data of order 2026-167: Street Address "Monpos 1L", City "St.Cruz")
--      appraiser is left alone: the invoice says 'Auto-assign' and so does the order.
--      The sheet no longer prints "Appraiser: Auto-assign" from v2.668 on.
select public.sigma_edit_invoice(
         i.id,
         jsonb_build_object('property_address', 'Monpos 1L, St.Cruz'),
         null,
         'greg@zenarch.net',
         'Property address corrected to the Project Data of order 2026-167 (was the address of 2026-166)',
         false)
  from public.invoices i
 where i.id = 'b8bc11ed-25e2-4e2a-a64f-e826a9196f4b'
   and i.invoice_number = '2026-167'
   and i.status <> 'void'
   and i.property_address = 'Monpos 1M, St.Cruz, na';

-- ── 2. Invoice 2026-168  (id a32e7ef0-ea9c-4d2c-a801-35a49d6490f0, status sent)
--      LEFT COMMENTED OUT: Project Data of order 2026-168 says "Monpos 1M", which is
--      what the invoice already carries. Fill in the real address — AFTER correcting
--      it in Project Data — and uncomment.
--      property_address:  'Monpos 1M, St.Cruz, na'  →  '<REAL STREET ADDRESS>, St.Cruz'
-- select public.sigma_edit_invoice(
--          i.id,
--          jsonb_build_object('property_address', '<REAL STREET ADDRESS>, St.Cruz'),
--          null,
--          'greg@zenarch.net',
--          'Property address corrected to the Project Data of order 2026-168',
--          false)
--   from public.invoices i
--  where i.id = 'a32e7ef0-ea9c-4d2c-a801-35a49d6490f0'
--    and i.invoice_number = '2026-168'
--    and i.status <> 'void'
--    and i.property_address = 'Monpos 1M, St.Cruz, na';

-- ── 3. Invoice 2026-166  (id e11b411f-5d1a-4d20-a51c-c4fb7ee75698, status sent)
--      Nothing to correct: 'Monpos 1M, St.Cruz, na' is this order's own address.
--      The trailing ", na" is no longer PRINTED from v2.668 on, so the stored text
--      can stay exactly as issued. Optional tidy-up only, left commented out:
--      property_address:  'Monpos 1M, St.Cruz, na'  →  'Monpos 1M, St.Cruz'
-- select public.sigma_edit_invoice(
--          i.id, jsonb_build_object('property_address', 'Monpos 1M, St.Cruz'), null,
--          'greg@zenarch.net', 'Trailing ", na" removed from the property address', false)
--   from public.invoices i
--  where i.id = 'e11b411f-5d1a-4d20-a51c-c4fb7ee75698'
--    and i.property_address = 'Monpos 1M, St.Cruz, na';

-- ── Check before committing: expect 2026-167 = 'Monpos 1L, St.Cruz'.
select invoice_number, status, property_address, appraiser, updated_at
  from public.invoices
 where order_id in ('2026-166', '2026-167', '2026-168')
 order by invoice_number;

commit;   -- or: rollback;

-- The client already holds the 10 Oct copy of 2026-167. After the correction,
-- "Resend invoice" on the Billing tab sends the corrected sheet.
