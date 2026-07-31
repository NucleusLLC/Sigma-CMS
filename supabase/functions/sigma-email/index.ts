// ─────────────────────────────────────────────────────────────────────────────
// sigma-email — send invoice-related email through the bureau's own SMTP mailbox.
//
// WHY server-side: SIGMA has no email capability (everything else is a mailto:).
// An invoice must not be marked "sent" unless the mail server actually accepted it,
// so the send, the delivery record, and the invoice's email_status all happen here
// in one place with the service role.
//
// WHY SMTP and not Resend (changed 2026-07-30): the bureau already sends mail from
// its own A2 Hosting mailbox for taxatie-bureau.com. Adding Resend would have meant
// a second provider, a second bill and a second sending reputation to maintain for
// the same domain. Invoices now leave from the same mailbox the rest of the business
// uses, so SPF/DKIM/DMARC are already aligned and nothing new needs verifying.
//
// AUTH: unchanged. Deployed with verify_jwt=false; it does its OWN check by calling
// auth.getUser(token). The anon key is a valid JWT but resolves to no user, so the
// caller's identity is recorded when there is one and falls back to body.sent_by.
//
// CONFIG (Supabase secrets):
//   SMTP_HOST  e.g. mail.taxatie-bureau.com
//   SMTP_PORT  465 (implicit TLS) or 587 (STARTTLS)
//   SMTP_USER  the full mailbox address
//   SMTP_PASS  that mailbox's password
//   SMTP_FROM  e.g. 'Taxatie Bureau Jozef Laclé <website@taxatie-bureau.com>'
//              Most servers insist the From address matches SMTP_USER; if the send
//              is rejected for that reason the error is surfaced verbatim.
//   Missing any of HOST/USER/PASS → {ok:false,error:'not_configured'}.
//
// Request (POST JSON, Authorization: Bearer <session token>):
//   { invoice_id, kind?, to, cc?, subject, html, attachment?:{ name, contentBase64 } }
// Response: { ok:true, id, provider_msg_id } | { ok:false, error }
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

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

// base64 → bytes, for the PDF attachment.
function b64ToBytes(b64: string): Uint8Array {
  const clean = b64.replace(/^data:[^;]+;base64,/, "").replace(/\s+/g, "");
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const ch = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return jsonRes({ ok: false, error: "POST only" }, 405, ch);

  const authz = req.headers.get("authorization") || "";
  const token = authz.replace(/^Bearer\s+/i, "").trim();
  if (!token) return jsonRes({ ok: false, error: "sign-in required" }, 401, ch);

  let sb;
  try { sb = admin(); } catch (e) { return jsonRes({ ok: false, error: String((e as Error).message) }, 500, ch); }

  // §FINANCE-OPEN (v2.278) — the app calls this with its normal (anon) key, like the
  //   rest of SIGMA. If the token resolves to a real user we record their email;
  //   otherwise we fall back to the sender passed in the body. No separate sign-in.
  let userEmail = "";
  try {
    const { data } = await sb.auth.getUser(token);
    userEmail = data?.user?.email || "";
  } catch { /* anon key → no user; fine */ }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return jsonRes({ ok: false, error: "invalid JSON body" }, 400, ch); }
  if (!userEmail && body.sent_by) userEmail = String(body.sent_by);

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

  const SMTP_HOST = Deno.env.get("SMTP_HOST") || "";
  const SMTP_PORT = Number(Deno.env.get("SMTP_PORT") || "465");
  const SMTP_USER = Deno.env.get("SMTP_USER") || "";
  const SMTP_PASS = Deno.env.get("SMTP_PASS") || "";
  const SMTP_FROM = Deno.env.get("SMTP_FROM") || SMTP_USER;

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

  if (!SMTP_HOST || !SMTP_USER || !SMTP_PASS) {
    await finish("failed", null, "SMTP not configured");
    return jsonRes({ ok: false, error: "not_configured",
      detail: "Email is not set up yet — add the SMTP_HOST, SMTP_USER and SMTP_PASS secrets." }, 503, ch);
  }

  // Port 465 is implicit TLS; 587 negotiates STARTTLS after connecting.
  const client = new SMTPClient({
    connection: {
      hostname: SMTP_HOST,
      port: SMTP_PORT,
      tls: SMTP_PORT === 465,
      auth: { username: SMTP_USER, password: SMTP_PASS },
    },
  });

  try {
    const msg: Record<string, unknown> = {
      from: SMTP_FROM,
      to,
      subject,
      html,
      // A text/plain alternative keeps it out of spam filters that distrust HTML-only mail.
      content: html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim(),
    };
    if (cc) msg.cc = cc.split(",").map((s) => s.trim()).filter(Boolean);
    if (attachment?.contentBase64 && attachment?.name) {
      msg.attachments = [{
        filename: attachment.name,
        content: b64ToBytes(attachment.contentBase64),
        encoding: "binary",
        contentType: /\.pdf$/i.test(attachment.name) ? "application/pdf" : "application/octet-stream",
      }];
    }
    await client.send(msg as never);
  } catch (e) {
    const detail = String((e as Error)?.message || e).slice(0, 500);
    await finish("failed", null, detail);
    try { await client.close(); } catch { /* ignore */ }
    return jsonRes({ ok: false, error: "the mail server rejected the message", detail }, 502, ch);
  }

  try { await client.close(); } catch { /* ignore */ }

  // SMTP gives no provider-side id the way an API would; record the mailbox used so
  // the delivery log still says where it went from.
  await finish("sent", "smtp:" + SMTP_USER, null);
  return jsonRes({ ok: true, id: logId, provider_msg_id: "smtp:" + SMTP_USER }, 200, ch);
});
