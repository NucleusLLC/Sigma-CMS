-- SIGMA_field_claims.sql — §FIELD-CLAIM (v2.619)
-- A consultant (Tristan) ticks the field work he EXECUTED from a personal link;
-- the office approves it before anything is owed.
--
--   consultant's link  →  sigma_link_state()  : what is already recorded / claimed
--                      →  sigma_link_claim()  : tick = claim (pending), untick = withdraw
--   office (signed in) →  sigma_claim_decide(): approve = recorded as DONE (owed) at his
--                                                rate / the given amount; reject = gone
--
-- WHY A LINK AND NOT A LOGIN: public.invoices / payments / payment_receipts are open to
-- every authenticated account, so a consultant login would expose all finance. The link
-- reaches ONLY the two functions below; it can read nothing else and write nothing but a
-- pending claim. The token is stored as a SHA-256 hash; issuing a new link kills the old.
--
-- SAFETY: additive (two new tables, new functions). Changes no existing row, table or
-- function. Re-runnable. Run once in the Supabase SQL editor (production).

begin;

-- ── 1. Tables ──────────────────────────────────────────────────────────────────
create table if not exists public.contractor_links (
  contractor_id uuid primary key references public.contractors(id) on delete cascade,
  token_hash    text not null unique,
  created_at    timestamptz not null default now(),
  created_by    text,
  last_used_at  timestamptz
);

create table if not exists public.work_claims (
  id            uuid primary key default gen_random_uuid(),
  contractor_id uuid not null references public.contractors(id),
  order_number  text not null,
  task_code     text not null,
  item_label    text,
  status        text not null default 'pending'
                check (status in ('pending','approved','rejected','withdrawn')),
  claimed_at    timestamptz not null default now(),
  decided_at    timestamptz,
  decided_by    text,
  decision_note text,
  work_item_id  uuid references public.work_items(id)
);
create unique index if not exists work_claims_open_idx
  on public.work_claims (contractor_id, order_number, task_code)
  where status in ('pending','approved');

alter table public.contractor_links enable row level security;
alter table public.work_claims      enable row level security;
drop policy if exists links_staff  on public.contractor_links;
drop policy if exists claims_staff on public.work_claims;
-- Office staff only. anon has NO policy: the link goes through the functions below.
create policy links_staff  on public.contractor_links for all to authenticated
  using (public.sigma_is_staff()) with check (public.sigma_is_staff());
create policy claims_staff on public.work_claims      for all to authenticated
  using (public.sigma_is_staff()) with check (public.sigma_is_staff());

-- ── 2. The link ────────────────────────────────────────────────────────────────
create or replace function public._sigma_link_hash(p_token text)
returns text language sql immutable as $$
  select encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex')
$$;

-- Staff: issue (or replace) a consultant's personal link. Returns the token ONCE.
create or replace function public.sigma_link_issue(p_contractor uuid, p_actor text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_tok text;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can issue a link.'; end if;
  if not exists (select 1 from public.contractors where id = p_contractor and active) then
    raise exception 'That consultant does not exist or is not active.';
  end if;
  v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.contractor_links (contractor_id, token_hash, created_by)
  values (p_contractor, public._sigma_link_hash(v_tok), p_actor)
  on conflict (contractor_id) do update
     set token_hash = excluded.token_hash, created_at = now(), created_by = excluded.created_by, last_used_at = null;
  insert into public.finance_audit_events (entity, entity_id, action, actor, metadata)
  values ('contractor', p_contractor, 'link_issued', p_actor, '{}'::jsonb);
  return v_tok;
end $$;

create or replace function public.sigma_link_revoke(p_contractor uuid, p_actor text default null)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can revoke a link.'; end if;
  delete from public.contractor_links where contractor_id = p_contractor;
  insert into public.finance_audit_events (entity, entity_id, action, actor, metadata)
  values ('contractor', p_contractor, 'link_revoked', p_actor, '{}'::jsonb);
  return true;
end $$;

-- Who holds this token? NULL = nobody (bad, replaced or revoked link, or inactive consultant).
create or replace function public._sigma_link_who(p_token text)
returns uuid language sql stable security definer set search_path = public as $$
  select l.contractor_id
    from public.contractor_links l join public.contractors c on c.id = l.contractor_id
   where l.token_hash = public._sigma_link_hash(p_token) and c.active
   limit 1
$$;

-- Link: everything the page needs, and nothing more.
--   me       : name
--   tasks    : the active field-work catalogue (code → label)
--   recorded : order|task pairs already recorded for ANYONE (not void) — hidden from the list
--              (mine = recorded for this consultant)
--   claims   : this consultant's own claims (last 400)
create or replace function public.sigma_link_state(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := public._sigma_link_who(p_token);
begin
  if v_me is null then raise exception 'This link is no longer valid. Ask the office for a new one.'; end if;
  update public.contractor_links set last_used_at = now() where contractor_id = v_me;
  return jsonb_build_object(
    'me', (select jsonb_build_object('name', full_name) from public.contractors where id = v_me),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'label', label)) from public.contractor_tasks where active is not false), '[]'::jsonb),
    'recorded', coalesce((select jsonb_agg(jsonb_build_object('order', order_number, 'task', task_code, 'mine', contractor_id = v_me, 'status', status))
                            from public.work_items where status <> 'void'), '[]'::jsonb),
    'claims', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
                  select jsonb_build_object('id', id, 'order', order_number, 'task', task_code, 'label', item_label,
                                            'status', status, 'at', claimed_at, 'note', decision_note) as x
                    from public.work_claims where contractor_id = v_me
                   order by claimed_at desc limit 400) q), '[]'::jsonb)
  );
end $$;

-- Link: tick (p_on = true) = "I executed this"; untick = withdraw while still pending.
create or replace function public.sigma_link_claim(p_token text, p_order text, p_task text, p_label text, p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := public._sigma_link_who(p_token); v_row public.work_claims;
begin
  if v_me is null then raise exception 'This link is no longer valid. Ask the office for a new one.'; end if;
  if coalesce(trim(p_order), '') = '' or not exists (select 1 from public.orders where order_id = p_order) then
    raise exception 'Unknown job %.', p_order;
  end if;
  if not exists (select 1 from public.contractor_tasks where code = p_task and active is not false) then
    raise exception 'Unknown field-work task %.', p_task;
  end if;
  if p_on then
    if exists (select 1 from public.work_items where order_number = p_order and task_code = p_task and status <> 'void') then
      raise exception 'Job % (%) is already recorded.', p_order, p_task;
    end if;
    insert into public.work_claims (contractor_id, order_number, task_code, item_label)
    values (v_me, p_order, p_task, left(coalesce(p_label, ''), 200))
    on conflict (contractor_id, order_number, task_code) where status in ('pending','approved') do nothing
    returning * into v_row;
    if v_row.id is null then
      select * into v_row from public.work_claims
       where contractor_id = v_me and order_number = p_order and task_code = p_task and status in ('pending','approved');
    end if;
  else
    update public.work_claims set status = 'withdrawn', decided_at = now(), decided_by = 'consultant'
     where contractor_id = v_me and order_number = p_order and task_code = p_task and status = 'pending'
    returning * into v_row;
    if v_row.id is null then
      if exists (select 1 from public.work_claims where contractor_id = v_me and order_number = p_order and task_code = p_task and status = 'approved') then
        raise exception 'Job % (%) was already approved by the office; ask the office to change it.', p_order, p_task;
      end if;
    end if;
  end if;
  return jsonb_build_object('id', v_row.id, 'status', coalesce(v_row.status, 'none'));
end $$;

-- ── 3. The office decides ──────────────────────────────────────────────────────
-- Approve: recorded through the normal path (sigma_assign_work, audited), then marked DONE,
-- so it appears in Done/Owed exactly like work assigned by hand. p_amount NULL = his rate
-- in force (the same rule as assigning by hand); pass an amount for the Master Fees fee.
create or replace function public.sigma_claim_decide(p_claim uuid, p_approve boolean, p_actor text default null,
                                                     p_amount numeric default null, p_note text default null)
returns public.work_claims language plpgsql security definer set search_path = public as $$
declare v_c public.work_claims; v_w public.work_items;
begin
  if not public.sigma_is_staff() then raise exception 'Only office staff can decide on claims.'; end if;
  select * into v_c from public.work_claims where id = p_claim for update;
  if not found then raise exception 'That claim does not exist.'; end if;
  if v_c.status <> 'pending' then raise exception 'That claim is already %.', v_c.status; end if;
  if p_approve then
    v_w := public.sigma_assign_work(v_c.contractor_id, v_c.order_number, v_c.task_code, p_actor, p_amount,
             'Claimed by consultant' || coalesce(' (' || nullif(v_c.item_label, '') || ')', '') || ', approved', 1);
    v_w := public.sigma_work_done(v_w.id, p_actor, true);
    update public.work_claims set status = 'approved', decided_at = now(), decided_by = p_actor,
           decision_note = p_note, work_item_id = v_w.id where id = p_claim returning * into v_c;
  else
    update public.work_claims set status = 'rejected', decided_at = now(), decided_by = p_actor,
           decision_note = p_note where id = p_claim returning * into v_c;
  end if;
  insert into public.finance_audit_events (entity, entity_id, action, actor, after_state, reason)
  values ('work_claim', v_c.id, case when p_approve then 'claim_approved' else 'claim_rejected' end, p_actor, to_jsonb(v_c), p_note);
  return v_c;
end $$;

-- ── 4. Who may call what ───────────────────────────────────────────────────────
-- "revoke from public" alone leaves anon/authenticated EXECUTE in Supabase: name them.
revoke all on function public._sigma_link_hash(text)                               from public, anon, authenticated;
revoke all on function public._sigma_link_who(text)                                from public, anon, authenticated;
revoke all on function public.sigma_link_issue(uuid, text)                         from public, anon;
revoke all on function public.sigma_link_revoke(uuid, text)                        from public, anon;
revoke all on function public.sigma_claim_decide(uuid, boolean, text, numeric, text) from public, anon;
revoke all on function public.sigma_link_state(text)                               from public;
revoke all on function public.sigma_link_claim(text, text, text, text, boolean)    from public;
grant execute on function public.sigma_link_issue(uuid, text)                         to authenticated;
grant execute on function public.sigma_link_revoke(uuid, text)                        to authenticated;
grant execute on function public.sigma_claim_decide(uuid, boolean, text, numeric, text) to authenticated;
grant execute on function public.sigma_link_state(text)                               to anon, authenticated;
grant execute on function public.sigma_link_claim(text, text, text, text, boolean)    to anon, authenticated;

commit;

-- Check (read-only), after running:
--   select proname, proacl from pg_proc where proname like 'sigma_link%' or proname like '%claim%';
