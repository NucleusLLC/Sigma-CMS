# Type 5 — Assessment Report: wording for approval (plan risk R5)

> **APPROVED — 23 September 2026, by the owner.** All four texts approved as written. Reliance clause: keep
> Type 5's wider wording ("the named client and the intended use stated in it"); confirm with the insurer when
> convenient — it is editable in Settings › Disclaimers. The Contents note (item 2) was made editable in
> Settings › Disclaimers as "Notes on this Report — Type 5 Assessment Report" (key `notes5`), with the approved
> text as its default. Released as v2.554.

Everything below is **proposed** wording written with the implementation. None of it has been approved by the bureau
or by its professional-indemnity insurer, and the Type 5 implementation plan records that approval as risk **R5**.
This page exists so the four texts can be read together, in the order a reader of the report meets them, and signed
off or replaced. Nothing here is live: the branch is not deployed.

For each item: where it prints, what it is for, and **how it is changed**. Two are editable in Settings ›
Disclaimers; two are in code and need a release. The quoted texts below were checked against `index.html`
character for character.

---

## 1. The declaration — `DISC_DEFAULTS[5]`

**Prints:** on the Professional Assessment / declaration page of every Assessment Report, and it is what the
signatory signs under.
**Changed by:** Settings › Disclaimers, per installation. The text below is only the default a fresh installation
starts with.

> This is a Type 5 — Assessment Report. It records the observable condition of the property within the scope, method
> and access stated in this report, as at the date given for that observation, together with the findings,
> recommendations and priorities that follow from it. It states NO market value, execution value or reconstruction
> value: it is not an appraisal and must not be relied upon as one. Any indicative remedial costs are estimates for
> planning purposes only, subject to the stated basis, exclusions and verification; they are not a quotation, a
> valuation, an insurance determination or a tax assessment. Areas and components recorded as not inspected, not
> accessible or unknown are outside the conclusions of this report. Nothing in this report is a certification of
> structural safety, compliance with any building code or regulation, insurability, or fitness for occupation; any
> such matter requires investigation by an appropriately qualified specialist. This report is prepared for the named
> client and the intended use stated in it, and no responsibility is accepted to any other party.

**Why it is worded this way**

- It never says a site visit happened. A desktop review prints this same paragraph; what was actually done is stated
  on the Scope page from the recorded method. A declaration that assumed a visit would be false on those reports.
- It refuses, by name, the four claims the specification forbids a template to make on its own: structural safety,
  code compliance, insurability, fitness for occupation.
- It states no value of any kind, so the Assessment Report can never be read as an appraisal.
- It puts the cost limitation in the declaration as well as on the cost page, because the cost page is optional.

**For the insurer:** the reliance clause is "the named client and the intended use stated in it, and no
responsibility is accepted to any other party." Type 4's equivalent says "the exclusive use of the named client".
Type 5's is wider, because an assessment is often commissioned for a named third party (a bank, an association).
Confirm which the policy requires.

---

## 2. The Contents note — `_t5ReportNotes()`

**Prints:** in "Notes on this Report", on the Contents page.
**Changed by:** code. It is a function in `index.html`, not a setting — changing it needs a release.

> This assessment report has been prepared for the named client and the intended use stated in it. Page numbers refer
> to the printed document. Finding references (F-001 and onwards) are permanent and are used throughout the report.
> Components shown as not inspected, not accessible or unknown are outside its conclusions.

**Why it exists at all.** The shared note used by Types 1–4 opens "This appraisal report has been prepared for the
exclusive use of the named client **and lender**" and goes on to describe an inspection visit. On an assessment that
is wrong, and on a desktop review it is false. Type 5 therefore prints its own.

**Decision needed:** whether this should become a fourth editable disclaimer instead of code. It is a one-line change
and would let the bureau alter it without a release. It was left in code so that Types 1–4 keep exactly the note they
print today.

---

## 3. The cost-schedule disclaimer

**Prints:** twice — as the subtitle of the cost page, and as a note under the totals. Only when the cost schedule is
switched on.
**Changed by:** code.

Page subtitle:

> Planning estimates only — not a quotation, a valuation, an insurance determination or a tax assessment

Note under the totals:

> These figures are indicative assessment estimates for planning, subject to the stated scope, basis and exclusions
> and to verification. Actual costs depend on detailed investigation, specification and tendering.

And where the schedule is incomplete, printed with the total rather than instead of it — on the cost page:

> **Indicative total — INCOMPLETE**
>
> **Incomplete.** One or more items are not estimated and are not included in the total.

and, in the executive summary:

> Indicative total AWG 550.00 — **incomplete**: at least one item is not estimated and is not included in this figure.

**Why.** The specification is explicit that repair costs are not market value, not reconstruction value, not an
insurance coverage decision and not a tax assessment, and that a missing price must leave the schedule visibly
incomplete rather than silently lower the total. The basis and the estimate date are required fields, so the report
can always say what the numbers rest on.

---

## 4. The specialist-referral line

This is a clause **inside** item 1 rather than a separate text, and it is the one most likely to be argued over, so
it is pulled out here:

> Nothing in this report is a certification of structural safety, compliance with any building code or regulation,
> insurability, or fitness for occupation; any such matter requires investigation by an appropriately qualified
> specialist.

The application enforces the matching behaviour: a finding may record a suspected cause and a confirmed cause as two
separate fields, and the report prints a suspected cause labelled as not confirmed. An urgent finding requires either
evidence or an explicit, reviewer-acknowledged evidence limitation — it can never be quietly suppressed.

---

## What is asked of the reviewer

| # | Text | Where | Editable without a release | Approved? |
|---|---|---|---|---|
| 1 | Declaration `DISC_DEFAULTS[5]` | Declaration page | Yes — Settings › Disclaimers | |
| 2 | Contents note `_t5ReportNotes()` | Contents page | **No — code** | |
| 3 | Cost disclaimer (subtitle, note, incomplete line) | Cost page | **No — code** | |
| 4 | Specialist-referral clause | Inside the declaration | Yes, with item 1 | |

Three answers close R5:

1. Approve, amend or replace each of the four texts.
2. Confirm the reliance wording in item 1 against the professional-indemnity policy.
3. Say whether item 2 should move out of code into Settings › Disclaimers.

Until then the branch stays unreleased. Sample reports showing all four texts in place are at
`AppraisalSuite/output/type5-samples/` (reports A and B carry the cost schedule; C has it switched off).
