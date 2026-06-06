// ============================================================================
// Supabase Edge Function: sigma-metrics  (v2 — rates + Postgres health)
// ----------------------------------------------------------------------------
// Proxies the project's PRIVILEGED Prometheus metrics endpoint
//   https://<ref>.supabase.co/customer/v1/privileged/metrics
// (requires service_role + not CORS-enabled). The service_role key lives ONLY
// here as a server-side secret and is NEVER sent to the browser.
//
// Counters (CPU, disk IO, throughput, transactions) are rates, so this takes
// TWO scrapes ~1s apart and returns the per-second delta. Point-in-time gauges
// (memory, disk space, connections, cache-hit) come from the 2nd scrape.
//
// Secrets required:  SIGMA_PROJECT_REF , SIGMA_SERVICE_ROLE_KEY
// Debug:  add ?raw=1 to get the full list of metric base-names (for mapping).
// ============================================================================

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type Sample = { labels: string; v: number };
type Map = Record<string, Sample[]>;

function parseProm(text: string): Map {
  const out: Map = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line[0] === "#") continue;
    const sp = line.lastIndexOf(" ");
    if (sp < 0) continue;
    const full = line.slice(0, sp);
    const v = parseFloat(line.slice(sp + 1));
    if (!isFinite(v)) continue;
    const brace = full.indexOf("{");
    const base = brace < 0 ? full : full.slice(0, brace);
    const labels = brace < 0 ? "" : full.slice(brace);
    (out[base] = out[base] || []).push({ labels, v });
  }
  return out;
}

const sumAll = (m: Map, b: string) => (m[b] ? m[b].reduce((a, s) => a + s.v, 0) : null);
const first = (m: Map, b: string) => (m[b] && m[b].length ? m[b][0].v : null);
const maxAll = (m: Map, b: string) => (m[b] ? Math.max(...m[b].map((s) => s.v)) : null);
const sumWhere = (m: Map, b: string, needle: string) =>
  m[b] ? m[b].filter((s) => s.labels.includes(needle)).reduce((a, s) => a + s.v, 0) : null;
// first non-null of several candidate metric names
const pick = (fn: (b: string) => number | null, ...names: string[]) => {
  for (const n of names) { const v = fn(n); if (v != null) return v; }
  return null;
};

async function scrape(url: string, auth: string) {
  const res = await fetch(url, { headers: { Authorization: auth } });
  if (!res.ok) { const b = await res.text(); throw new Error(`metrics ${res.status}: ${b.slice(0, 200)}`); }
  return { t: Date.now(), m: parseProm(await res.text()) };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const ref = Deno.env.get("SIGMA_PROJECT_REF");
  const key = Deno.env.get("SIGMA_SERVICE_ROLE_KEY");
  if (!ref || !key) return json({ error: "Missing SIGMA_PROJECT_REF or SIGMA_SERVICE_ROLE_KEY secret." }, 500);

  const url = `https://${ref}.supabase.co/customer/v1/privileged/metrics`;
  const auth = "Basic " + btoa("service_role:" + key);

  try {
    const s1 = await scrape(url, auth);

    // ?raw=1 → just the metric names, so we can verify/adjust the mapping.
    if (new URL(req.url).searchParams.get("raw")) {
      return json({ ok: true, metricCount: Object.keys(s1.m).length, names: Object.keys(s1.m).sort() });
    }

    await new Promise((r) => setTimeout(r, 1000));
    const s2 = await scrape(url, auth);
    const dt = (s2.t - s1.t) / 1000 || 1;
    const rate = (b: string) => {
      const a = sumAll(s1.m, b), z = sumAll(s2.m, b);
      return a != null && z != null ? Math.max(0, (z - a) / dt) : null;
    };

    // CPU% = 1 - idle_delta / total_delta  (across all cores/modes)
    let cpu: number | null = null;
    if (s1.m["node_cpu_seconds_total"] && s2.m["node_cpu_seconds_total"]) {
      const i1 = sumWhere(s1.m, "node_cpu_seconds_total", 'mode="idle"');
      const i2 = sumWhere(s2.m, "node_cpu_seconds_total", 'mode="idle"');
      const t1 = sumAll(s1.m, "node_cpu_seconds_total");
      const t2 = sumAll(s2.m, "node_cpu_seconds_total");
      if (i1 != null && i2 != null && t1 != null && t2 != null && t2 - t1 > 0) {
        cpu = Math.max(0, Math.min(100, 100 * (1 - (i2 - i1) / (t2 - t1))));
      }
    }

    // Disk IO busy% = max per-device io_time delta / elapsed
    let diskBusy: number | null = null;
    const IO = "node_disk_io_time_seconds_total";
    if (s1.m[IO] && s2.m[IO]) {
      const byDev = (m: Map) => { const o: Record<string, number> = {}; (m[IO] || []).forEach((s) => (o[s.labels] = s.v)); return o; };
      const a = byDev(s1.m), z = byDev(s2.m); let mx = 0;
      for (const k in z) if (a[k] != null) { const u = (z[k] - a[k]) / dt; if (u > mx) mx = u; }
      diskBusy = Math.max(0, Math.min(100, mx * 100));
    }

    // Memory / disk space (gauges, from 2nd scrape)
    const memTotal = first(s2.m, "node_memory_MemTotal_bytes");
    const memAvail = first(s2.m, "node_memory_MemAvailable_bytes");
    const fsSize = maxAll(s2.m, "node_filesystem_size_bytes");
    const fsAvail = maxAll(s2.m, "node_filesystem_avail_bytes");

    // Postgres health
    const hit = sumAll(s2.m, "pg_stat_database_blks_hit");
    const rd = sumAll(s2.m, "pg_stat_database_blks_read");
    const cacheHit = hit != null && rd != null && hit + rd > 0 ? (100 * hit) / (hit + rd) : null;
    const tps = (() => { const c = rate("pg_stat_database_xact_commit"), r = rate("pg_stat_database_xact_rollback"); return c == null && r == null ? null : (c || 0) + (r || 0); })();

    return json({
      ok: true,
      cpu,
      memory: memTotal != null ? { total: memTotal, available: memAvail, used: memAvail != null ? memTotal - memAvail : null } : null,
      disk: fsSize != null ? { total: fsSize, available: fsAvail, used: fsAvail != null ? fsSize - fsAvail : null } : null,
      diskIo: { busyPct: diskBusy, readBps: rate("node_disk_read_bytes_total"), writeBps: rate("node_disk_written_bytes_total") },
      network: { outBps: rate("node_network_transmit_bytes_total"), inBps: rate("node_network_receive_bytes_total") },
      load: { load1: first(s2.m, "node_load1"), load5: first(s2.m, "node_load5"), load15: first(s2.m, "node_load15") },
      connections: pick((b) => sumAll(s2.m, b), "pg_stat_database_numbackends", "pg_stat_database_num_backends", "pg_stat_activity_count"),
      maxConnections: pick((b) => maxAll(s2.m, b), "pg_settings_max_connections"),
      pg: {
        cacheHitPct: cacheHit,
        tps,
        rollbacks: sumAll(s2.m, "pg_stat_database_xact_rollback"),
        deadlocks: sumAll(s2.m, "pg_stat_database_deadlocks"),
      },
      metricCount: Object.keys(s2.m).length,
      sampledMs: s2.t - s1.t,
    });
  } catch (e) {
    return json({ error: String((e && (e as Error).message) || e) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });
}
