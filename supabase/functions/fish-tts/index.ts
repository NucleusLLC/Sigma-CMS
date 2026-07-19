// ─────────────────────────────────────────────────────────────────────────────
// fish-tts — CORS proxy for Fish Audio text-to-speech (SIGMA narrator cloud voice)
//
// Why this exists: api.fish.audio does NOT send CORS headers, so a browser fetch
// from sigma-cms.com is blocked. This function runs server-side (no CORS there),
// holds the FISH_API_KEY as a Supabase secret, and returns the audio to the browser
// with permissive CORS. The public SIGMA app never sees the key.
//
// Request (POST JSON):
//   { text: string, model?: string, reference_id?: string, format?: 'mp3'|'wav'|'opus',
//     apiKey?: string }   // apiKey is an OPTIONAL client override; normally omitted so
//                          //   the server secret is used (recommended).
// Response: the audio bytes (audio/mpeg by default), or JSON { error, detail } on failure.
//
// Deploy with verify_jwt=false so the app can call it with just the anon apikey.
// ─────────────────────────────────────────────────────────────────────────────

const FISH_URL = "https://api.fish.audio/v1/tts";
const DEFAULT_MODEL = "s2.1-pro-free";
const DEFAULT_VOICE = "e3cd384158934cc9a01029cd7d278634";
// Echo the caller's Origin when it's one of ours; otherwise fall back to "*".
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
    headers: { ...ch, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const ch = corsHeaders(origin);

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return jsonRes({ error: "POST only" }, 405, ch);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return jsonRes({ error: "invalid JSON body" }, 400, ch);
  }

  const text = String(payload?.text ?? "").trim();
  if (!text) return jsonRes({ error: "text is required" }, 400, ch);
  if (text.length > 5000) return jsonRes({ error: "text too long (max 5000 chars per request)" }, 413, ch);

  const key = (payload?.apiKey && String(payload.apiKey)) || Deno.env.get("FISH_API_KEY");
  if (!key) return jsonRes({ error: "FISH_API_KEY not configured on the server" }, 500, ch);

  const model = String(payload?.model || DEFAULT_MODEL);
  const reference_id = String(payload?.reference_id || DEFAULT_VOICE);
  const format = String(payload?.format || "mp3");

  let fr: Response;
  try {
    fr = await fetch(FISH_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${key}`,
        "Content-Type": "application/json",
        "model": model,
      },
      body: JSON.stringify({ text, reference_id, format }),
    });
  } catch (e) {
    return jsonRes({ error: "fish request failed", detail: String(e) }, 502, ch);
  }

  if (!fr.ok) {
    const detail = await fr.text().catch(() => "");
    return jsonRes({ error: `fish error ${fr.status}`, detail: detail.slice(0, 500) }, fr.status, ch);
  }

  const buf = await fr.arrayBuffer();
  return new Response(buf, {
    status: 200,
    headers: {
      ...ch,
      "Content-Type": fr.headers.get("Content-Type") || "audio/mpeg",
      "Cache-Control": "no-store",
    },
  });
});
