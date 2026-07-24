// ─────────────────────────────────────────────────────────────────────────────
// sigma-email — send invoice-related email through Resend.
//
// WHY server-side: SIGMA has no email capability (everything else is a mailto:).
// An invoice must not be marked "sent" unless a provider actually accepted it, so
// the send, the delivery record, and the invoice's email_status all happen here in
// one place with the service role.
//
// AUTH: Finance is authenticated-only (Option A). This function is deployed with
// verify_jwt=false and does its OWN check — it calls auth.getUser(token) and
// refuses anything whose role is not `authenticated`. The anon key is a valid JWT
// but resolves to no user, so it cannot send mail.
//
// CONFIG (Supabase secrets):
//   RESEND_API_KEY   required to actually send; absent → {ok:false,error:'not_configured'}
//   RESEND_FROM      e.g. 'Taxatie Bureau <billing@taxatie-bureau.com>'
//                    (the domain must be verified in Resend)
//
// Request (POST JSON, Authorization: Bearer <user session token>):
//   { invoice_id, kind?, to, cc?, subject, html, attachment?:{ name, contentBase64 } }
// Response: { ok:true, id, provider_msg_id } | { ok:false, error }
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
  return new Response(JSON.stringify(obj), { status, headers: { ...ch, "Content-Type": "application/json" } });
}

function admin() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("supabase env missing");
  return createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const ch = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return jsonRes({ ok: false, error: "POST only" }, 405, ch);

  // ── auth: require a real (authenticated) user, not anon ──
  const authz = req.headers.get("authorization") || "";
  const token = authz.replace(/^Bearer\s+/i, "").trim();
  if (!token) return jsonRes({ ok: false, error: "sign-in required" }, 401, ch);

  let sb;
  try { sb = admin(); } catch (e) { return jsonRes({ ok: false, error: String((e as Error).message) }, 500, ch); }

  let userEmail = "";
  try {
    const { data, error } = await sb.auth.getUser(token);
    const role = (data?.user?.role as string) || "";
    if (error || !data?.user || role === "anon") {
      return jsonRes({ ok: false, error: "a cloud sign-in is required to send invoices" }, 401, ch);
    }
    userEmail = data.user.email || "";
  } catch {
    return jsonRes({ ok: false, error: "could not verify sign-in" }, 401, ch);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return jsonRes({ ok: false, error: "invalid JSON body" }, 400, ch); }

  const invoiceId = body.invoice_id ? String(body.invoice_id) : null;
  const kind = String(body.kind || "invoice");
  const to = String(body.to || "").trim();
  const cc = body.cc ? String(body.cc).trim() : "";
  const subject = String(body.subject || "").trim();
  const html = String(body.html || "");
  const attachment = body.attachment as { name?: string; contentBase64?: string } | undefined;

  if (!to || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) return jsonRes({ ok: false, error: "a valid recipient email is required" }, 400, ch);
  if (!subject) return jsonRes({ ok: false, error: "subject is required" }, 400, ch);
  if (!html) return jsonRes({ ok: false, error: "message body is required" }, 400, ch);

  // Resolve the invoice number for the log (best effort).
  let invNumber: string | null = null;
  if (invoiceId) {
    try {
      const { data } = await sb.from("invoices").select("invoice_number").eq("id", invoiceId).maybeSingle();
      invNumber = data?.invoice_number ?? null;
    } catch { /* ignore */ }
  }

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  const RESEND_FROM = Deno.env.get("RESEND_FROM") || "SIGMA <onboarding@resend.dev>";

  // Log the attempt up front so a failure is never invisible.
  let logId: string | null = null;
  try {
    const { data } = await sb.from("invoice_emails").insert({
      invoice_id: invoiceId, invoice_number: invNumber, kind,
      recipient: to, cc: cc || null, subject,
      attachment_name: attachment?.name || null,
      status: "queued", sent_by: userEmail,
    }).select("id").single();
    logId = data?.id ?? null;
  } catch { /* logging must not block a send */ }

  async function finish(status: string, providerId: string | null, error: string | null) {
    if (logId) {
      try {
        await sb.from("invoice_emails").update({
          status, provider_msg_id: providerId, error,
          sent_at: status === "sent" ? new Date().toISOString() : null,
        }).eq("id", logId);
      } catch { /* ignore */ }
    }
    // Mark the invoice emailed ONLY on a real success.
    if (status === "sent" && invoiceId) {
      try { await sb.from("invoices").update({ email_status: "sent" }).eq("id", invoiceId); } catch { /* ignore */ }
    }
  }

  if (!RESEND_API_KEY) {
    await finish("failed", null, "RESEND_API_KEY not configured");
    return jsonRes({ ok: false, error: "not_configured",
      detail: "Email is not set up yet — add the RESEND_API_KEY secret and a verified RESEND_FROM address." }, 503, ch);
  }

  const payload: Record<string, unknown> = { from: RESEND_FROM, to: [to], subject, html };
  if (cc) payload.cc = cc.split(",").map((s) => s.trim()).filter(Boolean);
  if (attachment?.contentBase64 && attachment?.name) {
    payload.attachments = [{ filename: attachment.name, content: attachment.contentBase64 }];
  }

  let resp: Response;
  try {
    resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    await finish("failed", null, "network: " + String(e));
    return jsonRes({ ok: false, error: "could not reach the email provider", detail: String(e) }, 502, ch);
  }

  const result = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    const detail = (result && (result.message || result.error)) || ("HTTP " + resp.status);
    await finish("failed", null, String(detail).slice(0, 500));
    return jsonRes({ ok: false, error: "provider rejected the email", detail }, 502, ch);
  }

  const providerId = (result && result.id) ? String(result.id) : null;
  await finish("sent", providerId, null);
  return jsonRes({ ok: true, id: logId, provider_msg_id: providerId }, 200, ch);
});
