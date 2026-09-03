-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SIGMA — storage access for SIGNED-IN users  (§STORAGE-AUTH, v2.405)         ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- REPORTED: generating a report showed "Could not stage report (new row violates
-- row-level security policy) — is the public 'reports' bucket set up?", and the PDF
-- button stayed dark.
--
-- CAUSE, and it was self-inflicted. Every storage policy for the two SIGMA buckets was
-- written for the `anon` role, because SIGMA reached the database with the anon key:
--
--     sigma_reports_anon_write   ALL   {anon}   bucket_id = 'reports'
--     sigma_anon_storage_all     ALL   {anon}   bucket_id = 'Storage'
--
-- On 2026-09-03 the owner's Supabase Auth password was repaired so that sign-in would
-- produce a real session — which the contractor/field-work feature requires. From that
-- moment the app's requests carried a JWT, so PostgREST and Storage saw the role as
-- `authenticated` rather than `anon`. Postgres policies do NOT cascade between roles:
-- `TO anon` does not include an authenticated user. Every policy stopped matching, and
-- the first write to hit it — staging the report HTML — was refused.
--
-- Nothing was wrong with the bucket, and nothing was wrong with the report. Fixing one
-- thing (sign-in) broke another that quietly depended on being signed OUT.
--
-- THE FIX IS ADDITIVE. A signed-in user is granted exactly what anon already had. The
-- anon policies are left in place, so anyone still on the local-password path keeps
-- working; policies are OR'd, so having both is simply "either role may". No access is
-- widened: `reports` is a public bucket, and `Storage` already granted anon full access
-- through "app all Storage" anyway.

begin;

drop policy if exists sigma_reports_auth_write on storage.objects;
create policy sigma_reports_auth_write on storage.objects
  for all to authenticated
  using (bucket_id = 'reports') with check (bucket_id = 'reports');

drop policy if exists sigma_storage_auth_all on storage.objects;
create policy sigma_storage_auth_all on storage.objects
  for all to authenticated
  using (bucket_id = 'Storage') with check (bucket_id = 'Storage');

commit;

-- ── THE LESSON, worth leaving here ───────────────────────────────────────────
-- SIGMA is mid-migration between two auth models: local SHA-256 passwords with the
-- anon key, and real Supabase Auth sessions. Any policy written for exactly one of
-- those roles will break for whichever users are on the other side. Until the legacy
-- anon path is retired, every policy on this project should name BOTH roles —
-- `to anon, authenticated` — or the next account repaired will break the next feature.
