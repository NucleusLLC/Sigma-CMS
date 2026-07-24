# Invoicing & Accounts-Receivable — Implementation Plan

**Date:** 2026-07-24 · **Baseline:** v2.270 · Read `REPOSITORY_AUDIT.md` first.

---

## Decisions taken

| Question | Decision |
|---|---|
| Email provider | **Resend** |
| Tax | **Prices are tax-inclusive. No tax breakout on invoices.** |
| Numbering | Invoice number = order number. Implemented (`ORDER_INVOICE_NUMBERING.md`). |

## Decision still required — access posture (blocks Phase 2 schema)

Today RLS grants **anon `ALL`** on every business table, and the anon key is embedded in the
public page. Applying that pattern to invoices and payments would make the entire
accounts-receivable ledger readable by anyone who views source.

- **Option A (recommended).** Financial tables require a **real Supabase Auth session**
  (`to authenticated`), not anon. v2.268 already provisions real Auth accounts, so the
  mechanism exists. Cost: staff who currently sign in through the *local* password fallback
  have no Supabase session, so Finance would be invisible to them until their cloud login is
  set (Settings → Users → ☁ Cloud Logins repairs this per user).
- **Option B.** Follow the existing anon-open pattern. No sign-in changes; the ledger is
  world-readable to anyone with the URL.

I recommend **A**, and will not build financial tables under B without an explicit
instruction, because B knowingly publishes client financial data.

---

## Deviations from the brief (and why)

| Brief says | Reality | Approach |
|---|---|---|
| Organization/tenant scoping, prevent cross-org access | No org model exists; single firm | Every finance table carries `org_id text not null default 'sigma'`. Future-proof, zero behaviour today. No multi-tenancy is being invented. |
| Reuse the existing tax engine | None exists | Store `tax_treatment='inclusive'`, `tax_amount=0`. Columns exist so a BBO/BAZV breakout is later a data change, not a migration. |
| "All final calculations server-side" | No app server | Totals computed by a Postgres **generated column / trigger**, not by the browser. The browser previews only. |
| Reuse the existing PDF generator | `render-report-pdf` is **not deployed** | Deploy it (it already exists) and reuse it for invoice PDFs. Falls back to the browser raster path if PDFShift is unavailable. |
| "Do not mark sent until the provider accepts" | No provider | Resend via an edge function; `sent` is written **only** on a 2xx from Resend, with the provider message id stored. |
| IIF export | Legacy, error-prone | CSV/Excel only, behind an adapter interface so a QuickBooks Online API path can be added later. |

---

## Phase 2 — Core invoices *(next)*

**Schema** (new migration; `numeric(12,2)` everywhere for money):

- `invoices` — `id uuid`, `org_id`, `order_id` (FK → `orders.order_id`), `order_number`,
  `invoice_number` (**UNIQUE**), `client_*` and `bill_to_*` snapshots, `property_address`,
  dates, `currency 'AWG'`, `tax_treatment 'inclusive'`, `subtotal`, `tax_amount 0`,
  `total`, `amount_paid`, `balance`, `status`, notes, PDF ref, audit columns.
- `invoice_lines` — description, qty, unit_price, discount, line_total.
- `payments` + `payment_allocations` — a payment may be partial, span invoices, or be unallocated.
- `payment_receipts` — own sequence (`RCP-YYYY-NNN`), deliberately **not** the invoice number.
- `invoice_emails`, `client_statements`, `quickbooks_export_batches` / `_items`,
  `finance_audit_events`.

**Constraints that encode the rules:**

```sql
unique (org_id, invoice_number)
create unique index one_primary_invoice_per_order
  on invoices (order_id) where is_primary and status <> 'void';
```

**Derived state, server-side.** `balance = total - amount_paid` and the payment-derived
status (`sent → partially_paid → paid`, `overdue` by due date) are computed by trigger when
a payment is posted. The browser never writes them.

**Immutability.** A finalised invoice is not editable and not deletable; `void` is a status
transition that keeps the number and stays visible in reports.

Deliverables: migration, `Finance → Invoices` list + detail, quick-invoice from an order
(prefilled from the order, number inherited and read-only), draft → finalise workflow, and a
**Billing tab** on the order.

## Phase 3 — PDF & email

Deploy `render-report-pdf`. Add an invoice HTML template (company logo/address/bank details,
line items, total, payments, balance, payment instructions, page numbers) rendered through
the same pipeline; store the finalised PDF in the **private** `Storage` bucket — never the
public `reports` bucket.

Add a `sigma-email` edge function holding `RESEND_API_KEY`. Records in `invoice_emails`:
recipient, cc, subject, body, attachment, sender, provider message id, status, error.
`status='sent'` is written only on a 2xx from Resend.

**Needs from you:** a Resend API key, and a verified sending domain (likely
`taxatie-bureau.com`, with the DKIM/SPF records Resend issues).

## Phase 4 — Payments

Post full/partial/multiple payments, deposits, advances, reversals; automatic recalculation
of paid/balance/status via trigger; receipt PDF on its own sequence; payment history on the
Billing tab.

## Phase 5 — Statements & reports

Client statements by date range with aging buckets (current / 1-30 / 31-60 / 61-90 / 90+);
invoice, payment and AR reports; management dashboard (invoiced, collected, outstanding,
average collection period, orders without invoices). PDF/CSV/Excel export. Totals are never
mixed across currencies — AWG only until a reporting currency and rate method exist.

## Phase 6 — QuickBooks export

CSV/Excel export for customers, invoices, payments, behind an adapter interface. Export
batches with full logging; per-record state (not exported / exported / re-exported / failed);
re-export permitted but clearly marked.

**Blocked on:** the deployed `quickbooks` function is **older than the repo source**, reports
`connected: false`, and runs in **sandbox**. It needs re-deploying and reconnecting before
any export or live-invoice path can be tested. Note also its duplicate-`DocNumber` fallback,
which drops the number and lets QuickBooks auto-number — that must be removed, since it
breaks the invoice-number-equals-order-number rule.

---

## Sequencing note

Phases 2 → 6 are each independently shippable and each ends with a deployed, verified
version. Nothing in Phase 2 depends on QuickBooks or Resend, so the blocked items above do
not hold up core invoicing.

## Out of scope (explicitly)

Appraisal calculations, comparables, valuation workflows, report calculations, existing
document templates, order-number generation (now settled), and existing client records
beyond additive extension.
