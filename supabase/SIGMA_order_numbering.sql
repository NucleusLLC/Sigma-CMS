-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — server-authoritative appraisal order numbering
--
-- Replaces the browser-side `max(ORDERS) + 1` scheme, which had three defects:
--
--   1. NUMBER REUSE. The maximum was taken from the orders held in that browser.
--      Deleting the highest orders lowered the maximum, so the next order was
--      issued a number that had already been used — and, once invoicing exists,
--      an invoice number must never be reused.
--
--   2. SILENT OVERWRITE. Two people creating an order at the same moment both
--      computed the same number, and the save is an upsert on order_id, so the
--      second write replaced the first person's order instead of failing.
--
--   3. HARD-CODED YEAR ('2026-'), which would keep issuing 2026-NNN in 2027.
--
-- The counter is a HIGH-WATER MARK per year: it only ever moves forward, so a
-- deleted or voided number is never handed out again.
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.order_number_counters (
  year       int primary key,
  last_seq   int not null default 0,
  updated_at timestamptz not null default now()
);

-- No anon policy: the counter is only ever touched through the SECURITY DEFINER
-- function below, so the sequence cannot be rewound by a client.
alter table public.order_number_counters enable row level security;

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

  -- Highest number already present for this year. Taking GREATEST of this and the
  -- stored counter means the sequence can never collide with a row that exists,
  -- even if the counter table were ever reset or seeded late.
  select coalesce(max(split_part(order_id, '-', 2)::int), 0)
    into v_seed
    from public.orders
   where order_id ~ ('^' || v_year || '-[0-9]+$');

  -- Atomic: ON CONFLICT takes a row lock, so concurrent callers serialise here
  -- and each receives a distinct number.
  insert into public.order_number_counters (year, last_seq)
       values (v_year, v_seed + 1)
  on conflict (year) do update
          set last_seq   = greatest(public.order_number_counters.last_seq, v_seed) + 1,
              updated_at = now()
    returning last_seq into v_next;

  return v_year || '-' || lpad(v_next::text, 3, '0');
end $$;

-- The app authenticates with the anon key, so anon must be able to call it.
-- Execute rights on a SECURITY DEFINER function are NOT write rights on the table.
grant execute on function public.sigma_next_order_number(int) to anon, authenticated;

-- Seed the counter from the orders that already exist, so the first call after
-- deployment continues the existing series rather than restarting it.
insert into public.order_number_counters (year, last_seq)
select split_part(order_id, '-', 1)::int as year,
       max(split_part(order_id, '-', 2)::int) as last_seq
  from public.orders
 where order_id ~ '^[0-9]{4}-[0-9]+$'
 group by 1
on conflict (year) do update
  set last_seq = greatest(public.order_number_counters.last_seq, excluded.last_seq);
