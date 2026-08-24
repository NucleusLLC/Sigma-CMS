-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — BLU Capital Group appraisal requests            (§BLU-DEVELOPMENTS)
--
-- NOT APPLIED. Review, then run in the Supabase SQL editor.
-- Run SIGMA_order_numbering_blu.sql FIRST — the intake function calls
-- sigma_next_order_number(int, text) from that file.
--
-- WHAT THIS IS
--   BLU Capital Group's Sales & Control Desk sends SIGMA an appraisal request
--   once a buyer's deposit is verified, so the buyer can take an appraisal
--   report to their bank for a mortgage. Requests arrive at the
--   `blu-appraisal-intake` edge function (service role) and land here. The app
--   reads and updates them with the public anon key, in the new Developments
--   area — the same shape as Email Requests / public.inquiries.
--
-- SECURITY POSTURE (matches public.inquiries exactly — see SIGMA_inquiries_table.sql)
--   anon may SELECT / UPDATE / DELETE, but NOT INSERT. Inserts arrive only
--   through the edge function (service role, bypasses RLS). Denying anon INSERT
--   stops anyone holding the public anon key from injecting a fake request —
--   and, more importantly here, from burning numbers out of the shared yearly
--   order series.
--
-- NEVER store documents or base64 in this table. It has columns, and anything
-- larger gets its own table with its own columns. (2026-07-16 outage.)
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.blu_appraisal_requests (
  id                  uuid primary key default gen_random_uuid(),
  created_at          timestamptz not null default now(),
  received_at         timestamptz,                         -- body.requested_at, as sent by BLU
  source              text not null default 'blu-sales-control-desk',
  status              text not null default 'new',         -- new|seen|converted|archived

  -- who raised it on BLU's side
  requested_by_name   text,
  requested_by_role   text,

  -- reference
  reservation_ref     text,                                -- reference.reservation
  project_code        text,                                -- reference.project_code   e.g. WAYACA-VILLAS
  project_name        text,                                -- reference.project_name   e.g. Wayaca Modern Villas

  -- buyer
  client_first_name   text,
  client_last_name    text,
  client_email        text,
  client_phone        text,

  -- property. model_code and package_code are LEGITIMATELY NULL: BLU has not yet
  -- supplied house models or packages for Wayaca. NULL means "not yet supplied";
  -- it is never to be filled with a placeholder.
  lot_number          text,
  model_code          text,
  package_code        text,

  -- where the finished report goes
  deliver_to_client   boolean not null default true,
  bank_contact_name   text,
  bank_contact_email  text,

  -- allocation + linkage
  appraisal_number    text,                                -- '2026-045B' — the allocated order number
  order_id            text,                                -- set when converted to a Job Order
  idempotency_key     text not null,
  raw                 jsonb,                               -- full original payload, for audit
  updated_at          timestamptz not null default now()
);

-- ── Idempotency ─────────────────────────────────────────────────────────────
-- THE contract with BLU: a repeat POST carrying a key already seen returns the
-- ORIGINAL appraisal_number and id. It must not allocate a second number and
-- must not create a second record. Pressing the button twice, or a client retry
-- after a network timeout, is harmless.
--
-- The UNIQUE INDEX is what actually enforces that — not any read in the edge
-- function. Two simultaneous retries both read "no row"; the index makes exactly
-- one of them win, and the loser waits on it and returns the winner's answer.
-- Application-level checks alone cannot do this.
--
-- It is used as a CLAIM, inside public.sigma_blu_record_request() below, which is
-- also where the number is allocated — same transaction, so the loser of the race
-- never reaches the allocator and no number is ever spent twice or lost.
create unique index if not exists blu_requests_idem_uk
  on public.blu_appraisal_requests (idempotency_key);

-- Allocated numbers are unique too: one appraisal number, one request. Partial,
-- because the number is written a moment AFTER the row (see the edge function:
-- the row is claimed first so the unique key above decides the winner BEFORE a
-- number is spent, which is what keeps the shared series gap-free).
create unique index if not exists blu_requests_number_uk
  on public.blu_appraisal_requests (appraisal_number)
  where appraisal_number is not null;

create index if not exists blu_requests_status_created_idx
  on public.blu_appraisal_requests (status, created_at desc);
create index if not exists blu_requests_project_idx
  on public.blu_appraisal_requests (project_code);
create index if not exists blu_requests_reservation_idx
  on public.blu_appraisal_requests (reservation_ref);
create index if not exists blu_requests_created_idx
  on public.blu_appraisal_requests (created_at desc);

-- ── The row guard ───────────────────────────────────────────────────────────
-- Keeps updated_at fresh, and makes two columns immutable once written.
--
-- A TRIGGER rather than an RLS policy, on purpose: RLS is bypassed by the service
-- role and, on this project, `using (true)` for anon protects nothing anyway. A
-- trigger applies to every writer — the browser holding the public anon key, the
-- edge function, and a hand-typed UPDATE in the SQL editor.
--
--   appraisal_number  once allocated it has been HANDED TO BLU, and it will be
--                     the invoice number. Changing it afterwards leaves SIGMA and
--                     BLU naming one job two different things. Filling it while
--                     it is still NULL is what the intake RPC does, so that is
--                     the one transition allowed.
--   idempotency_key   the identity of the request. Rewriting it would let a
--                     second request for the same reservation slip past
--                     blu_requests_idem_uk and spend a second number.
--
-- Both are silently held at their old value rather than raising: a PATCH that
-- carries the whole row (PostgREST will) must still be able to set status or
-- order_id. What must never happen is the value actually changing.
create or replace function public.blu_requests_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if old.appraisal_number is not null then
    new.appraisal_number := old.appraisal_number;
  end if;
  new.idempotency_key := old.idempotency_key;
  return new;
end $$;

drop trigger if exists blu_requests_set_updated_at on public.blu_appraisal_requests;
create trigger blu_requests_set_updated_at
  before update on public.blu_appraisal_requests
  for each row execute function public.blu_requests_touch_updated_at();

-- ═════════════════════════════════════════════════════════════════════════════
-- THE INTAKE RPC — claim the key and allocate the number in ONE transaction
--
-- WHY THIS EXISTS, AND WHAT IT REPLACES
--   The first cut of the edge function did this over four separate HTTP calls:
--     1. read by idempotency_key
--     2. INSERT the row with no number      (the unique index picks the winner)
--     3. allocate a number
--     4. PATCH the number onto the row, only while it is still null
--
--   That ordering is right about the thing it was designed for — it never creates
--   two rows, and it never leaves a duplicate request. But it still SPENDS TWO
--   NUMBERS on a genuine race, and this is not theoretical:
--
--     A and B are the same request, retried. A inserts and wins. B gets 23505,
--     re-reads, finds the row with a NULL number, and falls through. BOTH now
--     call the allocator: A gets 045, B gets 046. A's PATCH lands. B's PATCH
--     matches nothing, so B correctly returns 045 — and 046 is gone for ever.
--
--   The counter is a high-water mark, so 046 is never re-issued. It is a
--   permanent hole in a series whose numeric part is also an invoice number, and
--   holes in an invoice series are an audit question for a real firm.
--
--   Steps 2 to 4 therefore happen HERE instead, in one statement, which
--   PostgREST runs in one transaction:
--
--     • `on conflict (idempotency_key) do nothing` claims the key. A concurrent
--       caller BLOCKS on the uncommitted row rather than proceeding, so it never
--       reaches the allocator at all.
--     • the loser then reads the winner's row `for update`, which cannot return
--       until the winner has committed the number it allocated.
--     • a row that somehow exists with a NULL number (a legacy row from the old
--       four-step path, or a hand insert) is RESUMED, not stranded.
--
--   Result: one request, one number, no gap, whatever the concurrency — and
--   nothing to resume after a crash, because a crash rolls the whole thing back.
--
-- The caller is the `blu-appraisal-intake` edge function, running as the service
-- role. It normalises and validates the payload first; everything below assumes
-- the values are already the right shape.
--
-- Requires public.sigma_next_order_number(int, text) — apply
-- SIGMA_order_numbering_blu.sql FIRST.
-- ═════════════════════════════════════════════════════════════════════════════
create or replace function public.sigma_blu_record_request(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_idem    text    := nullif(btrim(p->>'idempotency_key'), '');
  v_id      uuid;
  v_num     text;
  v_created boolean := false;
begin
  if v_idem is null then
    raise exception 'idempotency_key is required';
  end if;

  -- ── CLAIM ─────────────────────────────────────────────────────────────────
  insert into public.blu_appraisal_requests (
      source, received_at, status,
      requested_by_name, requested_by_role,
      reservation_ref, project_code, project_name,
      client_first_name, client_last_name, client_email, client_phone,
      lot_number, model_code, package_code,
      deliver_to_client, bank_contact_name, bank_contact_email,
      idempotency_key, raw)
  values (
      coalesce(nullif(btrim(p->>'source'), ''), 'blu-sales-control-desk'),
      nullif(btrim(p->>'received_at'), '')::timestamptz,
      'new',
      nullif(btrim(p->>'requested_by_name'),  ''),
      nullif(btrim(p->>'requested_by_role'),  ''),
      nullif(btrim(p->>'reservation_ref'),    ''),
      nullif(btrim(p->>'project_code'),       ''),
      nullif(btrim(p->>'project_name'),       ''),
      nullif(btrim(p->>'client_first_name'),  ''),
      nullif(btrim(p->>'client_last_name'),   ''),
      nullif(btrim(p->>'client_email'),       ''),
      nullif(btrim(p->>'client_phone'),       ''),
      nullif(btrim(p->>'lot_number'),         ''),
      -- model_code / package_code stay NULL when BLU has not supplied them.
      -- "Not yet established" is a fact about the request, not a gap to fill.
      nullif(btrim(p->>'model_code'),         ''),
      nullif(btrim(p->>'package_code'),       ''),
      coalesce((p->>'deliver_to_client')::boolean, true),
      nullif(btrim(p->>'bank_contact_name'),  ''),
      nullif(btrim(p->>'bank_contact_email'), ''),
      v_idem,
      p->'raw')
  on conflict (idempotency_key) do nothing
  returning id, appraisal_number into v_id, v_num;

  if v_id is null then
    -- Another caller owns this key. `on conflict do nothing` already waited for
    -- that transaction to finish, so the row is visible; `for update` waits again
    -- if it is mid-allocation, which is what makes a repeat return the SAME
    -- number instead of racing to allocate a second one.
    select b.id, b.appraisal_number
      into v_id, v_num
      from public.blu_appraisal_requests b
     where b.idempotency_key = v_idem
     for update;

    if v_id is null then
      raise exception 'sigma_blu_record_request: key % neither inserted nor found', v_idem;
    end if;
  else
    v_created := true;
  end if;

  -- ── ALLOCATE (only if this request has no number yet) ─────────────────────
  if v_num is null then
    -- Aruba's calendar, not the database server's. The app numbers an ordinary
    -- order from the browser's local year, and between 20:00 Aruba and midnight
    -- UTC on 31 December those two disagree.
    v_num := public.sigma_next_order_number(
               extract(year from (now() at time zone 'America/Aruba'))::int, 'B');

    update public.blu_appraisal_requests
       set appraisal_number = v_num
     where id = v_id
       and appraisal_number is null;

    -- Read back rather than trust the write: blu_requests_touch_updated_at holds
    -- an already-allocated number at its old value, so the row is the authority.
    select b.appraisal_number into v_num
      from public.blu_appraisal_requests b where b.id = v_id;

    if v_num is null then
      raise exception 'sigma_blu_record_request: number not attached to %', v_id;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'appraisal_number', v_num, 'created', v_created);
end $$;

-- Postgres grants EXECUTE to PUBLIC by default. On a SECURITY DEFINER function
-- that both INSERTs into this table and spends an appraisal number, leaving that
-- default in place would hand anyone holding the public anon key exactly the two
-- powers the RLS policies below are written to withhold.
revoke all on function public.sigma_blu_record_request(jsonb) from public;
grant execute on function public.sigma_blu_record_request(jsonb) to service_role;

-- ── Re-seed the counter from RESERVED numbers ───────────────────────────────
-- SIGMA_order_numbering_blu.sql seeds the year counter from public.orders, and at
-- the moment it runs this table does not exist. But a BLU number is allocated
-- when the request ARRIVES and only becomes an order later, so between those two
-- moments the highest number in use lives here and nowhere else. Without this,
-- a counter reset or a restore would hand a reserved number out a second time.
-- greatest() means it can only ever push forward.
insert into public.order_number_counters (year, last_seq)
select (regexp_match(appraisal_number, '^([0-9]{4})-([0-9]+)'))[1]::int      as year,
       max((regexp_match(appraisal_number, '^([0-9]{4})-([0-9]+)'))[2]::int) as last_seq
  from public.blu_appraisal_requests
 where appraisal_number ~ '^[0-9]{4}-[0-9]+'
 group by 1
on conflict (year) do update
  set last_seq = greatest(public.order_number_counters.last_seq, excluded.last_seq);

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- Same posture as public.inquiries. See the honest note in
-- SIGMA_ENABLE_RLS_ANON_v2.sql: because the anon key ships inside index.html,
-- `using (true)` clears the linter and keeps the app working, but it is not a
-- real access boundary. Withholding INSERT is the one piece of genuine
-- protection available at this layer, and it is withheld here for the same
-- reason it is withheld on inquiries.
alter table public.blu_appraisal_requests enable row level security;

drop policy if exists blu_requests_anon_select on public.blu_appraisal_requests;
drop policy if exists blu_requests_anon_update on public.blu_appraisal_requests;
drop policy if exists blu_requests_anon_delete on public.blu_appraisal_requests;

create policy blu_requests_anon_select on public.blu_appraisal_requests
  for select to anon, authenticated using (true);
create policy blu_requests_anon_update on public.blu_appraisal_requests
  for update to anon, authenticated using (true) with check (true);
create policy blu_requests_anon_delete on public.blu_appraisal_requests
  for delete to anon, authenticated using (true);
-- NB: intentionally no anon INSERT policy — inserts come only via the
-- blu-appraisal-intake edge function (service role).

-- PostgREST caches the list of callable functions. Without this,
-- rpc/sigma_blu_record_request comes back as PGRST202 "function not found" until
-- the API container happens to restart.
notify pgrst, 'reload schema';

-- ── VERIFY (read-only unless stated) ────────────────────────────────────────
--   select policyname, roles, cmd from pg_policies
--    where schemaname='public' and tablename='blu_appraisal_requests';
--
--   -- who can call the intake RPC — expect service_role and NOTHING else:
--   select p.proname, r.rolname, has_function_privilege(r.rolname, p.oid, 'execute')
--     from pg_proc p, (values ('anon'),('authenticated'),('service_role')) r(rolname)
--    where p.proname = 'sigma_blu_record_request';
--
--   -- idempotency really is enforced (the second insert must FAIL):
--   -- insert into public.blu_appraisal_requests (idempotency_key) values ('probe-1');
--   -- insert into public.blu_appraisal_requests (idempotency_key) values ('probe-1');
--   -- delete from public.blu_appraisal_requests where idempotency_key='probe-1';
--
--   -- the number guard holds (this UPDATE reports success and changes NOTHING):
--   -- update public.blu_appraisal_requests set appraisal_number='9999-999B'
--   --  where appraisal_number is not null;   -- then re-select and confirm
--
--   -- every reserved number is covered by the counter:
--   select c.year, c.last_seq,
--          (select max(substring(b.appraisal_number from ('^' || c.year || '-([0-9]+)'))::int)
--             from public.blu_appraisal_requests b
--            where b.appraisal_number like (c.year || '-%')) as max_reserved
--     from public.order_number_counters c order by c.year;
--   -- last_seq must be >= max_reserved for every year.

-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK — use supabase/SIGMA_blu_rollback_20260824.sql, which does this and
-- restores the pre-BLU numbering in the right order. By hand it is:
--   drop function if exists public.sigma_blu_record_request(jsonb);
--   drop table if exists public.blu_appraisal_requests;
--   drop function if exists public.blu_requests_touch_updated_at();
--   notify pgrst, 'reload schema';
-- (Dropping the table does NOT rewind the order counter, which is correct: a
--  number that has been handed to BLU must never be handed out again.)
-- ─────────────────────────────────────────────────────────────────────────────
