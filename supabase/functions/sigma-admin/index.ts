// ─────────────────────────────────────────────────────────────────────────────
// sigma-admin — provision SIGMA logins as REAL Supabase Auth accounts.
//
// WHY: SIGMA signs in via Supabase Auth first, falling back to a SHA-256 hash in
// localStorage. That local hash only exists on the machine where it was set, so a
// new employee opening SIGMA on their own laptop had nothing to match and fell
// through to Supabase Auth — where the account was missing or unconfirmed. Result:
// "I gave my employee a login but they can't sign in."
//
// This function creates accounts with email_confirm: true, so they work from ANY
// device immediately — no confirmation email, no Supabase dashboard.
//
// AUTHORISATION — the hard part. The SIGMA app is a public static page with the
// anon key embedded in it, so an admin secret can NEVER be shipped inside it.
// Instead the admin types an ADMIN KEY at the moment of provisioning; we verify it
// here against a PBKDF2-SHA256 hash held in the SIGMA_ADMIN_SECRET_HASH secret.
// The key itself is never stored server-side, never in the page, and never in
// localStorage. A wrong key costs a deliberate delay, and the key is long and
// random, so guessing is impractical.
//
// Deploy with verify_jwt=false (we do our own auth) and set:
//   SIGMA_ADMIN_SECRET_HASH = pbkdf2$<iterations>$<saltB64>$<hashB64>
//
// Request (POST JSON, header `Authorization: Bearer <ADMIN KEY>`):
//   { action: "create_user",  email, password, name?, role? }
//   { action: "set_password", email, password }
//   { action: "set_active",   email, active }
//   { action: "list_users" }
//   { action: "ping" }        // verifies the admin key only
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
    status, headers: { ...ch, "Content-Type": "application/json" },
  });
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** Verify the supplied key against `pbkdf2$<iters>$<saltB64>$<hashB64>`. */
async function verifyAdminKey(key: string, stored: string): Promise<boolean> {
  const parts = stored.split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2") return false;
  const iterations = parseInt(parts[1], 10);
  if (!Number.isFinite(iterations) || iterations < 1000) return false;
  const salt = b64ToBytes(parts[2]);
  const expected = b64ToBytes(parts[3]);
  const mat = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations, hash: "SHA-256" }, mat, expected.length * 8,
  );
  return timingSafeEqual(new Uint8Array(bits), expected);
}

function admin() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("supabase env missing");
  return createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
}

/** Look up an auth user by email (listUsers is paged; scan a few pages). */
async function findByEmail(sb: ReturnType<typeof admin>, email: string) {
  const target = email.toLowerCase();
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await sb.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw new Error(error.message);
    const hit = (data?.users || []).find((u: { email?: string }) => (u.email || "").toLowerCase() === target);
    if (hit) return hit;
    if (!data || (data.users || []).length < 200) break;
  }
  return null;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const ch = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return jsonRes({ ok: false, error: "POST only" }, 405, ch);

  const storedHash = Deno.env.get("SIGMA_ADMIN_SECRET_HASH");
  if (!storedHash) return jsonRes({ ok: false, error: "server not configured" }, 500, ch);

  const auth = req.headers.get("authorization") || "";
  const key = auth.replace(/^Bearer\s+/i, "").trim();
  if (!key) return jsonRes({ ok: false, error: "admin key required" }, 401, ch);

  let keyOk = false;
  try { keyOk = await verifyAdminKey(key, storedHash); } catch { keyOk = false; }
  if (!keyOk) {
    await sleep(1200);   // make guessing expensive
    return jsonRes({ ok: false, error: "Admin key not accepted." }, 401, ch);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); }
  catch { return jsonRes({ ok: false, error: "invalid JSON body" }, 400, ch); }

  const action = String(body.action || "");
  const email = String(body.email || "").trim().toLowerCase();
  const password = String(body.password || "");
  const name = String(body.name || "").trim();
  const role = String(body.role || "").trim();

  try {
    const sb = admin();

    if (action === "ping") return jsonRes({ ok: true, action: "ping" }, 200, ch);

    if (action === "list_users") {
      const { data, error } = await sb.auth.admin.listUsers({ page: 1, perPage: 200 });
      if (error) throw new Error(error.message);
      return jsonRes({
        ok: true,
        users: (data?.users || []).map((u: Record<string, unknown>) => ({
          email: u.email,
          confirmed: !!(u.email_confirmed_at || u.confirmed_at),
          last_sign_in_at: u.last_sign_in_at ?? null,
          created_at: u.created_at ?? null,
          banned_until: (u as { banned_until?: string }).banned_until ?? null,
        })),
      }, 200, ch);
    }

    if (!email) return jsonRes({ ok: false, error: "email is required" }, 400, ch);

    if (action === "create_user" || action === "set_password") {
      if (!password || password.length < 8) {
        return jsonRes({ ok: false, error: "password must be at least 8 characters" }, 400, ch);
      }
      const existing = await findByEmail(sb, email);
      if (existing) {
        // Already there → set the password and make sure it's confirmed + unbanned,
        // so a previously stuck account starts working immediately.
        const { error } = await sb.auth.admin.updateUserById(existing.id, {
          password,
          email_confirm: true,
          ban_duration: "none",
          user_metadata: {
            ...(existing.user_metadata || {}),
            ...(name ? { name } : {}),
            ...(role ? { role } : {}),
          },
        });
        if (error) throw new Error(error.message);
        return jsonRes({ ok: true, action, created: false, updated: true, email }, 200, ch);
      }
      const { error } = await sb.auth.admin.createUser({
        email, password,
        email_confirm: true,               // ← the whole point: usable immediately
        user_metadata: { ...(name ? { name } : {}), ...(role ? { role } : {}) },
      });
      if (error) throw new Error(error.message);
      return jsonRes({ ok: true, action, created: true, updated: false, email }, 200, ch);
    }

    if (action === "set_active") {
      const active = body.active !== false;
      const existing = await findByEmail(sb, email);
      if (!existing) return jsonRes({ ok: false, error: "no cloud account for " + email }, 404, ch);
      const { error } = await sb.auth.admin.updateUserById(existing.id, {
        ban_duration: active ? "none" : "876000h",   // ~100 years = disabled
      });
      if (error) throw new Error(error.message);
      return jsonRes({ ok: true, action, email, active }, 200, ch);
    }

    return jsonRes({ ok: false, error: "unknown action: " + action }, 400, ch);
  } catch (e) {
    return jsonRes({ ok: false, error: String((e as Error)?.message || e) }, 500, ch);
  }
});
