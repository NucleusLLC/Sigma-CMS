// ─────────────────────────────────────────────────────────────────────────────
// website-intake — receives inquiries from taxatie-bureau.com and records them
// in public.inquiries so they surface in the SIGMA "Email Requests" area.
//
// Why this exists: the website is a static export on shared hosting with no DB.
// Its PHP handlers (request.php / contact.php) still send SMTP email as before;
// they ADDITIONALLY POST here so the CMS gets a live, queryable feed. Email stays
// the guaranteed sink — a failure here never loses an inquiry.
//
// Auth: a shared bearer secret (INTAKE_SECRET), NOT a Supabase JWT. Deploy with
// verify_jwt=false. The insert runs with the service role, so the `inquiries`
// table needs no anon INSERT policy (bots with the public anon key can't write).
//
// Request (POST JSON, header `Authorization: Bearer <INTAKE_SECRET>`):
//   {
//     kind: 'request' | 'message',
//     source?: 'website', locale?, received_at?,
//     client_name?, client_email?, client_phone?, preferred_contact?,
//     // request-only:
//     purpose?, property_type?, property_address?, property_size_m2?, has_floorplan?, notes?,
//     // message-only:
//     subject?, message?
//   }
// Response: { ok: true, id } on success, or { ok:false, error } on failure.
// ─────────────────────────────────────────────────────────────────────────────

const ALLOW = /(^https?:\/\/localhost(:\d+)?$)|(\.pages\.dev$)|(taxatie-bureau\.com$)|(sigma-cms\.com$)/i;

function corsHeaders(origin: string | null): Record<string, string> {
  const o = origin && ALLOW.test(origin) ? origin : "*";
  return {
    "Access-Control-Allow-Origin": o,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

function jsonRes(obj: unknown, status: number, ch: Record<string, string>) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...ch, "Content-Type": "application/json" },
  });
}

// constant-time-ish compare so the secret check doesn't leak length/prefix via timing
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function s(v: unknown): string | null {
  if (v === undefined || v === null) return null;
  const t = String(v).trim();
  return t === "" ? null : t;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const ch = corsHeaders(origin);

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return jsonRes({ ok: false, error: "POST only" }, 405, ch);

  // shared-secret auth
  const secret = Deno.env.get("INTAKE_SECRET");
  if (!secret) return jsonRes({ ok: false, error: "server not configured" }, 500, ch);
  const auth = req.headers.get("authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  if (!token || !safeEqual(token, secret)) {
    return jsonRes({ ok: false, error: "unauthorized" }, 401, ch);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonRes({ ok: false, error: "invalid JSON body" }, 400, ch);
  }

  // Health probe: proves connectivity + that the shared secret is accepted,
  // WITHOUT writing a row. Used by api/sigma-check.php on the website host.
  if (body.probe === true) {
    return jsonRes({ ok: true, probe: true, message: "token accepted" }, 200, ch);
  }

  // honeypot backstop (PHP already screens this, but never trust one layer)
  if (s(body.company)) return jsonRes({ ok: true, id: null, skipped: "honeypot" }, 200, ch);

  const kind = body.kind === "message" ? "message" : "request";

  // whitelist → inquiry columns; `raw` keeps the full original payload for audit
  const row: Record<string, unknown> = {
    kind,
    source: s(body.source) || "website",
    locale: s(body.locale),
    received_at: s(body.received_at),
    status: "new",
    client_name: s(body.client_name),
    client_email: s(body.client_email),
    client_phone: s(body.client_phone),
    preferred_contact: s(body.preferred_contact),
    purpose: s(body.purpose),
    property_type: s(body.property_type),
    property_address: s(body.property_address),
    property_size_m2: s(body.property_size_m2),
    has_floorplan: s(body.has_floorplan),
    notes: s(body.notes),
    subject: s(body.subject),
    message: s(body.message),
    raw: body,
  };

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SUPABASE_URL || !SERVICE_KEY) {
    return jsonRes({ ok: false, error: "supabase env missing" }, 500, ch);
  }

  let ins: Response;
  try {
    ins = await fetch(`${SUPABASE_URL}/rest/v1/inquiries`, {
      method: "POST",
      headers: {
        "apikey": SERVICE_KEY,
        "Authorization": `Bearer ${SERVICE_KEY}`,
        "Content-Type": "application/json",
        "Prefer": "return=representation",
      },
      body: JSON.stringify(row),
    });
  } catch (e) {
    return jsonRes({ ok: false, error: "insert request failed", detail: String(e) }, 502, ch);
  }

  if (!ins.ok) {
    const detail = await ins.text().catch(() => "");
    return jsonRes({ ok: false, error: `insert error ${ins.status}`, detail: detail.slice(0, 500) }, 502, ch);
  }

  let id: string | null = null;
  try {
    const rows = await ins.json();
    id = Array.isArray(rows) && rows[0]?.id ? String(rows[0].id) : null;
  } catch { /* representation parse is best-effort */ }

  return jsonRes({ ok: true, id }, 200, ch);
});
