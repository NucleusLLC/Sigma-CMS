# Type 5 — Assessment Report: verification

Run on 15 Sep 2026 against the branch build (`sigma-t5/index.html`), Chrome 64-bit headless via `puppeteer-core`, Node 24.12.
Every browser check boots the **shipped** `index.html` on `file://` and drives real functions and real DOM. Only the network and persistence edges are stubbed. All fixtures are synthetic.

## How to run

The checks live in `AppraisalSuite/tools` and read `sigma-deploy/index.html` by default. To run them against the branch, copy each tool with the path swapped:

```bash
sed 's#AppraisalSuite/sigma-deploy/index.html#AppraisalSuite/sigma-t5/index.html#g' tools/<check>.mjs > /tmp/<check>.mjs
node /tmp/<check>.mjs
```

## Results

Columns: exit code · `ok` lines · `FAIL` lines.

### New for Type 5

| Check | What it proves | exit | ok | fail |
|---|---|---|---|---|
| `type-registry-check` | Types 1–4 print exactly the v2.526 strings at every former literal site; Type 5 resolves everywhere; valuation gates | 0 | 42 | 0 |
| `t5-skeleton-check` | Real new-order form creates a Type 5 (label, fee, DRAFT); `_toRow`/`_fromRow` round trip; tabs; Quick-View; disclaimers; cover; also the Type 4 fee-0 fix | 0 | 21 | 0 |
| `t5-model-check` | Spec cost fixture (400/100/excluded 50/500/50/0/**550**, unpriced → incomplete); rounding; currency; one mode per line; review/issue gates; desktop rules; stable refs; urgent evidence; approval invalidation; idempotent issue; revisions; import | 0 | 83 | 0 |
| `t5-form-check` | Assessment form in Chrome: fields and rules; not accessible clears condition; refs never reused; evidence = path + caption; live cost totals; autosave writes one `_t5`, no flat keys; **no bleed between orders**; reopen; full lifecycle through the buttons; issued read-only; revision 2; desktop label; import | 0 | 30 | 0 |
| `t5-report-check` | Three rendered reports read sheet by sheet (below) plus pre-flight | 0 | 63 | 0 |
| `t5-revision-pdf-check` | Issued + released revision kept at `-r<N>.pdf` without overwrite, recorded, never re-uploaded; drafts, unreleased and revision-2 drafts keep nothing | 0 | 11 | 0 |
| `t5-tablet-check` | The form at iPad portrait and landscape (added 16 Sep — see "Closed since") | 0 | 18 | 0 |
| `t5-photo-check` | Real JPEG bytes, including one over HTTP, through the evidence chain (added 16 Sep) | 0 | 26 | 0 |

### Existing checks (regression)

| Check | exit | ok | fail |
|---|---|---|---|
| `type-baseline` (Types 1–3 byte-identical) | 0 | 16 | 0 |
| `type4-check` (updated to accept the registry form; still passes on main) | 0 | 92 | 0 |
| `t4-bleed-check` (new with the hotfix) | 0 | 6 | 0 |
| `t4-checklist-check` | 0 | 33 | 0 |
| `t4-form-check` | 0 | 30 | 0 |
| `t4-render-check` | 0 | 50 | 0 |
| `t4-noval-check` | 0 | 26 | 0 |
| `t4-report-order-check` (layout guard may name `_isT5`; passes on main) | 0 | 61 | 0 |
| `t4-preflight-check` (loop bound ≥ 15; passes on main) | 0 | 24 | 0 |
| `t4-arrange-check` | 0 | 23 | 0 |
| `t4-sectionorder-check` | 0 | 39 | 0 |
| `t4-loc-toggle-check` | 0 | 11 | 0 |
| `t4-letters-check` | 0 | 13 | 0 |
| `t4-compact-check` | 0 | 8 | 0 |
| `t4-relay-check` | 0 | 8 | 0 |
| `t4-print-check` | 0 | 5 | 0 |
| `t4-email-check` | 0 | 22 | 0 |
| `t4-gen-ai-check` | 0 | 37 | 0 |
| `pdf-latest-check` | 0 | 26 | 0 |
| `billing-disc-send-check` | 0 | 21 | 0 |
| `cost-prefs-check` | 0 | 14 | 0 |
| `master-fees-check` | 0 | 29 | 0 |
| `sec-disable-check` | 0 | 8 | 0 |
| `spill-heading-check` | 0 | 3 | 0 |
| `scope-print-check` | 0 | 7 | 0 |
| `spill-check` | **1** | 56 | 0 |

`spill-check` exits 1 with `ReferenceError: _t4ReflowRuntime is not defined` after 56 passing checks. It does exactly the same on `main` v2.526/v2.527, so it is not caused by this work.

Not run, because they need an input file and do not self-test by default: `print-check`, `opinion-check`, `report-pdf-check` (`pdfjs-dist` is not installed where the copied tool runs).

## Report QA (`t5-report-check`)

| Report | Scenario | Sheets | Asserted |
|---|---|---|---|
| A | Issued, released; urgent finding with an acknowledged evidence limitation; cost schedule enabled (spec fixture plus an unpriced line) | 9 | Page order = Contents order; each Contents number = the sheet its link lands on; one "of N"; nothing in the footer band; no valuation/USPAP/"appraisal report"; cover "Rev. 1 · Issued"; no watermark; urgent item in the executive summary; suspected cause labelled not confirmed; total AWG 550.00 INCOMPLETE; excluded and not-estimated lines; reviewer conclusion and signatory; no appraisal stamp |
| B | Draft; two buildings; 14 long findings; one photograph present, one missing | 14 | As A, plus DRAFT watermark on every sheet; "Not issued"; findings run across several sheets; building labels kept; photograph and caption print; the missing photograph is named; action schedule groups by priority; "not signed", no signatory name |
| C | Desktop review; one component not accessible, one not applicable; costs disabled (with a hidden line); no findings | 8 | "The property was not visited"; no on-site wording; "Document review date"; plan area shows its source; Not accessible / Not applicable printed as such; no cost page or totals; the document-review no-defects wording; no action schedule page |
| Pre-flight | A, B, C | — | Assessment Report group and no valuation group; issued/ready; incomplete costs flagged; draft prints as DRAFT; missing evidence photograph named; costs not included |

## Visual inspection

The three reports were printed to A4 PDF with Chrome after their layout scripts ran. Every sheet was screenshotted and inspected: cover, executive summary, findings, cost schedule and sign-off (A); condition matrix, action schedule and watermark (B); executive summary and assignment (C).

Two defects were found and fixed:

1. The cover type strip wrapped into the scope line. It is now shortened to "Assessment Report · Rev. N · …".
2. A "Property type" row fell back to the report-type label. It now shows only the order's property type.

Samples (not in the repository): `AppraisalSuite/output/type5-samples/t5-sample-{A,B,C}.{html,pdf}` and `png-{A,B,C}/sheet-NN.png`.

## Not verified

- Anything against production data, storage or the database. Production reads were blocked in this session, and the spec forbids it. This is the only remaining item that needs production access; the tablet-layout and photograph-bytes items were closed on 16 Sep 2026 (see "Closed since").
- Dutch-language Type 5 report output. Strings exist but were not rendered. Checked against Type 4 first: the Type 4 report body is English too (7 `_rt()` calls in 278 lines, against 24 in Type 5's 1105), so this is the house standard for a condition report, not a Type 5 regression. Only the picker and the type labels are translated.

## Closed since (16 Sep 2026)

Two "not verified" items were closed with two new checks. Both boot the shipped `index.html` in real Chrome, as the
rest of the suite does.

| Check | What it proves | exit | ok | fail |
|---|---|---|---|---|
| `t5-tablet-check` | The Assessment form at iPad portrait 768×1024 and landscape 1024×768, in its widest state (2 findings with evidence, 2 cost lines, every component rated): the page never scrolls sideways, nothing inside the card sticks out past it, all 138 bound controls are drawn and on screen, all 99 labels survive the narrower column, every action control is ≥ 28px tall on a coarse pointer, and no page error is thrown at either width | 0 | 18 | 0 |
| `t5-photo-check` | Real photograph bytes through the evidence chain: a 1600×900 landscape JPEG, a 900×1600 portrait JPEG and a 1200×800 JPEG **fetched over HTTP** (the shape a Storage public URL has) all decode at their true size in the rendered report, each prints at the source aspect ratio, none breaks the 62mm evidence box or its column, each caption stays with its image, and an absent photograph is named rather than dropped | 0 | 26 | 0 |

`t5-photo-check` also settles the spec's §8 rule on orientation with measured geometry: a portrait photograph is
limited by the 62mm height and letterboxed sideways (picture 132×234 inside a 314×234 box), a landscape one is
limited by the column width instead (314×177 in a 314×177 box). Both keep the source ratio to within 0.3%.

**One change was needed to make `t5-tablet-check` pass.** At tablet width the geometry was already correct, but the
remove (`.t5-x`, 18px), evidence (`.t5-evb`, 20–23px) and validation-link (15px) controls were too small to hit with
a thumb. **§T5-TOUCH (v2.528)** raises them to 32px inside `@media (pointer:coarse)` only, so the desktop form is
byte-identical — `type-baseline`, `type4-check`, `t4-render-check` and the six Type 5 checks were re-run after it and
all still pass with the same counts.

What remains unverified about photographs is only the part that needs production: the app hydrating `data` from a
real `storagePath` against the live Storage bucket. That path is shared with Types 1–4 and has been live for
versions; Type 5 adds nothing to it. Everything downstream of it is now measured.

## Re-run after the v2.528 renumber (15 Sep 2026)

The 62 Type 5 / registry section tags were renumbered from `(v2.527)` to `(v2.528)`, `APP_VERSION`, the `<meta
name="version">` and a changelog entry were set to `v2.528`, and two tools that pinned a version inside a source anchor
were made version-agnostic (`t5-model-check` on the `§T5-MODEL` banner, `type4-check` on the `§TYPE-REGISTRY` opening of
the page-suppression block — both now match `\(v[0-9.]+\)`).

The whole suite above was run again against the renumbered file. Every check returned the same exit code and 0 FAIL.
The `ok` counts were re-counted for the six Type 5 checks and for `type-baseline` and `type4-check`, and each matched
its row above exactly (42 / 21 / 83 / 30 / 63 / 11, 16, 92); the remaining regressions were checked on exit code and
FAIL count only. `spill-check` still exits 1 on the same pre-existing
`_t4ReflowRuntime` ReferenceError it throws on `main`. `print-check`, `opinion-check` and `report-pdf-check` were again
not run, for the reasons given above.
