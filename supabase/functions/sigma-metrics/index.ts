// ============================================================================
// Supabase Edge Function: sigma-metrics
// ----------------------------------------------------------------------------
// Proxies the project's PRIVILEGED Prometheus metrics endpoint
//   https://<ref>.supabase.co/customer/v1/privileged/metrics
// which requires the service_role key + is NOT CORS-enabled, so it can NEVER be
// called from the public single-file app. This function holds the key as a
// server-side SECRET (env var) and returns a small curated JSON the Dashboard
// can render. The service_role key is NEVER sent to the browser.
//
// Secrets required (set via: supabase secrets set ...):
//   SIGMA_PROJECT_REF        e.g. cimgpycjczatjzltgscf
//   SIGMA_SERVICE_ROLE_KEY   the project's service_role JWT
// (Custom secret names — Supabase reserves the SUPABASE_ prefix.)
// ============================================================================

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Parse Prometheus text exposition into base-name -> [sample values].
function parseProm(text: string): Record<string, number[]> {
  const out: Record<string, number[]> = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line[0] === "#") continue;
    const sp = line.lastIndexOf(" ");
    if (sp < 0) continue;
    const full = line.slice(0, sp);
    const val = parseFloat(line.slice(sp + 1));
    if (!isFinite(val)) continue;
    const brace = full.indexOf("{");
    const base = brace < 0 ? full : full.slice(0, brace);
    (out[base] = out[base] || []).push(val);
  }
  return out;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const ref = Deno.env.get("SIGMA_PROJECT_REF");
  const key = Deno.env.get("SIGMA_SERVICE_ROLE_KEY");
  if (!ref || !key) {
    return json({ error: "Missing SIGMA_PROJECT_REF or SIGMA_SERVICE_ROLE_KEY secret." }, 500);
  }

  try {
    const url = `https://${ref}.supabase.co/customer/v1/privileged/metrics`;
    const auth = "Basic " + btoa("service_role:" + key);
    const res = await fetch(url, { headers: { Authorization: auth } });
    if (!res.ok) {
      const body = await res.text();
      return json({ error: `metrics endpoint ${res.status}`, detail: body.slice(0, 300) }, 502);
    }

    const m = parseProm(await res.text());
    const one = (b: string) => (m[b] && m[b].length ? m[b][0] : null);
    const sum = (b: string) => (m[b] ? m[b].reduce((a, c) => a + c, 0) : null);
    const max = (b: string) => (m[b] ? Math.max(...m[b]) : null);

    const memTotal = one("node_memory_MemTotal_bytes");
    const memAvail = one("node_memory_MemAvailable_bytes");
    const fsSize = max("node_filesystem_size_bytes");
    const fsAvail = max("node_filesystem_avail_bytes");

    return json({
      ok: true,
      memory: memTotal != null
        ? { total: memTotal, available: memAvail, used: memAvail != null ? memTotal - memAvail : null }
        : null,
      disk: fsSize != null
        ? { total: fsSize, available: fsAvail, used: fsAvail != null ? fsSize - fsAvail : null }
        : null,
      load: { load1: one("node_load1"), load5: one("node_load5"), load15: one("node_load15") },
      connections: sum("pg_stat_database_num_backends"),
      maxConnections: max("pg_settings_max_connections"),
      metricCount: Object.keys(m).length,
    });
  } catch (e) {
    return json({ error: String((e && (e as Error).message) || e) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}
