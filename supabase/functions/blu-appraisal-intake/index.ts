// ─────────────────────────────────────────────────────────────────────────────
// blu-appraisal-intake — receives appraisal requests from BLU Capital Group's
// Sales & Control Desk and records them in public.blu_appraisal_requests, so
// they surface in the SIGMA "Developments" area.
//
// Why this exists: when a buyer's deposit is verified, BLU asks SIGMA for an
// appraisal report the buyer can take to their bank for a mortgage. The desk
// posts here; SIGMA allocates the appraisal number on the spot and hands it
// straight back, so both systems name the same job by the same number from the
// first second.
//
// Modelled on `website-intake` (auth, CORS, response shape, service-role call by
// plain fetch — no SDK). Two things are different and deliberate:
//   • it ALLOCATES A NUMBER out of SIGMA's shared yearly series, and
//   • it is IDEMPOTENT, because allocating a number twice is not a cosmetic
//     fault: the invoice number is the order number.
//
// Auth: a shared bearer secret (BLU_INTAKE_SECRET), NOT a Supabase JWT. Deploy
// with verify_jwt=false. The write runs with the service role, so the table
// needs no anon INSERT policy.
//
// ═══ THE WIRE CONTRACT — do not redesign it ══════════════════════════════════
// Fixed by the sending side, blucapitalgroup/web/src/lib/dashboard/appraisal.ts.
// POST, header `Authorization: Bearer <BLU_INTAKE_SECRET>`, body:
//   {
//     "source": "blu-sales-control-desk",
//     "requested_at": "<ISO 8601>",
//     "requested_by": { "name": "...", "role": "..." },
//     "reference": { "reservation": "...", "project_code": "WAYACA-VILLAS",
//                    "project_name": "Wayaca Modern Villas" },
//     "client": { "first_name": "...", "last_name": "...", "email": "...", "phone": "..." },
//     "property": { "lot_number": "...", "model_code": null|"...", "package_code": null|"..." },
//     "deliver_to": { "client": true, "bank_contact": null | { "name": "...", "email": "..." } },
//     "idempotency_key": "<stable per reservation, identical on every retry>"
//   }
// Success: { "ok": true, "appraisal_number": "2026-045B", "id": "<uuid>" }
// Failure: { "ok": false, "error": "<message>" }
//
// model_code and package_code are LEGITIMATELY NULL — BLU has not yet supplied
// house models or packages for Wayaca. They are accepted as null and stored as
// null. Nothing here ever invents a value for them.
//
// ═══ IDEMPOTENCY — how it is actually enforced ═══════════════════════════════
// By ONE database call, public.sigma_blu_record_request(jsonb), which claims the
// idempotency key AND allocates the number inside a single transaction. The long
// note above that function in SIGMA_blu_appraisal_requests.sql has the detail;
// the short version:
//
//   • `insert ... on conflict (idempotency_key) do nothing` claims the key. The
//     UNIQUE INDEX is the arbiter, not any check in this file.
//   • a concurrent retry BLOCKS on that uncommitted row and then reads it
//     `for update`, so it never reaches the allocator: it returns the winner's
//     number instead of spending a second one.
//   • a row that somehow already exists without a number is RESUMED, not
//     stranded — and there is nothing to resume after a crash, because a crash
//     rolls the whole transaction back.
//
// An earlier version did the claim, the allocation and the attach as four
// separate HTTP calls. That never duplicated a request, but on a genuine race it
// allocated a number it then had to throw away — a permanent hole in a series
// whose numeric part is also an invoice number.
//
// The read below is a FAST PATH only: a repeat that has already finished is
// answered without opening a write transaction. Removing it would change nothing
// about correctness.
//
// ═══ DEPLOY (Greg runs this — nothing here deploys itself) ═══════════════════
// Full runbook, including the rollback: docs/blu-developments/DEPLOY_RUNBOOK.md
//   1. Apply supabase/SIGMA_milestone_20260824.sql        (snapshot first)
//   2. Apply supabase/SIGMA_order_numbering_blu.sql       (the B-suffix allocator)
//   3. Apply supabase/SIGMA_blu_appraisal_requests.sql    (table + RLS + the RPC)
//   4. From sigma-deploy\ :
//        supabase secrets set BLU_INTAKE_SECRET="<the shared secret given to BLU>"
//        supabase functions deploy blu-appraisal-intake --no-verify-jwt
//      (config.toml already carries verify_jwt = false for this function.)
//   5. Smoke test WITHOUT writing a row or spending a number:
//        curl -sS -X POST "https://<ref>.supabase.co/functions/v1/blu-appraisal-intake" \
//          -H "Authorization: Bearer <BLU_INTAKE_SECRET>" \
//          -H "Content-Type: application/json" -d '{"probe":true}'
//      → {"ok":true,"probe":true,"message":"token accepted"}
// ─────────────────────────────────────────────────────────────────────────────

const ALLOW = /(^https?:\/\/localhost(:\d+)?$)|(\.pages\.dev$)|(blucapitalgroup\.(com|net)$)|(sigma-cms\.com$)/i;

const TABLE = "blu_appraisal_requests";
const RPC = "sigma_blu_record_request";

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

// A timestamp the database can store, or null. Normalised HERE rather than passed
// through: an unparseable requested_at reaching a `::timestamptz` cast would fail
// the whole insert over a field nothing depends on.
function iso(v: unknown): string | null {
  const t = s(v);
  if (!t) return null;
  const d = new Date(t);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

function obj(v: unknown): Record<string, unknown> {
  return (v && typeof v === "object" && !Array.isArray(v)) ? v as Record<string, unknown> : {};
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const ch = corsHeaders(origin);

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return jsonRes({ ok: false, error: "POST only" }, 405, ch);

  // ── shared-secret auth ────────────────────────────────────────────────────
  const secret = Deno.env.get("BLU_INTAKE_SECRET");
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
  // WITHOUT writing a row and WITHOUT consuming an appraisal number.
  if (body.probe === true) {
    return jsonRes({ ok: true, probe: true, message: "token accepted" }, 200, ch);
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SUPABASE_URL || !SERVICE_KEY) {
    return jsonRes({ ok: false, error: "supabase env missing" }, 500, ch);
  }

  type RestInit = { method?: string; body?: string; headers?: Record<string, string> };
  const rest = (path: string, init: RestInit = {}) =>
    fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
      method: init.method || "GET",
      body: init.body,
      headers: {
        "apikey": SERVICE_KEY,
        "Authorization": `Bearer ${SERVICE_KEY}`,
        "Content-Type": "application/json",
        ...(init.headers || {}),
      },
    });

  // ── validate ──────────────────────────────────────────────────────────────
  const idem = s(body.idempotency_key);
  if (!idem) {
    // Refusing is the only safe answer: without a key a retry would allocate a
    // second number for the same reservation.
    return jsonRes({ ok: false, error: "idempotency_key is required" }, 400, ch);
  }
  if (idem.length > 200) {
    return jsonRes({ ok: false, error: "idempotency_key too long (max 200)" }, 400, ch);
  }

  const reference   = obj(body.reference);
  const client      = obj(body.client);
  const property    = obj(body.property);
  const requestedBy = obj(body.requested_by);
  const deliverTo   = obj(body.deliver_to);
  const bank        = obj(deliverTo.bank_contact);

  const missing: string[] = [];
  if (!s(reference.reservation))  missing.push("reference.reservation");
  if (!s(reference.project_code)) missing.push("reference.project_code");
  if (!s(client.first_name) && !s(client.last_name)) missing.push("client.first_name / client.last_name");
  if (!s(client.email))           missing.push("client.email");
  if (!s(property.lot_number))    missing.push("property.lot_number");
  if (missing.length) {
    return jsonRes({ ok: false, error: "missing required field(s): " + missing.join(", ") }, 400, ch);
  }

  // deliver_to.client defaults to TRUE when not stated: a buyer who asked for an
  // appraisal to take to their bank is always a recipient unless BLU says
  // otherwise. A bank contact is additional, never a replacement.
  const deliverClient = deliverTo.client === undefined || deliverTo.client === null
    ? true : deliverTo.client === true;

  // The flat shape sigma_blu_record_request() expects. `raw` carries the original
  // nested payload verbatim, so nothing BLU sent is lost even if it is something
  // this table has no column for.
  const payload: Record<string, unknown> = {
    source:             s(body.source) || "blu-sales-control-desk",
    received_at:        iso(body.requested_at),
    requested_by_name:  s(requestedBy.name),
    requested_by_role:  s(requestedBy.role),
    reservation_ref:    s(reference.reservation),
    project_code:       s(reference.project_code),
    project_name:       s(reference.project_name),
    client_first_name:  s(client.first_name),
    client_last_name:   s(client.last_name),
    client_email:       s(client.email),
    client_phone:       s(client.phone),
    lot_number:         s(property.lot_number),
    // null stays null — "not yet supplied" is real information, not a gap to fill.
    model_code:         s(property.model_code),
    package_code:       s(property.package_code),
    deliver_to_client:  deliverClient,
    bank_contact_name:  s(bank.name),
    bank_contact_email: s(bank.email),
    idempotency_key:    idem,
    raw:                body,
  };

  try {
    // ── fast path ───────────────────────────────────────────────────────────
    // A repeat that already has its number is answered without opening a write
    // transaction. An optimisation only; the RPC below is correct on its own.
    const q = "select=id,appraisal_number&idempotency_key=eq." + encodeURIComponent(idem);
    const pre = await rest(`${TABLE}?${q}&limit=1`);
    if (pre.ok) {
      const rows = await pre.json().catch(() => []);
      const row = (Array.isArray(rows) && rows[0]) ? rows[0] : null;
      if (row && row.appraisal_number) {
        return jsonRes({
          ok: true,
          appraisal_number: String(row.appraisal_number),
          id: String(row.id),
          repeat: true,
        }, 200, ch);
      }
    } else if (pre.status === 404) {
      return jsonRes({
        ok: false,
        error: "SIGMA is not ready: the blu_appraisal_requests table does not exist. "
             + "Apply SIGMA_order_numbering_blu.sql, then SIGMA_blu_appraisal_requests.sql.",
      }, 503, ch);
    }
    // Any OTHER read failure is deliberately ignored: the RPC is the authority,
    // and refusing a request because an optimisation failed would be worse.

    // ── claim + allocate, in one transaction ────────────────────────────────
    const r = await rest(`rpc/${RPC}`, {
      method: "POST",
      body: JSON.stringify({ p: payload }),
    });

    if (!r.ok) {
      const detail = (await r.text().catch(() => "")).slice(0, 500);
      if (r.status === 404 || detail.indexOf("PGRST202") >= 0) {
        return jsonRes({
          ok: false,
          error: "SIGMA is not ready: sigma_blu_record_request() is not installed. "
               + "Apply SIGMA_blu_appraisal_requests.sql, then run: notify pgrst, 'reload schema';",
        }, 503, ch);
      }
      return jsonRes({ ok: false, error: `intake failed (${r.status})`, detail }, 502, ch);
    }

    const rec = obj(await r.json().catch(() => null));
    const num = s(rec.appraisal_number);
    const id = s(rec.id);
    if (!num || !id) {
      // Never report success without the number: the desk would show a green tick
      // and have nothing to quote to the bank.
      return jsonRes({ ok: false, error: "SIGMA recorded the request but returned no appraisal number" }, 502, ch);
    }

    return rec.created === true
      ? jsonRes({ ok: true, appraisal_number: num, id }, 200, ch)
      : jsonRes({ ok: true, appraisal_number: num, id, repeat: true }, 200, ch);
  } catch (e) {
    return jsonRes({ ok: false, error: String((e && (e as Error).message) || e) }, 502, ch);
  }
});
