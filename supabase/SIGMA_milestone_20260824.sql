-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — MILESTONE SNAPSHOT, 2026-08-24            (§BLU-DEVELOPMENTS setup)
--
-- RUN THIS FIRST, BEFORE ANY OTHER FILE IN THIS CHANGE.
--
-- It takes a dated copy of everything the BLU Capital Group intake work touches,
-- so SIGMA_blu_rollback_20260824.sql can put the database back exactly as it was.
-- It writes only new `*_backup_20260824` tables and changes nothing that exists.
-- Precedent: orders_insp_backup_20260716 (the doc-bloat outage).
--
-- SAFE TO RUN TWICE. Every snapshot is `create table if not exists ... as`, which
-- Postgres skips ENTIRELY when the table already exists. That is deliberate: a
-- second run after the change has been applied must NOT overwrite the before
-- picture with an after picture. If you truly need a fresh snapshot, drop the
-- backup table by hand first, and be sure you know what you are dropping.
--
-- WHAT IS NOT SNAPSHOT, AND WHY
--   public.orders          — this change never writes to it. New BLU orders are
--                            created through the ordinary New Order path like any
--                            other. A full copy would also duplicate insp_data,
--                            which is exactly what drowned the database on
--                            2026-07-16. Only the id index is copied, below.
--   public.invoices        — untouched. An invoice for a BLU order is raised by
--                            the existing sigma_create_invoice_from_order().
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. The order-number counter ─────────────────────────────────────────────
-- The single most important row in this change: allocating a BLU number moves
-- last_seq forward, and the counter is a high-water mark that only goes up.
create table if not exists public.order_number_counters_backup_20260824 as
  select *, now() as snapshot_at from public.order_number_counters;

-- ── 2. The order-id index ───────────────────────────────────────────────────
-- Tiny (two columns). Its job is to let you prove afterwards that no existing
-- order was renumbered or overwritten:
--
--   select b.order_id from public.orders_id_backup_20260824 b
--    where not exists (select 1 from public.orders o where o.order_id = b.order_id);
--   -- must return ZERO rows.
-- order_id ALONE. An earlier version of this file also selected created_at, which
-- public.orders does not have -- it has updated_at. The whole snapshot aborted on
-- that column, in a transaction, so nothing was captured and the operator only
-- found out after the change had gone in. The column added nothing the stated
-- purpose needs, so it is gone rather than corrected.
create table if not exists public.orders_id_backup_20260824 as
  select order_id, now() as snapshot_at from public.orders;

-- ── 3. The numbering functions, as source ───────────────────────────────────
-- SIGMA_order_numbering_blu.sql uses `create or replace` on
-- sigma_next_order_number(int). Replace destroys the old body, and there is no
-- undo, so the exact text is kept here. The rollback script also carries a
-- literal copy of the pre-BLU body, so it works even if this was never run —
-- this table is the authoritative cross-check.
create table if not exists public.sigma_funcdef_backup_20260824 as
  select p.oid::regprocedure::text as signature,
         pg_get_functiondef(p.oid)  as definition,
         now()                      as snapshot_at
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('sigma_next_order_number',
                       'sigma_next_order_seq',
                       'sigma_blu_record_request',
                       'blu_requests_touch_updated_at');

-- ── 4. Existing BLU requests, if any ────────────────────────────────────────
-- Empty on a first deployment (the table does not exist yet). Present if you are
-- re-applying over a live BLU integration, in which case these rows carry
-- appraisal numbers that have already been given to BLU and must survive.
do $$
begin
  if to_regclass('public.blu_appraisal_requests') is not null
     and to_regclass('public.blu_appraisal_requests_backup_20260824') is null then
    execute 'create table public.blu_appraisal_requests_backup_20260824 as
             select *, now() as snapshot_at from public.blu_appraisal_requests';
    raise notice 'snapshot: blu_appraisal_requests copied';
  else
    raise notice 'snapshot: blu_appraisal_requests skipped (absent, or already snapshot)';
  end if;
end $$;

-- ── 4b. Lock the snapshots down ─────────────────────────────────────────────
-- `create table ... as` inherits Supabase's default grants for anon and
-- authenticated, and the anon key ships inside index.html. orders_id_backup is a
-- complete index of every order number this firm has ever issued, so left open it
-- is a public listing of the order book. RLS with no policies denies anon and
-- authenticated outright while the SQL editor and service_role bypass it, which is
-- exactly the access this data should have.
--
-- Done here rather than left to the dashboard's "Run and enable RLS" prompt: that
-- prompt never sees the table created inside the DO block above, because it is
-- built from a string the linter cannot parse.
do $$
declare t text;
begin
  foreach t in array array['order_number_counters_backup_20260824',
                           'orders_id_backup_20260824',
                           'sigma_funcdef_backup_20260824',
                           'blu_appraisal_requests_backup_20260824'] loop
    if to_regclass('public.'||t) is not null then
      execute format('alter table public.%I enable row level security', t);
      execute format('revoke all on public.%I from anon, authenticated', t);
    end if;
  end loop;
end $$;

-- ── 5. Confirm what was captured (read-only) ────────────────────────────────
select 'order_number_counters' as snapshot,
       (select count(*) from public.order_number_counters_backup_20260824) as rows
union all
select 'orders_id',
       (select count(*) from public.orders_id_backup_20260824)
union all
select 'function definitions',
       (select count(*) from public.sigma_funcdef_backup_20260824)
union all
select 'blu_appraisal_requests',
       coalesce((select count(*) from public.blu_appraisal_requests_backup_20260824), 0);

-- Read the counter you are about to move, and write the numbers down:
select year, last_seq, updated_at from public.order_number_counters order by year;

-- ─────────────────────────────────────────────────────────────────────────────
-- To discard these snapshots once the change has been live and healthy for a
-- while (there is no hurry — they are small):
--   drop table if exists public.order_number_counters_backup_20260824;
--   drop table if exists public.orders_id_backup_20260824;
--   drop table if exists public.sigma_funcdef_backup_20260824;
--   drop table if exists public.blu_appraisal_requests_backup_20260824;
-- ─────────────────────────────────────────────────────────────────────────────
