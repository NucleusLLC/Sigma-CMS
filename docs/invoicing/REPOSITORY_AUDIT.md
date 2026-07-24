# SIGMA-CMS — Repository Audit (invoicing module)

**Date:** 2026-07-24 · **App version at audit:** v2.270 · **Supabase project:** `cimgpycjczatjzltgscf`

Every claim below was verified against the code or the live database. Where something
was *probed* live (deployment status, constraints) that is stated explicitly.

---

## 1. Architecture in one paragraph

SIGMA-CMS is a **single static HTML file** (`sigma-deploy/index.html`, ~5.8 MB, ~45,900 lines)
with inline CSS and JS — no framework, no build step, no bundler. It is served by
Cloudflare Pages from the `main` branch of `github.com/NucleusLLC/Sigma-CMS`. All data
lives in Supabase and is reached directly from the browser with the **public anon key**,
which is embedded in the page source. A handful of Deno edge functions do the work that
cannot happen in the browser.

**Consequence that shapes everything below:** there is no application server. Any rule
that must be enforced — permissions, money maths, "don't mark it sent until it sent" —
has to live in Postgres or in an edge function, because the browser is untrusted.

---

## 2. Answers to the eight required questions

### 2.1 How are appraisal order numbers generated?

**As of v2.270: by the database.** `sigma_next_order_number(p_year)` (SECURITY DEFINER)
allocates from `order_number_counters`, a per-year high-water-mark counter. See
`ORDER_INVOICE_NUMBERING.md`.

**Before v2.270** the number was computed in the browser as `max(in-memory ORDERS) + 1`
with the year hard-coded as `'2026-'`. That produced three defects — number reuse after
deletion, identical numbers under concurrent creation (which *overwrote* the other user's
order, because the save is an upsert on `order_id`), and no year rollover. All three are
fixed; the detail is in `ORDER_INVOICE_NUMBERING.md`.

### 2.2 Do appraisal orders already have unique constraints?

**Yes, verified live:**

```
orders_pkey          PRIMARY KEY (id)          -- bigint surrogate
orders_order_id_key  UNIQUE (order_id)         -- the human number, e.g. '2026-091'
```

Note the app keys everything on **`order_id`**, not `id`. The unique constraint exists but
did *not* protect against the old numbering bug, because `persistOrders()` writes with
`upsert(..., { onConflict: 'order_id' })` — a clash silently **updates** the existing row
instead of raising.

### 2.3 Is more than one invoice per order currently possible?

**Not in the data model — but yes in practice, destructively.** An order carries three
scalar fields in `extra_data`: `qbInvoiceId`, `qbInvoiceNo`, `qbInvoiceUrl`. Creating a
second invoice **overwrites** them; the first invoice still exists in QuickBooks but SIGMA
loses the reference. Two of the three entry points ask for confirmation first; the guided
`_invoiceStepCreate` path does not.

Worse: when QuickBooks rejects a duplicate `DocNumber` (error 6140) the edge function
**drops the DocNumber and retries**, so QuickBooks auto-numbers the invoice. The result is
a second invoice whose number is *not* the order number, which then overwrites the first
one's reference on the order.

### 2.4 Which PDF generator does SIGMA use?

Three paths, in order of preference:

1. **`render-report-pdf` edge function → PDFShift** (true vector). **NOT DEPLOYED** —
   a live probe returns `{"code":"NOT_FOUND"}`. Source exists at the repo root only.
2. **html2canvas + jsPDF** in the browser (raster). Because of (1), *this is what actually
   runs today.*
3. `window.print()` for the print view.

There is **no invoice PDF and no invoice template** of any kind. All PDF machinery is
appraisal-report-only.

**Storage:** bucket `reports` (**public**) holds `<orderId>.pdf` / `.src.html`; bucket
`Storage` (private, signed URLs) holds photos and documents.

### 2.5 Which email provider does SIGMA use?

**None.** Every "email" action in SIGMA builds a `mailto:` URL and hands off to the user's
mail client (`_sigmaReportEmailHref`, `_sigmaOpenMailto`). There is no server-side sender,
no delivery confirmation, and no send log — SIGMA cannot currently know whether anything
was sent.

(The SMTP in `taxatie-bureau.com/a2-static/api/config.php` belongs to the *website* on A2
shared hosting, a different system. It is not reachable from SIGMA.)

**Decision taken:** **Resend** will be introduced for invoicing email. See
`IMPLEMENTATION_PLAN.md` §Phase 3.

### 2.6 Does QuickBooks code already exist?

**Yes.** `quickbooks-edge-function.ts` (repo root) implements the full OAuth2
authorization-code flow, stores tokens in `qb_tokens` (RLS on, **no policy** → service role
only), and supports ops `status` / `invoice` / `invlink` / `disconnect`. It finds-or-creates
a Customer by exact `DisplayName`, ensures one shared Item ("Appraisal Services"), and posts
an Invoice with one line per cost item.

**Live probe findings:**
- The function **is deployed** (v11) and reachable, but the deployed copy is **older than
  the source in the repo** — its response omits `fnVersion`, which the app's own diagnostic
  treats as "old, needs re-deploy".
- It reports `connected: false` — **no QuickBooks tokens are stored**, so nothing can be
  invoiced right now.
- `QB_ENV = sandbox`, not production.

It sends **no** `CurrencyRef`, **no** `TxnTaxDetail`, and **no** billing address.

### 2.7 How are taxes currently calculated?

**They are not.** There is no tax code, no rate, no tax field, anywhere in the app or the
edge functions. Prices are treated as tax-inclusive by convention only.

**Decision taken:** prices remain **tax-inclusive with no breakout**. The invoice will show
a single total and no tax line. The schema still carries `tax_treatment` and `tax_amount`
columns (set to `inclusive` / `0`) so a future BBO/BAZV breakout does not require a
migration.

### 2.8 How are organization-level permissions enforced?

**They are not, at any level.**

- **No organization/tenant model exists** — no `org_id`, `tenant_id`, or equivalent on any
  table. SIGMA is single-firm. The spec's "prevent cross-organization access" has nothing
  to enforce against.
- `role` is a free-text string on a localStorage user record. `canEdit` and `canExport`
  are written by the settings UI and **never read for any gating decision anywhere**.
- Every database call uses the **same anon key for every user**, so Postgres cannot tell an
  Administrator from a trainee. No RLS policy references `auth.uid()` or a role claim.
- RLS grants **anon `ALL` (`using true, with check true`)** on `orders`, `contacts`,
  `report_templates`, `messages`, and both storage buckets.

Since the anon key ships inside a public page, **anyone who views source can read and write
every record.** The repo's own SQL says so: *"these anon-allow policies clear the linter
warning but do NOT add real protection."*

The only genuine server-side authorisation in the system is the `sigma-admin` edge function
(PBKDF2-verified admin key, added v2.268) and the `INTAKE_SECRET` gate on `website-intake`.

---

## 3. Existing financial surface

**There is no financial table of any kind.** Full public schema (verified live):
`orders`, `contacts`, `inquiries`, `messages`, `report_templates`, `orders_archive` (empty),
`qb_tokens`, `order_number_counters`, and one dated backup table.

All billing state is denormalised onto the order row:

| Where | Fields |
|---|---|
| `orders.fee` (real column, `numeric`) | the agreed fee — 35 rows populated, range 275–1150 |
| `orders.extra_data` (JSON text) | `qbInvoiceId`, `qbInvoiceNo`, `qbInvoiceUrl`, `invoiceStatus` (`''｜pending｜invoiced`), `pendingInvoice`, `feeStatus`, `costItems`, `costTotal` |

Known defects in that surface:
- `pendingInvoice` is written and persisted but **never read** — dead data.
- `costItems` has **type drift**: `[{label,amount}]` at create time versus `{id:boolean}`
  everywhere else, so a brand-new order falls through to "Report only" in the invoice payload.
- Invoicing from the Cost tab sets `qbInvoiceId` but leaves `invoiceStatus` empty; the badges
  read `qbInvoiceId` first, which masks the inconsistency.

## 4. Money handling

- **Currency is AWG** throughout the billing UI. (`fmtCurrency` prints `$` but is used only
  for valuation figures, not fees — a display inconsistency, not a billing one.)
- **All amounts are plain JavaScript floats.** No decimal-safe type, no rounding discipline.
- `orders.fee` is Postgres `numeric` (unconstrained precision) — decimal-safe *at rest*.
- **The price master lives only in `localStorage`** (`ams_costPrefs_v1`), not in Supabase.
  Two devices can therefore total the same order differently, and editing a price silently
  changes what a historical invoice would rebuild as. This is the strongest argument for
  snapshotting line items onto the invoice at finalisation.

## 5. Client model

`public.contacts`: `id text pk, first_name, last_name, company, client_type, email,
work_phone, cell_phone, addr, city, country, notes, hear_from, order_count, created_at,
updated_at`.

Order-side client fields live in `extra_data`: `clientFirst`, `clientLast`, `clientEmail`,
`clientWork`, `clientCell`, `clientAddr`, `city`, `zip`, `country`, `stateZip`, `hearFrom`,
plus a real `client text` column holding a display string.

- **There is no billing address.** One client address, one property address. The invoice
  preview currently uses the **property** address as "Bill To".
- **There is no relational link between orders and contacts** — no `contact_id`. QuickBooks
  customers are matched by exact display-name string.

## 6. Conventions the module must follow

- **Nav area:** sidebar `<div class="ni" onclick="setView('x')">` inside a `.nav-sec`, a
  top-level `<div class="view" id="view-x">` sibling, and an `if(view==='x')` init hook in
  `setView()`. The active-state highlighter matches on **label text prefix**, so the visible
  label must start with the view name.
- **Per-order tab:** four places must be updated together — the `#editTabStrip` markup, a
  sibling `.epanel` div, the `EDIT_TABS` array, and the `_EDIT_PANEL_NAMES` map.
- **Persistence:** `_toRow()` / `_fromRow()`; anything without a dedicated column goes into
  the `extra_data` JSON whitelist. `insp_data` and `val_data` are *omitted* rather than
  nulled when not loaded (§DATA-SAFE) — never regress that.
- **Deploy:** edit `index.html` → commit → push → Cloudflare rebuilds (~1 min). Bump
  `APP_VERSION`, the `<meta name="version">` tag, and add a changelog entry.

## 7. Risk register carried into the build

| # | Risk | Status |
|---|---|---|
| 1 | Order/invoice number reuse | **Fixed v2.270** |
| 2 | Concurrent creation overwrites an order | **Fixed v2.270** |
| 3 | Financial data readable by anyone with the page | **OPEN — decision required** |
| 4 | No email provider | Resend chosen; not yet built |
| 5 | `render-report-pdf` not deployed | **OPEN** — invoice PDFs need it (or the raster fallback) |
| 6 | QuickBooks stale, disconnected, sandbox | **OPEN** — blocks export testing |
| 7 | Price master only in localStorage | Mitigated by snapshotting lines at finalisation |
| 8 | Floats for money | Fix in the new schema (`numeric`, server-side totals) |
| 9 | No billing address | New `invoices` table snapshots one |
