-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SIGMA — percentage discounts keep 4 decimals  (§DISC-4DP, v2.761)           ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- REPORTED (5 Nov 2026, invoice 2026-173): subtotal 2,466.79 had to become 1,500.00,
-- which needs a 39.1921 % discount. The box would not take it, and what was saved
-- came back as 39.19 % — total 1,500.05, not 1,500.00.
--
-- ROOT CAUSE. invoices.discount_value is numeric(12,2) and sigma_set_invoice_discount
-- rounds p_value to 2 decimals before writing it. Two decimals are right for an
-- AMOUNT, but a PERCENTAGE needs more to land on an exact total.
--
-- FIX. discount_value becomes numeric(14,4) (same whole-number range as before, two
-- more decimals) and the RPC rounds to 4. sigma_invoice_recalc already rounds the
-- resulting discount_amount to cents, so totals stay in cents.
--
-- public.invoices_v reads the column, and Postgres refuses to retype a column a view
-- uses, so the view is dropped and recreated from its OWN current definition in the
-- same transaction, and its grants are put back exactly as they were
-- (anon/authenticated = INSERT, SELECT, UPDATE, DELETE, MAINTAIN; service_role = ALL).
-- No row data changes: every stored value keeps its value (39.19 stays 39.19).

begin;

do $$
declare
  v_def text;
  f_old text;
  f_new text;
begin
  v_def := pg_get_viewdef('public.invoices_v'::regclass, true);
  execute 'drop view public.invoices_v';
  execute 'alter table public.invoices alter column discount_value type numeric(14,4)';
  execute 'create view public.invoices_v as ' || v_def;

  f_old := pg_get_functiondef('public.sigma_set_invoice_discount'::regproc);
  f_new := replace(f_old, 'round(coalesce(p_value,0), 2)', 'round(coalesce(p_value,0), 4)');
  if f_new = f_old then
    raise exception 'sigma_set_invoice_discount: rounding expression not found, nothing changed';
  end if;
  execute f_new;
end $$;

alter view public.invoices_v owner to postgres;
grant insert, select, update, delete, maintain on public.invoices_v to anon, authenticated;
grant all on public.invoices_v to service_role;

commit;

-- Check afterwards:
--   select format_type(atttypid, atttypmod) from pg_attribute
--    where attrelid = 'public.invoices'::regclass and attname = 'discount_value';
--   -- expect numeric(14,4)
