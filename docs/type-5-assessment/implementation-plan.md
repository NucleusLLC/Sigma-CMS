# Type 5 — Assessment Report: implementation plan

Branch `feat/type5-assessment` (worktree `AppraisalSuite/sigma-t5`). Not pushed, not deployed.
Each phase ends in a commit with its checks green, so the work can stop at any phase boundary
without leaving the app broken.

## Guard rails for every phase

- Before and after each phase: `type-baseline` (Types 1–3 byte-identical), the `t4-*` checks,
  `pdf-latest-check`, `billing-disc-send-check`, run against the worktree file.
- No `apprType === 5` sprinkled through the file. Anything "is this report a valuation or not"
  goes through one registry. Anything specific to the Type 4 checklist stays specific to Type 4.
- Photographs and documents are referenced by storage path, never embedded.

## Phase 1 — Type registry (ships no visible change for Types 1–4)

`SIGMA_TYPES` in one place, next to `SECS_*`:

```js
{ 1:{ key:'parcel',       label:'Parcel Only',        family:'appraisal' },
  2:{ key:'building',     label:'Parcel + Building',  family:'appraisal' },
  3:{ key:'newbuild',     label:'New Construction',   family:'appraisal' },
  4:{ key:'inspection',   label:'Building Inspection',family:'condition' },
  5:{ key:'assessment',   label:'Assessment Report',  family:'condition' } }
```

Helpers: `sigmaType(t)`, `sigmaTypeLabel(t)`, `sigmaTypeFromLabel(s)`, `sigmaNoValuation(order)`.

- Every label map in audit §2.1 reads from the registry. Where a map printed a different
  string for the same type (`_tn` 'Parcel + New Construction'; the long `TYPES` form), the
  registry carries that variant explicitly, so the output does not change.
- `_tmap` (DB load) uses `sigmaTypeFromLabel`, so `'Assessment Report'` loads as 5.
- The "no valuation" gates switch from `=== 4` to `sigmaNoValuation(order)`. Type 4 behaves
  exactly as before; Type 5 inherits every one.
- `_secIdxsFor(5)` → `SECS_T5`.

**Done when:** type-baseline passes, all `t4-*` checks pass, and a new `type-registry-check`
asserts every former literal site resolves the same strings for 1–4.

## Phase 2 — Type 5 skeleton

- New-order type card, badge, `moType23Fields` panel (as Type 4), stored label.
- Change Type modal, demo order, report-customiser sample label.
- Strings `typeName5`, `typeStrip5`, `typeScope5`, `typeLabel5` (EN, NL).
- `DISC_DEFAULTS[5]` and every disclaimer function that hard-codes keys; `REPORT_LEGAL_NL[5]`;
  the `disc` map inside `generateReport`. The Type 5 declaration states no value and makes no
  safety, code-compliance, insurability or occupation claim.
- Cost rows: Type 5 uses its own list when the bureau has one, else Type 2's (as Type 4 does).
- Client email noun: "Assessment Report".
- Cover title `ASSESSMENT REPORT` (generalise `_t4CoverTitle` to a per-type stock title).

**Done when:** a Type 5 order can be created, reopened as Type 5 (through `_tmap`), edited,
inspected (tabs appear), invoiced, and every valuation control says it does not apply.

## Phase 3 — Assessment data model and pure logic (no UI yet)

Stored in `insp_data.s15._t5` (a new section 15, captured and restored like section 14):

- **Assignment:** purpose (configurable list + other), intended use, recipients, inspector,
  reviewer; inspection date, effective date, issue date kept separate.
- **Scope:** method `visual | limited_visual | desktop | specialist`; access
  `full | partial | exterior | none | document_only`; inspected areas, excluded areas, access
  restrictions, occupancy, weather, documents consulted, equipment used; area source per area
  `measured | plan | cadastral | estimate | unknown`.
- **Components:** the spec's ten sections as stable codes `C01…C10`; per component and per
  location: `applicability` (`applicable | not_applicable`), `observation`
  (`inspected | not_inspected | not_accessible | unknown`), `condition` from the existing codes
  (`NEW GOOD FAIR POOR BAD UNFINISHED`, or empty), notes. A component that was not inspected
  can never carry a condition.
- **Locations:** repeatable buildings / units / floors / rooms (`L1…`), plus manual labels.
- **Findings:** `uid` (random), `ref` `F-001` from a monotonic counter that never reuses a
  number, location, component, material, observation, extent/qty/unit, condition, severity,
  priority (`urgent | short | planned | monitor`), timeframe, cause suspected / confirmed /
  source / confidence, recommended action and action type, evidence references (photo storage
  paths + caption), inspector, dates, last editor, review status, imported flag.
- **Costs** (optional, off by default): base currency AWG or USD; lines in exactly one mode,
  `qty` (quantity × (materials + labour)) or `lump`; include flag; linked findings; source and
  date; contingency % and tax % only when explicitly entered; explicit FX (rate, direction,
  date, source) for any line in the other currency.
- **Conclusion:** overall condition code + rationale, executive summary, limitations text.
- **Lifecycle:** `draft → in_review → approved → issued`, return to draft before issue;
  approval stores the content hash of the assessment; any later change invalidates it.
  Issue records `{rev, hash, at, by, signatory, snapshot}`; a correction opens `rev + 1`
  with a reason and keeps every earlier issued snapshot untouched.

Pure functions, unit-tested without a browser: `t5CostCalc`, `t5Blockers` (review and issue
gates), `t5Hash`, `t5NextRef`, `t5ActionSchedule`, `t5Validate`.

**Done when:** the spec's numerical fixture gives exactly 400 / 100 / excluded 50 / 500 / 50 /
0 / 550, an unpriced line marks it incomplete, mixed currency without FX is rejected, and the
review/issue gates match §10 of the spec.

## Phase 4 — Assessment form (Inspect Data › Assessment)

Tabs for Type 5: Classification (0) · **Assessment (15)** · Photos (10) · Documents (11) · Sign-Off (13).
The Assessment section has sub-panels: Assignment · Scope & access · Condition matrix ·
Findings · Costs · Conclusion · Review & issue, a validation summary with links to the
incomplete fields, and the existing autosave status. Drafts save incomplete. Issued content is
read-only until a revision is opened.

**Done when:** driven in real Chrome — create findings, reorder, delete, reopen: references stay
stable; not-accessible components cannot be rated; costs recalc live; approve then edit shows
the approval invalidated.

## Phase 5 — The report

In `generateReport`, a Type 5 branch on the same one-boolean rule as Type 4:
Cover (ASSESSMENT REPORT, revision, issue date) · Executive summary · Contents ·
Assignment & property · Scope, method & access · Description & condition matrix ·
Detailed findings · Recommended action schedule · Remedial cost schedule (only when enabled) ·
Professional assessment & limitations · Reviewer declaration & sign-off (signature only once
approved) · Documents · Photographs.

Reuses the Type 4 reflow (`data-t4` → a condition-report flag) so long findings flow across
sheets. Desktop review never prints on-site wording. DRAFT watermark unless issued.

**Done when:** three synthetic reports (short; multi-building with photos; limited access
with costs disabled) render, every page is read by a check, and no valuation words, pages or
fields appear.

## Phase 6 — Issue, revision and release

Issue gate (client-side, recorded): reviewer conclusion, signatory, no blocking errors, approval
matching the current hash. Issuing turns the order's DRAFT off only through the existing
payment gate (§DRAFT-GATE). The published PDF of an issued revision is also kept at
`<stem>-r<N>.pdf` so a correction never overwrites it.

## Phase 7 — Verification and documents

`verification.md` (commands and results), `implementation-notes.md` (decisions, deviations,
blockers), `user-guide.md`, synthetic sample report HTML/PDF in an ignored output folder.

## Not in this plan (and why)

- **AI drafting** — the spec forbids provider keys in the browser, and that is the only AI path
  released today. Picked up when SaaS Day 7 (`sigma-ai` edge function) ships.
- **Server-side authorization, tenancy, transactional concurrency** — blocked by the current
  RLS/login architecture (audit §4); belongs to the SaaS conversion.
- **Deployment** — the spec says not to deploy; releasing is the owner's call.
