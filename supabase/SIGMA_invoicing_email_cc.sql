-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — Invoicing: CC recipients + a traceable invoice-sent log (§INVOICE-CC)
--
-- THE ASK. "When sending an invoice, send it to me and my daughter as well…
-- install an invoice-sent log, kept under each project, so we can always trace
-- back if an invoice was sent to a client."
--
-- invoice_emails (Phase 3) already recorded the invoice, the recipient, the kind,
-- the timestamp, the status, the provider message id and the error. Four things
-- were missing before it could answer the owner's question:
--
--   1. cc_emails    — Phase 3 has a `cc` TEXT column, which is fine for reading
--                     but useless for asking "was Seanna copied on this one?".
--                     The list is now stored as an ARRAY of exactly the addresses
--                     the mail server was actually handed. `cc` is still written
--                     as the human-readable join, so nothing that already reads it
--                     breaks.
--   2. cc_dropped   — addresses that were SUPPLIED but not used: malformed, a
--                     duplicate of the client, over the cap, or refused by the
--                     mail server. Without this the log would quietly imply a copy
--                     went out when it did not.
--   3. order_number — the log has to read "under each project". invoice_id is
--                     ON DELETE SET NULL, so joining through invoices loses the
--                     history exactly when someone is trying to trace it. The
--                     order number is denormalised onto the row instead.
--   4. warning      — the send succeeded but in a degraded way (the client got the
--                     invoice; the CC copy was refused). `error` keeps its single
--                     meaning: the invoice did NOT go out.
--
-- WHY NOT insp_data: none of this touches orders.insp_data. That column caused the
-- 2026-07-16 production outage and stays out of every new feature.
--
-- Idempotent, and safe on the live table: every statement is `if not exists` or a
-- default change. No existing row is rewritten and no column is dropped, renamed
-- or made NOT NULL, so this cannot fail against the rows already in the table.
--
-- Access is unchanged — invoice_emails is already reachable by anon and
-- authenticated through the invoice_emails_anon_all policy created in
-- SIGMA_invoicing_open_access.sql. Nothing here widens it.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. The columns ──────────────────────────────────────────────────────────
alter table public.invoice_emails add column if not exists cc_emails   text[];
alter table public.invoice_emails add column if not exists cc_dropped  text[];
alter table public.invoice_emails add column if not exists order_number text;
alter table public.invoice_emails add column if not exists warning     text;

-- No NOT NULL and no default on cc_emails: null means "this row predates the CC
-- feature and we do not know", '{}' means "we know: nothing was copied". Those are
-- different answers and the log must not conflate them.
comment on column public.invoice_emails.cc_emails is
  'CC addresses actually handed to the mail server. null = pre-v2.309 row (unknown); {} = no CC was sent.';
comment on column public.invoice_emails.cc_dropped is
  'Addresses supplied but NOT sent to: malformed, duplicate of the recipient, over the cap, or refused by the server.';
comment on column public.invoice_emails.order_number is
  'Denormalised from invoices.order_number so the history survives the invoice row (invoice_id is ON DELETE SET NULL).';
comment on column public.invoice_emails.warning is
  'Set when the send succeeded in a degraded way — e.g. the client was served but the CC copy was refused. error stays null.';

-- ── 2. Read the log by project ──────────────────────────────────────────────
-- The per-order panel asks exactly this: newest first, for one order number.
create index if not exists invoice_emails_order_idx
  on public.invoice_emails (order_number, created_at desc);

-- ── 3. Backfill order_number for the rows already there ─────────────────────
-- Only where it can be known for certain, from the invoice the row still points at.
-- Bounded and re-runnable: the `is null` guard means a second run touches nothing.
update public.invoice_emails e
   set order_number = i.order_number
  from public.invoices i
 where e.invoice_id = i.id
   and e.order_number is null;

-- ── 4. provider now means what it says ──────────────────────────────────────
-- The column defaulted to 'resend', which has never actually sent an invoice from
-- this system — mail has gone through the bureau's own SMTP mailbox since
-- 2026-07-30. The edge function now writes 'smtp' explicitly; the default is
-- corrected so a row written by anything else is not mislabelled either.
--
-- Existing rows are deliberately NOT rewritten. They say 'resend' because that is
-- what the column defaulted to when they were written, and a delivery log is not
-- something to retro-edit.
alter table public.invoice_emails alter column provider set default 'smtp';

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFY
--
--   select column_name, data_type
--     from information_schema.columns
--    where table_schema='public' and table_name='invoice_emails'
--      and column_name in ('cc','cc_emails','cc_dropped','order_number','warning');
--   -- expect 5 rows: cc text, cc_emails ARRAY, cc_dropped ARRAY,
--   --                order_number text, warning text
--
--   select count(*) filter (where order_number is not null) as backfilled,
--          count(*) as total
--     from public.invoice_emails;
--
-- ROLLBACK
--
--   drop index if exists public.invoice_emails_order_idx;
--   alter table public.invoice_emails alter column provider set default 'resend';
--   alter table public.invoice_emails drop column if exists warning;
--   alter table public.invoice_emails drop column if exists order_number;
--   alter table public.invoice_emails drop column if exists cc_dropped;
--   alter table public.invoice_emails drop column if exists cc_emails;
--
-- Dropping those columns DESTROYS the record of who was copied on invoices already
-- sent. Roll the edge function back to v4 first; only drop the columns if the
-- feature is being abandoned outright.
-- ─────────────────────────────────────────────────────────────────────────────
