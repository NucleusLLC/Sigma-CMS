// tv-news — headline relay for the office TV board (sigma-cms.com/calendar, §TV-NEWS).
//
// News sites publish RSS but send no CORS headers, so the board cannot read them from the
// browser. This function fetches a few public feeds server-side, keeps title / link / time /
// photo, and returns JSON with permissive CORS. It reads public news only — no SIGMA data,
// no secrets — so it is deployed with verify_jwt = false and needs no auth header.
//
//   GET /functions/v1/tv-news  ->  { at, world:[...], ai:[...] }
//   item = { title, link, t (ISO), img, src }
//
// Results are cached in memory for 10 minutes so the TV's polling never hammers the feeds.

const WORLD = [
  { src: "BBC", url: "https://feeds.bbci.co.uk/news/world/rss.xml" },
  { src: "GUARDIAN", url: "https://www.theguardian.com/world/rss" },
];
const AI = [
  { src: "GUARDIAN", url: "https://www.theguardian.com/technology/artificialintelligenceai/rss" },
  { src: "WIRED", url: "https://www.wired.com/feed/tag/ai/latest/rss" },
  { src: "THE VERGE", url: "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml" },
  { src: "MIT TECH REVIEW", url: "https://www.technologyreview.com/topic/artificial-intelligence/feed" },
];
const TTL_MS = 10 * 60 * 1000;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};

type Item = { title: string; link: string; t: string; img: string; src: string };
let cache: { at: number; body: string } | null = null;

function decode(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/<[^>]+>/g, "")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCharCode(parseInt(n, 16)))
    .replace(/&quot;/g, '"').replace(/&apos;|&#39;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
    .replace(/\s+/g, " ").trim();
}
function tag(block: string, name: string): string {
  const m = block.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`, "i"));
  return m ? m[1] : "";
}
function attrUrl(s: string): string {
  return s.replace(/&amp;/g, "&").trim();
}
function image(block: string): string {
  // largest media:content / media:thumbnail, then enclosure, then first <img> in the body
  let best = "", bestW = -1;
  for (const m of block.matchAll(/<media:(?:content|thumbnail)\b([^>]*)>/gi)) {
    const a = m[1], u = a.match(/url="([^"]+)"/i);
    if (!u) continue;
    const ty = a.match(/(?:type|medium)="([^"]+)"/i);
    if (ty && !/image/i.test(ty[1])) continue;
    const w = Number((a.match(/width="(\d+)"/i) || [])[1] || 0);
    if (w > bestW) { best = u[1]; bestW = w; }
  }
  if (best) return attrUrl(best);
  const enc = block.match(/<enclosure\b[^>]*url="([^"]+)"[^>]*type="image/i);
  if (enc) return attrUrl(enc[1]);
  const body = (tag(block, "content:encoded") || tag(block, "content") || tag(block, "description") || tag(block, "summary"))
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"');
  const img = body.match(/<img\b[^>]*src="([^"]+)"/i);
  return img ? attrUrl(img[1]) : "";
}

async function feed(f: { src: string; url: string }): Promise<Item[]> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 8000);
  try {
    const r = await fetch(f.url, { signal: ctl.signal, headers: { "User-Agent": "Mozilla/5.0 (SIGMA office board)" } });
    if (!r.ok) return [];
    const x = await r.text();
    const blocks = [...x.matchAll(/<(item|entry)\b[\s\S]*?<\/\1>/gi)].map((m) => m[0]);
    return blocks.slice(0, 25).map((b) => {
      const linkAtom = b.match(/<link\b[^>]*href="([^"]+)"/i);
      let img = image(b);
      if (f.src === "BBC") img = img.replace("/standard/240/", "/standard/480/");
      const when = decode(tag(b, "pubDate") || tag(b, "published") || tag(b, "updated") || tag(b, "dc:date"));
      const d = new Date(when);
      return {
        title: decode(tag(b, "title")),
        link: decode(tag(b, "link")) || (linkAtom ? attrUrl(linkAtom[1]) : ""),
        t: isNaN(d.getTime()) ? "" : d.toISOString(),
        img,
        src: f.src,
      };
    }).filter((i) => i.title);
  } catch {
    return [];
  } finally {
    clearTimeout(timer);
  }
}

async function group(list: { src: string; url: string }[], max: number): Promise<Item[]> {
  const all = (await Promise.all(list.map(feed))).flat();
  const seen = new Set<string>();
  return all
    .filter((i) => { const k = i.title.toLowerCase(); if (seen.has(k)) return false; seen.add(k); return true; })
    .sort((a, b) => (b.t || "").localeCompare(a.t || ""))
    .slice(0, max);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (!cache || Date.now() - cache.at > TTL_MS) {
    const [world, ai] = await Promise.all([group(WORLD, 30), group(AI, 30)]);
    if (world.length || ai.length || !cache) {
      cache = { at: Date.now(), body: JSON.stringify({ at: new Date().toISOString(), world, ai }) };
    }
  }
  return new Response(cache.body, {
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=300" },
  });
});
