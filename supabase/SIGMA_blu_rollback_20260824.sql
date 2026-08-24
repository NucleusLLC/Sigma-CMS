-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — ROLLBACK of the BLU Capital Group intake  (§BLU-DEVELOPMENTS)
--
-- Undoes SIGMA_order_numbering_blu.sql and SIGMA_blu_appraisal_requests.sql, and
-- puts public.sigma_next_order_number(int) back to its pre-BLU body.
--
-- SAFE TO RUN TWICE. Every step is `if exists` or guarded, and the archive step
-- refuses to overwrite an archive it has already written.
--
-- ═══ READ THIS BEFORE RUNNING ════════════════════════════════════════════════
--
-- 1. THE COUNTER IS NOT REWOUND, and that is correct, not an oversight.
--    public.order_number_counters keeps whatever last_seq the BLU numbers pushed
--    it to. A number that has been handed to BLU — quoted to a buyer, quoted to
--    a bank, possibly already on an invoice — must never be issued to anything
--    else. Rolling the counter back would do exactly that. The cost of leaving
--    it forward is a gap in the series; the cost of rewinding it is two
--    documents with the same number.
--
-- 2. THE REQUEST ROWS ARE ARCHIVED, NOT DELETED. Step 1 below copies
--    public.blu_appraisal_requests to blu_appraisal_requests_archive_20260824
--    before anything is dropped. Those rows are the only record of which numbers
--    were promised to BLU.
--
-- 3. ORDERS ALREADY CREATED FROM A BLU REQUEST ARE NOT TOUCHED. They are
--    ordinary appraisal orders that happen to carry a 'B' in the number; nothing
--    in the app treats them specially. They keep working after the rollback, and
--    their invoices keep working, because invoices_number_matches_order compares
--    the invoice number against the ORDER number rather than against a fixed
--    shape.
--
-- 4. DEPLOY THE APP FIRST, IF YOU ARE ROLLING BACK THE APP TOO. index.html v2.350
--    reads public.blu_appraisal_requests. It fails softly if the table is gone
--    (the Developments area shows "the table does not exist yet"), so the order
--    of the two rollbacks does not matter for safety — but the panel looks
--    broken until index.html goes back to v2.349.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Archive the requests ─────────────────────────────────────────────────
do $$
begin
  if to_regclass('public.blu_appraisal_requests') is null then
    raise notice 'rollback 1/6: blu_appraisal_requests absent — nothing to archive';
  elsif to_regclass('public.blu_appraisal_requests_archive_20260824') is not null then
    raise notice 'rollback 1/6: archive already exists — left alone';
  else
    execute 'create table public.blu_appraisal_requests_archive_20260824 as
             select *, now() as archived_at from public.blu_appraisal_requests';
    raise notice 'rollback 1/6: requests archived';
  end if;
end $$;

-- ── 2. Drop the intake RPC ──────────────────────────────────────────────────
-- Before the table, because it reads it; before the allocator, because it calls
-- sigma_next_order_number(int, text).
drop function if exists public.sigma_blu_record_request(jsonb);

-- ── 3. Drop the table and its trigger function ──────────────────────────────
drop table    if exists public.blu_appraisal_requests;          -- takes the trigger with it
drop function if exists public.blu_requests_touch_updated_at();

-- ── 4. Restore the pre-BLU numbering ────────────────────────────────────────
-- Verbatim from SIGMA_order_numbering.sql, so this file works even if
-- SIGMA_milestone_20260824.sql was never run. To confirm it matches what was
-- actually on the server before the change:
--
--   select signature, definition from public.sigma_funcdef_backup_20260824
--    where signature like 'sigma_next_order_number%';
--
-- NOTE the known limitation you are restoring: this body reads the high-water
-- mark with split_part(order_id,'-',2)::int against '^YYYY-[0-9]+$'. It SKIPS any
-- order id that is not purely numeric — including every '...B' order left behind
-- by the BLU work. It cannot throw on them (the regex excludes them first), but
-- if the counter were ever reset it would under-count and re-issue a number that
-- a BLU order already holds. Keep the counter where it is and this is moot; that
-- is reason 1 at the top of this file.
create or replace function public.sigma_next_order_number(p_year int default null)
returns text
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
    raise exception 'sigma_next_order_number: implausible year %', v_year;
  end if;

  select coalesce(max(split_part(order_id, '-', 2)::int), 0)
    into v_seed
    from public.orders
   where order_id ~ ('^' || v_year || '-[0-9]+$');

  insert into public.order_number_counters (year, last_seq)
       values (v_year, v_seed + 1)
  on conflict (year) do update
          set last_seq   = greatest(public.order_number_counters.last_seq, v_seed) + 1,
              updated_at = now()
    returning last_seq into v_next;

  return v_year || '-' || lpad(v_next::text, 3, '0');
end $$;

-- create-or-replace keeps whatever grants are on the function, and
-- SIGMA_order_numbering_blu.sql revoked it from PUBLIC. Put the app's access back
-- explicitly, or every New Order falls to the browser-side fallback.
grant execute on function public.sigma_next_order_number(int) to anon, authenticated;

-- ── 5. Drop the BLU-only numbering functions ────────────────────────────────
-- After step 4, so nothing still in use is dropped.
drop function if exists public.sigma_next_order_number(int, text);
drop function if exists public.sigma_next_order_seq(int);

-- ── 6. Tell PostgREST ───────────────────────────────────────────────────────
notify pgrst, 'reload schema';

-- ── VERIFY (read-only) ──────────────────────────────────────────────────────
-- Everything BLU should be gone, and the plain allocator should be back:
select p.oid::regprocedure::text as still_present
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('sigma_next_order_number','sigma_next_order_seq',
                     'sigma_blu_record_request','blu_requests_touch_updated_at')
 order by 1;
-- expect exactly one row: sigma_next_order_number(integer)

select to_regclass('public.blu_appraisal_requests')                    as table_gone_if_null,
       to_regclass('public.blu_appraisal_requests_archive_20260824')   as archive_kept;

-- The counter is deliberately still forward. Compare it with the snapshot to see
-- how many numbers the BLU work consumed, and satisfy yourself the gap is
-- understood rather than surprising:
select c.year, c.last_seq as now_at, b.last_seq as before_change,
       c.last_seq - b.last_seq as numbers_consumed
  from public.order_number_counters c
  left join public.order_number_counters_backup_20260824 b using (year)
 order by c.year;

-- Prove no pre-existing order was lost along the way:
select b.order_id as missing_from_orders
  from public.orders_id_backup_20260824 b
 where not exists (select 1 from public.orders o where o.order_id = b.order_id);
-- expect ZERO rows.

-- ─────────────────────────────────────────────────────────────────────────────
-- STILL TO DO BY HAND after this file (it cannot reach them from SQL):
--   • supabase functions delete blu-appraisal-intake      (or leave it: with the
--     RPC gone it answers 503 "SIGMA is not ready" and writes nothing)
--   • supabase secrets unset BLU_INTAKE_SECRET
--   • tell BLU to turn the feature off — clearing
--     SIGMA_APPRAISAL_INTAKE_URL / SIGMA_APPRAISAL_INTAKE_SECRET on their side —
--     so their desk says "not configured" instead of showing a button that fails
--   • revert index.html to v2.349 and push (Cloudflare Pages auto-deploys)
-- ─────────────────────────────────────────────────────────────────────────────
