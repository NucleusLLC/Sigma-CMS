# Type 5 — Assessment Report: implementation notes

Branch `feat/type5-assessment`. Not pushed, not deployed.
The code tags read `v2.528`. They were written as `v2.527` while the work was in progress; production took v2.527 for an
unrelated Type 4 hotfix on 15 Sep 2026, so the 62 Type 5 / registry tags were renumbered to `v2.528` and `APP_VERSION`,
the `<meta name="version">` and the changelog were set to `v2.528`. The two `v2.527` tags left in `index.html` are the
hotfix's own (`§T4-NO-BLEED`) and belong to main.

## What was built

| Area | Where (section tags in `index.html`) |
|---|---|
| Type registry | `§TYPE-REGISTRY`: `SIGMA_TYPES`, `sigmaType*`, `sigmaNoValuation` |
| Skeleton | picker card, badge, Quick-View T5, `typeName5…typeLabel5` (EN/NL), `DISC_DEFAULTS[5]` + disclaimer functions, email noun |
| Data model and rules (pure) | `§T5-MODEL`: `t5CostCalc`, `t5Blockers`, `t5Hash`, `t5EffectiveState`, lifecycle, import |
| Form | `§T5-FORM`: `isec-15` "Assessment", `t5Render`, path binding, section-15 capture/restore |
| Report | `§T5-REPORT` (inside `generateReport`), `_t5PageIds`, `_t5CoverTitle`, `_t5ReportNotes` |
| Pre-flight | `§T5-PREFLIGHT` in `_rcBuildChecks` |
| Issued revision PDFs | `§T5-REVISION-PDF`: `_t5KeepRevisionPdf` |
| Touch sizing | `§T5-TOUCH`: a `@media (pointer:coarse)` block; desktop unchanged |

Data lives in `orders.insp_data.s15._t5`, and photographs are referenced by storage path. No database migration was needed. The 15 Sep 2026 schema dump has no CHECK constraint on `orders.property_type`, and `'Assessment Report'` reads back as 5 through the registry.

## Decisions and assumptions

1. **Type 5 is a condition report.** It has no valuation, like Type 4, and every valuation gate asks `sigmaNoValuation()`. The baseline overlaps heavily with Type 4, and Type 4 is unchanged. Whether the bureau wants both reports is the owner's decision.
2. **Condition codes reuse the app's existing scale** (NEW GOOD FAIR POOR BAD UNFINISHED). Applicability, observation, condition, severity and priority are stored separately. The model removes a condition from anything that was not inspected.
3. **Priorities:** urgent attention · short term · planned maintenance · monitor. Default timeframes are suggestions filled in only when the timeframe is empty; the assessor can change them.
4. **Finding references** come from a counter that only rises. Removing a finding keeps it with `removed: true`, so a reference is never reused.
5. **Money** is integer cents, rounded half away from zero per line on the decimal value. That is the same policy as `_cents` (§PROMILLE-FIX), and it matches Postgres `numeric`.
   - Amounts follow the app's reader, where `1.500` means 1500.
   - Quantities, percentages and exchange rates never use thousands grouping, so `2.500` means 2.5.
   - Contingency and tax apply only when a percentage is entered. The tax base is chosen explicitly (subtotal, or subtotal plus contingency).
   - A different currency needs a recorded rate, direction, date and source; without them there is no total.
6. **Approval** belongs to the content hash, so any edit to printable content invalidates it.
   - The reviewer's conclusion prints on the report, so it must be written before approving.
   - The inspector may also be the reviewer, because a one-person bureau has no one else; the approver is always recorded.
7. **Issuing** is idempotent and freezes a snapshot. A correction opens revision N+1 with a reason, and revision N is never touched. An issued revision prints from its snapshot.
8. **Release stays separate from issuing.**
   - Not issued: the report prints with the DRAFT watermark and "Signatory — not signed", whatever the order's DRAFT switch says.
   - Issued: release goes through the existing DRAFT switch and its payment rule (§DRAFT-GATE).
   - The PDF of an issued revision is kept at `<stem>-r<N>.pdf` only when it is published with DRAFT off.
9. **Report page order follows the spec, with one deviation:** Contents is page 2 and the Executive Summary page 3. The spec puts the summary before the Contents, but the report engine emits the Contents before any type's pages, and changing that would affect Types 1–4.
10. **The shared compaction pass** (§T4-COMPACT) places short sections on the same sheet. The Contents numbers are verified against the sheets the links land on.
11. **Wording that must go to the bureau and its insurer (plan risk R5)** — all four texts are set out for signature in `wording-for-approval.md`, checked character for character against `index.html`:
    - the `DISC_DEFAULTS[5]` declaration;
    - the Contents note (`_t5ReportNotes`);
    - the cost disclaimer;
    - the "does not certify structural safety…" line.

    All four are proposed wording. The declaration (and the structural-safety clause inside it) is editable in Settings › Disclaimers; `_t5ReportNotes` and the cost disclaimer are in code and need a release to change.

## Deviations from the spec, and why

| Spec | What was done | Why |
|---|---|---|
| Server-side authorisation, roles, release override logging | Client-side gates and an audit trail on the assessment | The browser writes `orders` directly (anon `USING (true)`), so a server gate is impossible until real logins and RLS exist (SaaS Stage D). |
| Tenant isolation and cross-tenant tests | Not applicable | Single organisation; tenancy is the SaaS conversion (Stage C migrations drafted, not applied). |
| Transactions, optimistic concurrency, idempotent jobs | Idempotent issue; stale-publish protection comes from §PDF-LATEST; no concurrent-edit conflict detection | Sections are saved as whole JSON blobs by upsert. A conflict check needs a server-side version column. |
| Server-side decimal implementation | Pure function with integer cents, unit-tested | No server exists for this. |
| AI drafting (optional) | Not built | The spec forbids provider keys in the browser, and that is the only AI path released today. It can be added when `sigma-ai` (SaaS Day 7) ships. |
| Separate entities / tables | One JSON object per order | The spec says to adapt to the real schema. This app keeps inspection data in `insp_data`. |
| Signed, scoped download links | Public `reports` bucket as before | The cover QR code must resolve without logging in. Unchanged, and recorded as a limitation. |
| Low/high cost ranges | Not built | Optional in the spec. |
| Plan markers on floor plans | Manual location labels and optional L1… locations | The spec says not to build a CAD editor. |

## Things found and fixed along the way (outside Type 5)

- **§T4-NO-BLEED (hotfix v2.527, live):** opening a Building Inspection after another one carried the first order's checklist into the second, and autosave then saved it there. **Production orders opened in that sequence before 15 Sep may carry another order's findings.** They have not been audited, because reading production was blocked.
- **§TYPE-COST-PANEL (hotfix v2.527, live):** a new Type 4 order was saved with a fee of 0.
- `spill-check` fails the same way on `main` (`_t4ReflowRuntime is not defined`). This is pre-existing and unrelated.

## Migration and setup

None. The branch is additive: no table, column, bucket or edge function. The kept revision PDFs use the existing `reports` bucket.

## Rollback

Revert the branch commits. Stored Type 5 orders keep their `insp_data.s15` and `property_type = 'Assessment Report'`. On a build without the registry, an unknown label loads as Type 2 (the old `_tmap` fallback): the data stays in the row but is not shown. Reinstate the branch to show it again. Nothing in this work deletes or rewrites existing data.
