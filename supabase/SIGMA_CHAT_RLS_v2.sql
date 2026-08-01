-- ============================================================================
--  SIGMA_CHAT_RLS_v2.sql   —   FOR REVIEW ONLY.  NOT RUN.  NOT REQUIRED.
--  §CHAT-ANONDB (v2.297)
-- ============================================================================
--
--  WHY THIS EXISTS
--  ---------------
--  public.messages has exactly one RLS policy:
--
--      sigma_anon_chat_all   FOR ALL   TO anon   USING (true)   WITH CHECK (true)
--
--  A policy bound `TO anon` does not apply to role `authenticated`. There is no
--  policy for `authenticated` on this table at all, so RLS denies that role
--  everything — INSERT *and* SELECT. Verified read-only against the live
--  project (cimgpycjczatjzltgscf) on 2026-08-01:
--
--      set local role anon;           select count(*) from public.messages;  -> 2
--      set local role authenticated;  select count(*) from public.messages;  -> 0
--
--  The app's main Supabase client is created with persistSession:true and
--  autoRefreshToken:true. Any user who has ever signed in through Supabase Auth
--  keeps a live, self-refreshing session in localStorage, so every PostgREST
--  call from that browser goes out as role `authenticated` — and was silently
--  refused by RLS. That is why one user could send and another could not:
--  same build, same payload, different database role.
--
--
--  IS THIS SCRIPT NEEDED?
--  ----------------------
--  No. v2.297 fixes the problem entirely in the client (§CHAT-ANONDB): Team Chat
--  now uses its own session-less Supabase client, so it always presents the anon
--  key and always runs as role `anon` — the role the existing policy covers —
--  for every member of staff, cloud-authenticated or local-only.
--
--  This script is offered only as the DB-side alternative / belt-and-braces. It
--  makes the table behave sanely for `authenticated` as well, which protects any
--  FUTURE code path that reaches `messages` through the main client. Running it
--  is safe and changes nothing for anyone who works today.
--
--  Review it before running. Run it in the Supabase SQL editor.
--
-- ============================================================================

begin;

-- Keep the existing anon policy exactly as it is; simply extend the same
-- open-team-chat rule to signed-in users too. Team Chat is a single shared room
-- for staff, so the rule is intentionally the same for both roles.
drop policy if exists sigma_auth_chat_all on public.messages;

create policy sigma_auth_chat_all
  on public.messages
  for all
  to authenticated
  using (true)
  with check (true);

-- `authenticated` already holds the table grants (verified 2026-08-01), so no
-- GRANT is required. Listed here only so a reviewer can confirm it:
--   grant select, insert, update, delete on public.messages to authenticated;
--   grant usage, select on sequence public.messages_id_seq to authenticated;

commit;


-- ---------------------------------------------------------------------------
--  VERIFY (read-only) after running:
-- ---------------------------------------------------------------------------
--  select policyname, roles::text, cmd, qual, with_check
--    from pg_policies where schemaname='public' and tablename='messages';
--  -- expect two rows: sigma_anon_chat_all {anon}, sigma_auth_chat_all {authenticated}
--
--  set local role authenticated; select count(*) from public.messages;  -- expect 2
-- ---------------------------------------------------------------------------
