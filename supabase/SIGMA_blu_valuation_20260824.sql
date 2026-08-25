-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — BLU presumable valuation on an appraisal request  (§BLU-VALUATION)
--
-- NOT APPLIED. Review, then run in the Supabase SQL editor.
--
-- ⚠ THIS ALTERS A LIVE TABLE THAT ALREADY HOLDS PRODUCTION ROWS.
--   public.blu_appraisal_requests and public.sigma_blu_record_request(jsonb) were
--   applied to production on 2026-08-24 by SIGMA_order_numbering_blu.sql and
--   SIGMA_blu_appraisal_requests.sql. Those two files are HISTORY and must not be
--   edited — an already-applied file that quietly grows a column is a file nobody
--   can trust again. This is the additive follow-up.
--
--   Everything below is additive and idempotent:
--     • every column is `add column if not exists`, nullable, no default
--     • every constraint is dropped-if-exists then re-added, so a second run is a
--       no-op and never leaves a half-named duplicate
--     • no existing row is read, rewritten or re-validated into failure: the new
--       columns are NULL on every row that already exists, and NULL satisfies
--       every check written here
--     • the RPC is `create or replace`, keeping its name, signature, ownership
--       and its `service_role`-only grant
--
-- WHAT THIS IS
--   BLU's Sales & Control Desk now sends the presumable valuation along with the
--   appraisal request, so the appraiser opens the Job Order with the figures
--   already in it instead of re-keying them out of an email.
--
--   On the wire (fixed by the sending side — see the edge function header) the
--   request gains a nullable `valuation` member:
--
--     "valuation": {
--       "currency": "AWG",
--       "lines": [{"key":"land","label":"Land","quantity_m2":196.4,
--                  "rate_minor":45000,"amount_minor":8838000}],
--       "sub_total_minor":   42058375,
--       "added_value_pct":   0.18,
--       "added_value_minor":  7570508,
--       "pfmv_minor":        49628883,
--       "pev_pct":           0.8,
--       "pev_minor":         39703106,
--       "prcv_minor":        40790883,
--       "rate_card_source": "Wayaca Modern Villas_Numbers.xlsx VALUES sheet",
--       "supersedes": null
--     }
--
--   EVERY MONEY VALUE IS AN INTEGER IN MINOR UNITS (cents). They are stored as
--   `bigint` and never as `numeric`/`float`: a valuation that has been through a
--   binary float is a valuation you cannot reconcile against an invoice.
--
--   PFMV = sub-total + green-building uplift.  PEV = pev_pct × PFMV.
--   PRCV = PFMV − the land line.  SIGMA STORES WHAT ARRIVES AND RECOMPUTES
--   NOTHING — BLU's spreadsheet is the source of these three, and if its own
--   arithmetic does not tie, that is a fact about the request which the
--   Developments card shows rather than silently corrects.
--
-- "NOT SUPPLIED" vs "SUPPLIED AND ZERO"
--   `valuation` may be absent or null — Coriara has a different valuation module
--   and four other projects have none — and a supplied figure may legitimately be
--   0. A money column cannot carry that distinction on its own, so the
--   discriminator is a separate timestamp:
--
--     valuation_received_at IS NULL      → BLU supplied no valuation
--     valuation_received_at IS NOT NULL  → BLU supplied one; the figures are real,
--                                          including any that are zero
--
--   A CHECK below keeps those two states honest: no valuation column may be
--   populated without the timestamp, and the timestamp may not exist without the
--   five figures the contract makes mandatory.
--
-- NEVER store documents or base64 here. `valuation_lines` is a jsonb ARRAY OF
-- SMALL OBJECTS (five scalar members each) and is capped by the edge function at
-- 200 lines. It is not a place to park a spreadsheet. (2026-07-16 outage.)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1 · Columns ─────────────────────────────────────────────────────────────
alter table public.blu_appraisal_requests
  -- the discriminator: set once, when a valuation is first recorded
  add column if not exists valuation_received_at        timestamptz,
  -- ISO 4217, upper case. Stored rather than assumed: SIGMA's valuation screens
  -- are AWG-primary, and a USD valuation must be visible as such, not silently
  -- read as florins.
  add column if not exists valuation_currency           text,
  -- the line items verbatim: [{key,label,quantity_m2,rate_minor,amount_minor}]
  add column if not exists valuation_lines              jsonb,
  add column if not exists valuation_sub_total_minor    bigint,
  -- a FRACTION (0.18 = 18%), exactly as sent. numeric, never float.
  add column if not exists valuation_added_value_pct    numeric(9,6),
  add column if not exists valuation_added_value_minor  bigint,
  -- the three headline figures, typed so they can be read, indexed, summed and
  -- displayed without parsing json in the browser or in a report query
  add column if not exists valuation_pfmv_minor         bigint,
  add column if not exists valuation_pev_pct            numeric(9,6),
  add column if not exists valuation_pev_minor          bigint,
  add column if not exists valuation_prcv_minor         bigint,
  -- provenance: which rate card produced these numbers
  add column if not exists valuation_rate_card_source   text,
  -- BLU's own pointer at the valuation this one replaces (their reference, not
  -- ours — a superseding valuation arrives as a NEW request with a NEW
  -- idempotency key, because a recorded valuation is never rewritten in place)
  add column if not exists valuation_supersedes         text;

comment on column public.blu_appraisal_requests.valuation_received_at is
  'When SIGMA recorded BLU''s presumable valuation. NULL = no valuation supplied. This, not a zero figure, is the "was one supplied?" test.';
comment on column public.blu_appraisal_requests.valuation_pfmv_minor is
  'Presumable Free Market Value, INTEGER MINOR UNITS (cents) of valuation_currency. Stored exactly as BLU sent it; never recomputed.';
comment on column public.blu_appraisal_requests.valuation_prcv_minor is
  'Presumable Re-Construction Value as BLU defines it: PFMV minus the land line, with NO demolition uplift. SIGMA''s own report formula adds 10% to the same base — see §BLU-VALUATION in index.html.';

-- ── 2 · Constraints ─────────────────────────────────────────────────────────
-- drop-then-add so a second run is a clean no-op. Existing rows have NULL in every
-- new column, and NULL passes all of these, so nothing already stored can fail.

-- (a) the two states, and only those two. No valuation column may be set without
--     the timestamp, and the timestamp may not stand without the five figures the
--     wire contract makes mandatory.
alter table public.blu_appraisal_requests
  drop constraint if exists blu_requests_valuation_state_ck;
alter table public.blu_appraisal_requests
  add constraint blu_requests_valuation_state_ck check (
    case
      when valuation_received_at is null then
        valuation_currency          is null
        and valuation_lines         is null
        and valuation_sub_total_minor   is null
        and valuation_added_value_pct   is null
        and valuation_added_value_minor is null
        and valuation_pfmv_minor    is null
        and valuation_pev_pct       is null
        and valuation_pev_minor     is null
        and valuation_prcv_minor    is null
        and valuation_rate_card_source is null
        and valuation_supersedes    is null
      else
        valuation_currency          is not null
        and valuation_lines         is not null
        and valuation_sub_total_minor is not null
        and valuation_pfmv_minor    is not null
        and valuation_pev_minor     is not null
        and valuation_prcv_minor    is not null
    end
  );

-- (b) lines is an ARRAY of objects, never a bare object or a string
alter table public.blu_appraisal_requests
  drop constraint if exists blu_requests_valuation_lines_ck;
alter table public.blu_appraisal_requests
  add constraint blu_requests_valuation_lines_ck check (
    valuation_lines is null or jsonb_typeof(valuation_lines) = 'array'
  );

-- (c) ISO 4217 shape. Not a whitelist: BLU may legitimately quote in USD one day,
--     and refusing an unknown-but-well-formed code would drop a real valuation.
alter table public.blu_appraisal_requests
  drop constraint if exists blu_requests_valuation_currency_ck;
alter table public.blu_appraisal_requests
  add constraint blu_requests_valuation_currency_ck check (
    valuation_currency is null or valuation_currency ~ '^[A-Z]{3}$'
  );

-- (d) money is non-negative. Zero is allowed and meaningful; negative is not a
--     valuation, it is a bug upstream.
alter table public.blu_appraisal_requests
  drop constraint if exists blu_requests_valuation_money_ck;
alter table public.blu_appraisal_requests
  add constraint blu_requests_valuation_money_ck check (
    coalesce(valuation_sub_total_minor,   0) >= 0
    and coalesce(valuation_added_value_minor, 0) >= 0
    and coalesce(valuation_pfmv_minor,    0) >= 0
    and coalesce(valuation_pev_minor,     0) >= 0
    and coalesce(valuation_prcv_minor,    0) >= 0
  );

-- (e) the two percentages are FRACTIONS. 0.18, not 18. A sender that switches to
--     whole percent would otherwise multiply a valuation by a hundred and nothing
--     downstream would notice.
alter table public.blu_appraisal_requests
  drop constraint if exists blu_requests_valuation_pct_ck;
alter table public.blu_appraisal_requests
  add constraint blu_requests_valuation_pct_ck check (
    (valuation_added_value_pct is null or (valuation_added_value_pct >= 0 and valuation_added_value_pct <= 1))
    and (valuation_pev_pct     is null or (valuation_pev_pct     >= 0 and valuation_pev_pct     <= 1))
  );

-- ── 3 · Index ───────────────────────────────────────────────────────────────
-- "which requests arrived with a valuation" is the one question this table will be
-- asked about the new columns. Partial, so it stays the size of the answer.
create index if not exists blu_requests_valuation_idx
  on public.blu_appraisal_requests (valuation_received_at desc)
  where valuation_received_at is not null;

-- ── 4 · The row guard, extended ─────────────────────────────────────────────
-- Same discipline the original trigger established for appraisal_number: NULL → a
-- value is allowed (that is the intake RPC doing its job), value → anything else is
-- silently held.
--
-- WHY WRITE-ONCE. A recorded valuation is the figure the appraisal was accepted on.
-- BLU's own contract already carries `supersedes`, which means a revision arrives as
-- a NEW request with a NEW idempotency key pointing back at the old one — never as a
-- rewrite of a row SIGMA has already acted on. Held rather than raised, for the same
-- reason as before: a PostgREST PATCH sends the whole row, and it must still be able
-- to set status or order_id.
create or replace function public.blu_requests_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();

  if old.appraisal_number is not null then
    new.appraisal_number := old.appraisal_number;
  end if;
  new.idempotency_key := old.idempotency_key;

  -- §BLU-VALUATION — a recorded valuation is immutable, as one block. Held
  -- together so a partial update can never leave PFMV from one valuation beside
  -- line items from another.
  if old.valuation_received_at is not null then
    new.valuation_received_at       := old.valuation_received_at;
    new.valuation_currency          := old.valuation_currency;
    new.valuation_lines             := old.valuation_lines;
    new.valuation_sub_total_minor   := old.valuation_sub_total_minor;
    new.valuation_added_value_pct   := old.valuation_added_value_pct;
    new.valuation_added_value_minor := old.valuation_added_value_minor;
    new.valuation_pfmv_minor        := old.valuation_pfmv_minor;
    new.valuation_pev_pct           := old.valuation_pev_pct;
    new.valuation_pev_minor         := old.valuation_pev_minor;
    new.valuation_prcv_minor        := old.valuation_prcv_minor;
    new.valuation_rate_card_source  := old.valuation_rate_card_source;
    new.valuation_supersedes        := old.valuation_supersedes;
  end if;

  return new;
end $$;

-- The trigger itself is unchanged and already installed; re-created so this file
-- also works on a database restored from before it existed.
drop trigger if exists blu_requests_set_updated_at on public.blu_appraisal_requests;
create trigger blu_requests_set_updated_at
  before update on public.blu_appraisal_requests
  for each row execute function public.blu_requests_touch_updated_at();

-- ── 5 · Typed readers for the incoming jsonb ────────────────────────────────
-- The edge function validates first and rejects a malformed valuation with a named
-- error before any of this runs. These exist because the RPC is SECURITY DEFINER
-- and reachable from the SQL editor as well as from the function, and because a
-- bare `(v->>'pfmv_minor')::bigint` on a float or a string raises
-- `invalid input syntax for type bigint` — accurate, but it names neither the field
-- nor the request.
--
-- A FLOAT WHERE A MINOR UNIT BELONGS IS A BUG, NOT A ROUNDING DETAIL: 4962888.3 is
-- rejected, never truncated to 4962888.

-- STABLE rather than IMMUTABLE on purpose. These are only ever called from the RPC
-- below, and marking them immutable would let the planner constant-fold a call whose
-- arguments it can see, which for a function whose whole job is to RAISE is a way to
-- get an error at plan time instead of at the point the value is used.
create or replace function public.sigma_blu_minor(v jsonb, k text, req boolean)
returns bigint
language plpgsql
stable
as $$
declare
  e jsonb := v -> k;
  n numeric;
begin
  if e is null or jsonb_typeof(e) = 'null' then
    if req then
      raise exception 'valuation.% is required and must be an integer number of minor units', k;
    end if;
    return null;
  end if;
  if jsonb_typeof(e) <> 'number' then
    raise exception 'valuation.% must be a JSON number in minor units, got %', k, jsonb_typeof(e);
  end if;
  n := (e #>> '{}')::numeric;
  if n <> trunc(n) then
    raise exception 'valuation.% must be an INTEGER number of minor units, got %', k, n;
  end if;
  if n < 0 then
    raise exception 'valuation.% must not be negative, got %', k, n;
  end if;
  return n::bigint;
end $$;

create or replace function public.sigma_blu_fraction(v jsonb, k text)
returns numeric
language plpgsql
stable
as $$
declare
  e jsonb := v -> k;
  n numeric;
begin
  if e is null or jsonb_typeof(e) = 'null' then return null; end if;
  if jsonb_typeof(e) <> 'number' then
    raise exception 'valuation.% must be a JSON number (a fraction, 0.18 = 18%%), got %', k, jsonb_typeof(e);
  end if;
  n := (e #>> '{}')::numeric;
  if n < 0 or n > 1 then
    raise exception 'valuation.% must be a fraction between 0 and 1 (0.18 = 18%%), got %', k, n;
  end if;
  return n;
end $$;

revoke all on function public.sigma_blu_minor(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function public.sigma_blu_fraction(jsonb, text)       from public, anon, authenticated;
grant execute on function public.sigma_blu_minor(jsonb, text, boolean) to service_role;
grant execute on function public.sigma_blu_fraction(jsonb, text)       to service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6 · THE INTAKE RPC — now claims the key, allocates the number AND records the
--     valuation, all in the SAME transaction.
--
-- WHY THE VALUATION HAS TO BE IN HERE AND NOT IN A FOLLOW-UP PATCH
--   The claim is what decides which of two concurrent retries wins. If the
--   valuation were attached afterwards, a retry that crashed between the two would
--   leave a request holding an appraisal number — a number already handed to BLU
--   and already quotable to a bank — with no figures behind it, and the retry that
--   follows would take the fast path and never fill the gap. Writing it inside the
--   claim makes that state unreachable: either the row exists complete, or it does
--   not exist.
--
-- THE RESUME PATH. A row that already exists WITHOUT a valuation (it arrived before
--   BLU switched the feature on, or before this migration was applied) is filled in
--   when a valuation finally arrives under the same idempotency key. That is the
--   one and only NULL → value transition; the trigger above refuses every other.
--   The edge function knows to skip its fast path in exactly this case, so the
--   re-send actually reaches here.
--
-- Everything about the numbering is unchanged from SIGMA_blu_appraisal_requests.sql
-- — same claim, same allocator, same read-back. The long note above that version
-- explains why, and it still applies.
-- ═════════════════════════════════════════════════════════════════════════════
create or replace function public.sigma_blu_record_request(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_idem      text    := nullif(btrim(p->>'idempotency_key'), '');
  v_id        uuid;
  v_num       text;
  v_created   boolean := false;
  v_val       jsonb;
  v_has_val   boolean := false;
  v_val_done  boolean := false;
  v_now       timestamptz := now();
  -- the valuation, parsed ONCE, before anything is written
  v_lines     jsonb;
  v_cur       text;
  v_sub       bigint;
  v_avp       numeric;
  v_avm       bigint;
  v_pfmv      bigint;
  v_pevp      numeric;
  v_pev       bigint;
  v_prcv      bigint;
  v_rcs       text;
  v_sup       text;
begin
  if v_idem is null then
    raise exception 'idempotency_key is required';
  end if;

  -- ── VALIDATE the valuation, if one came ───────────────────────────────────
  -- Absent, JSON null and a missing member are all "not supplied" and are all
  -- fine. Anything else that is not an object is a malformed request, and half a
  -- valuation is worse than none: it is rejected outright rather than stored.
  if p ? 'valuation' and jsonb_typeof(p->'valuation') not in ('null') then
    if jsonb_typeof(p->'valuation') <> 'object' then
      raise exception 'valuation must be a JSON object or null, got %', jsonb_typeof(p->'valuation');
    end if;
    v_val := p->'valuation';
    v_has_val := true;

    v_cur := upper(btrim(coalesce(v_val->>'currency', '')));
    if v_cur !~ '^[A-Z]{3}$' then
      raise exception 'valuation.currency must be a 3-letter ISO 4217 code, got %', coalesce(v_val->>'currency', '(missing)');
    end if;

    v_lines := v_val->'lines';
    if v_lines is null or jsonb_typeof(v_lines) <> 'array' then
      raise exception 'valuation.lines must be an array (it may be empty), got %',
                      coalesce(jsonb_typeof(v_lines), '(missing)');
    end if;
    if jsonb_array_length(v_lines) > 200 then
      raise exception 'valuation.lines has % entries; the limit is 200', jsonb_array_length(v_lines);
    end if;

    -- Parsed here, once, so every raise happens BEFORE the claim rather than inside
    -- the INSERT's value list. Half a valuation is never written: a failure on the
    -- last field aborts before the first one has been stored.
    v_sub  := public.sigma_blu_minor(v_val, 'sub_total_minor',   true);
    v_avp  := public.sigma_blu_fraction(v_val, 'added_value_pct');
    v_avm  := public.sigma_blu_minor(v_val, 'added_value_minor', false);
    v_pfmv := public.sigma_blu_minor(v_val, 'pfmv_minor',        true);
    v_pevp := public.sigma_blu_fraction(v_val, 'pev_pct');
    v_pev  := public.sigma_blu_minor(v_val, 'pev_minor',         true);
    v_prcv := public.sigma_blu_minor(v_val, 'prcv_minor',        true);
    v_rcs  := left(nullif(btrim(coalesce(v_val->>'rate_card_source','')), ''), 300);
    v_sup  := left(nullif(btrim(coalesce(v_val->>'supersedes','')),       ''), 200);
  end if;

  -- ── CLAIM (+ the valuation, in the same statement) ────────────────────────
  insert into public.blu_appraisal_requests (
      source, received_at, status,
      requested_by_name, requested_by_role,
      reservation_ref, project_code, project_name,
      client_first_name, client_last_name, client_email, client_phone,
      lot_number, model_code, package_code,
      deliver_to_client, bank_contact_name, bank_contact_email,
      idempotency_key, raw,
      valuation_received_at, valuation_currency, valuation_lines,
      valuation_sub_total_minor, valuation_added_value_pct, valuation_added_value_minor,
      valuation_pfmv_minor, valuation_pev_pct, valuation_pev_minor, valuation_prcv_minor,
      valuation_rate_card_source, valuation_supersedes)
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
      p->'raw',
      -- §BLU-VALUATION — all twelve, or all NULL. Never a mixture: every one of these
      -- is NULL unless v_has_val, which is exactly what blu_requests_valuation_state_ck
      -- enforces at the table level.
      case when v_has_val then v_now else null end,
      v_cur, v_lines, v_sub, v_avp, v_avm, v_pfmv, v_pevp, v_pev, v_prcv, v_rcs, v_sup)
  on conflict (idempotency_key) do nothing
  returning id, appraisal_number, (valuation_received_at is not null)
       into v_id, v_num, v_val_done;

  if v_id is null then
    -- Another caller owns this key. `on conflict do nothing` already waited for
    -- that transaction to finish, so the row is visible; `for update` waits again
    -- if it is mid-allocation, which is what makes a repeat return the SAME
    -- number instead of racing to allocate a second one.
    select b.id, b.appraisal_number, (b.valuation_received_at is not null)
      into v_id, v_num, v_val_done
      from public.blu_appraisal_requests b
     where b.idempotency_key = v_idem
     for update;

    if v_id is null then
      raise exception 'sigma_blu_record_request: key % neither inserted nor found', v_idem;
    end if;

    -- RESUME the valuation: the row predates it, and one has now arrived. The only
    -- NULL → value transition the trigger permits, and it happens under the same
    -- row lock, so two retries cannot both write it.
    if v_has_val and not v_val_done then
      update public.blu_appraisal_requests
         set valuation_received_at       = v_now,
             valuation_currency          = v_cur,
             valuation_lines             = v_lines,
             valuation_sub_total_minor   = v_sub,
             valuation_added_value_pct   = v_avp,
             valuation_added_value_minor = v_avm,
             valuation_pfmv_minor        = v_pfmv,
             valuation_pev_pct           = v_pevp,
             valuation_pev_minor         = v_pev,
             valuation_prcv_minor        = v_prcv,
             valuation_rate_card_source  = v_rcs,
             valuation_supersedes        = v_sup
       where id = v_id
         and valuation_received_at is null;

      -- Read back rather than trust the write: the trigger is the authority on
      -- whether a valuation was actually accepted.
      select (b.valuation_received_at is not null) into v_val_done
        from public.blu_appraisal_requests b where b.id = v_id;
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

  return jsonb_build_object(
    'id',                 v_id,
    'appraisal_number',   v_num,
    'created',            v_created,
    -- The caller needs to tell "BLU sent no valuation" from "BLU sent one and it
    -- did not land". Absent from the old version, so an old deployment answering a
    -- valuation-carrying request is detectable by its ABSENCE.
    'valuation_supplied', v_has_val,
    'valuation_recorded', coalesce(v_val_done, false));
end $$;

-- Postgres grants EXECUTE to PUBLIC by default, and `create or replace` RESETS the
-- grants to that default. Re-apply them, or the anon key that ships in index.html
-- regains the two powers this whole design withholds.
revoke all on function public.sigma_blu_record_request(jsonb) from public, anon, authenticated;
grant execute on function public.sigma_blu_record_request(jsonb) to service_role;

-- PostgREST caches the column list as well as the function list. Without this,
-- every new column comes back as PGRST204 "column not found in the schema cache"
-- and the Developments panel reads a valuation that is sitting right there.
notify pgrst, 'reload schema';

-- ── VERIFY (read-only unless stated) ────────────────────────────────────────
--   -- the columns exist and are the right types
--   select column_name, data_type, numeric_precision, is_nullable
--     from information_schema.columns
--    where table_schema='public' and table_name='blu_appraisal_requests'
--      and column_name like 'valuation%'
--    order by ordinal_position;
--   -- expect 12 rows; every *_minor is bigint, both *_pct are numeric(9,6),
--   -- valuation_lines is jsonb, and all are nullable.
--
--   -- nothing already stored was disturbed
--   select count(*) as rows_total,
--          count(valuation_received_at) as rows_with_valuation
--     from public.blu_appraisal_requests;
--   -- rows_total unchanged from before this file; rows_with_valuation = 0.
--
--   -- who can call the intake RPC — expect service_role and NOTHING else:
--   select r.rolname, has_function_privilege(r.rolname, p.oid, 'execute')
--     from pg_proc p, (values ('anon'),('authenticated'),('service_role')) r(rolname)
--    where p.proname = 'sigma_blu_record_request';
--
--   -- a float where a minor unit belongs is REJECTED, not truncated:
--   select public.sigma_blu_minor('{"x":4962888.3}'::jsonb, 'x', true);
--   -- ERROR: valuation.x must be an INTEGER number of minor units, got 4962888.3
--   select public.sigma_blu_minor('{"x":"4962888"}'::jsonb, 'x', true);
--   -- ERROR: valuation.x must be a JSON number in minor units, got string
--   select public.sigma_blu_fraction('{"p":18}'::jsonb, 'p');
--   -- ERROR: valuation.p must be a fraction between 0 and 1 (0.18 = 18%), got 18
--
--   -- the two-state rule really holds (this INSERT must FAIL):
--   -- insert into public.blu_appraisal_requests (idempotency_key, valuation_pfmv_minor)
--   --   values ('probe-state', 1);      -- violates blu_requests_valuation_state_ck
--
--   -- and a recorded valuation cannot be rewritten (reports success, changes nothing):
--   -- update public.blu_appraisal_requests set valuation_pfmv_minor = 1
--   --  where valuation_received_at is not null;   -- then re-select and confirm
--
--   -- END TO END, rolled back — see step 3b of docs/blu-developments/DEPLOY_RUNBOOK.md

-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK — this file only. It leaves the numbering and the table itself alone,
-- because both were already live before it ran.
--
--   alter table public.blu_appraisal_requests
--     drop constraint if exists blu_requests_valuation_state_ck,
--     drop constraint if exists blu_requests_valuation_lines_ck,
--     drop constraint if exists blu_requests_valuation_currency_ck,
--     drop constraint if exists blu_requests_valuation_money_ck,
--     drop constraint if exists blu_requests_valuation_pct_ck;
--   drop index if exists public.blu_requests_valuation_idx;
--   alter table public.blu_appraisal_requests
--     drop column if exists valuation_received_at,
--     drop column if exists valuation_currency,
--     drop column if exists valuation_lines,
--     drop column if exists valuation_sub_total_minor,
--     drop column if exists valuation_added_value_pct,
--     drop column if exists valuation_added_value_minor,
--     drop column if exists valuation_pfmv_minor,
--     drop column if exists valuation_pev_pct,
--     drop column if exists valuation_pev_minor,
--     drop column if exists valuation_prcv_minor,
--     drop column if exists valuation_rate_card_source,
--     drop column if exists valuation_supersedes;
--   drop function if exists public.sigma_blu_minor(jsonb, text, boolean);
--   drop function if exists public.sigma_blu_fraction(jsonb, text);
--   -- then re-run the RPC + trigger halves of SIGMA_blu_appraisal_requests.sql to
--   -- put sigma_blu_record_request() and blu_requests_touch_updated_at() back to
--   -- their pre-valuation bodies, and finally:
--   notify pgrst, 'reload schema';
--
-- ⚠ DROPPING THE COLUMNS DESTROYS EVERY VALUATION RECEIVED. Export them first:
--   create table public.blu_valuation_backup_20260824 as
--     select id, appraisal_number, valuation_received_at, valuation_currency,
--            valuation_lines, valuation_sub_total_minor, valuation_added_value_pct,
--            valuation_added_value_minor, valuation_pfmv_minor, valuation_pev_pct,
--            valuation_pev_minor, valuation_prcv_minor, valuation_rate_card_source,
--            valuation_supersedes
--       from public.blu_appraisal_requests where valuation_received_at is not null;
-- ─────────────────────────────────────────────────────────────────────────────
