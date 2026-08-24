-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — order numbering, extended for BLU Capital Group  (§BLU-NUMBERING)
--
-- NOT APPLIED. Review, then run in the Supabase SQL editor.
-- Additive and re-runnable: every statement is `create or replace` /
-- `create ... if not exists`. It replaces the body of
-- public.sigma_next_order_number(int) from SIGMA_order_numbering.sql; it does
-- not edit that file and does not drop anything.
--
-- ═══ THE DECISION ═══════════════════════════════════════════════════════════
-- A BLU appraisal takes the NEXT number in SIGMA's existing yearly series and
-- carries a trailing 'B'. If the last order was 2026-044, the next BLU one is
-- 2026-045B, and no non-BLU order will ever be issued 2026-045.
--
-- ONE counter, one numeric series. That matters because the invoice number IS
-- the order number (see SIGMA_invoicing_reissue.sql): a numeric part handed out
-- twice would be two invoices with the same number.
--
-- ═══ THE TRAP THIS FILE EXISTS TO FIX ═══════════════════════════════════════
-- The shipped function seeds its high-water mark like this:
--
--     select coalesce(max(split_part(order_id, '-', 2)::int), 0)
--       from public.orders
--      where order_id ~ ('^' || v_year || '-[0-9]+$');
--
-- Both halves break the moment a '2026-045B' row exists:
--
--   • The regex is anchored with `[0-9]+$`, so '2026-045B' does NOT match. The
--     seed would silently ignore every BLU order — and after a counter reset or
--     a restore, hand 045 out a SECOND time, to a non-BLU order.
--
--   • Loosening that regex naively (e.g. `-[0-9]+.*$`) is worse, not better:
--     split_part('2026-045B','-',2) is the TEXT '045B', and '045B'::int throws
--       invalid input syntax for type integer: "045B"
--     — i.e. the allocator errors out and NO order of any kind can be created.
--
-- The fix below does two things instead of one:
--   1. matches on a prefix (`like '2026-%'`) rather than a whole-string shape,
--      so no future order-id shape can fall out of the scan, and
--   2. extracts the numeric part with a CAPTURING substring() —
--        substring(order_id from '^2026-([0-9]+)')
--      which returns only the digits that directly follow the year, whatever
--      trails them. Non-matching rows yield NULL, which max() ignores; nothing
--      is ever cast unless it is already known to be all digits.
--
-- ═══ ORDER-ID SHAPES THIS TOLERATES ═════════════════════════════════════════
--   2026-045      the ordinary order number (lpad to 3)
--   2026-045B     a BLU order (this file)
--   2026-094-2    the re-issue form. NOTE (verified in the repo): this shape
--                 lives on invoices.invoice_number, NOT on orders.order_id —
--                 SIGMA_invoicing_reissue.sql deliberately leaves order_number
--                 alone and only moves invoice_number. It is handled here
--                 anyway so that, if such an id ever does land in orders, the
--                 seed reads 94 and neither throws nor under-counts.
--   2026-045B-2   a re-issue of a BLU order, should that ever be written.
--   2026-PREVIEW  the in-memory-only fake order the report previewer builds
--                 (index.html:43182). It is not persisted today; if it ever
--                 were, it now contributes NULL instead of throwing.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. The shared allocator ─────────────────────────────────────────────────
-- Returns the next raw SEQUENCE NUMBER for a year. Every order number in SIGMA,
-- suffixed or not, comes through here, so the numeric part is issued exactly
-- once. The counter remains a HIGH-WATER MARK: it only moves forward, so a
-- deleted or voided number is never handed out again.
create or replace function public.sigma_next_order_seq(p_year int default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year int := coalesce(p_year, extract(year from now())::int);
  v_seed int;
  v_next int;
begin
  if v_year < 2000 or v_year > 2999 then
    raise exception 'sigma_next_order_seq: implausible year %', v_year;
  end if;

  -- Highest numeric part already present for this year, across EVERY order-id
  -- shape. See the header: prefix match + capturing substring, never a bare
  -- split_part()::int.
  select coalesce(max(nullif(substring(order_id from ('^' || v_year || '-([0-9]+)')), '')::int), 0)
    into v_seed
    from public.orders
   where order_id like (v_year || '-%');

  -- Atomic: ON CONFLICT takes a row lock, so concurrent callers serialise here
  -- and each receives a distinct number.
  insert into public.order_number_counters (year, last_seq)
       values (v_year, v_seed + 1)
  on conflict (year) do update
          set last_seq   = greatest(public.order_number_counters.last_seq, v_seed) + 1,
              updated_at = now()
    returning last_seq into v_next;

  return v_next;
end $$;

-- ── 2. The plain number — unchanged contract ────────────────────────────────
-- Same name, same signature, same return shape ('2026-045') as before, so the
-- app's existing _sb.rpc('sigma_next_order_number', { p_year: yr }) call is
-- untouched. CREATE OR REPLACE keeps the anon/authenticated grants.
create or replace function public.sigma_next_order_number(p_year int default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year int := coalesce(p_year, extract(year from now())::int);
begin
  return v_year || '-' || lpad(public.sigma_next_order_seq(v_year)::text, 3, '0');
end $$;

-- ── 3. The suffixed number ──────────────────────────────────────────────────
-- Two arguments, and p_suffix deliberately has NO default: a one-argument call
-- must keep resolving unambiguously to the function above.
--
--   select public.sigma_next_order_number(null, 'B');   -- → '2026-045B'
--
-- The suffix is letters only and capped at three characters, so it can never
-- introduce a '-' and turn the number into something the seed above would read
-- as a different series.
create or replace function public.sigma_next_order_number(p_year int, p_suffix text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year int  := coalesce(p_year, extract(year from now())::int);
  v_sfx  text := coalesce(p_suffix, '');
begin
  if v_sfx !~ '^[A-Za-z]{0,3}$' then
    raise exception 'sigma_next_order_number: invalid suffix %', p_suffix;
  end if;
  return v_year || '-' || lpad(public.sigma_next_order_seq(v_year)::text, 3, '0') || upper(v_sfx);
end $$;

-- ── 4. Grants ───────────────────────────────────────────────────────────────
-- Postgres grants EXECUTE on a new function to PUBLIC by default, so every one of
-- these is REVOKED first and then granted deliberately. On a SECURITY DEFINER
-- function that increments a counter, "granted by default" means "anyone holding
-- the anon key can burn appraisal numbers out of the live series", which is the
-- one thing this whole file exists to prevent.
--
--   sigma_next_order_number(int)        anon MUST keep it — it is what the app
--                                       calls to number an ordinary order.
--   sigma_next_order_number(int,text)   only the BLU intake path issues suffixed
--                                       numbers, and it runs as service_role.
--   sigma_next_order_seq(int)           the raw counter. Nothing outside these
--                                       two wrappers has any business calling it;
--                                       they reach it as their SECURITY DEFINER
--                                       owner, not as the caller, so revoking it
--                                       from anon breaks nothing.
revoke all on function public.sigma_next_order_seq(int)             from public;
revoke all on function public.sigma_next_order_number(int)          from public;
revoke all on function public.sigma_next_order_number(int, text)    from public;

grant execute on function public.sigma_next_order_seq(int)             to service_role;
grant execute on function public.sigma_next_order_number(int)          to anon, authenticated, service_role;
grant execute on function public.sigma_next_order_number(int, text)    to service_role;

-- ── 5. Re-seed the counter, suffix-aware ────────────────────────────────────
-- The original seeding statement in SIGMA_order_numbering.sql had the SAME
-- blind spot (`where order_id ~ '^[0-9]{4}-[0-9]+$'`), so it too would skip a
-- BLU row. Re-run here with the safe extraction. greatest() means this can only
-- ever push the counter FORWARD — it can never rewind a live series.
insert into public.order_number_counters (year, last_seq)
select (regexp_match(order_id, '^([0-9]{4})-([0-9]+)'))[1]::int      as year,
       max((regexp_match(order_id, '^([0-9]{4})-([0-9]+)'))[2]::int) as last_seq
  from public.orders
 where order_id ~ '^[0-9]{4}-[0-9]+'
 group by 1
on conflict (year) do update
  set last_seq = greatest(public.order_number_counters.last_seq, excluded.last_seq);

-- NOTE: this seeds from public.orders ONLY, because at the moment this file runs
-- public.blu_appraisal_requests does not exist yet. A BLU number can be RESERVED
-- (allocated, handed to BLU) before it is converted into an order, so it lives on
-- the request row and nowhere else until then. SIGMA_blu_appraisal_requests.sql
-- therefore runs the matching re-seed over that table, and must be applied second.

-- PostgREST caches the list of callable functions. Without this, the new
-- two-argument overload comes back as PGRST202 "function not found" until the
-- API container happens to restart.
notify pgrst, 'reload schema';

-- ── 6. VERIFY (read-only; run after the block above) ────────────────────────
-- Prove the extraction on every shape at once — writes nothing, touches no table:
--
--   select v, substring(v from '^[0-9]{4}-([0-9]+)') as extracted
--     from (values ('2026-044'), ('2026-045B'), ('2026-094-2'),
--                  ('2026-045B-2'), ('2026-PREVIEW'), ('2025-100')) t(v);
--
--   expected:  044 | 045 | 094 | 045 | (null) | 100
--   The old `split_part(v,'-',2)::int` throws on rows 2 and 4 and skips row 3.
--
-- What shapes actually exist in orders right now:
--
--   select order_id,
--          substring(order_id from '^[0-9]{4}-([0-9]+)') as numeric_part
--     from public.orders
--    order by order_id;
--
-- Anything that would have thrown under the old extraction:
--
--   select order_id from public.orders
--    where order_id ~ '^[0-9]{4}-'
--      and order_id !~ '^[0-9]{4}-[0-9]+$';
--
-- The counter vs. the highest number really in use:
--
--   select c.year, c.last_seq,
--          (select max(substring(o.order_id from ('^' || c.year || '-([0-9]+)'))::int)
--             from public.orders o where o.order_id like (c.year || '-%')) as max_in_orders
--     from public.order_number_counters c order by c.year;
--
-- last_seq must be >= max_in_orders for every year.

-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK
--
--   -- restore the one-argument function to its pre-BLU body
--   -- (paste the create-or-replace block from SIGMA_order_numbering.sql), then
--   -- put its grant back, because create-or-replace keeps whatever this file set:
--   grant execute on function public.sigma_next_order_number(int) to anon, authenticated;
--   drop function if exists public.sigma_next_order_number(int, text);
--   drop function if exists public.sigma_next_order_seq(int);
--   notify pgrst, 'reload schema';
--
-- Run SIGMA_blu_rollback_20260824.sql FIRST — public.sigma_blu_record_request()
-- calls sigma_next_order_number(int,text) and will not drop cleanly after it.
--
-- The counter table itself is NOT touched by a rollback. If BLU numbers have
-- already been issued, leaving last_seq where it is is the CORRECT outcome —
-- rewinding it would reissue a number that is already on a document.
-- ─────────────────────────────────────────────────────────────────────────────
