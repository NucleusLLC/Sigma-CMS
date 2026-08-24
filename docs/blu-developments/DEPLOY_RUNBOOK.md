# Developments (BLU Capital Group) — deploy runbook

**Version:** v2.350 · **Section:** `§BLU-DEVELOPMENTS` · **Written:** 2026-08-24
**Project:** Sigma CMS, Supabase ref `cimgpycjczatjzltgscf`
**Sending side:** `blucapitalgroup/web/src/lib/dashboard/appraisal.ts` (already built and tested)

---

## What this deploys

When BLU Capital Group's Sales & Control Desk verifies a buyer's deposit, it POSTs an
appraisal request to a new edge function. SIGMA records it, **allocates the appraisal
number on the spot** out of the same yearly series every other order draws from — with a
trailing `B`, e.g. `2026-045B` — and hands that number straight back, so both systems name
the job the same thing from the first second. The request appears in a new **Developments**
area in the sidebar, and one click raises a Job Order under the number already reserved.

Four pieces:

| Piece | File |
|---|---|
| The `B`-suffix allocator | `supabase/SIGMA_order_numbering_blu.sql` |
| The table, RLS and the atomic intake RPC | `supabase/SIGMA_blu_appraisal_requests.sql` |
| The receiving edge function | `supabase/functions/blu-appraisal-intake/index.ts` |
| The Developments UI | `index.html` (v2.350) |

**The one rule everything here protects:** the invoice number *is* the order number. A
numeric part must be issued exactly once — never twice, and preferably never wasted.

---

## Order of operations

Do these in order. Steps 1–4 are database only and change nothing a user can see; the
feature is not reachable until step 8.

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
`index.html`.

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
4. Click **Create Job Order**. The type picker opens, the form is pre-filled, and the yellow
   banner names the number it will use. Submit, and confirm the order lands in Orders under
   exactly that number.
5. The request flips to **Converted** with a link to the order.
6. Click **Create Job Order** again on the same request — it must refuse, naming the
   existing order.

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

---

## Rollback

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
