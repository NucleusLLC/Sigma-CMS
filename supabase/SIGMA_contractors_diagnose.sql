-- ════════════════════════════════════════════════════════════════════════════════
--  SIGMA — why does a job order read NOT PAID?   (READ ONLY — changes nothing)
--
--  Run the whole thing. It returns ONE grid with five labelled sections, so the
--  question can be answered without running five separate queries.
--
--  HOW TO READ IT
--
--  1  PAYOUTS BY STATUS
--       Any `draft` row is a payout that was created and never marked paid. If the
--       money for it has already been transferred, that ALONE explains everything:
--       until it is marked paid, SIGMA prints the consultant a document headed
--       "STATEMENT OF WORK … Not yet paid", and every job order on it reads NOT PAID.
--       This is the likeliest answer.
--
--  2  WORK ROWS PER CONSULTANT
--       Before v2.491 the panel read only the newest 300 rows, oldest PAID work cut
--       first. Anyone over 300 here was being shown a false NOT PAID on their older
--       jobs. That is already fixed in the app — this just says whether it was hitting.
--
--  3  WORK BY STATUS
--       `done` = finished and owed, not yet paid out. A large number here with few or
--       no payouts in section 1 means the work was never billed through SIGMA at all.
--
--  4  DONE AND OWED, NEVER PUT ON A PAYOUT
--       The individual job orders behind section 3. If the consultant was paid for
--       these in cash or by transfer without a payout being raised, SIGMA has no way
--       to know, and NOT PAID is the honest answer to what it was told.
--
--  5  PAYOUTS IN DETAIL
--       Number, status, date and total — to match against whatever document the
--       consultant is holding.
-- ════════════════════════════════════════════════════════════════════════════════

with c as (
  select id, full_name from public.contractors
), w as (
  select wi.*, c.full_name from public.work_items wi left join c on c.id = wi.contractor_id
), p as (
  select po.*, c.full_name from public.contractor_payouts po left join c on c.id = po.contractor_id
)
select section, who, detail, n, amount from (

  select 1 as ord,
         '1 PAYOUTS BY STATUS'::text                      as section,
         coalesce(full_name, '(no consultant)')::text      as who,
         status::text                                      as detail,
         count(*)::text                                    as n,
         to_char(coalesce(sum(total), 0), 'FM999999990.00')::text as amount
    from p group by 1, 2, 3, 4

  union all
  select 2, '2 WORK ROWS PER CONSULTANT (over 300 = the old cap was hiding paid work)',
         coalesce(full_name, '(no consultant)'), 'non-void rows',
         count(*)::text, to_char(coalesce(sum(amount), 0), 'FM999999990.00')
    from w where status <> 'void' group by 1, 2, 3, 4

  union all
  select 3, '3 WORK BY STATUS', coalesce(full_name, '(no consultant)'), status,
         count(*)::text, to_char(coalesce(sum(amount), 0), 'FM999999990.00')
    from w group by 1, 2, 3, 4

  union all
  select 4, '4 DONE AND OWED, NEVER PUT ON A PAYOUT', coalesce(full_name, '(no consultant)'),
         order_number || ' · ' || task_code, '1', to_char(amount, 'FM999999990.00')
    from w where status = 'done' and payout_id is null

  union all
  select 5, '5 PAYOUTS IN DETAIL', coalesce(full_name, '(no consultant)'),
         payout_number || ' · ' || status || coalesce(' · paid ' || payout_date::text, ''),
         '1', to_char(total, 'FM999999990.00')
    from p

) x order by ord, who, detail;
