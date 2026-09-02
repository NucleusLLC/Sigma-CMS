-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SIGMA — CONTRACTORS / FIELD WORK  (Release A)                               ║
-- ║  §CONTRACTOR-WORK (v2.383)                                                   ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- ASKED FOR: "create feature for Tristan Lacle, when he measure an Order, he can
-- check mark it, and it maintains the amount due to him. Also when we pay him for
-- his work, these are cleared. So lets treat his work as a consultant... He mostly
-- does Measurement, inspections, floorplan, cadaster inzage, and Cadaster Siteplan."
--
-- This is ACCOUNTS PAYABLE, and it is deliberately kept OUT of the invoicing tables.
-- A contractor's fee is money going out; invoices/payments are money coming in. Put
-- them in the same tables and turnover, the BBO return and the aging report all start
-- reporting numbers that are not true. Separate tables, same proven patterns.
--
-- ── DECISIONS THIS ENCODES (settled with the owner, 2026-09-02) ───────────────
--   • Fixed rate per task type, dated, so raising a rate never re-prices work that
--     was already done. Same valid_from/valid_to shape as public.tax_rates.
--   • SIGMA produces the payout statement; the contractor does not invoice us. So
--     there is no BBO on this side and no supplier-invoice number. Both can be
--     added later as columns without reshaping anything — see §LATER at the foot.
--   • The contractor eventually ticks his OWN work (Release B). The policies below
--     are already written for that; see the note on "staff" immediately after.
--
-- ── HOW "STAFF" IS DECIDED, AND WHY IT IS SAFE TO SHIP TODAY ─────────────────
--   There is no staff/role table in SIGMA, and inventing one that every existing
--   Finance user must be enrolled into before Finance keeps working is exactly how
--   you lock the office out of their own money screens on a Friday afternoon.
--
--   So the rule is inverted, and it is the whole trick of this migration:
--
--       an authenticated user who is NOT linked to a contractor row IS staff.
--
--   Today nobody is linked, so every existing Finance user keeps precisely the
--   access they have now — this migration cannot take anything away from anyone.
--   The moment contractors.auth_user_id is set for Tristan, that one account
--   becomes constrained to his own rows, and only his.
--
--   Contractors get SELECT only. Every write goes through a SECURITY DEFINER
--   function that re-checks ownership, so a contractor can mark his own work done
--   but can never set its amount, its status, or anybody else's row. The money maths
--   runs on the server, as it does everywhere else in this system.
--
-- ── SAFETY ────────────────────────────────────────────────────────────────────
--   Additive only. Creates tables/functions that do not exist; alters nothing that
--   does; drops nothing. Re-runnable (if not exists / or replace).

begin;

-- ── 1. The people ─────────────────────────────────────────────────────────────
create table if not exists public.contractors (
  id            uuid primary key default gen_random_uuid(),
  org_id        text not null default 'sigma',
  full_name     text not null,
  email         text,
  phone         text,
  -- Release B links this to auth.users. Until it is set, this contractor cannot
  -- sign in, and no existing account is affected by the row existing.
  auth_user_id  uuid unique,
  active        boolean not null default true,
  notes         text,
  created_by    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists contractors_active_idx on public.contractors (active, full_name);

-- ── 2. The catalogue of work ──────────────────────────────────────────────────
-- A table, not a CHECK constraint: a sixth kind of work should be one INSERT, not
-- a migration and a redeploy.
create table if not exists public.contractor_tasks (
  code    text primary key,
  label   text not null,
  sort    int  not null default 0,
  active  boolean not null default true
);
insert into public.contractor_tasks (code, label, sort) values
  ('MEASURE',   'Measurement',            10),
  ('INSPECT',   'Inspection',             20),
  ('FLOORPLAN', 'Floor plan',             30),
  ('INZAGE',    'Cadastral register (Inzage)', 40),
  ('SITEPLAN',  'Cadastral site plan',    50)
on conflict (code) do nothing;

-- ── 3. Rates, dated ───────────────────────────────────────────────────────────
create table if not exists public.contractor_rates (
  id            uuid primary key default gen_random_uuid(),
  org_id        text not null default 'sigma',
  contractor_id uuid not null references public.contractors(id) on delete cascade,
  task_code     text not null references public.contractor_tasks(code),
  amount        numeric(12,2) not null check (amount >= 0),
  currency      text not null default 'AWG',
  valid_from    date not null default current_date,
  valid_to      date,
  created_by    text,
  created_at    timestamptz not null default now(),
  constraint contractor_rates_span_chk check (valid_to is null or valid_to >= valid_from)
);
create index if not exists contractor_rates_lookup_idx
  on public.contractor_rates (contractor_id, task_code, valid_from desc);

-- The rate in force for a task on a date. Same rule the tax lookup uses.
create or replace function public.sigma_contractor_rate(
  p_contractor uuid, p_task text, p_on date default null)
returns numeric language sql stable security definer set search_path = public as $$
  select r.amount
    from public.contractor_rates r
   where r.contractor_id = p_contractor
     and r.task_code     = p_task
     and r.valid_from   <= coalesce(p_on, current_date)
     and (r.valid_to is null or r.valid_to >= coalesce(p_on, current_date))
   order by r.valid_from desc
   limit 1
$$;

-- ── 4. Payouts (declared before work_items so the FK can point at it) ─────────
create table if not exists public.payout_counters (
  year int primary key, last_seq int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.payout_counters enable row level security;   -- no policy: definer-only

create table if not exists public.contractor_payouts (
  id            uuid primary key default gen_random_uuid(),
  org_id        text not null default 'sigma',
  payout_number text not null unique,
  contractor_id uuid not null references public.contractors(id),
  status        text not null default 'draft'
                  check (status in ('draft','paid','void')),
  total         numeric(12,2) not null default 0,
  currency      text not null default 'AWG',
  payout_date   date,
  method        text,
  reference     text,
  notes         text,
  pdf_path      text,
  void_reason   text,
  created_by    text,
  created_at    timestamptz not null default now(),
  paid_at       timestamptz,
  paid_by       text,
  updated_at    timestamptz not null default now()
);
create index if not exists contractor_payouts_who_idx
  on public.contractor_payouts (contractor_id, status, created_at desc);

-- Its own series. PAY-2026-001 — never the invoice series and never the receipt one.
create or replace function public.sigma_next_payout_number(p_year int default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_year int := coalesce(p_year, extract(year from now())::int); v_next int;
begin
  insert into public.payout_counters (year, last_seq) values (v_year, 1)
  on conflict (year) do update set last_seq = public.payout_counters.last_seq + 1, updated_at = now()
  returning last_seq into v_next;
  return 'PAY-' || v_year || '-' || lpad(v_next::text, 3, '0');
end $$;

-- ── 5. The work itself ────────────────────────────────────────────────────────
-- One row per (contractor × order × task). The amount is SNAPSHOTTED at assignment.
--
-- Snapshotting is right here, and it is worth saying why, because snapshotting the
-- client onto an invoice caused a real bug in this system. A client identity is a
-- CURRENT fact — who this person is today — so freezing it went wrong. An agreed
-- rate is a HISTORICAL fact: what he was to be paid for work done in August must not
-- move when the rate changes in January. Freeze the second, follow the first.
create table if not exists public.work_items (
  id            uuid primary key default gen_random_uuid(),
  org_id        text not null default 'sigma',
  contractor_id uuid not null references public.contractors(id),
  order_number  text not null,                 -- orders.order_id, e.g. '2026-118'
  task_code     text not null references public.contractor_tasks(code),
  status        text not null default 'assigned'
                  check (status in ('assigned','done','paid','void')),
  amount        numeric(12,2) not null check (amount >= 0),
  currency      text not null default 'AWG',
  rate_id       uuid references public.contractor_rates(id),   -- provenance of the snapshot
  payout_id     uuid references public.contractor_payouts(id) on delete set null,
  assigned_at   timestamptz not null default now(),
  assigned_by   text,
  done_at       timestamptz,
  done_by       text,
  voided_at     timestamptz,
  voided_by     text,
  void_reason   text,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists work_items_who_idx    on public.work_items (contractor_id, status);
create index if not exists work_items_order_idx  on public.work_items (order_number);
create index if not exists work_items_payout_idx on public.work_items (payout_id);

-- The same job cannot be billed twice by the same person — but a VOIDED row must not
-- block re-adding it, so the uniqueness is partial.
create unique index if not exists work_items_once_idx
  on public.work_items (contractor_id, order_number, task_code)
  where status <> 'void';

-- ── 6. Who am I? ──────────────────────────────────────────────────────────────
-- NULL means "not a contractor", which this system reads as staff. See the header.
create or replace function public.sigma_my_contractor_id()
returns uuid language sql stable security definer set search_path = public as $$
  select c.id from public.contractors c where c.auth_user_id = auth.uid() limit 1
$$;

create or replace function public.sigma_is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and public.sigma_my_contractor_id() is null
$$;

-- ── 7. RLS ────────────────────────────────────────────────────────────────────
-- Nothing here is readable by the anon role. Unlike the legacy tables, these start
-- correct: authenticated only, and a contractor sees strictly his own rows.
alter table public.contractors        enable row level security;
alter table public.contractor_tasks   enable row level security;
alter table public.contractor_rates   enable row level security;
alter table public.contractor_payouts enable row level security;
alter table public.work_items         enable row level security;

drop policy if exists contractors_sel   on public.contractors;
drop policy if exists contractors_staff on public.contractors;
drop policy if exists tasks_sel         on public.contractor_tasks;
drop policy if exists tasks_staff       on public.contractor_tasks;
drop policy if exists rates_sel         on public.contractor_rates;
drop policy if exists rates_staff       on public.contractor_rates;
drop policy if exists payouts_sel       on public.contractor_payouts;
drop policy if exists payouts_staff     on public.contractor_payouts;
drop policy if exists work_sel          on public.work_items;
drop policy if exists work_staff        on public.work_items;

-- Read: staff see everything; a contractor sees only himself and his own work.
create policy contractors_sel on public.contractors for select to authenticated
  using (public.sigma_is_staff() or id = public.sigma_my_contractor_id());
create policy rates_sel on public.contractor_rates for select to authenticated
  using (public.sigma_is_staff() or contractor_id = public.sigma_my_contractor_id());
create policy payouts_sel on public.contractor_payouts for select to authenticated
  using (public.sigma_is_staff() or contractor_id = public.sigma_my_contractor_id());
create policy work_sel on public.work_items for select to authenticated
  using (public.sigma_is_staff() or contractor_id = public.sigma_my_contractor_id());
-- The catalogue is not sensitive and everyone needs its labels.
create policy tasks_sel on public.contractor_tasks for select to authenticated using (true);

-- Write: STAFF ONLY, and even they are expected to go through the functions below.
-- A contractor holds no write grant at all, so "mark my work done" can only ever
-- happen through sigma_work_done(), which re-checks ownership. He cannot set an
-- amount, a status or a payout on anything, including his own rows.
create policy contractors_staff on public.contractors        for all to authenticated
  using (public.sigma_is_staff()) with check (public.sigma_is_staff());
create policy tasks_staff       on public.contractor_tasks   for all to authenticated
  using (public.sigma_is_staff()) with check (public.sigma_is_staff());
create policy rates_staff       on public.contractor_rates   for all to authenticated
  using (public.sigma_is_staff()) with check (public.sigma_is_staff());
create policy payouts_staff     on public.contractor_payouts for all to authenticated
  using (public.sigma_is_staff()) with check (public.sigma_is_staff());
create policy work_staff        on public.work_items         for all to authenticated
  using (public.sigma_is_staff()) with check (public.sigma_is_staff());

-- ── 8. The operations ─────────────────────────────────────────────────────────
-- Assign a task. The amount is taken from the rate in force unless one is passed by
-- hand (a one-off agreed price), and the rate row that produced it is remembered.
create or replace function public.sigma_assign_work(
  p_contractor uuid, p_order text, p_task text,
  p_actor text default null, p_amount numeric default null, p_notes text default null)
returns public.work_items language plpgsql security definer set search_path = public as $$
declare v_rate_id uuid; v_amount numeric; v_row public.work_items;
begin
  if not public.sigma_is_staff() then
    raise exception 'Only office staff can assign work.';
  end if;
  if coalesce(trim(p_order), '') = '' then
    raise exception 'A work item must belong to an order.';
  end if;
  perform 1 from public.contractors where id = p_contractor and active;
  if not found then raise exception 'That contractor does not exist, or is not active.'; end if;

  select r.id, r.amount into v_rate_id, v_amount
    from public.contractor_rates r
   where r.contractor_id = p_contractor and r.task_code = p_task
     and r.valid_from <= current_date
     and (r.valid_to is null or r.valid_to >= current_date)
   order by r.valid_from desc limit 1;

  v_amount := coalesce(p_amount, v_amount);
  if v_amount is null then
    raise exception 'No rate is set for % on this task, and no amount was given. Set a rate in Finance → Contractors first.',
      (select full_name from public.contractors where id = p_contractor);
  end if;
  if p_amount is not null then v_rate_id := null; end if;   -- a hand-typed price is not a rate

  insert into public.work_items (contractor_id, order_number, task_code, amount, rate_id, assigned_by, notes)
  values (p_contractor, trim(p_order), p_task, v_amount, v_rate_id, p_actor, p_notes)
  returning * into v_row;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, metadata)
  values ('work_item', v_row.id, 'work_assigned', p_actor, to_jsonb(v_row),
          jsonb_build_object('order', v_row.order_number, 'task', p_task, 'amount', v_amount));
  return v_row;
end $$;

-- Mark it done. THIS is the tick. A contractor may call it for his own work; staff
-- may call it for anyone. Nothing else about the row can be changed here.
create or replace function public.sigma_work_done(p_item uuid, p_actor text default null, p_done boolean default true)
returns public.work_items language plpgsql security definer set search_path = public as $$
declare v_row public.work_items; v_mine uuid := public.sigma_my_contractor_id();
begin
  select * into v_row from public.work_items where id = p_item;
  if not found then raise exception 'That work item does not exist.'; end if;
  if not (public.sigma_is_staff() or v_row.contractor_id = v_mine) then
    raise exception 'That is not your work item.';
  end if;
  if v_row.status = 'void' then raise exception 'That work item was voided.'; end if;
  if v_row.status = 'paid' then
    raise exception 'Work item % has already been paid, on payout %. Void the payout first if it was wrong.',
      v_row.order_number, coalesce((select payout_number from public.contractor_payouts where id = v_row.payout_id), '(unknown)');
  end if;

  update public.work_items
     set status  = case when p_done then 'done' else 'assigned' end,
         done_at = case when p_done then now() else null end,
         done_by = case when p_done then p_actor else null end,
         updated_at = now()
   where id = p_item
   returning * into v_row;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, metadata)
  values ('work_item', v_row.id, case when p_done then 'work_done' else 'work_reopened' end,
          p_actor, to_jsonb(v_row),
          jsonb_build_object('order', v_row.order_number, 'task', v_row.task_code, 'amount', v_row.amount));
  return v_row;
end $$;

-- Never deleted — voided, with a reason, exactly like a reversed payment.
create or replace function public.sigma_void_work(p_item uuid, p_reason text, p_actor text default null)
returns public.work_items language plpgsql security definer set search_path = public as $$
declare v_row public.work_items;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can void work.'; end if;
  select * into v_row from public.work_items where id = p_item;
  if not found then raise exception 'That work item does not exist.'; end if;
  if v_row.status = 'paid' then
    raise exception 'That work item has been paid and cannot be voided. Void its payout first.';
  end if;
  update public.work_items
     set status = 'void', void_reason = coalesce(nullif(trim(p_reason), ''), '(no reason given)'),
         voided_at = now(), voided_by = p_actor, updated_at = now()
   where id = p_item returning * into v_row;
  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, reason)
  values ('work_item', v_row.id, 'work_voided', p_actor, to_jsonb(v_row), p_reason);
  return v_row;
end $$;

-- Gather done items into a payout. Refuses anything not 'done', already paid, on
-- another payout, or belonging to somebody else — one at a time, by name, so a
-- rejected batch says which item was wrong rather than just failing.
create or replace function public.sigma_create_payout(
  p_contractor uuid, p_items uuid[], p_actor text default null, p_notes text default null)
returns public.contractor_payouts language plpgsql security definer set search_path = public as $$
declare v_pay public.contractor_payouts; v_num text; v_total numeric := 0; v_id uuid; v_row public.work_items;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can create a payout.'; end if;
  if p_items is null or array_length(p_items, 1) is null then
    raise exception 'Select at least one piece of work to pay for.';
  end if;

  foreach v_id in array p_items loop
    select * into v_row from public.work_items where id = v_id;
    if not found then raise exception 'One of the selected items no longer exists.'; end if;
    if v_row.contractor_id <> p_contractor then
      raise exception 'Work item % (%) belongs to a different contractor.', v_row.order_number, v_row.task_code;
    end if;
    if v_row.status <> 'done' then
      raise exception 'Work item % (%) is "%", not done — only completed work can be paid.',
        v_row.order_number, v_row.task_code, v_row.status;
    end if;
    if v_row.payout_id is not null then
      raise exception 'Work item % (%) is already on payout %.', v_row.order_number, v_row.task_code,
        (select payout_number from public.contractor_payouts where id = v_row.payout_id);
    end if;
    v_total := v_total + v_row.amount;
  end loop;

  v_num := public.sigma_next_payout_number();
  insert into public.contractor_payouts (payout_number, contractor_id, total, notes, created_by)
  values (v_num, p_contractor, v_total, p_notes, p_actor)
  returning * into v_pay;

  update public.work_items set payout_id = v_pay.id, updated_at = now()
   where id = any(p_items);

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, metadata)
  values ('contractor_payout', v_pay.id, 'payout_created', p_actor, to_jsonb(v_pay),
          jsonb_build_object('items', array_length(p_items,1), 'total', v_total));
  return v_pay;
end $$;

-- Paying it is what clears the work — "when we pay him for his work, these are cleared".
create or replace function public.sigma_pay_payout(
  p_payout uuid, p_date date default null, p_method text default null,
  p_reference text default null, p_actor text default null)
returns public.contractor_payouts language plpgsql security definer set search_path = public as $$
declare v_pay public.contractor_payouts;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can pay a payout.'; end if;
  select * into v_pay from public.contractor_payouts where id = p_payout;
  if not found then raise exception 'That payout does not exist.'; end if;
  if v_pay.status = 'paid' then raise exception 'Payout % has already been paid.', v_pay.payout_number; end if;
  if v_pay.status = 'void' then raise exception 'Payout % is void.', v_pay.payout_number; end if;

  update public.contractor_payouts
     set status = 'paid', payout_date = coalesce(p_date, current_date),
         method = p_method, reference = p_reference,
         paid_at = now(), paid_by = p_actor, updated_at = now()
   where id = p_payout returning * into v_pay;

  update public.work_items set status = 'paid', updated_at = now()
   where payout_id = p_payout and status = 'done';

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, metadata)
  values ('contractor_payout', v_pay.id, 'payout_paid', p_actor, to_jsonb(v_pay),
          jsonb_build_object('total', v_pay.total, 'method', p_method, 'reference', p_reference));
  return v_pay;
end $$;

-- Voiding a payout hands its work back as unpaid rather than destroying it.
create or replace function public.sigma_void_payout(p_payout uuid, p_reason text, p_actor text default null)
returns public.contractor_payouts language plpgsql security definer set search_path = public as $$
declare v_pay public.contractor_payouts;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can void a payout.'; end if;
  select * into v_pay from public.contractor_payouts where id = p_payout;
  if not found then raise exception 'That payout does not exist.'; end if;
  if v_pay.status = 'void' then raise exception 'Payout % is already void.', v_pay.payout_number; end if;

  update public.work_items set status = 'done', payout_id = null, updated_at = now()
   where payout_id = p_payout and status in ('done','paid');
  update public.contractor_payouts
     set status = 'void', void_reason = coalesce(nullif(trim(p_reason),''), '(no reason given)'), updated_at = now()
   where id = p_payout returning * into v_pay;

  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, reason)
  values ('contractor_payout', v_pay.id, 'payout_voided', p_actor, to_jsonb(v_pay), p_reason);
  return v_pay;
end $$;

-- ── 9. What is owed, at a glance ─────────────────────────────────────────────
-- RLS on work_items applies through the view, so a contractor querying it sees only
-- his own figure and staff see everyone.
create or replace view public.contractor_balances_v as
select c.id                as contractor_id,
       c.full_name,
       c.email,
       c.active,
       count(*) filter (where w.status = 'assigned')                as assigned_count,
       count(*) filter (where w.status = 'done')                    as done_count,
       coalesce(sum(w.amount) filter (where w.status = 'done'), 0)  as owed_now,
       coalesce(sum(w.amount) filter (where w.status = 'paid'), 0)  as paid_to_date,
       max(w.done_at) filter (where w.status in ('done','paid'))    as last_worked_at
  from public.contractors c
  left join public.work_items w on w.contractor_id = c.id and w.status <> 'void'
 group by c.id, c.full_name, c.email, c.active;

-- ── 10. Grants ────────────────────────────────────────────────────────────────
-- authenticated only. The anon role is granted nothing here, deliberately: unlike the
-- legacy tables, none of this is readable with the key that ships in index.html.
grant select on public.contractors, public.contractor_tasks, public.contractor_rates,
                public.contractor_payouts, public.work_items, public.contractor_balances_v
  to authenticated;
grant insert, update, delete on public.contractors, public.contractor_tasks,
                public.contractor_rates, public.contractor_payouts, public.work_items
  to authenticated;   -- still gated by the staff-only policies above

grant execute on function public.sigma_contractor_rate(uuid,text,date)              to authenticated;
grant execute on function public.sigma_my_contractor_id()                           to authenticated;
grant execute on function public.sigma_is_staff()                                   to authenticated;
grant execute on function public.sigma_assign_work(uuid,text,text,text,numeric,text) to authenticated;
grant execute on function public.sigma_work_done(uuid,text,boolean)                 to authenticated;
grant execute on function public.sigma_void_work(uuid,text,text)                    to authenticated;
grant execute on function public.sigma_create_payout(uuid,uuid[],text,text)         to authenticated;
grant execute on function public.sigma_pay_payout(uuid,date,text,text,text)         to authenticated;
grant execute on function public.sigma_void_payout(uuid,text,text)                  to authenticated;
grant execute on function public.sigma_next_payout_number(int)                      to authenticated;

-- ── 11. Take it back off anon ─────────────────────────────────────────────────
-- Supabase's default privileges on the public schema hand `anon` a grant on every
-- new table automatically, so section 10 above is not the whole story: the grant
-- existed the moment the tables did. RLS still returned nothing (no policy names
-- anon), but a grant that exists is one `disable row level security` away from
-- exposing what a contractor is paid. Taken away explicitly.
--
-- REVOKE ... FROM PUBLIC would NOT do this: anon holds its own grant, not one
-- inherited from PUBLIC. Verify with pg_class.relacl / pg_proc.proacl, because
-- has_function_privilege() keeps answering true for a role that still holds a
-- direct grant.
revoke all on public.contractors           from anon;
revoke all on public.contractor_tasks      from anon;
revoke all on public.contractor_rates      from anon;
revoke all on public.contractor_payouts    from anon;
revoke all on public.work_items            from anon;
revoke all on public.payout_counters       from anon;
revoke all on public.contractor_balances_v from anon;
revoke execute on function public.sigma_assign_work(uuid,text,text,text,numeric,text) from anon;
revoke execute on function public.sigma_work_done(uuid,text,boolean)                 from anon;
revoke execute on function public.sigma_void_work(uuid,text,text)                    from anon;
revoke execute on function public.sigma_create_payout(uuid,uuid[],text,text)         from anon;
revoke execute on function public.sigma_pay_payout(uuid,date,text,text,text)         from anon;
revoke execute on function public.sigma_void_payout(uuid,text,text)                  from anon;
revoke execute on function public.sigma_next_payout_number(int)                      from anon;
revoke execute on function public.sigma_contractor_rate(uuid,text,date)              from anon;
revoke execute on function public.sigma_my_contractor_id()                           from anon;
revoke execute on function public.sigma_is_staff()                                   from anon;

commit;

-- ── §LATER — the two things Release A deliberately leaves out ─────────────────
--  1. If the contractor ever starts invoicing the bureau instead of being paid on a
--     statement, add supplier_invoice_no / supplier_invoice_date / tax_amount to
--     contractor_payouts. Nothing above needs reshaping for that.
--  2. Release B links a person to a login:
--         update public.contractors set auth_user_id = '<uuid from auth.users>'
--          where full_name = 'Tristan Laclé';
--     DO NOT run that until the Finance policies are scoped to staff — as things
--     stand, public.invoices / payments / payment_receipts are all
--     "for all to authenticated using (true)", so any authenticated account can read
--     and write every invoice in the system. That is a change to make deliberately,
--     with the office's own access tested first, and it is not part of this file.
