# Type 5 — Assessment Report: repository audit

Audited 15 Sep 2026 against `sigma-deploy` `main` at `dcf8df1` (v2.526), in worktree
`sigma-t5` on branch `feat/type5-assessment`. Line numbers refer to that build of
`index.html` and will drift.

## 1. What the repository actually is

The spec is written for a conventional server-backed application (migrations, server
validators, tenant-scoped APIs, background jobs, a test runner). SIGMA-CMS is not that,
and the plan has to be built on what is really here:

| Spec assumes | Repository reality |
|---|---|
| Framework, build, package manifests | One static file, `index.html`, **79,697 lines**, no build step. `package.json` exists only for dev tooling. Deploy = `git push origin main` to Cloudflare Pages. |
| Server backend and API | Supabase project `cimgpycjczatjzltgscf`, called **directly from the browser** with the anon key. A few Deno edge functions (none for reports; `render-report-pdf` is referenced but never deployed). |
| Server-side authorization, tenant isolation | Every public table is `USING (true)` for `anon` (memory: sigma-cms-rls-hardening). Login is dual local SHA-256 + Supabase Auth; the local path has no JWT, so RLS cannot be tightened yet. There is one organisation (`org_id text = 'sigma'` on finance tables). Multi-tenancy is the separate SaaS conversion (`CascadeProjects/Sigma-CMS`, Stage C migrations drafted, not applied). |
| Migrations | Hand-applied SQL. Orders keep almost all order data in JSON (`orders.insp_data` text, `orders.extra_data`). |
| Test runner | None. Verification is `node tools/*.mjs` scripts in `AppraisalSuite/tools` (untracked), most of which boot the shipped `index.html` in real Chrome through `puppeteer-core`. |
| PDF service | In-browser: the report is HTML opened in a new tab (browser print), and a raster PDF (html2canvas + jsPDF) is published to the public `reports` bucket (`_sigmaPublishReportPDF`). |
| AI integration | Browser → `api.anthropic.com` with a key held in `localStorage` (`appraisalSuite_anthKey_v1`). The server-side replacement (`functions/sigma-ai`, SaaS Day 7) is prepared but not released. |

## 2. What a report type is here

A type is a number, `order.apprType`, plus a text label stored in `orders.property_type`.

- **Stage 0 (the Type 4 plan's open question) is answered.** The 15 Sep 2026 schema dump
  (`Sigma-CMS/backups/db-20260915-0108/sigma-schema.sql`) has **no CHECK constraint** on
  `orders.property_type` (plain `text`, line 5717). The only database consumer is
  `sigma_create_invoice_from_order`, which uses it as an invoice line description fallback.
  **Type 5 needs no migration to exist.**
- The label ↔ number map is read back on load: `_tmap` at L62635
  (`{'Parcel Only':1,'Parcel + Building':2,'New Construction':3,'Building Inspection':4}`,
  anything unknown → **2**). An unmapped `'Assessment Report'` would silently load as Type 2.
  This is the first thing Type 5 must fix.

### 2.1 Every place that assumes a fixed set of types

Found by `grep` over `apprType`, `{1:` literals, `4:` keys, `SECS_T*`, `_isT4`, `data-t4`
and `'t1'/'t2'/'t3'`. The "missing key 4" trap (memory: sigma-cms-type4) hit Type 4 **five
times**, because every per-type lookup falls back to Type 2 with no error.

**Label maps, each a separate literal (10):**
L26737 `BADGES` (new-order badge) · L27054 `typeLabels` (order create) · L47683 `TYPE_LABELS`
(type change) · L62635 `_tmap` (DB load) · L64175 report-customiser sample label ·
L64630 `_tn` (demo order) · L72155 `TYPES` and L72290 `TL` (Change Type modal) ·
L50391–50393 `typeNames/typeStrip/typeScope` (report cover) · L52220 `_typeLabel` (Contents).

**Section sets:** `SECS_ALL` (L16472), `SECS_T1`, `SECS_ALL_IDX`, `SECS_T4` (L16495),
chosen in `_secIdxsFor` (L17207). `buildTabs()` hides every `isec-N` not in `_secIdxs`.
Section 14 (`isec-14`, "Building Inspection") is reachable only through `SECS_T4`.

**String tables:** `REPORT_STRINGS.en` (L17534…) and `.nl` (L17974…), keys `typeName1-4`,
`typeStrip1-4`, `typeScope1-4`, `typeLabel1-4`. No Spanish type keys (ES falls back to EN).

**Disclaimers:** `DISC_DEFAULTS` (L56976) keyed 1-4; `discLoad` (L57021) builds its return
object from **hard-coded keys**, as do `discSave` (L57242), `discRestoreUI` (L57312) and
`discReset` (L58232). `REPORT_LEGAL_NL` (L18523). `generateReport` builds its own
`disc = {1:…,4:…}` map (L50654).

**Costs and fees:** `COST_DEFAULTS` t1-t3 (L74367); `getCostPrefs` loops `['t1','t2','t3']`;
`getCostItems(t)` returns `p['t'+t] || p.t2`. Type 4 has no list of its own and gets Type 2's.
Master Fees (`MF`, L31847) prints columns t1-t3 only.

**"No valuation" gates written as `apprType === 4` (about 30):** order-row Valuation button
(L20210, L20245), `_valBlockedFor` (L45489), Quick-View tracker and valuation box (L46884,
L46907, L47000), report pre-flight (L49166), `generateReport` value suppression (L50279),
section-order panel (L19120, L19264, L19273, L19542), client email noun (L61447).

**Type 4 report machinery inside `generateReport` (L49971):** `_isT4` (L50974) drives the page
list (L51079, via `_t4OrderFor` and `T4_PAGE_IDS` L19022), cover title (`_t4CoverTitle`
L18332, used at L51337, L51459, L52223), `<body data-t4="1">` (L51975), the Contents rows
(L51878), page rendering (L54325, `_t4Pg[id]`) and the post-render reflow and relay passes
(§T4-REFLOW/§T4-RELAY, L56154–56770), which match `data-t4` and `^page-t4`.

## 3. One report traced end to end (Type 4, the closest relative)

1. **Create.** New-order modal: type card (L12882) → `moType23Fields` panel shared with Type 2
   (L26719) → `submitOrder` builds `newOrder` with `apprType`, `type: typeLabels[at]` (L27081),
   cost items from `getCostItems` → `ORDERS.unshift` → `persistOrders(id)` (upsert into
   `orders`, JSON columns). New orders start in DRAFT (`draftMode = true`, §DRAFT-GATE v2.462).
2. **Edit.** Project Data modal `openEdit` (tabs `EDIT_TABS` L43862: General, Client, Parcel,
   Financial, Building, Cost, Billing, Notes, Map); `_editApplySnapshot` writes the form back.
3. **Inspect.** `openInsp` (L22483) → `_secIdxsFor(apprType)` → `buildTabs`. Each section
   saves as a JSON blob: `_inspCapture(secIdx)` → `localStorage insp_<id>_<n>` +
   `ORDERS[i].inspData.s<n>` → `persistOrders` on Next/Submit. Section 14 captures the
   checklist explicitly (`d._t4 = _t4Capture()`, L24036).
4. **Photos.** Section 10 zones; bytes go to the `Storage` bucket and the row keeps
   `storagePath` (§DOC-SERVER-STRIP, after the 16 Jul 2026 outage caused by inline bytes).
5. **Report.** `reportCheckRun` → pre-flight (`_rcBuildChecks`) → `reportCheckProceed` →
   `generateReport(id)` → HTML in `window._rcReportHtml` → opened as a blob: URL →
   background `_sigmaPublishReportPDF` (raster PDF to `reports/<job>-<token>.pdf`).
6. **Release.** DRAFT watermark + no signature/stamp while `order.draftMode`; turning DRAFT
   off is gated on the invoice being paid (`qvToggleDraft`, §DRAFT-GATE). Email/PDF buttons
   send the published link.
7. **Billing.** One invoice per order, numbered by the order number (`finCreateForOrder`,
   `sigma_create_invoice_from_order`); Cost-tab discount carried as the invoice's own field.

## 4. Capabilities the spec needs that do not exist, and cannot be built honestly in this architecture now

| Spec requirement | Why it cannot be real today | What can be done in-app |
|---|---|---|
| Server-side authorization on every action; roles author / reviewer / issuer / viewer | No JWT for local logins; `anon` has ALL on `orders` | Client-side gates and an audit trail on the order. **Not security.** Recorded as a blocker. |
| Tenant isolation, cross-tenant denial | Single tenant; SaaS Stage C/D not applied | None needed for one bureau; recorded for the SaaS plan. |
| Transactions, optimistic concurrency, idempotent jobs | Browser writes whole JSON sections via upsert | A save-time revision counter and a conflict check against the stored row (best effort). |
| Immutable issued content, new revision per correction | Same row is overwritten; PDF path is reused | Frozen snapshot of the assessment data kept inside the order with a content hash; issuing and revising are recorded; the published PDF for an issued revision is kept at its own path. |
| Server decimal/money implementation | None for assessments | Integer-cent arithmetic in one pure function, with rounding documented and unit-tested. |
| AI keys never in the browser | The existing integration is browser-held | Out of scope until SaaS Day 7 releases `sigma-ai`; no new browser-key AI is added for Type 5. |
| Signed download links scoped per user | `reports` bucket is public by design (cover QR) | Unchanged; recorded. |

## 5. Confirmed facts, constraints and proposed defaults (kept separate)

**Confirmed facts** — everything in §§1–4 above, read from the code and the schema dump.

**Repository constraints**
- Additive only: no renumbering of orders, no reinterpretation of stored `apprType` values,
  no writes to production data as part of this task (memory: never change data without consent).
- Types 1–4 must stay byte-identical where the harnesses measure them (`tools/type-baseline.mjs`
  plus the fourteen `t4-*` checks).
- No inline bytes in `insp_data` (the 16 Jul 2026 outage shape).
- A parallel session commits to `sigma-deploy/main`; this work stays on its own branch.
- The spec says do not deploy. Nothing is pushed.

**Proposed defaults (not an approved specification — the spec says so itself)**
- Identifier `5`, semantic key `assessment`, stored label `'Assessment Report'`, display
  `Type 5 · Assessment Report`, PDF title `ASSESSMENT REPORT`.
- Type 5 is a *condition* report, like Type 4: no valuation anywhere.
- Type 4 is the nearest existing report and overlaps heavily with this baseline (condition,
  findings, priorities, limitations). The difference the baseline draws is: Type 5 adds scope
  and access modes including desktop review, a findings register with stable references and
  cause/confidence, an optional remedial cost schedule, and a review → approve → issue →
  revise lifecycle. **Whether the bureau wants both reports, or wants Type 4 to grow into
  this, is a decision for the owner.** Building Type 5 does not change Type 4.
