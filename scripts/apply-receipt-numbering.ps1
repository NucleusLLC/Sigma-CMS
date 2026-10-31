# apply-receipt-numbering.ps1 — applies supabase/SIGMA_receipt_number_jobno.sql to the LIVE
# Sigma-CMS database (project cimgpycjczatjzltgscf) through the Supabase Management API,
# then prints a read-only dry run of the new numbering.
#   pwsh -File scripts/apply-receipt-numbering.ps1            # apply + verify
#   pwsh -File scripts/apply-receipt-numbering.ps1 -VerifyOnly
# The personal access token is read from Windows Credential Manager ("Supabase CLI:supabase").
param([switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
$sig = @'
using System; using System.Runtime.InteropServices;
public class SigmaCredRead {
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredReadW(string target, int type, int flags, out IntPtr cred);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr cred);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct CREDENTIAL { public int Flags; public int Type; public string TargetName; public string Comment; public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist; public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName; }
  public static string Get(string target){ IntPtr p; if(!CredReadW(target,1,0,out p)) return null; var c=(CREDENTIAL)Marshal.PtrToStructure(p,typeof(CREDENTIAL)); var b=new byte[c.CredentialBlobSize]; Marshal.Copy(c.CredentialBlob,b,0,b.Length); CredFree(p); return System.Text.Encoding.UTF8.GetString(b); }
}
'@
if (-not ('SigmaCredRead' -as [type])) { Add-Type -TypeDefinition $sig }
$t = [SigmaCredRead]::Get('Supabase CLI:supabase')
if (-not $t) { throw 'Supabase token not found in Credential Manager (target "Supabase CLI:supabase").' }
$uri = 'https://api.supabase.com/v1/projects/cimgpycjczatjzltgscf/database/query'
function Q($sql) { Invoke-RestMethod -Uri $uri -Method Post -Headers @{Authorization = "Bearer $t"} -ContentType 'application/json' -Body (@{query = $sql} | ConvertTo-Json) }

if (-not $VerifyOnly) {
  $sql = Get-Content -Raw (Join-Path $PSScriptRoot '..\supabase\SIGMA_receipt_number_jobno.sql')
  $r = Q $sql
  Write-Host ('applied: ' + ($r | ConvertTo-Json -Compress))
}
$v = Q @"
select public.sigma_next_receipt_number_for('2026-178') as next_178,
       public.sigma_next_receipt_number_for('2026-179') as next_179,
       (select count(*) from public.payment_receipts) as receipts_so_far,
       position('sigma_next_receipt_number_for' in pg_get_functiondef('public.sigma_post_payment'::regproc)) > 0 as post_payment_wired;
"@
Write-Host ('verify: ' + ($v | ConvertTo-Json -Compress))
Write-Host 'Expected: next_178 = 2026-178-R2 (RCP-2026-065 already exists on it), next_179 = 2026-179-R1, post_payment_wired = true. Nothing was written by the verify step.'
