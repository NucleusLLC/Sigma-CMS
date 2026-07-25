-- ─────────────────────────────────────────────────────────────────────────────
-- SIGMA-CMS — Invoicing: remove the separate cloud sign-in (v2.278)
--
-- The finance tables were authenticated-only (Option A), which forced a SECOND
-- sign-in on top of the app's normal login. Every other table in this app
-- (orders, contacts, report_templates, messages) is reachable with the app's
-- normal access, so Finance is now made consistent with them: reachable through
-- the standard app login, no separate cloud session required.
--
-- This grants the `anon` role (the key the app ships with) the same access the
-- rest of the app already has. Trade-off, stated plainly: like orders/contacts,
-- finance data is then readable by anyone holding that public key. The invoices
-- carry the same client + fee information those tables already expose.
-- ─────────────────────────────────────────────────────────────────────────────

do $$
declare t text;
begin
  foreach t in array array[
    'invoices','invoice_lines','payments','payment_allocations',
    'payment_receipts','invoice_emails','client_statements','finance_audit_events'
  ] loop
    execute format('drop policy if exists %I on public.%I', t||'_anon_all', t);
    execute format(
      'create policy %I on public.%I for all to anon, authenticated using (true) with check (true)',
      t||'_anon_all', t);
  end loop;
end $$;

-- Functions: allow the app (anon) to call them, same as authenticated.
grant execute on function public.sigma_create_invoice_from_order(text,jsonb,date,text,text,text,jsonb) to anon;
grant execute on function public.sigma_finalize_invoice(uuid,text)              to anon;
grant execute on function public.sigma_void_invoice(uuid,text,text)             to anon;
grant execute on function public.sigma_invoice_recalc(uuid)                     to anon;
grant execute on function public.sigma_post_payment(uuid,numeric,date,text,text,text,text) to anon;
grant execute on function public.sigma_reverse_payment(uuid,text,text)          to anon;
grant execute on function public.sigma_next_receipt_number(int)                 to anon;
grant execute on function public.sigma_invoice_apply_payments(uuid)             to anon;
grant execute on function public.sigma_finance_summary(date,date)               to anon;
grant execute on function public.sigma_next_statement_number(int)               to anon;

-- Views used by the reports/statements.
grant select on public.invoices_v  to anon;
grant select on public.payments_v  to anon;
grant select on public.ar_aging_v  to anon;
