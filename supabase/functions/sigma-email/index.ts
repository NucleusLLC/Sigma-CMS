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
//   { invoice_id, kind?, to, cc?: string[], subject, html, attachment?:{ name, contentBase64 } }
// Response: { ok:true, id, provider_msg_id, cc, cc_dropped, warning? }
//         | { ok:false, error }
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
// denomailer's OWN address predicate — see §DENOMAILER-CC-BUG below for why this
// library-internal import is deliberate and load-bearing. Same pinned version as
// the client above, so the two can never disagree.
import { isSingleMail } from "https://deno.land/x/denomailer@1.6.0/config/mail/email.ts";

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

// A plain address and nothing else: no whitespace (so no CR/LF can reach a header),
// and no angle brackets (so 'Name <a@b.com>' never lands in the delivery log as if
// it were an address).
const EMAIL_RE = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;

// ─────────────────────────────────────────────────────────────────────────────
// §DENOMAILER-CC-BUG — why every address is checked TWICE.
//
// denomailer 1.6.0, config/mail/mod.ts, in the block that validates recipients:
//
//     const valCc = validateEmailList(config.cc);
//     if (valCc.bad.length > 0) {
//       config.to = valCc.ok;          // ← assigns to `to`, not `cc`
//
// If ANY cc address fails denomailer's own isSingleMail() test, the library
// OVERWRITES the To list with the surviving CC addresses. The client is silently
// dropped from the envelope and the invoice goes only to the bureau — and the send
// still succeeds, so we would record it as delivered to a client who never got it.
// (The bcc branch has the identical typo.) The same assignment also means a `to`
// address that denomailer dislikes empties the To list while the CCs keep it from
// erroring, with the same result.
//
// It cannot be caught after the fact: the send returns success either way.
//
// So the guard is upstream. Nothing is ever handed to denomailer that denomailer
// would call bad — isSingleMail is imported from the same pinned version and used
// as the gate, so `valCc.bad` and `valTo.bad` are provably always empty and that
// branch can never run. EMAIL_RE is applied as well because isSingleMail alone
// also accepts 'Name <a@b.com>', which we do not want in a header or a log row.
// ─────────────────────────────────────────────────────────────────────────────
function sendableAddress(e: string): boolean {
  return EMAIL_RE.test(e) && isSingleMail(e);
}

// ─────────────────────────────────────────────────────────────────────────────
// §INVOICE-CC (v2.309) — copy the bureau in on every invoice it sends.
//
// The owner wants himself and his daughter copied on client invoices, with the
// list editable in Finance settings. The list arrives here as `cc: string[]`.
//
// THE RULE THIS FILE ENFORCES: a bad CC address must never cost the client its
// invoice. Everything below is written so the primary recipient is served first
// and the CC list is best-effort on top of it:
//
//   • junk entries are dropped here, before the mail server ever sees them — an
//     empty string, a missing '@', a stray name, whatever the settings box let
//     through. Dropping is silent to SMTP but recorded in invoice_emails.
//   • the primary recipient is never also CC'd (the client would get it twice),
//     and duplicates collapse case-insensitively.
//   • the list is capped, so a pasted address book cannot turn one invoice into
//     a bulk mailing that gets the mailbox rate-limited or blacklisted.
//   • HEADER INJECTION is impossible by construction, not by escaping: EMAIL_RE
//     rejects every whitespace character, so a CR or LF can never reach a header.
// ─────────────────────────────────────────────────────────────────────────────
const CC_MAX = 10;          // a copy list, not a mailing list
const ADDR_MAX = 254;       // RFC 5321 maximum path length

function normalizeCc(raw: unknown, primary: string): { list: string[]; dropped: string[] } {
  // The contract is string[]. A comma/semicolon string is still accepted because
  // that is what this function took before v2.309, and an older client in a stale
  // tab must not start failing.
  let parts: string[] = [];
  if (Array.isArray(raw)) parts = raw.map((v) => String(v ?? ""));
  else if (typeof raw === "string") parts = raw.split(/[,;]/);

  const seen = new Set<string>([primary.trim().toLowerCase()]);
  const list: string[] = [];
  const dropped: string[] = [];

  for (const p of parts) {
    const e = p.trim().toLowerCase();
    if (!e) continue;                                   // blanks are not an error
    // A rejected entry is recorded AS THE OWNER TYPED IT (case and all), so the log
    // shows him his own typo rather than a normalised version of it. Whitespace is
    // collapsed only so a pasted line-break cannot make the log unreadable.
    if (e.length > ADDR_MAX || !sendableAddress(e)) { dropped.push(p.trim().replace(/\s+/g, " ").slice(0, ADDR_MAX)); continue; }
    if (seen.has(e)) continue;                          // dupe, or the client itself
    if (list.length >= CC_MAX) { dropped.push(e); continue; }
    seen.add(e);
    list.push(e);
  }
  return { list, dropped };
}

// Did the mail server refuse the message because of a CC address rather than the
// client's? denomailer puts every recipient in ONE SMTP transaction, so a single
// bad RCPT TO sinks the whole send — including the invoice the client is waiting
// for. When that is what happened we retry once without the CC list.
//
// The gates below exist to make that retry safe, because a retry that re-delivers
// a message the server already accepted would send the client the invoice twice:
//   • never retry on a transport failure (timeout, dropped connection). Those are
//     the only errors that can be raised AFTER the message was accepted, and they
//     are never caused by a CC address anyway.
//   • never retry when the server named the PRIMARY recipient — dropping the CCs
//     cannot fix that, and pretending otherwise just doubles the damage.
function ccLikelyAtFault(detail: string, ccList: string[], primary: string): boolean {
  if (!ccList.length) return false;
  const d = detail.toLowerCase();
  if (/(timed out|timeout|connection|closed|reset|econn|broken pipe|socket)/.test(d)) return false;
  if (d.includes(primary.trim().toLowerCase())) return false;
  if (ccList.some((a) => d.includes(a))) return true;   // the server named a CC address
  // Deliberately NOT keyed on the bare 55x code. '552 Message size exceeds limit'
  // and '535 Authentication failed' are 5xx failures that no amount of dropping CCs
  // will fix, and a retry there is a second doomed connection for nothing. Only
  // wording that actually means "I refuse this recipient" counts.
  return /(recipient|rcpthost|relay|unknown user|user unknown|no such user|mailbox unavailable|mailbox not found|no mailbox|address rejected|does not exist)/.test(d);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const ch = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return jsonRes({ ok: false, error: "POST only" }, 405, ch);

  const authz = req.headers.get("authorization") || "";
  const token = authz.replace(/^Bearer\s+/i, "").trim();
  if (!token) return jsonRes({ ok: false, error: "sign-in required" }, 401, ch);

  // Typed rather than inferred: `finish()` closes over it further down, and without
  // an annotation that closure makes it implicitly `any` (it always did — this is
  // the only reason `deno check` ever failed on this file).
  let sb!: ReturnType<typeof admin>;
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
  const subject = String(body.subject || "").trim();
  const html = String(body.html || "");
  const attachment = body.attachment as { name?: string; contentBase64?: string } | undefined;

  // Checked with the same gate as the CCs (§DENOMAILER-CC-BUG): an address the mail
  // library would classify as bad must be refused HERE, in words, rather than
  // quietly emptying the To list downstream and mailing the invoice to nobody.
  if (!to || to.length > ADDR_MAX || !sendableAddress(to)) {
    return jsonRes({ ok: false, error: "a valid recipient email is required" }, 400, ch);
  }
  if (!subject) return jsonRes({ ok: false, error: "subject is required" }, 400, ch);
  if (!html) return jsonRes({ ok: false, error: "message body is required" }, 400, ch);

  // §INVOICE-CC — validated AFTER the primary recipient, and never able to reject
  // the request: a malformed CC entry is dropped, not raised.
  const { list: ccList, dropped: ccDropped } = normalizeCc(body.cc, to);

  // Resolve the invoice number + order for the log (best effort). order_number is
  // denormalised onto the log row so the history still reads under its project
  // after the invoice itself is gone (invoice_id is ON DELETE SET NULL).
  let invNumber: string | null = null;
  let ordNumber: string | null = null;
  if (invoiceId) {
    try {
      const { data } = await sb.from("invoices").select("invoice_number, order_number").eq("id", invoiceId).maybeSingle();
      invNumber = data?.invoice_number ?? null;
      ordNumber = data?.order_number ?? null;
    } catch { /* ignore */ }
  }

  const SMTP_HOST = Deno.env.get("SMTP_HOST") || "";
  const SMTP_PORT = Number(Deno.env.get("SMTP_PORT") || "465");
  const SMTP_USER = Deno.env.get("SMTP_USER") || "";
  const SMTP_PASS = Deno.env.get("SMTP_PASS") || "";
  const SMTP_FROM = Deno.env.get("SMTP_FROM") || SMTP_USER;

  // Log the attempt up front so a failure is never invisible. One row per request:
  // the retry below is part of the same send, not a second one, so it updates this
  // row rather than writing another — the history must read as one line per invoice
  // actually put on the wire.
  let logId: string | null = null;
  try {
    const { data } = await sb.from("invoice_emails").insert({
      invoice_id: invoiceId, invoice_number: invNumber, order_number: ordNumber, kind,
      recipient: to,
      cc: ccList.length ? ccList.join(", ") : null,   // legacy text column, kept readable
      cc_emails: ccList,                              // the list as actually used
      cc_dropped: ccDropped.length ? ccDropped : null,
      subject,
      attachment_name: attachment?.name || null,
      status: "queued", provider: "smtp", sent_by: userEmail,
    }).select("id").single();
    logId = data?.id ?? null;
  } catch { /* logging must not block a send */ }

  // Returns the exact timestamp written to the log, so the confirmation the user is
  // shown is the same instant the history will show them tomorrow — not a second
  // clock reading taken on the way out.
  async function finish(status: string, providerId: string | null, error: string | null,
                        ccUsed: string[], ccLost: string[], warning: string | null): Promise<string | null> {
    const sentAt = status === "sent" ? new Date().toISOString() : null;
    if (logId) {
      try {
        await sb.from("invoice_emails").update({
          status, provider_msg_id: providerId, error, warning,
          cc: ccUsed.length ? ccUsed.join(", ") : null,
          cc_emails: ccUsed,
          cc_dropped: ccLost.length ? ccLost : null,
          sent_at: sentAt,
        }).eq("id", logId);
      } catch { /* ignore */ }
    }
    // Mark the invoice emailed ONLY on a real success.
    if (status === "sent" && invoiceId) {
      try { await sb.from("invoices").update({ email_status: "sent" }).eq("id", invoiceId); } catch { /* ignore */ }
    }
    return sentAt;
  }

  if (!SMTP_HOST || !SMTP_USER || !SMTP_PASS) {
    await finish("failed", null, "SMTP not configured", ccList, ccDropped, null);
    return jsonRes({ ok: false, error: "not_configured",
      detail: "Email is not set up yet — add the SMTP_HOST, SMTP_USER and SMTP_PASS secrets." }, 503, ch);
  }

  // One attempt = one fresh client. A client that threw mid-transaction is not in a
  // state worth reusing, and the retry has to start from a clean connection.
  async function sendOnce(cc: string[]): Promise<string | null> {
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
      // A real Cc header, not a bcc: the client should see that the bureau is copied.
      if (cc.length) msg.cc = cc;
      if (attachment?.contentBase64 && attachment?.name) {
        msg.attachments = [{
          filename: attachment.name,
          content: b64ToBytes(attachment.contentBase64),
          encoding: "binary",
          contentType: /\.pdf$/i.test(attachment.name) ? "application/pdf" : "application/octet-stream",
        }];
      }
      await client.send(msg as never);
      return null;
    } catch (e) {
      return String((e as Error)?.message || e).slice(0, 500);
    } finally {
      try { await client.close(); } catch { /* ignore */ }
    }
  }

  let ccUsed = ccList;
  let ccLost = ccDropped.slice();
  let warning: string | null = null;

  let detail = await sendOnce(ccUsed);

  if (detail && ccLikelyAtFault(detail, ccUsed, to)) {
    const refused = ccUsed;
    const second = await sendOnce([]);
    if (second === null) {
      // The invoice went out. The copy did not — said plainly, never silently.
      ccUsed = [];
      ccLost = ccLost.concat(refused);
      warning = "Sent to the client, but the mail server refused the CC copy to "
              + refused.join(", ") + " — " + detail;
      detail = null;
    } else {
      detail = second;   // not the CC's fault after all; report the real failure
    }
  }

  if (detail) {
    await finish("failed", null, detail, ccUsed, ccLost, warning);
    return jsonRes({ ok: false, error: "the mail server rejected the message", detail }, 502, ch);
  }

  // SMTP gives no provider-side id the way an API would; record the mailbox used so
  // the delivery log still says where it went from.
  const sentAt = await finish("sent", "smtp:" + SMTP_USER, null, ccUsed, ccLost, warning);
  return jsonRes({
    ok: true, id: logId, provider_msg_id: "smtp:" + SMTP_USER,
    recipient: to, cc: ccUsed, cc_dropped: ccLost, warning,
    sent_at: sentAt,
  }, 200, ch);
});
