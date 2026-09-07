-- ════════════════════════════════════════════════════════════════════════════
--  SIGMA_inquiry_attribution.sql
--  §ADS-ATTRIB — record WHERE an enquiry came from, so advertising spend can be
--  measured against work won instead of merely sitting beside it.
--
--  WHY
--    Every row in `inquiries` today carries source = 'website'. Nothing marks a
--    lead as having arrived from a Meta campaign, so the Online AD Management
--    panel can only place spend and enquiries side by side and say plainly that
--    the two are not linked. These columns are what turn that into a count.
--
--  SHAPE OF THE CHANGE — additive and nullable, per the migration policy:
--    · No existing column is altered, renamed, retyped or dropped.
--    · Every new column is NULLABLE with no default, so every one of the 42 rows
--      already in the table stays exactly as it is and reads NULL — which is the
--      truth: their origin was never recorded and cannot be reconstructed.
--    · Nothing in the live app selects * and depends on column count.
--    · Reversal is at the bottom and drops only what this file added.
--
--  WHAT IT DOES NOT DO
--    It does not backfill. An enquiry from before this ships has no recoverable
--    source, and inventing one would put a fabricated number in a report about
--    money. They stay NULL and the panel counts them as "origin not recorded".
--
--  BLIND SPOT, STATED ON PURPOSE
--    UTM tags travel on a LINK. An Instagram DM does not carry one, so leads that
--    arrive by messaging can never populate these columns automatically. On the
--    campaign measured on 2026-09-07 that was 2 conversations at USD 34.82 each —
--    the two most expensive interactions it produced. Those must be marked by
--    hand or they stay invisible.
-- ════════════════════════════════════════════════════════════════════════════

begin;

alter table public.inquiries add column if not exists utm_source   text;
alter table public.inquiries add column if not exists utm_medium   text;
alter table public.inquiries add column if not exists utm_campaign text;
alter table public.inquiries add column if not exists utm_content  text;
alter table public.inquiries add column if not exists referrer     text;
alter table public.inquiries add column if not exists landing_url  text;

comment on column public.inquiries.utm_source   is 'utm_source from the landing URL, e.g. "meta". NULL = origin was not recorded.';
comment on column public.inquiries.utm_medium   is 'utm_medium, e.g. "paid_social".';
comment on column public.inquiries.utm_campaign is 'utm_campaign — the Meta campaign name or id the click came from.';
comment on column public.inquiries.utm_content  is 'utm_content — placement or creative, e.g. "stories".';
comment on column public.inquiries.referrer     is 'document.referrer at the time the form was opened.';
comment on column public.inquiries.landing_url  is 'the full first URL of the visit, kept so a tag can be re-read if the parse was wrong.';

-- The panel filters by source over a date window; this is the index that serves it.
-- Partial, because the overwhelming majority of rows will never carry a tag and
-- there is no reason to index NULLs.
create index if not exists inquiries_utm_source_created_idx
  on public.inquiries (utm_source, created_at desc)
  where utm_source is not null;

commit;

-- ════════════════════════════════════════════════════════════════════════════
--  REVERSAL — written before the change was applied, per the migration policy.
--  Drops only what this file created. No data other than these columns' own
--  contents is touched, and nothing that existed before this file is affected.
--
--  begin;
--  drop index if exists public.inquiries_utm_source_created_idx;
--  alter table public.inquiries drop column if exists landing_url;
--  alter table public.inquiries drop column if exists referrer;
--  alter table public.inquiries drop column if exists utm_content;
--  alter table public.inquiries drop column if exists utm_campaign;
--  alter table public.inquiries drop column if exists utm_medium;
--  alter table public.inquiries drop column if exists utm_source;
--  commit;
-- ════════════════════════════════════════════════════════════════════════════
