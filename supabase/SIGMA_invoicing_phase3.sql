-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — Invoicing, Phase 3 (invoice email delivery)
--
-- Records every attempt to email an invoice. The row is written by the
-- sigma-email edge function (service role); the app reads it to show history.
--
-- The invoice is marked emailed ONLY when the provider (Resend) accepts the
-- message — the function writes status='sent' with the provider message id, or
-- status='failed' with the error. It never claims a send that did not happen.
--
-- Access: authenticated only, matching the rest of Finance (Option A).
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.invoice_emails (
  id                uuid primary key default gen_random_uuid(),
  org_id            text not null default 'sigma',
  invoice_id        uuid references public.invoices(id) on delete set null,
  invoice_number    text,
  kind              text not null default 'invoice',   -- invoice|reminder|overdue|receipt|statement
  recipient         text not null,
  cc                text,
  subject           text,
  body              text,
  attachment_name   text,
  status            text not null default 'queued',    -- queued|sent|failed
  provider          text default 'resend',
  provider_msg_id   text,
  error             text,
  sent_by           text,
  created_at        timestamptz not null default now(),
  sent_at           timestamptz
);
create index if not exists invoice_emails_invoice_idx on public.invoice_emails (invoice_id, created_at desc);
create index if not exists invoice_emails_created_idx on public.invoice_emails (created_at desc);

alter table public.invoice_emails enable row level security;
drop policy if exists invoice_emails_auth on public.invoice_emails;
create policy invoice_emails_auth on public.invoice_emails
  for all to authenticated using (true) with check (true);
