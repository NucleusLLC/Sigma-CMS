# Deploy the `sigma-metrics` Edge Function

This function lets the Dashboard show CPU/disk/memory/connection metrics WITHOUT
ever putting the `service_role` key in the public app. The key lives only as a
server-side secret inside this function.

## One-time setup

### A) Install the Supabase CLI (if you don't have it)
- Windows (PowerShell, with Scoop):
  ```powershell
  scoop install supabase
  ```
  …or download from https://github.com/supabase/cli/releases and put `supabase.exe` on your PATH.

### B) Log in + link the project
```powershell
supabase login                       # opens browser, paste the access token
supabase link --project-ref cimgpycjczatjzltgscf
```
(Run these from `C:\Users\greg\CascadeProjects\AppraisalSuite\sigma-deploy`, which
now contains the `supabase\functions\sigma-metrics` folder.)

### C) Set the two secrets
Get the **service_role** key from: Supabase Dashboard → Project Settings → API →
`service_role` (the secret one, NOT anon).
```powershell
supabase secrets set SIGMA_PROJECT_REF=cimgpycjczatjzltgscf
supabase secrets set SIGMA_SERVICE_ROLE_KEY="<paste service_role JWT here>"
```

### D) Deploy
```powershell
supabase functions deploy sigma-metrics
```

> If you prefer the function be callable with just the anon key (it is, by
> default — the app already sends the anon JWT), no extra flags are needed.
> Do NOT add `--no-verify-jwt` unless you want it fully public.

## Enable the privileged metrics endpoint
The endpoint `…/customer/v1/privileged/metrics` is available on paid plans. Your
project is on **Small** compute, so it works. If the function returns
`metrics endpoint 401/403`, double-check the service_role key.

## Test
```powershell
curl -i "https://cimgpycjczatjzltgscf.supabase.co/functions/v1/sigma-metrics" `
  -H "Authorization: Bearer <anon-key>" -H "apikey: <anon-key>"
```
You should get JSON with `memory`, `disk`, `load`, `connections`.

## What the Dashboard does
The "Database & Storage Monitor" card calls this function on **Refresh**. If the
function isn't deployed yet, the card still shows all the DB + Storage data (via
the anon key + `sigma_db_stats()` RPC) and just notes that infra metrics are
unavailable. So deploying this is OPTIONAL — deploy it when you want the
CPU/disk/connection panel to light up.
