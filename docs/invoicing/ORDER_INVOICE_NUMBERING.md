# Order & Invoice Numbering

**Status:** implemented in **v2.270** (commit `66e37bb`). Migration:
`sigma-deploy/supabase/SIGMA_order_numbering.sql`.

---

## The rule

> **The invoice number is the appraisal order number.** `2026-001` → `2026-001`.
>
> **A re-issue after a void is suffixed.** `2026-001` → `2026-001-2` → `2026-001-3`.

The order is the source. The invoice never generates a number of its own, and the number
is never editable by a user.

`order_number` is *always* the plain order number. Only `invoice_number` carries the
re-issue suffix — see [§INVOICE-REISSUE](#re-issuing-after-a-void) below.

Because of that, a defect in order numbering is a defect in *billing*. The numbering had to
be made correct before any invoicing work started.

---

## What was wrong (before v2.270)

`index.html` computed the number in the browser:

```js
var maxId = ORDERS.reduce(function(mx,o){
  var n = parseInt((o.id||'').split('-')[1]) || 0; return n > mx ? n : mx;
}, 0);
var newId = '2026-' + String(maxId+1).padStart(3,'0');
```

Three defects:

**1. Numbers were reused.** `ORDERS` is whatever that browser happens to hold. Delete the
highest orders and the maximum drops, so the next order is issued a number that has already
been used. This was not theoretical — the live database has **35 orders whose highest number
is `2026-091`**: 56 numbers are gone and `orders_archive` is empty. Deleting `2026-091`
would have made the next order `2026-091` again.

**2. Concurrent creation overwrote an order.** Two people creating an order at the same
moment both computed the same number. The save is
`upsert(rows, { onConflict: 'order_id' })`, so the second write **updated the first
person's row** — a silent, total overwrite of someone else's order, with no error shown.
The `UNIQUE (order_id)` constraint did not help, because an upsert treats a conflict as an
instruction to update.

**3. The year was hard-coded** as `'2026-'`, so January would have issued `2026-092`
rather than `2027-001`.

---

## The design

A per-year counter table plus one allocator function:

```sql
create table public.order_number_counters (
  year int primary key,
  last_seq int not null default 0,
  updated_at timestamptz not null default now()
);
```

`sigma_next_order_number(p_year int default null) returns text`, `SECURITY DEFINER`.

Three properties, each deliberate:

**Monotonic (high-water mark).** The counter only ever moves forward. A deleted or voided
number is therefore never handed out again — which is exactly what the invoicing rules
require.

**Collision-proof against existing rows.** Each call also reads the current maximum for that
year out of `orders` and takes `GREATEST(counter, that maximum) + 1`. So even if the counter
were reset, lost, or seeded late, the allocator can never return a number that already
exists.

**Atomic.** Allocation is a single `INSERT ... ON CONFLICT (year) DO UPDATE ... RETURNING`,
which takes a row lock. Concurrent callers serialise on that lock and each receives a
distinct number.

**Why `SECURITY DEFINER` with no anon policy on the table:** the app authenticates as `anon`,
so `anon` needs `EXECUTE` on the function — but it must *not* be able to `UPDATE` the counter
directly, or a client could rewind the sequence and force reuse. Execute rights on a
definer function are not write rights on its table. Verified: a direct anon `PATCH` of
`order_number_counters` does not lower `last_seq`.

The counter was seeded from the orders that already existed, so the series continues rather
than restarting (`2026 → 91`; next number `2026-092`).

---

## Client behaviour

| Function | Role |
|---|---|
| `_allocOrderNumber()` | Calls the RPC. This is the normal path. |
| `_localOrderNumberFallback(yr)` | **Offline only.** `max + 1` over the local cache, now *year-aware* (the old code counted every year together). |
| `_ensureUniqueOrderId(o)` | Re-checks the number against the database immediately before saving; re-allocates on a clash. Closes the overwrite path for the offline fallback too. |

`submitOrder()` and `_submitOrderImpl()` are now `async`.

**Offline caveat, stated plainly:** if the database is unreachable the number is provisional.
`_ensureUniqueOrderId()` corrects it before the row is written, so a clash cannot overwrite
another order — but the number the user saw at creation time may change.

---

## Verification (executed 2026-07-24, against the live database)

| Assertion | Result |
|---|---|
| Continues the existing series | `2026-092` ✅ |
| Increments | `2026-093` ✅ |
| Does **not** reuse a number after deleting the three highest orders | `2026-094` ✅ |
| New year starts its own series | `2027-001` ✅ |
| Default argument uses the server clock's year | `2026-…` ✅ |
| **12 parallel calls through the anon key → 12 distinct numbers** | `092…103`, all unique ✅ |
| `anon` may execute the function | ✅ |
| `anon` cannot rewind the counter | ✅ |
| Client: fallback is year-aware, ignores other years | ✅ |
| Client: allocator returns a well-formed number offline | ✅ |

Logic tests ran inside a transaction that was **rolled back**, and the concurrency test's
numbers were returned to the real high-water mark afterwards — **no order was created and no
number was burned.** The next real order is `2026-092`.

---

## Rules this establishes for invoicing

1. `invoices.invoice_number` is derived from `orders.order_id` at creation and is immutable.
2. `invoices.order_number` is stored alongside it — always the plain order number.
3. `UNIQUE (org_id, invoice_number)` on invoices, and a partial unique index enforcing
   **one non-void primary invoice per order**.
4. Voiding keeps the number. Nothing ever reissues it — a replacement gets a *new*
   number in the same series (see below).
5. An order may exist with no invoice; an invoice may never exist without an order.

---

## Re-issuing after a void

**Status:** implemented in **§INVOICE-REISSUE**. Migration:
`sigma-deploy/supabase/SIGMA_invoicing_reissue.sql`.

### What was wrong

Three rules disagreed, and the disagreement only surfaced the first time an invoice was
actually voided (order `2026-094`, 2026-07-31):

| Rule | Said |
|---|---|
| `invoices_one_primary_per_order` (partial unique, `where is_primary and status <> 'void'`) | a voided invoice frees the slot, so a corrected invoice **can** be raised |
| `sigma_create_invoice_from_order`'s guard | agrees — refuses only on a **non-void** primary |
| `invoices_org_number_uk` (`unique (org_id, invoice_number)`) | the voided invoice still **holds** `2026-094`, so the replacement collided |
| `invoices_number_matches_order` (`check invoice_number = order_number`) | forbade any number that is not literally the order number |

So the create was refused with a duplicate-key error, while the app's own wording told the
owner to "void it and raise a new one".

### The rule now

A re-issued invoice is **suffixed** against its order number: `2026-094`, `2026-094-2`,
`2026-094-3`. The invoice stays tied to its order, the document plainly reads as a
replacement, and **no invoice number is ever reused** — the hard rule established above.

The suffix is derived **server-side** inside the RPC, from the highest suffix already in
use for that order (voids included) — `max(...) + 1`, never `count(...)`, so a gap or a
manually inserted row cannot cause a collision. It is never passed in by the client.

### Concurrency

The guard, the suffix read and the insert are wrapped in a transaction-scoped advisory
lock keyed on the order:

```sql
perform pg_advisory_xact_lock(hashtext('sigma_invoice_from_order'), hashtext(p_order_id));
```

Two simultaneous clicks therefore serialise: the second waits, sees the first invoice
committed, and is refused by the primary-invoice guard in words a human can read rather
than with a raw duplicate-key error. `invoices_org_number_uk` remains the last-resort
backstop, and a bounded retry loop re-derives the number if some *other* writer takes it.

The lock is transaction-scoped, not session-scoped, so it is safe under Supabase's
transaction-mode connection pooling.
