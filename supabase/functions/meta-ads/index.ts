// ─────────────────────────────────────────────────────────────────────────────
// meta-ads — READ-ONLY proxy for the Meta (Facebook / Instagram) Marketing API.
//
// WHY THIS EXISTS — the same reason fish-tts exists, twice over:
//   1. A browser cannot hold META_ACCESS_TOKEN. An ads token is a bearer credential
//      for a spending account; anything shipped to index.html is public, and SIGMA's
//      anon key is already in the page. The token lives here, in a Supabase secret,
//      and NEVER crosses the wire to the browser in any form — not in a response
//      body, not in an error detail, not in a log row. See redact() below.
//   2. graph.facebook.com sends no CORS headers usable from sigma-cms.com.
//
// WHAT IT WILL NOT DO — deliberately:
//   • It NEVER writes. No POST/DELETE to Graph, ever. Creating or editing a campaign
//     needs the `ads_management` permission, which needs Meta App Review (a business
//     process measured in days-to-weeks). Until the bureau holds that permission,
//     any create path here would be untestable dead code. The app deep-links to Meta
//     Ads Manager instead. See §ADS-NO-WRITE.
//   • It NEVER invents a number. If Graph did not return a metric, the field is
//     `null` — not 0, not "", not a placeholder. A missing insight and a genuine
//     zero are different facts and the dashboard prints them differently. There is
//     no `|| 0` anywhere in this file, on purpose. See §ADS-NO-FABRICATION.
//   • It NEVER returns partial data on error. Any Graph failure produces
//     `{ok:false, step, title, detail, remedy}` and nothing else, so the panel
//     physically has no numbers to render. See §ADS-GUARD (fail closed).
//
// SECRETS (Supabase → Project Settings → Edge Functions → Secrets):
//   META_ACCESS_TOKEN   REQUIRED. A long-lived User token or (preferred) a System
//                       User token from Meta Business Manager. Needs `ads_read`.
//   META_AD_ACCOUNT_ID  RECOMMENDED. e.g. `act_1234567890` (the `act_` prefix is
//                       optional — it is normalised below). May instead be sent per
//                       request as `accountId`, so the owner can record it in SIGMA
//                       Settings without a redeploy. The TOKEN can never be sent
//                       per request: there is no code path that reads one from the
//                       body.
//   META_GRAPH_VERSION  OPTIONAL. Defaults to GRAPH_DEFAULT below.
//   META_REQUIRE_AUTH   OPTIONAL. "1" → demand a real Supabase user (see §ADS-AUTH).
//
// Request (POST JSON):
//   { action: "diagnose" }                      → connection test, no metrics
//   { action: "overview", accountId?, preset?, daily? }
//   { action: "adsets",   accountId?, campaignId? }
//   preset ∈ today | last_7d | last_30d | maximum          (default last_7d)
//
// Response: see the JSON shapes on each handler. Every failure is `{ok:false,…}`
// with an HTTP status that matches, so the caller cannot mistake one for the other.
//
// Deploy with verify_jwt=false so the app can call it with just the anon apikey
// (SIGMA's local-SHA256 login path carries no user JWT — see §ADS-AUTH).
//   supabase functions deploy meta-ads --no-verify-jwt
// NOT DEPLOYED as of writing: no credentials exist yet. Deployment is the owner's
// call, after the secrets above are set.
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const GRAPH_DEFAULT = "v21.0";
const GRAPH_HOST = "https://graph.facebook.com";

// §ADS-GUARD — volume ceiling. Meta rate-limits per ad account and the bureau
//   shares that budget with Ads Manager itself, so a runaway dashboard could lock
//   the owner out of his own reporting. One "overview" costs at most 4 Graph calls.
//   200/hour is ~50 full refreshes an hour — far past any human use of a dashboard
//   panel, and small enough that an unattended loop is stopped before Meta notices.
const ADS_MAX_PER_HOUR = 200;
// Second-layer ceiling that needs no database at all: a per-isolate token bucket.
// This is what actually holds if `meta_ads_usage` does not exist.
const ADS_MAX_PER_MIN_LOCAL = 20;

// The four ranges the panel offers. An unknown preset is REJECTED rather than
// silently coerced, so a typo can never quietly change what a number means.
const PRESETS: Record<string, string> = {
  today: "today",
  last_7d: "last_7d",
  last_30d: "last_30d",
  maximum: "maximum",
};

const ALLOW = /(^https?:\/\/localhost(:\d+)?$)|(\.pages\.dev$)|(sigma-cms\.com$)/i;

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
    headers: { ...ch, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// §ADS-REDACT — the token must not be able to escape, by any route.
//
// Graph echoes a surprising amount back in error text, and Deno's own fetch errors
// can carry the request URL — which, for Graph, contains `access_token=` in the
// query string. So EVERY string that leaves this function (and every string that
// reaches console) is passed through redact() first. It removes:
//   (a) any literal occurrence of the token itself, even a fragment of ≥12 chars,
//   (b) any `access_token=…` query parameter, whatever its value.
// Applied last, so it also catches values composed after the fact.
// ─────────────────────────────────────────────────────────────────────────────
function redact(s: unknown, token?: string): string {
  let out = typeof s === "string" ? s : JSON.stringify(s ?? "");
  out = out.replace(/access_token=[^&\s"'\\]*/gi, "access_token=[redacted]");
  if (token && token.length >= 12) {
    // Whole token first, then any long fragment of it that may have been truncated
    // into the message by Graph or by a proxy.
    const whole = token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    out = out.replace(new RegExp(whole, "g"), "[redacted]");
    for (let len = token.length; len >= 12; len -= 8) {
      const frag = token.slice(0, len).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      out = out.replace(new RegExp(frag, "g"), "[redacted]");
    }
  }
  return out;
}

// `1234567890` | `act_1234567890` | ` act_1234567890 ` → `act_1234567890`.
// Anything that is not digits after the optional prefix is REJECTED (returns null)
// rather than repaired — a mangled account id must surface as a clear diagnosis,
// not as a Graph 404 the owner has to decode.
function normAccount(raw: unknown): string | null {
  const s = String(raw ?? "").trim();
  if (!s) return null;
  const m = /^(?:act_)?(\d{5,25})$/.exec(s);
  return m ? "act_" + m[1] : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// §ADS-DIAGNOSE — turn a Graph error into something the owner can act on.
//
// The whole point of the Settings "Test connection" button is that it must not say
// "an error occurred". Graph's own codes are precise; this is the translation table.
// Anything unrecognised falls through to `graph_error` carrying the verbatim (but
// redacted) message, so a new code is still readable rather than swallowed.
// ─────────────────────────────────────────────────────────────────────────────
type Diag = {
  step: string;
  title: string;
  detail: string;
  remedy: string;
  http: number;
};

function classifyGraphError(err: Record<string, unknown> | null, httpStatus: number, token?: string): Diag {
  const code = Number(err?.code ?? 0);
  const sub = Number(err?.error_subcode ?? 0);
  const msg = redact(String(err?.message ?? ""), token);
  const userMsg = redact(String(err?.error_user_msg ?? ""), token);
  const detail = (userMsg || msg || ("HTTP " + httpStatus)).slice(0, 400);

  if (code === 190) {
    if (sub === 463) {
      return {
        step: "expired_token", http: 401,
        title: "The Meta access token has expired.",
        detail,
        remedy: "Generate a new long-lived token (or a System User token, which does not expire) and replace the META_ACCESS_TOKEN secret in Supabase.",
      };
    }
    if (sub === 460 || sub === 458 || sub === 459) {
      return {
        step: "revoked_token", http: 401,
        title: "The Meta access token has been revoked.",
        detail,
        remedy: sub === 458
          ? "The app was removed from the Facebook account. Re-add the app, then issue and store a new token."
          : "The Facebook password was changed or the session was invalidated. Issue a new token and replace META_ACCESS_TOKEN.",
      };
    }
    return {
      step: "bad_token", http: 401,
      title: "Meta rejected the access token.",
      detail,
      remedy: "Check META_ACCESS_TOKEN in Supabase → Edge Functions → Secrets. It must be the full token, with no quotes and no trailing whitespace.",
    };
  }
  if (code === 102) {
    return {
      step: "bad_token", http: 401,
      title: "The Meta session is no longer valid.",
      detail,
      remedy: "Issue a fresh token in Meta Business Manager and replace META_ACCESS_TOKEN.",
    };
  }
  if (code === 200 || code === 10 || code === 3) {
    return {
      step: "no_permission", http: 403,
      title: "The token does not carry the ads_read permission.",
      detail,
      remedy: "In Meta Business Manager, re-issue the token with the ads_read scope, and confirm the token's user (or System User) is assigned to this ad account with at least Analyst access.",
    };
  }
  if (code === 100 && (sub === 33 || sub === 0)) {
    return {
      step: "no_account_access", http: 404,
      title: "That ad account cannot be seen with this token.",
      detail,
      remedy: "Either the ad account id is wrong, or the token's user is not assigned to it. Copy the id from Ads Manager (it looks like act_1234567890) and check the assignment in Business Manager → Ad Accounts → People.",
    };
  }
  if (code === 803) {
    return {
      step: "no_account", http: 404,
      title: "No ad account with that id exists.",
      detail,
      remedy: "Copy the ad account id from the Ads Manager URL (act_…) and record it again in SIGMA Settings → Online AD Management.",
    };
  }
  if (code === 4 || code === 17 || code === 32 || code === 613 || (code >= 80000 && code <= 80014)) {
    return {
      step: "rate_limited", http: 429,
      title: "Meta is rate-limiting this ad account.",
      detail,
      remedy: "Wait a few minutes and press Refresh. Meta's ad-account limits are shared with Ads Manager, so heavy use there counts against the same budget.",
    };
  }
  if (code === 1 || code === 2) {
    return {
      step: "graph_down", http: 503,
      title: "Meta's Graph API is temporarily unavailable.",
      detail,
      remedy: "This is Meta's side, not SIGMA's. Try again in a few minutes.",
    };
  }
  return {
    step: "graph_error", http: 502,
    title: "Meta refused the request.",
    detail: detail + (code ? "  (Graph code " + code + (sub ? "/" + sub : "") + ")" : ""),
    remedy: "The message above is Meta's own wording, passed through unchanged.",
  };
}

function failRes(d: Diag, ch: Record<string, string>, extra?: Record<string, unknown>) {
  return jsonRes({ ok: false, step: d.step, title: d.title, detail: d.detail, remedy: d.remedy, ...(extra || {}) }, d.http, ch);
}

// ─────────────────────────────────────────────────────────────────────────────
// The single Graph entry point. Every read goes through here, so redaction, error
// classification and the "no partial data" rule are enforced in exactly one place.
// Returns either {data} or {diag} — never both, never neither.
// ─────────────────────────────────────────────────────────────────────────────
async function graphGet(
  path: string,
  params: Record<string, string>,
  token: string,
): Promise<{ data?: Record<string, unknown>; diag?: Diag }> {
  const version = Deno.env.get("META_GRAPH_VERSION") || GRAPH_DEFAULT;
  const url = new URL(GRAPH_HOST + "/" + version + "/" + path);
  for (const k of Object.keys(params)) url.searchParams.set(k, params[k]);

  let r: Response;
  try {
    // The token rides in the header, not the query string, so it cannot land in an
    // intermediary's access log. (§ADS-REDACT still scrubs the query form in case a
    // Graph error quotes a URL back at us.)
    r = await fetch(url.toString(), {
      method: "GET",
      headers: { "Authorization": "Bearer " + token, "Accept": "application/json" },
    });
  } catch (e) {
    return {
      diag: {
        step: "network", http: 504,
        title: "Could not reach Meta.",
        detail: redact(String(e), token).slice(0, 300),
        remedy: "The Edge Function could not open a connection to graph.facebook.com. This is almost always transient — try Refresh. If it persists, check the Supabase function logs.",
      },
    };
  }

  let body: Record<string, unknown>;
  try {
    body = await r.json();
  } catch {
    return {
      diag: {
        step: "graph_error", http: 502,
        title: "Meta returned something that was not JSON.",
        detail: "HTTP " + r.status,
        remedy: "Try again. If it repeats, Meta may be mid-incident.",
      },
    };
  }

  if (!r.ok || body?.error) {
    return { diag: classifyGraphError((body?.error as Record<string, unknown>) ?? null, r.status, token) };
  }
  return { data: body };
}

// ─────────────────────────────────────────────────────────────────────────────
// §ADS-NO-FABRICATION — the numeric contract.
//
// Graph returns metrics as STRINGS ("1234", "12.34") and OMITS them entirely when
// there was no delivery. `num()` therefore distinguishes three cases and collapses
// none of them:
//     absent / ""      → null   ("we do not know")
//     "0"              → 0      ("we know it was zero")
//     "1234"           → 1234
// A non-numeric string also yields null rather than NaN, because NaN formats as
// "NaN" downstream and NaN is not a fact either.
//
// There is no default anywhere. The dashboard prints "—" for null and "0" for 0,
// and those are different sentences.
// ─────────────────────────────────────────────────────────────────────────────
function num(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  if (s === "") return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

function str(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s === "" ? null : s;
}

// Meta's "Results" is objective-dependent: the number is buried in the `actions`
// array under an action_type that depends on what the campaign optimises for.
// Guessing wrong would print a real number under a wrong label, which is worse than
// printing nothing — so an unmapped objective yields {results:null,label:null} and
// the panel says "not available for this objective" instead.
const RESULT_ACTION: Record<string, { type: string; label: string }> = {
  OUTCOME_TRAFFIC: { type: "link_click", label: "Link clicks" },
  LINK_CLICKS: { type: "link_click", label: "Link clicks" },
  OUTCOME_ENGAGEMENT: { type: "post_engagement", label: "Engagements" },
  POST_ENGAGEMENT: { type: "post_engagement", label: "Engagements" },
  PAGE_LIKES: { type: "like", label: "Page likes" },
  VIDEO_VIEWS: { type: "video_view", label: "Video views" },
  OUTCOME_LEADS: { type: "lead", label: "Leads" },
  LEAD_GENERATION: { type: "lead", label: "Leads" },
  OUTCOME_SALES: { type: "offsite_conversion.fb_pixel_purchase", label: "Purchases" },
  CONVERSIONS: { type: "offsite_conversion.fb_pixel_purchase", label: "Purchases" },
  PRODUCT_CATALOG_SALES: { type: "offsite_conversion.fb_pixel_purchase", label: "Purchases" },
  OUTCOME_APP_PROMOTION: { type: "app_install", label: "App installs" },
  APP_INSTALLS: { type: "app_install", label: "App installs" },
  MESSAGES: { type: "onsite_conversion.messaging_conversation_started_7d", label: "Conversations" },
  // Awareness/Reach campaigns have no discrete "result" action — reach IS the result,
  // and it is already its own column. Mapped explicitly to null so it is a decision,
  // not an omission.
  OUTCOME_AWARENESS: { type: "", label: "" },
  BRAND_AWARENESS: { type: "", label: "" },
  REACH: { type: "", label: "" },
};

function pickResult(objective: string | null, actions: unknown): { results: number | null; result_label: string | null } {
  const none = { results: null, result_label: null };
  if (!objective) return none;
  const map = RESULT_ACTION[objective];
  if (!map || !map.type) return none;
  if (!Array.isArray(actions)) return none;
  for (const a of actions as Array<Record<string, unknown>>) {
    if (String(a?.action_type ?? "") === map.type) {
      const v = num(a?.value);
      return v === null ? none : { results: v, result_label: map.label };
    }
  }
  // The objective is mapped but Graph reported no such action in this window. That
  // is a genuine zero — Meta ran the ads and nobody converted — so say 0, not "—".
  return { results: 0, result_label: map.label };
}

const ACCOUNT_STATUS: Record<number, string> = {
  1: "Active", 2: "Disabled", 3: "Unsettled", 7: "Pending risk review",
  8: "Pending settlement", 9: "In grace period", 100: "Pending closure",
  101: "Closed", 201: "Any active", 202: "Any closed",
};

// ─────────────────────────────────────────────────────────────────────────────
// §ADS-GUARD — ceilings + the audit row.
//
// Fail-closed means something specific here, and it is worth being precise about
// which parts close and which degrade:
//
//   CLOSED (refuse the request): missing token, missing/malformed account id,
//     unknown action, unknown preset, any Graph error. In every one of those cases
//     the response carries NO metrics at all, so there is nothing for the panel to
//     misread. This is the rule that protects the "no fabricated numbers" promise.
//
//   DEGRADES (still serves): the usage ledger. `meta_ads_usage` is optional — if it
//     is absent or unreachable the request still runs, but the per-isolate bucket
//     below is then the only ceiling. Refusing analytics because a log table is
//     missing would be theatre, not safety, so it is called out rather than faked:
//     the response says `guard:"local-only"` when the ledger was unavailable.
//
// OPTIONAL LEDGER TABLE (create only if you want durable metering):
//   create table public.meta_ads_usage (
//     id bigserial primary key,
//     created_at timestamptz not null default now(),
//     action text, account_id text, ok boolean, step text, calls int
//   );
//   -- no policies: written with the service role from inside this function only.
// The ledger records the ACTION and the OUTCOME. It never records the token, and
// never records a metric value.
// ─────────────────────────────────────────────────────────────────────────────
const localHits: number[] = [];
function localBucketOk(): boolean {
  const now = Date.now();
  while (localHits.length && now - localHits[0] > 60_000) localHits.shift();
  if (localHits.length >= ADS_MAX_PER_MIN_LOCAL) return false;
  localHits.push(now);
  return true;
}

// deno-lint-ignore no-explicit-any
function adminClient(): any {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return null;
  return createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const ch = corsHeaders(origin);

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return jsonRes({ ok: false, step: "method", title: "POST only", detail: "", remedy: "" }, 405, ch);

  // ── ceiling 1: per-isolate, needs nothing ──────────────────────────────────
  if (!localBucketOk()) {
    return failRes({
      step: "rate_ceiling", http: 429,
      title: "SIGMA is throttling its own calls to Meta.",
      detail: "More than " + ADS_MAX_PER_MIN_LOCAL + " requests in a minute from this instance.",
      remedy: "Wait a moment and press Refresh. This ceiling exists so a stuck browser tab cannot burn the ad account's Graph quota.",
    }, ch);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return failRes({ step: "bad_request", http: 400, title: "Invalid JSON body.", detail: "", remedy: "" }, ch);
  }

  const action = String(payload?.action ?? "").trim() || "diagnose";
  if (action !== "diagnose" && action !== "overview" && action !== "adsets") {
    return failRes({
      step: "bad_request", http: 400,
      title: "Unknown action.",
      detail: "Received: " + String(action).slice(0, 40),
      remedy: "This function serves only: diagnose, overview, adsets. It is read-only by design — see §ADS-NO-WRITE.",
    }, ch);
  }

  // ── §ADS-AUTH ──────────────────────────────────────────────────────────────
  // Deployed with verify_jwt=false, because SIGMA's real login path is the local
  // SHA-256 check and carries no Supabase user JWT (see §RLS-HARDENING in the app).
  // fish-tts has the same shape. If the bureau later moves login to Supabase Auth,
  // set META_REQUIRE_AUTH=1 and this becomes a hard gate with no code change.
  //
  // Worth stating plainly: with the default (off), anyone who learns this URL can
  // read the bureau's ad METRICS. They cannot spend, cannot write, and cannot see
  // the token. That is the tradeoff, and it is the same one fish-tts already makes.
  if (Deno.env.get("META_REQUIRE_AUTH") === "1") {
    const authz = req.headers.get("authorization") || "";
    const bearer = authz.toLowerCase().startsWith("bearer ") ? authz.slice(7).trim() : "";
    const db = adminClient();
    let userOk = false;
    if (bearer && db) {
      try {
        const { data } = await db.auth.getUser(bearer);
        userOk = !!data?.user?.id;
      } catch { userOk = false; }
    }
    if (!userOk) {
      return failRes({
        step: "unauthorised", http: 401,
        title: "Sign-in required.",
        detail: "META_REQUIRE_AUTH is on and the request carried no valid Supabase user token.",
        remedy: "Sign in again, or unset META_REQUIRE_AUTH if SIGMA is still on the local login path.",
      }, ch);
    }
  }

  // ── the token. Server-side only, never from the body. ──────────────────────
  const token = Deno.env.get("META_ACCESS_TOKEN");
  if (!token) {
    return failRes({
      step: "no_secret", http: 503,
      title: "META_ACCESS_TOKEN is not set on the server.",
      detail: "The Edge Function is deployed but has no Meta credential, so no advertising data can be read. Nothing is being shown because nothing is known.",
      remedy: "Supabase → Project Settings → Edge Functions → Secrets → add META_ACCESS_TOKEN (a long-lived User token, or a System User token from Business Manager, carrying ads_read).",
    }, ch);
  }

  const account = normAccount(payload?.accountId ?? Deno.env.get("META_AD_ACCOUNT_ID"));
  if (!account) {
    const supplied = String(payload?.accountId ?? Deno.env.get("META_AD_ACCOUNT_ID") ?? "");
    return failRes({
      step: supplied ? "bad_account_id" : "no_account",
      http: supplied ? 400 : 503,
      title: supplied ? "That ad account id is not a valid Meta account id." : "No ad account id has been recorded.",
      detail: supplied
        ? "Received " + JSON.stringify(supplied.slice(0, 40)) + ". Meta ad account ids are all digits, optionally prefixed act_."
        : "Neither SIGMA Settings nor the META_AD_ACCOUNT_ID secret holds one.",
      remedy: "Open Meta Ads Manager; the id is in the address bar as act_1234567890. Record it in SIGMA → Settings → Online AD Management, or set META_AD_ACCOUNT_ID as a Supabase secret.",
    }, ch);
  }

  // ── ceiling 2: durable ledger, when it exists ──────────────────────────────
  const db = adminClient();
  let guard = "local-only";
  if (db) {
    try {
      const since = new Date(Date.now() - 3_600_000).toISOString();
      const { count, error } = await db.from("meta_ads_usage")
        .select("id", { count: "exact", head: true })
        .gte("created_at", since);
      if (!error) {
        guard = "ledger";
        if (typeof count === "number" && count >= ADS_MAX_PER_HOUR) {
          return failRes({
            step: "rate_ceiling", http: 429,
            title: "SIGMA's hourly ceiling for Meta calls has been reached.",
            detail: count + " calls in the last hour (ceiling " + ADS_MAX_PER_HOUR + ").",
            remedy: "Wait for the hour to roll. If this happens in normal use the ceiling is too low — raise ADS_MAX_PER_HOUR in the meta-ads function.",
          }, ch, { guard });
        }
      }
    } catch { guard = "local-only"; }
  }

  // Bookkeeping. Never awaited on the response path, and it carries no token and no
  // metric — only which action ran and how it ended.
  const note = (ok: boolean, step: string, calls: number) => {
    if (!db || guard !== "ledger") return;
    try {
      db.from("meta_ads_usage")
        .insert({ action, account_id: account, ok, step, calls })
        .then(() => {}, () => {});
    } catch { /* bookkeeping must never break a read */ }
  };

  // ── every action begins by resolving the account. It is the cheapest call, it
  //    proves the token AND the permission AND the account in one round trip, and
  //    it is where the CURRENCY comes from. Currency is never assumed: the panel
  //    formats money with whatever Meta says this account bills in.
  const accRes = await graphGet(account, {
    fields: "id,account_id,name,currency,timezone_name,account_status,business_name,amount_spent,spend_cap",
  }, token);
  if (accRes.diag) {
    note(false, accRes.diag.step, 1);
    return failRes(accRes.diag, ch, { guard, account_id: account });
  }
  const a = accRes.data as Record<string, unknown>;
  const acct = {
    id: str(a.id),
    account_id: str(a.account_id),
    name: str(a.name),
    currency: str(a.currency),
    timezone_name: str(a.timezone_name),
    account_status: num(a.account_status),
    account_status_text: ACCOUNT_STATUS[Number(a.account_status)] ?? null,
    business_name: str(a.business_name),
    // amount_spent arrives in MINOR units (cents) for most currencies. It is passed
    // through as Meta sent it, with the unit named, rather than silently divided by
    // 100 — a wrong divisor is exactly the kind of quiet lie this file exists to
    // avoid. The panel shows it only where it can say "lifetime, minor units".
    amount_spent_minor: num(a.amount_spent),
  };

  // ── action: diagnose ───────────────────────────────────────────────────────
  if (action === "diagnose") {
    note(true, "ok", 1);
    return jsonRes({
      ok: true,
      step: "ok",
      guard,
      graph_version: Deno.env.get("META_GRAPH_VERSION") || GRAPH_DEFAULT,
      account: acct,
      // A checklist the Settings panel prints verbatim. Each line is something that
      // was actually PROVEN by the round trip above, not something assumed.
      checks: [
        { key: "secret", label: "META_ACCESS_TOKEN is set on the server", state: "ok", detail: "Present. Its value is never returned to the browser." },
        { key: "account", label: "Ad account id is valid and reachable", state: "ok", detail: account },
        { key: "ads_read", label: "Token carries ads_read for this account", state: "ok", detail: "Proven: Meta answered a read on this ad account." },
        {
          key: "status", label: "Ad account status",
          state: Number(a.account_status) === 1 ? "ok" : "warn",
          detail: (acct.account_status_text ?? "unknown") + (Number(a.account_status) === 1 ? "" : " — campaigns may not deliver while the account is in this state."),
        },
        {
          key: "currency", label: "Reporting currency",
          state: acct.currency ? "ok" : "warn",
          detail: acct.currency ?? "Meta did not report a currency; money will be shown unformatted.",
        },
        {
          key: "ads_management", label: "Token carries ads_management (create / edit campaigns)",
          state: "na",
          detail: "Not tested and not used. SIGMA never writes to Meta — see the Create-campaign note. Creating campaigns in-app would need this permission plus Meta App Review.",
        },
      ],
    }, 200, ch);
  }

  // ── action: adsets ─────────────────────────────────────────────────────────
  if (action === "adsets") {
    const p: Record<string, string> = {
      fields: "id,name,status,effective_status,campaign_id,daily_budget,lifetime_budget,optimization_goal,billing_event,start_time,end_time",
      limit: "100",
    };
    const cid = str(payload?.campaignId);
    if (cid && /^\d{5,25}$/.test(cid)) {
      const r = await graphGet(cid + "/adsets", p, token);
      if (r.diag) { note(false, r.diag.step, 2); return failRes(r.diag, ch, { guard }); }
      note(true, "ok", 2);
      return jsonRes({ ok: true, guard, account: acct, adsets: (r.data?.data as unknown[]) ?? [] }, 200, ch);
    }
    const r = await graphGet(account + "/adsets", p, token);
    if (r.diag) { note(false, r.diag.step, 2); return failRes(r.diag, ch, { guard }); }
    note(true, "ok", 2);
    return jsonRes({ ok: true, guard, account: acct, adsets: (r.data?.data as unknown[]) ?? [] }, 200, ch);
  }

  // ── action: overview ───────────────────────────────────────────────────────
  const presetKey = String(payload?.preset ?? "last_7d");
  const preset = PRESETS[presetKey];
  if (!preset) {
    return failRes({
      step: "bad_request", http: 400,
      title: "Unknown date range.",
      detail: "Received: " + presetKey.slice(0, 30),
      remedy: "Allowed: today, last_7d, last_30d, maximum.",
    }, ch, { guard });
  }

  let calls = 1;

  // (2) the campaigns themselves — names, objectives, statuses, budgets.
  const campRes = await graphGet(account + "/campaigns", {
    fields: "id,name,status,effective_status,objective,daily_budget,lifetime_budget,budget_remaining,start_time,stop_time,created_time,updated_time",
    limit: "50",
  }, token);
  calls++;
  if (campRes.diag) { note(false, campRes.diag.step, calls); return failRes(campRes.diag, ch, { guard, account: acct }); }
  const rawCampaigns = (campRes.data?.data as Array<Record<string, unknown>>) ?? [];

  // (3) the metrics, one row per campaign, for the chosen window.
  const insRes = await graphGet(account + "/insights", {
    level: "campaign",
    date_preset: preset,
    fields: "campaign_id,campaign_name,objective,impressions,reach,frequency,clicks,ctr,cpc,cpm,spend,actions,date_start,date_stop",
    limit: "200",
  }, token);
  calls++;
  if (insRes.diag) { note(false, insRes.diag.step, calls); return failRes(insRes.diag, ch, { guard, account: acct }); }
  const insRows = (insRes.data?.data as Array<Record<string, unknown>>) ?? [];
  const byCampaign = new Map<string, Record<string, unknown>>();
  for (const row of insRows) {
    const k = str(row.campaign_id);
    if (k) byCampaign.set(k, row);
  }

  // (4) OPTIONAL daily series for the sparkline. Requested only when the panel asks
  //     for it, so the default refresh is 3 Graph calls, not 4.
  const daily = payload?.daily === true && preset !== "today";
  const series = new Map<string, Array<Record<string, number | string | null>>>();
  if (daily) {
    const dayRes = await graphGet(account + "/insights", {
      level: "campaign",
      date_preset: preset,
      time_increment: "1",
      fields: "campaign_id,impressions,reach,clicks,spend,date_start",
      limit: "500",
    }, token);
    calls++;
    // A failed sparkline must not take the whole panel down — but it must also not
    // be silently replaced with a flat line. On failure the series stays absent and
    // the panel draws no chart at all.
    if (!dayRes.diag) {
      for (const row of ((dayRes.data?.data as Array<Record<string, unknown>>) ?? [])) {
        const k = str(row.campaign_id);
        if (!k) continue;
        if (!series.has(k)) series.set(k, []);
        series.get(k)!.push({
          d: str(row.date_start),
          impressions: num(row.impressions),
          reach: num(row.reach),
          clicks: num(row.clicks),
          spend: num(row.spend),
        });
      }
    }
  }

  const campaigns = rawCampaigns.map((c) => {
    const id = str(c.id);
    const ins = id ? byCampaign.get(id) : undefined;
    const objective = str(c.objective);
    const res = ins ? pickResult(objective, ins.actions) : { results: null, result_label: null };
    return {
      id,
      name: str(c.name),
      status: str(c.status),
      effective_status: str(c.effective_status),
      objective,
      // Budgets are minor units too. Same rule as amount_spent: named, not converted.
      daily_budget_minor: num(c.daily_budget),
      lifetime_budget_minor: num(c.lifetime_budget),
      budget_remaining_minor: num(c.budget_remaining),
      start_time: str(c.start_time),
      stop_time: str(c.stop_time),
      created_time: str(c.created_time),
      // `null` means Meta returned NO insight row for this campaign in this window —
      // i.e. it did not deliver. The panel says exactly that. It does not say 0.
      insights: ins
        ? {
          impressions: num(ins.impressions),
          reach: num(ins.reach),
          frequency: num(ins.frequency),
          clicks: num(ins.clicks),
          ctr: num(ins.ctr),
          cpc: num(ins.cpc),
          cpm: num(ins.cpm),
          // spend is in MAJOR units in the insights edge (unlike budgets). Meta is
          // inconsistent here; the field names carry the unit so nothing downstream
          // has to remember which is which.
          spend: num(ins.spend),
          results: res.results,
          result_label: res.result_label,
          date_start: str(ins.date_start),
          date_stop: str(ins.date_stop),
        }
        : null,
      series: id && series.has(id) ? series.get(id) : null,
    };
  });

  note(true, "ok", calls);
  return jsonRes({
    ok: true,
    guard,
    graph_version: Deno.env.get("META_GRAPH_VERSION") || GRAPH_DEFAULT,
    account: acct,
    currency: acct.currency,
    preset: presetKey,
    calls,
    fetched_at: new Date().toISOString(),
    campaigns,
    // Told, not implied: if Meta returned no insight rows at all, the panel must be
    // able to distinguish "no campaigns" from "campaigns that did not deliver".
    insight_rows: insRows.length,
  }, 200, ch);
});

// ─────────────────────────────────────────────────────────────────────────────
// §ADS-NO-WRITE — why campaign creation is not in this file.
//
// Creating a campaign through the API is not one call. The minimum viable chain is
//   POST act_X/campaigns   → objective, special_ad_categories, status
//   POST act_X/adsets      → daily_budget, billing_event, optimization_goal,
//                            bid_strategy, targeting{geo,age,interests}, promoted_object
//   POST act_X/adcreatives → page_id, link, message, image_hash|video_id, call_to_action
//   POST act_X/ads         → creative + adset
// plus an image upload (act_X/adimages) and a Facebook Page the token administers.
//
// ALL FOUR require the `ads_management` permission. `ads_management` is not a
// checkbox: Meta grants it through App Review, which needs a business verification,
// a privacy policy URL, a screencast of the integration and a written use case. In
// practice that is days for a clean submission and weeks if anything is queried.
//
// So: writing it now would produce four endpoints that cannot be called, cannot be
// tested, and would rot. The dashboard deep-links to Ads Manager for the connected
// account instead — a URL that needs no permission at all and is the tool the owner
// already uses. If and when ads_management is granted, this is where the write side
// belongs, and the guard rails above (ceiling, ledger, redaction, fail-closed) are
// already the right shape for it.
// ─────────────────────────────────────────────────────────────────────────────
