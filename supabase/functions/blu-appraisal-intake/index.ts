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
//     "valuation": null | { … see §BLU-VALUATION below … },
//     "idempotency_key": "<stable per reservation, identical on every retry>"
//   }
// Success: { "ok": true, "appraisal_number": "2026-045B", "id": "<uuid>" }
// Failure: { "ok": false, "error": "<message>" }
//
// model_code and package_code are LEGITIMATELY NULL — BLU has not yet supplied
// house models or packages for Wayaca. They are accepted as null and stored as
// null. Nothing here ever invents a value for them.
//
// ═══ §BLU-VALUATION — the presumable valuation ═══════════════════════════════
// Added 2026-08-24. Optional member, so Coriara (a different valuation module) and
// the four projects with none keep sending exactly what they send today.
//
//   "valuation": {
//     "currency": "AWG",
//     "lines": [{"key":"land","label":"Land","quantity_m2":196.4,
//                "rate_minor":45000,"amount_minor":8838000}],
//     "sub_total_minor":   42058375,
//     "added_value_pct":   0.18,
//     "added_value_minor":  7570508,
//     "pfmv_minor":        49628883,
//     "pev_pct":           0.8,
//     "pev_minor":         39703106,
//     "prcv_minor":        40790883,
//     "rate_card_source": "Wayaca Modern Villas_Numbers.xlsx VALUES sheet",
//     "supersedes": null
//   }
//
// EVERY MONEY VALUE IS AN INTEGER IN MINOR UNITS (cents). A float where a minor
// unit belongs is a BUG, not a rounding detail, and it is REJECTED — never
// silently truncated, never silently rounded. 4962888.3 names the field it came
// from and the whole request fails; storing 4962888 would put a figure on an
// appraisal that nobody sent.
//
// The two percentages are FRACTIONS: 0.18 is 18%. A sender that switched to whole
// percent would multiply a valuation by a hundred, so anything outside 0…1 is
// rejected too.
//
// ABSENT vs ZERO. `valuation` may be missing or null, and a supplied figure may
// legitimately be 0. Those are different facts, and SIGMA keeps them apart with a
// separate timestamp column (valuation_received_at), not with a zero. So this
// function never invents an empty valuation object: no member means no valuation.
//
// HALF A VALUATION IS WORSE THAN NONE. Every check below rejects the WHOLE request
// with a named error BEFORE any database work, so no request can end up holding an
// appraisal number and three of its six figures.
//
// ATOMICITY. The valuation is written by the same sigma_blu_record_request()
// statement that claims the idempotency key and allocates the number — one
// transaction. A retry cannot produce a row with a number and no figures.
//
// SIGMA STORES WHAT ARRIVES. The arithmetic is not re-derived and the three
// headline figures are not renamed. Where BLU's own sheet does not tie, the
// Developments card says so; it does not quietly correct it.
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
//   2. Apply supabase/SIGMA_order_numbering_blu.sql       (the B-suffix allocator)  ✔ live 2026-08-24
//   3. Apply supabase/SIGMA_blu_appraisal_requests.sql    (table + RLS + the RPC)   ✔ live 2026-08-24
//   3b. Apply supabase/SIGMA_blu_valuation_20260824.sql   (§BLU-VALUATION: the
//       valuation columns + the RPC that records them). MUST be applied BEFORE this
//       function is deployed — otherwise a request carrying a valuation still gets
//       its number, but comes back with valuation_recorded:false and the figures
//       are dropped until BLU re-sends.
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

// ── §BLU-VALUATION — validation ─────────────────────────────────────────────
// Thrown, not returned, so the first bad field aborts the whole valuation and no
// caller can accidentally carry on with a half-read one. Caught once, at the call
// site, and turned into a 400 naming the field.
class BadValuation extends Error {}
function bad(msg: string): never { throw new BadValuation(msg); }

const MAX_LINES = 200;          // a valuation, not a spreadsheet (2026-07-16 outage)
const MAX_LABEL = 200;
const MAX_KEY = 60;
const MAX_SOURCE = 300;

// An integer count of minor units, or null when the field is optional and absent.
//
// `typeof v === "number"` on purpose: "45000" is a string, and accepting it would
// mean guessing whether the sender meant minor units or major ones. The contract
// says integer; a string is a defect at the source and is reported as one.
function minor(v: unknown, field: string, required: boolean): number | null {
  if (v === undefined || v === null) {
    if (required) bad(`valuation.${field} is required and must be an integer number of minor units (cents)`);
    return null;
  }
  if (typeof v !== "number" || !Number.isFinite(v)) {
    bad(`valuation.${field} must be a JSON number in minor units (cents), got ${typeof v === "string" ? `the string "${v}"` : String(v)}`);
  }
  if (!Number.isInteger(v)) {
    bad(`valuation.${field} must be an INTEGER number of minor units (cents), got ${v} — a fractional cent is a bug at the source, not a rounding detail`);
  }
  if (v < 0) bad(`valuation.${field} must not be negative, got ${v}`);
  if (!Number.isSafeInteger(v)) bad(`valuation.${field} exceeds the safe integer range, got ${v}`);
  return v;
}

// A fraction: 0.18 means 18%.
function fraction(v: unknown, field: string): number | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "number" || !Number.isFinite(v)) {
    bad(`valuation.${field} must be a JSON number expressed as a fraction (0.18 = 18%), got ${typeof v}`);
  }
  if (v < 0 || v > 1) {
    bad(`valuation.${field} must be a fraction between 0 and 1 (0.18 = 18%, not 18), got ${v}`);
  }
  return v;
}

// A measured quantity — NOT money, so it is legitimately fractional (196.4 m²).
function quantity(v: unknown, field: string): number | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "number" || !Number.isFinite(v)) {
    bad(`valuation.${field} must be a JSON number, got ${typeof v}`);
  }
  if (v < 0) bad(`valuation.${field} must not be negative, got ${v}`);
  return v;
}

function shortText(v: unknown, field: string, max: number): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") bad(`valuation.${field} must be a string or null, got ${typeof v}`);
  const t = v.trim();
  if (!t) return null;
  if (t.length > max) bad(`valuation.${field} is longer than ${max} characters`);
  return t;
}

type ValLine = {
  key: string | null;
  label: string | null;
  quantity_m2: number | null;
  rate_minor: number | null;
  amount_minor: number | null;
};

// Returns the flat valuation the RPC expects, or null when BLU supplied none.
// Throws BadValuation for anything malformed.
//
// Note what is NOT here: no arithmetic. sub_total, PFMV, PEV and PRCV are stored
// exactly as sent. If BLU's own sheet does not tie, that is a fact about the
// request and SIGMA shows it rather than silently correcting a figure a bank may
// already have seen.
function readValuation(raw: unknown): Record<string, unknown> | null {
  if (raw === undefined || raw === null) return null;      // not supplied — the common case
  if (typeof raw !== "object" || Array.isArray(raw)) {
    bad(`valuation must be a JSON object or null, got ${Array.isArray(raw) ? "an array" : typeof raw}`);
  }
  const v = raw as Record<string, unknown>;

  const currency = typeof v.currency === "string" ? v.currency.trim().toUpperCase() : "";
  if (!/^[A-Z]{3}$/.test(currency)) {
    bad(`valuation.currency must be a 3-letter ISO 4217 code, got ${v.currency === undefined ? "(missing)" : JSON.stringify(v.currency)}`);
  }

  if (!Array.isArray(v.lines)) {
    bad(`valuation.lines must be an array (it may be empty), got ${v.lines === undefined ? "(missing)" : typeof v.lines}`);
  }
  const src = v.lines as unknown[];
  if (src.length > MAX_LINES) {
    bad(`valuation.lines has ${src.length} entries; the limit is ${MAX_LINES}`);
  }
  const lines: ValLine[] = src.map((entry, i) => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      bad(`valuation.lines[${i}] must be an object`);
    }
    const L = entry as Record<string, unknown>;
    return {
      key:          shortText(L.key,   `lines[${i}].key`,   MAX_KEY),
      label:        shortText(L.label, `lines[${i}].label`, MAX_LABEL),
      quantity_m2:  quantity(L.quantity_m2,  `lines[${i}].quantity_m2`),
      rate_minor:   minor(L.rate_minor,   `lines[${i}].rate_minor`,   false),
      amount_minor: minor(L.amount_minor, `lines[${i}].amount_minor`, false),
    };
  });

  return {
    currency,
    lines,
    sub_total_minor:   minor(v.sub_total_minor,   "sub_total_minor",   true),
    added_value_pct:   fraction(v.added_value_pct, "added_value_pct"),
    added_value_minor: minor(v.added_value_minor, "added_value_minor", false),
    pfmv_minor:        minor(v.pfmv_minor,        "pfmv_minor",        true),
    pev_pct:           fraction(v.pev_pct,        "pev_pct"),
    pev_minor:         minor(v.pev_minor,         "pev_minor",         true),
    prcv_minor:        minor(v.prcv_minor,        "prcv_minor",        true),
    rate_card_source:  shortText(v.rate_card_source, "rate_card_source", MAX_SOURCE),
    supersedes:        shortText(v.supersedes,       "supersedes",       MAX_LABEL),
  };
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

  // §BLU-VALUATION — read and validate BEFORE anything is written, and before the
  // missing-field check below. Two reasons, both deliberate:
  //   • a malformed valuation fails the WHOLE request with a named error: better
  //     that BLU's desk sees "valuation.pfmv_minor must be an INTEGER…" and fixes
  //     the sender than that SIGMA records an appraisal number against half a
  //     valuation;
  //   • running it FIRST makes a free build-probe possible — a payload that is both
  //     missing a required field AND carrying a bad valuation is refused by every
  //     version of this function, with a message that says which version answered
  //     (see step 7 of docs/blu-developments/DEPLOY_RUNBOOK.md).
  // Nothing here depends on the fields below, so the order costs nothing: a
  // well-formed valuation raises nothing and the missing-field error still wins.
  let valuation: Record<string, unknown> | null;
  try {
    valuation = readValuation(body.valuation);
  } catch (e) {
    if (e instanceof BadValuation) {
      return jsonRes({ ok: false, error: e.message }, 400, ch);
    }
    throw e;
  }
  const hasValuation = valuation !== null;

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
    // Omitted entirely when BLU sent none — the RPC tests `p ? 'valuation'`, and
    // an explicit null would be indistinguishable from an empty one supplied.
    ...(hasValuation ? { valuation } : {}),
  };

  try {
    // ── fast path ───────────────────────────────────────────────────────────
    // A repeat that already has its number is answered without opening a write
    // transaction. An optimisation only; the RPC below is correct on its own.
    //
    // §BLU-VALUATION — with ONE exception, which is load-bearing rather than an
    // optimisation: if this request carries a valuation and the stored row has
    // none, the fast path must NOT answer, or the re-send that is meant to attach
    // the figures would be short-circuited and the valuation lost for good. That
    // happens for real — a request sent before BLU turned the valuation on, and
    // any request that arrived while SIGMA_blu_valuation_20260824.sql was not yet
    // applied. Falling through lets the RPC's resume path fill the gap, under the
    // same row lock and without allocating a second number.
    //
    // valuation_received_at is selected explicitly; on a database where the
    // migration has not run PostgREST answers 400 for the unknown column, the read
    // is treated as failed (as any other read failure is) and the RPC decides.
    const q = "select=id,appraisal_number,valuation_received_at&idempotency_key=eq." + encodeURIComponent(idem);
    const pre = await rest(`${TABLE}?${q}&limit=1`);
    if (pre.ok) {
      const rows = await pre.json().catch(() => []);
      const row = (Array.isArray(rows) && rows[0]) ? rows[0] : null;
      const needsValuation = hasValuation && !row?.valuation_received_at;
      if (row && row.appraisal_number && !needsValuation) {
        return jsonRes({
          ok: true,
          appraisal_number: String(row.appraisal_number),
          id: String(row.id),
          repeat: true,
          ...(hasValuation ? { valuation_recorded: true } : {}),
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
      // §BLU-VALUATION — a named validation error raised inside the RPC (the
      // defence-in-depth copy of the checks above) is the sender's problem, not
      // SIGMA's: report it as a 400 with the message, not as a 502. Nothing was
      // written — the whole statement rolled back, and no number was spent.
      if (r.status === 400 && /valuation\./.test(detail)) {
        return jsonRes({ ok: false, error: `rejected by SIGMA: ${detail.slice(0, 300)}` }, 400, ch);
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

    const out: Record<string, unknown> = { ok: true, appraisal_number: num, id };
    if (rec.created !== true) out.repeat = true;

    if (hasValuation) {
      // The number IS allocated and BLU must be told it, so a valuation that did
      // not land is reported as a warning beside a successful answer rather than
      // as a failure. Turning this into a 5xx would make the desk retry for ever
      // against an unchanged database while the number stays spent.
      //
      // `valuation_recorded` is absent (not false) from the pre-valuation RPC, so
      // the one case this catches in practice is "the function was deployed before
      // SIGMA_blu_valuation_20260824.sql was applied".
      const recorded = rec.valuation_recorded === true;
      out.valuation_recorded = recorded;
      if (!recorded) {
        out.warning = "SIGMA recorded the request and allocated the appraisal number, but NOT the valuation: "
          + "the valuation columns are not installed. Apply supabase/SIGMA_blu_valuation_20260824.sql, then "
          + "re-send this request with the SAME idempotency_key — it attaches the valuation to the existing "
          + "row and does not allocate a second number.";
      }
    }

    return jsonRes(out, 200, ch);
  } catch (e) {
    return jsonRes({ ok: false, error: String((e && (e as Error).message) || e) }, 502, ch);
  }
});
