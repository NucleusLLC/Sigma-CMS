-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SIGMA — invoices_v must carry the discount  (§VIEW-DISCOUNT, v2.383)         ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- REPORTED: "when I EDIT an invoice and add a discount, lets say 10%, it adds the
-- discount, but later when I view the invoice, it doesn't show the discount of 10%,
-- but it implemented the discount, but I need to be able to view the discount, so
-- the client knows I added the discount."
--
-- ROOT CAUSE. public.invoices_v names its columns explicitly and was written before
-- §BBO-DISCOUNT (v2.328) added discount_type / discount_value / discount_amount /
-- discount_reason to public.invoices. The new columns were never added to the view.
--
-- Every render path in the app reads the VIEW, not the table — finFetch (the whole
-- Finance list, and therefore finById), finPreviewInvoice, the Billing tab, the PDF
-- builder and the email attachment. So inv.discount_amount arrived undefined,
-- _bboDisc fell to 0, and _finInvoiceHtml skipped the discount row it has always been
-- able to draw. Meanwhile subtotal and total were both correct, because the database
-- computed them. The printed invoice therefore showed:
--
--        Subtotal   950.00
--        Total      855.00      ← 95.00 missing, with nothing to explain it
--
-- which is worse than not discounting at all: the client is handed a document whose
-- arithmetic does not add up, and the discount they were given is invisible.
--
-- SECOND SYMPTOM, same cause. FIN.rows comes from this view, so the "% Discount"
-- form and the Edit modal both read discount_type as absent on an invoice that HAS
-- a discount — they open showing "none". Saving from that state can clear a discount
-- that is really applied. Adding the columns fixes the printout and that together.
--
-- SAFETY. create or replace view, appending four columns AFTER the existing ones —
-- required, because replace may add at the end but may not reorder or retype what is
-- already there. No table is touched, no data is written, and every existing column
-- keeps its name, type and position, so all 11 readers are unaffected except that
-- four more fields now arrive.

begin;

create or replace view public.invoices_v as
 SELECT id,
    org_id,
    order_id,
    order_number,
    invoice_number,
    is_primary,
    status,
    client_name,
    client_email,
    client_phone,
    bill_to_name,
    bill_to_address,
    bill_to_city,
    bill_to_country,
    property_address,
    appraiser,
    service_description,
    company_snapshot,
    invoice_date,
    due_date,
    finalized_at,
    currency,
    tax_treatment,
    subtotal,
    tax_amount,
    total,
    amount_paid,
    balance,
    payment_terms,
    public_notes,
    internal_notes,
    pdf_path,
    email_status,
    qb_export_status,
    created_by,
    finalized_by,
    created_at,
    updated_at,
        CASE
            WHEN status = ANY (ARRAY['void'::text, 'credited'::text, 'paid'::text, 'draft'::text]) THEN status
            WHEN balance > 0::numeric AND due_date IS NOT NULL AND due_date < CURRENT_DATE THEN 'overdue'::text
            ELSE status
        END AS effective_status,
        CASE
            WHEN due_date IS NULL OR balance <= 0::numeric THEN NULL::integer
            ELSE CURRENT_DATE - due_date
        END AS days_overdue,
    -- §VIEW-DISCOUNT (v2.383) — appended, so nothing above shifts position.
    --   Defaulted rather than raw: a NULL discount_type reaching the client code as
    --   undefined is what this whole fix is about, so the view answers 'none'/0 and
    --   the caller never has to guess what an absent value meant.
    coalesce(discount_type, 'none') AS discount_type,
    coalesce(discount_value, 0)     AS discount_value,
    coalesce(discount_amount, 0)    AS discount_amount,
    discount_reason
   FROM invoices i;

commit;

-- After this, no client change is needed: _finInvoiceHtml has drawn the row since
-- v2.328 and was only ever missing its input.
--
--   +-------------------------------------------+
--   |  Subtotal              950.00             |
--   |  Discount (10%)        -95.00             |
--   |  Total                 855.00             |
--   +-------------------------------------------+
