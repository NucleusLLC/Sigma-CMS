# Developments (BLU Capital Group) — deploy runbook

**Version:** v2.351 · **Sections:** `§BLU-DEVELOPMENTS`, `§BLU-VALUATION` · **Written:** 2026-08-24
**Project:** Sigma CMS, Supabase ref `cimgpycjczatjzltgscf`
**Sending side:** `blucapitalgroup/web/src/lib/dashboard/appraisal.ts` (already built and tested)

---

## ⚠ WHERE THIS DEPLOY ACTUALLY STARTS TODAY

**Steps 1, 2 and 3 were applied to production on 2026-08-24 and are LIVE.**
`public.blu_appraisal_requests`, `sigma_blu_record_request(jsonb)` and the `B`-suffix
allocator all exist on the live server right now.

The valuation (v2.351, `§BLU-VALUATION`) is therefore **not** a change to those two
files — an already-applied file that quietly grows a column is a file nobody can trust
again. It is a separate, additive migration **against a live table that already holds
production rows**: `supabase/SIGMA_blu_valuation_20260824.sql`.

> ### → Start at **step 3b**. Then 4 onwards as written.

Steps 2 and 3 must **not** be re-run as a way of picking up the valuation. Step 1 (the
snapshot) has already run and refuses to overwrite itself, so re-running it is harmless
but pointless.

---

## What this deploys

When BLU Capital Group's Sales & Control Desk verifies a buyer's deposit, it POSTs an
appraisal request to a new edge function. SIGMA records it, **allocates the appraisal
number on the spot** out of the same yearly series every other order draws from — with a
trailing `B`, e.g. `2026-045B` — and hands that number straight back, so both systems name
the job the same thing from the first second. The request appears in a new **Developments**
area in the sidebar, and one click raises a Job Order under the number already reserved.

**v2.351 adds the valuation.** The request can now carry BLU's presumable valuation —
the line items, the sub-total, the green-building added value, and the three headline
figures PFMV / PEV / PRCV, every money value an **integer in minor units (cents)**. It is
shown on the request card, and it is carried into the Job Order so the appraiser opens a
populated valuation instead of a blank one. `valuation` is **optional**: Coriara has a
different valuation module and four other projects have none, and a request without one
reads *"Not supplied"* — never a zero.

Five pieces:

| Piece | File | State |
|---|---|---|
| The `B`-suffix allocator | `supabase/SIGMA_order_numbering_blu.sql` | **live 2026-08-24** |
| The table, RLS and the atomic intake RPC | `supabase/SIGMA_blu_appraisal_requests.sql` | **live 2026-08-24** |
| The valuation columns + the RPC that records them | `supabase/SIGMA_blu_valuation_20260824.sql` | **new — step 3b** |
| The receiving edge function | `supabase/functions/blu-appraisal-intake/index.ts` | redeploy |
| The Developments UI + Job-Order carry-over | `index.html` (v2.351) | push |

**The one rule everything here protects:** the invoice number *is* the order number. A
numeric part must be issued exactly once — never twice, and preferably never wasted.

**The second rule, added by v2.351:** a request must never end up holding an appraisal
number and half a valuation. The valuation is written by the same statement that claims
the idempotency key, and a malformed one is rejected outright before any of it.

---

## Order of operations

Do these in order. Steps 1–4 are database only and change nothing a user can see; the
feature is not reachable until step 8.

**Today (2026-08-24, second pass):** 1, 2 and 3 are already done. Go to **3b**.

### 1 · Snapshot (do not skip)

Supabase SQL editor → run **`supabase/SIGMA_milestone_20260824.sql`**.

It copies the order-number counter, an index of every existing `order_id`, and the current
source of the numbering functions into `*_backup_20260824` tables. It is safe to run twice
— a second run will *not* overwrite the first snapshot.

Write down what the last query prints:

```sql
select year, last_seq, updated_at from public.order_number_counters order by year;
```

That is the number this change is about to start moving.

### 2 · The allocator

Run **`supabase/SIGMA_order_numbering_blu.sql`**.

It adds `sigma_next_order_seq(int)` and `sigma_next_order_number(int, text)`, and replaces
the body of the existing `sigma_next_order_number(int)`. The one-argument function keeps
its name, signature, return shape and its grant to `anon`, so the app's existing call is
untouched.

It also fixes a trap that would have bitten the moment a `2026-045B` row existed: the old
high-water-mark seed used `split_part(order_id,'-',2)::int`, which throws
`invalid input syntax for type integer: "045B"`. The new one extracts with a capturing
`substring()`, so a non-matching id contributes NULL instead of an exception.

Then prove the extraction over every id shape at once — this writes nothing:

```sql
select v, substring(v from '^[0-9]{4}-([0-9]+)') as extracted
  from (values ('2026-044'),('2026-045B'),('2026-094-2'),
               ('2026-045B-2'),('2026-PREVIEW'),('2025-100')) t(v);
-- expect: 044 | 045 | 094 | 045 | (null) | 100
```

### 3 · The table, RLS and the intake RPC

Run **`supabase/SIGMA_blu_appraisal_requests.sql`**.

Must come after step 2 — `sigma_blu_record_request()` calls
`sigma_next_order_number(int, text)`.

*Applied to production 2026-08-24. Do not re-run it to pick up the valuation — that is
step 3b, in its own file.*

### 3b · The valuation columns — **an ADDITION TO A LIVE TABLE** (v2.351, `§BLU-VALUATION`)

Run **`supabase/SIGMA_blu_valuation_20260824.sql`**.

Must come after step 3, and **before** the function is redeployed in step 6. It alters
`public.blu_appraisal_requests`, which by now holds real requests, so read what it does
before you run it:

* twelve new columns, every one `add column if not exists`, nullable, **no default** —
  so no existing row is rewritten and no table rewrite is triggered;
* five CHECK constraints, each `drop … if exists` then re-added — every existing row has
  NULL in the new columns and NULL passes all five;
* one partial index on `valuation_received_at`;
* `blu_requests_touch_updated_at()` extended so a **recorded valuation is immutable**,
  exactly as `appraisal_number` already is;
* two small typed readers, `sigma_blu_minor()` and `sigma_blu_fraction()`;
* `sigma_blu_record_request(jsonb)` replaced, so the valuation is written **inside the
  same statement that claims the idempotency key**.

The whole file is safe to run twice.

> **`create or replace function` RESETS grants to the PUBLIC default.** The file
> re-applies `revoke … from public` / `grant execute … to service_role` immediately
> after. Do not run only part of it — an RPC that anon can call is an RPC that can spend
> appraisal numbers using the key that ships in `index.html`. Step 4's grant check below
> is what proves it landed.

Then confirm nothing already stored was disturbed:

```sql
select count(*) as rows_total,
       count(valuation_received_at) as rows_with_valuation
  from public.blu_appraisal_requests;
-- rows_total must equal what it was before this file. rows_with_valuation = 0.

select column_name, data_type, numeric_precision
  from information_schema.columns
 where table_schema='public' and table_name='blu_appraisal_requests'
   and column_name like 'valuation%'
 order by ordinal_position;
-- 12 rows. Every *_minor is bigint; both *_pct are numeric(9,6); lines is jsonb.
```

And that a float where a minor unit belongs is refused rather than truncated:

```sql
select public.sigma_blu_minor('{"x":4962888.3}'::jsonb, 'x', true);
-- ERROR: valuation.x must be an INTEGER number of minor units, got 4962888.3
select public.sigma_blu_fraction('{"p":18}'::jsonb, 'p');
-- ERROR: valuation.p must be a fraction between 0 and 1 (0.18 = 18%), got 18
```

### 4 · Verify the database half

```sql
-- policies: select / update / delete for anon, and NO insert
select policyname, roles, cmd from pg_policies
 where schemaname='public' and tablename='blu_appraisal_requests';

-- who can call the intake RPC — service_role must be the ONLY 'true'
select r.rolname, has_function_privilege(r.rolname, p.oid, 'execute') as can_execute
  from pg_proc p, (values ('anon'),('authenticated'),('service_role')) r(rolname)
 where p.proname = 'sigma_blu_record_request';

-- and anon must NOT be able to spend a suffixed number directly
select r.rolname, has_function_privilege(r.rolname, p.oid, 'execute')
  from pg_proc p, (values ('anon'),('service_role')) r(rolname)
 where p.oid::regprocedure::text = 'sigma_next_order_number(integer,text)';
```

If any of those reads wrong, stop and fix it before going further — an `anon` that can call
either function can burn numbers out of the live series using the key that ships in
`index.html`. **Run this check again after step 3b**, because `create or replace function`
resets the grant to the PUBLIC default and it is the file's own `revoke`/`grant` pair that
puts it back.

Also confirm the new constraints refuse a half valuation:

```sql
-- must FAIL with blu_requests_valuation_state_ck
begin;
  insert into public.blu_appraisal_requests (idempotency_key, valuation_pfmv_minor)
    values ('probe-state', 1);
rollback;
```

### 5 · The secret

Agree one shared secret with BLU. Generate a long random one; it is the only thing standing
between the public internet and a function that spends appraisal numbers.

```powershell
# from sigma-deploy\
supabase secrets set BLU_INTAKE_SECRET="<the shared secret>"
```

BLU sets the *same* value as `SIGMA_APPRAISAL_INTAKE_SECRET`, plus
`SIGMA_APPRAISAL_INTAKE_URL` = `https://cimgpycjczatjzltgscf.supabase.co/functions/v1/blu-appraisal-intake`,
and turns on `FEATURE_SIGMA_APPRAISAL`. Until both are set their desk says
"not configured" rather than showing a button that fails.

### 6 · Deploy the function

```powershell
# from sigma-deploy\
supabase functions deploy blu-appraisal-intake --no-verify-jwt
```

**Step 3b must already be applied.** The function itself is safe either way — a request
carrying a valuation still gets its number, and comes back
`{"ok":true,"appraisal_number":"…","valuation_recorded":false,"warning":"…apply
SIGMA_blu_valuation_20260824.sql, then re-send with the SAME idempotency_key…"}`. But the
figures are dropped until BLU re-sends, and re-sending is a manual step nobody wants to
discover a week later. Apply 3b first and this never happens.

`--no-verify-jwt` is required, not optional. BLU authenticates with the shared bearer
secret above, not with a Supabase JWT; with JWT verification on, the gateway rejects every
request before the function's own secret check ever runs. `supabase/config.toml` already
carries `verify_jwt = false` for this function so a later redeploy keeps the setting.

### 7 · Smoke test — spends no number, writes no row

```bash
curl -sS -X POST "https://cimgpycjczatjzltgscf.supabase.co/functions/v1/blu-appraisal-intake" \
  -H "Authorization: Bearer <BLU_INTAKE_SECRET>" \
  -H "Content-Type: application/json" \
  -d '{"probe":true}'
```

Expect `{"ok":true,"probe":true,"message":"token accepted"}`.

Then prove the secret actually gates it:

```bash
curl -sS -X POST ".../blu-appraisal-intake" \
  -H "Authorization: Bearer wrong" -H "Content-Type: application/json" -d '{"probe":true}'
# → {"ok":false,"error":"unauthorized"}   (HTTP 401)
```

The probe is checked **before** any database work and before any validation, so it proves
reachability, deployment and the secret, and nothing else. That is the point of it.

One more, to prove the **deployed build** carries the v2.351 valuation checks. It is
deliberately built so that **every** version of the function refuses it and writes nothing:
the payload is missing a required field *and* carries a float where a minor unit belongs.
Only the answer differs.

```bash
curl -sS -X POST ".../blu-appraisal-intake" \
  -H "Authorization: Bearer <BLU_INTAKE_SECRET>" -H "Content-Type: application/json" \
  -d '{"idempotency_key":"probe-val",
       "valuation":{"currency":"AWG","lines":[],"sub_total_minor":1,
                    "pfmv_minor":4962888.3,"pev_minor":1,"prcv_minor":1}}'
```

* **v2.351 or later** → `valuation.pfmv_minor must be an INTEGER number of minor units
  (cents), got 4962888.3 …` — the valuation is checked first, so this is what answers.
* **v2.350 (the pre-valuation build)** → `missing required field(s): reference.reservation,
  …` — it does not know about `valuation` at all. If you see this, step 6 did not take.

Both are HTTP 400, both write no row, and neither spends a number. Do not "simplify" this
probe by filling in the missing fields: a v2.350 function would then *accept* the request,
ignore the valuation, and burn a real appraisal number.

### 8 · End-to-end, without creating a real appraisal

The probe does not exercise the table, the allocator or the idempotency guarantee. This
does — inside a transaction that is **rolled back**, so the row disappears *and the counter
goes back with it* (the counter is a table row, not a sequence, so a rollback really does
rewind it). Paste the whole block into the SQL editor as one query:

```sql
begin;

  select public.sigma_blu_record_request('{
    "source":"blu-sales-control-desk",
    "received_at":"2026-08-24T12:00:00Z",
    "requested_by_name":"Runbook","requested_by_role":"test",
    "reservation_ref":"RUNBOOK-TEST","project_code":"WAYACA-VILLAS",
    "project_name":"Wayaca Modern Villas",
    "client_first_name":"Runbook","client_last_name":"Test",
    "client_email":"runbook@example.invalid","client_phone":"+297 000 0000",
    "lot_number":"0","model_code":null,"package_code":null,
    "deliver_to_client":true,"bank_contact_name":null,"bank_contact_email":null,
    "idempotency_key":"runbook-smoke-1","raw":{}
  }'::jsonb) as first_call;

  -- the SAME key again: must return the SAME number, and must not allocate a second
  select public.sigma_blu_record_request('{
    "idempotency_key":"runbook-smoke-1","client_email":"runbook@example.invalid",
    "lot_number":"0","reservation_ref":"RUNBOOK-TEST","project_code":"WAYACA-VILLAS"
  }'::jsonb) as second_call;

  select year, last_seq from public.order_number_counters;   -- moved by exactly 1

rollback;
```

What to check:

* `first_call` returns `{"id":"…","created":true,"appraisal_number":"2026-0NNB"}`.
* `second_call` returns the **same** `appraisal_number` and `"created": false`.
* the counter moved by exactly **one**, not two.

Then confirm the rollback really rewound everything:

```sql
select count(*) from public.blu_appraisal_requests where idempotency_key='runbook-smoke-1';  -- 0
select year, last_seq from public.order_number_counters order by year;  -- same as step 1
```

Also worth doing once, because it is the guard most likely to be quietly wrong:

```sql
begin;
  select public.sigma_blu_record_request('{"idempotency_key":"guard-1","lot_number":"0"}'::jsonb);
  -- now try to rewrite the allocated number, the way a compromised anon key would
  update public.blu_appraisal_requests set appraisal_number='9999-999B'
   where idempotency_key='guard-1';
  select appraisal_number from public.blu_appraisal_requests where idempotency_key='guard-1';
  -- must STILL be the allocated 2026-0NNB. The UPDATE reports success and changes nothing.
rollback;
```

### 8b · The valuation, end to end — also rolled back (v2.351)

```sql
begin;

  -- a request WITH a valuation
  select public.sigma_blu_record_request('{
    "idempotency_key":"runbook-val-1",
    "reservation_ref":"RUNBOOK-VAL","project_code":"WAYACA-VILLAS",
    "project_name":"Wayaca Modern Villas",
    "client_email":"runbook@example.invalid","lot_number":"0",
    "valuation":{
      "currency":"AWG",
      "lines":[{"key":"land","label":"Land","quantity_m2":196.4,
                "rate_minor":45000,"amount_minor":8838000}],
      "sub_total_minor":42058375,
      "added_value_pct":0.18,"added_value_minor":7570508,
      "pfmv_minor":49628883,
      "pev_pct":0.8,"pev_minor":39703106,
      "prcv_minor":40790883,
      "rate_card_source":"Wayaca Modern Villas_Numbers.xlsx VALUES sheet",
      "supersedes":null
    }
  }'::jsonb) as with_valuation;

  select appraisal_number, valuation_currency,
         valuation_pfmv_minor, valuation_pev_minor, valuation_prcv_minor,
         valuation_received_at is not null as recorded,
         jsonb_array_length(valuation_lines) as lines
    from public.blu_appraisal_requests where idempotency_key='runbook-val-1';

  -- immutability: this UPDATE reports success and must change NOTHING
  update public.blu_appraisal_requests set valuation_pfmv_minor = 1
   where idempotency_key='runbook-val-1';
  select valuation_pfmv_minor from public.blu_appraisal_requests
   where idempotency_key='runbook-val-1';        -- still 49628883

  -- the RESUME path: a request arrives with no valuation, one follows later under
  -- the SAME key. It must attach, and must NOT allocate a second number.
  select public.sigma_blu_record_request('{
    "idempotency_key":"runbook-val-2","lot_number":"0","client_email":"r@example.invalid"
  }'::jsonb) as no_valuation_yet;
  select public.sigma_blu_record_request('{
    "idempotency_key":"runbook-val-2","lot_number":"0","client_email":"r@example.invalid",
    "valuation":{"currency":"AWG","lines":[],"sub_total_minor":0,
                 "pfmv_minor":0,"pev_minor":0,"prcv_minor":0}
  }'::jsonb) as valuation_attached;
  -- same appraisal_number in both, "valuation_recorded": true in the second

  -- SUPPLIED AND ZERO is not "not supplied"
  select appraisal_number, valuation_pfmv_minor, valuation_received_at is not null as recorded
    from public.blu_appraisal_requests where idempotency_key='runbook-val-2';
  -- pfmv 0, recorded TRUE

rollback;
```

Then the rejections. Each must ERROR, and each must name its own field:

```sql
-- a float where a minor unit belongs
select public.sigma_blu_record_request('{"idempotency_key":"x","lot_number":"0",
  "valuation":{"currency":"AWG","lines":[],"sub_total_minor":1,
               "pfmv_minor":4962888.3,"pev_minor":1,"prcv_minor":1}}'::jsonb);
-- ERROR: valuation.pfmv_minor must be an INTEGER number of minor units, got 4962888.3

-- a percentage sent as 18 instead of 0.18
select public.sigma_blu_record_request('{"idempotency_key":"x","lot_number":"0",
  "valuation":{"currency":"AWG","lines":[],"sub_total_minor":1,"added_value_pct":18,
               "pfmv_minor":1,"pev_minor":1,"prcv_minor":1}}'::jsonb);
-- ERROR: valuation.added_value_pct must be a fraction between 0 and 1

-- lines that are not an array
select public.sigma_blu_record_request('{"idempotency_key":"x","lot_number":"0",
  "valuation":{"currency":"AWG","lines":{},"sub_total_minor":1,
               "pfmv_minor":1,"pev_minor":1,"prcv_minor":1}}'::jsonb);
-- ERROR: valuation.lines must be an array (it may be empty), got object
```

Each of those rolls its whole statement back: **no row, and no number spent.** Confirm:

```sql
select count(*) from public.blu_appraisal_requests where idempotency_key='x';   -- 0
select year, last_seq from public.order_number_counters order by year;          -- unmoved
```

The same checks run in the edge function first, so BLU's desk normally sees a 400 with
the field name and never reaches the database at all. The SQL copies exist because the
RPC is `SECURITY DEFINER` and reachable from the SQL editor too.

### 9 · Deploy the app

```powershell
# from sigma-deploy\
git push origin main      # Cloudflare Pages auto-builds and deploys sigma-cms.com
```

Then in the app: **Developments** appears in the sidebar under Email Requests. With no
requests yet it must read *"No development requests yet…"* — not an error. If it says
*"the blu_appraisal_requests table does not exist yet"*, step 3 did not take.

### 10 · The first real request

Ask BLU to send one from a reservation they are genuinely raising an appraisal for. **This
one consumes a real number** — that is unavoidable and correct, because it *is* a real
appraisal.

Check, in this order:

1. BLU's desk shows the returned appraisal number.
2. It appears in **Developments** within one Refresh, with that number, the project, the
   lot, the reservation reference, the buyer, and *Not yet supplied* against House model and
   Package (BLU has no models or packages for Wayaca — that is the true state, not a bug).
3. Ask BLU to press it a **second** time. Nothing new appears, and they get the **same**
   number back. That is the idempotency key doing its job.
4. If BLU sent a valuation, the card shows **PFMV / PEV / PRCV** as money, the sub-total
   and added value, the rate card it came from, and the line items behind a one-click
   toggle. If they sent none it reads *"Not supplied — BLU sent no valuation with this
   request"*, and shows **no zero anywhere**.
5. Click **Create Job Order**. The type picker opens, the form is pre-filled, and the yellow
   banner names the number it will use — and, when a valuation came, says the valuation is
   loaded and names the PRCV difference (see below). Submit, and confirm the order lands in
   Orders under exactly that number.
6. Open that order's **Valuation** screen. The chooser opens on **Presumable**; continue,
   and the Presumable calculator already holds BLU's line items (land under Parcel, the
   rest under Building), their execution rate, and the green-building added value as a
   percentage adjustment. **PFMV and PEV must match BLU's figures to the cent.**
7. Everything BLU sent — including the three figures verbatim — is also in the order's
   **Notes**.
8. The request flips to **Converted** with a link to the order.
9. Click **Create Job Order** again on the same request — it must refuse, naming the
   existing order.

> **The one figure that will not match, by design.** SIGMA's Presumable Re-Construction
> Value is `((Sub-Total − Parcel) ± adjustments) × 1.10` — a house convention that adds a
> 10% demolition allowance. BLU's PRCV is the same base **without** the 10%. So the report
> prints exactly `1.10 ×` BLU's PRCV. This is not reconciled automatically because only
> the appraiser can decide which convention the report is asserting. The prefill banner,
> the order's Notes and `§BLU-VALUATION` in `index.html` all name both numbers, and BLU's
> own figure is kept untouched in `valData.bluValuation`. **Settle this with the appraiser
> before the first BLU report is issued.**

---

## How the numbering is protected (what to trust, and why)

| Risk | What stops it |
|---|---|
| Two retries create two requests | `blu_requests_idem_uk`, a UNIQUE INDEX on `idempotency_key` |
| Two retries spend two numbers | The claim and the allocation are one transaction inside `sigma_blu_record_request()`. The loser blocks on the uncommitted row and never reaches the allocator |
| A crash between claiming and allocating | There is no "between" — a crash rolls the whole transaction back. A row that somehow exists without a number is resumed on the next call |
| A BLU number colliding with an ordinary one | One shared counter. `2026-045B` is issued, so `2026-045` never will be |
| An allocated number being changed later | `blu_requests_touch_updated_at` holds a non-null `appraisal_number` at its old value, for every writer including the anon key |
| Converting one request into two orders | Three checks, cheapest first: the row's status, the orders table asked directly, and `_ensureUniqueOrderId()` which **throws** for a reserved BLU number instead of quietly re-allocating |
| Anyone with the public anon key spending a number | `EXECUTE` on the intake RPC and on the two-argument allocator is revoked from PUBLIC and granted only to `service_role` |
| A request holding a number and half a valuation | The valuation is written by the same `insert … on conflict` that claims the key. There is no "between" to crash in |
| A malformed valuation being partly stored | The edge function validates every field and rejects the WHOLE request with a named 400; `sigma_blu_minor()` / `sigma_blu_fraction()` repeat the checks inside the transaction |
| A float, or a percentage sent as `18`, being silently accepted | Both are rejected, not truncated and not rescaled. `4962888.3` is an error, never `4962888` |
| A recorded valuation being changed later | `blu_requests_touch_updated_at` holds all twelve valuation columns at their old values, as one block, for every writer including the anon key |
| A valuation lost because it arrived before the migration | The RPC's resume path attaches it on a re-send under the same key, and the edge function's fast path steps aside for exactly that case. No second number is allocated |
| "Supplied and zero" being mistaken for "not supplied" | The discriminator is `valuation_received_at`, never a zero figure. A CHECK keeps the two states from mixing |

---

## Rollback

### Rolling back only the valuation (v2.351), leaving Developments live

`SIGMA_blu_valuation_20260824.sql` ends with its own rollback block, commented out. It
drops the five constraints, the index, the twelve columns and the two readers, and tells
you to re-run the RPC + trigger halves of `SIGMA_blu_appraisal_requests.sql` to put
`sigma_blu_record_request()` and `blu_requests_touch_updated_at()` back to their
pre-valuation bodies.

**Dropping those columns destroys every valuation received.** The same block has the
`create table public.blu_valuation_backup_20260824 as select …` to run first. Then revert
`index.html` to v2.350 and redeploy the edge function from the previous commit — or leave
the new function in place, which is also safe: with the columns gone it answers
`valuation_recorded:false` and a warning, and writes nothing it cannot write.

### Rolling back the whole Developments feature

Run **`supabase/SIGMA_blu_rollback_20260824.sql`**. It archives the request rows, drops the
RPC, the table and the trigger function, restores the pre-BLU body of
`sigma_next_order_number(int)` with its `anon` grant, drops the BLU-only functions, and
reloads the PostgREST schema. Safe to run twice.

Then, by hand:

```powershell
supabase functions delete blu-appraisal-intake     # optional — see below
supabase secrets unset BLU_INTAKE_SECRET
```

and revert `index.html` to v2.349 and push.

**The order-number counter is deliberately NOT rewound.** Any number already handed to BLU
has been quoted to a buyer and possibly to a bank; re-issuing it would put the same number
on two documents. A gap in the series is the cheaper of the two outcomes, by a wide margin.
The rollback script prints how many numbers were consumed so the gap is a known quantity
rather than a surprise during a year-end reconciliation.

Leaving the edge function deployed is also fine: with the RPC gone it answers
`503 {"ok":false,"error":"SIGMA is not ready…"}` and writes nothing. Deleting it gives BLU a
cleaner failure.

---

## Things worth knowing before you touch this again

* **`SIGMA_blu_appraisal_requests.sql` and `SIGMA_order_numbering_blu.sql` are HISTORY.**
  They were applied to production on 2026-08-24 and must not be edited. Everything since
  is a dated, additive file of its own — `SIGMA_blu_valuation_20260824.sql` is the first.
  A file that has run and then changes is a file nobody can reconcile a database against.
* **The full rollback script archives with `select *`,** so it picks up the valuation
  columns without any change — `blu_appraisal_requests_archive_20260824` will contain them.
* **The valuation lives in `orders.val_data`, not `orders.insp_data`.** `val_data` is the
  small structured column the valuation screens and the report already read. `insp_data`
  is the column that drowned the database on 2026-07-16 (§DOC-SERVER-STRIP / §RAW-GUARD)
  and nothing here goes near it. A full six-line valuation adds well under 2 KB.
* **Three things are written into `valData`, and they are different in kind.**
  `bluValuation` is the verbatim record in minor units — evidence, never recomputed;
  `presumData` is the app's own Presumable calculator, seeded from BLU's lines so the
  appraiser inherits the detail; `valMode:'presumable'` because a presumable valuation is
  all BLU supplied (left unset, a Type-3 order defaults to `both` and the report would
  print an empty Current section beside the full one).
* **A non-AWG valuation is stored but NOT loaded into the calculator.** SIGMA's valuation
  screens are AWG-primary throughout, so pouring USD into them would read as florins on
  the report. The figures are on the card and in the Notes, flagged, and the calculator is
  left for the appraiser. BLU quotes AWG today; this is the guard for the day they don't.
* **Where BLU's own arithmetic does not tie, the card says which figure and by how much
  — and stores what arrived anyway.** Nothing recalculates PFMV, PEV or PRCV behind their
  back: a bank may already be holding the sheet those numbers came off.
* **`config.toml` lists only this function.** Every other edge function keeps whatever it is
  deployed with today; nothing in this change alters them.
* **`model_code` / `package_code` are null on purpose.** BLU has no house models or packages
  for Wayaca. Both ends refuse to invent one — the wire sends null, the table stores null,
  the UI prints *Not yet supplied*. When models do arrive, both ends already have a place
  for them and no migration is needed.
* **Producing and sending the report is still done by hand.** This work ends at
  "request received → visible → converted to a Job Order". The Developments panel says so
  in the delivery box, so nobody assumes SIGMA has emailed anything.
* **Type 1's Notes field is an `<input>`, not a `<textarea>`,** and the HTML value
  sanitisation algorithm strips newlines from those. The BLU pre-fill flattens its note with
  a visible `·` separator for Type 1 so nothing is silently lost. *The Email Requests
  pre-fill (`_erPrefillNote`, v2.264) still has this problem and runs its note together on
  Type 1.* Fixing that is a separate, safe change.
* **PostgREST caches which functions exist.** Both SQL files end with
  `notify pgrst, 'reload schema';`. Without it a new RPC comes back as
  `PGRST202 function not found` until the API container happens to restart — the edge
  function detects that case specifically and says what to run.
