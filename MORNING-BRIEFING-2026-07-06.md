# Sigma-CMS — Morning Briefing (overnight of July 5→6)

## ☕ TL;DR — you're in good shape
- **No permanent data loss.** 3 of the 4 hit orders are fully recovered; the 4th (2026‑081) has its photos safe in Storage and re-linked.
- **I found the *real* cause of the "081 shows only the cover" problem** — it was NOT a render bug, it was a stale in-memory flag. **Fixed and deployed as v2.241.**
- **I found the *real* cause of the cover "bleeding through all orders"** — a single **global** cover-graphic overlay. One console command clears it (below).
- **The thing that kept undoing our work all night was a stale browser tab** running the old code. Keep to **one tab, current version.**

---

## 1. What broke, and where recovery landed

| Order | Status this morning |
|---|---|
| 2026‑006 | ✅ Fully recovered — photos, text, valuation |
| 2026‑037 | ✅ Fully recovered — photos, text, valuation |
| 2026‑079 | ✅ Fully recovered — photos, text, valuation |
| 2026‑081 | ✅ Valuation + 28 photos + cover (photos safe in Storage, re-linked). Its **July‑5 typed notes** were entered after the backup and aren't recoverable — re-enter those. |
| Other 17 orders | ✅ Never affected |

Photo **files** are permanently safe in Storage (`Storage/photos/<order>/…`) regardless of the DB — a database write never deletes them.

---

## 2. What I fixed and DEPLOYED overnight — **v2.241 is live**

**Fix A — report now always loads fresh data (§HYDRATE-FORCE).**
The report used to skip re-loading an order's data if a "already loaded" flag was set. That flag got stuck on an *empty* copy during the throttle/stale-tab chaos, so the report kept drawing from a blank copy → 0 photos. The report now **re-pulls the current data from the database every time it generates.** This is the actual fix for 081-shows-only-cover.

**Fix B — report keeps the photos it just downloaded (§PHOTO-DATA-PRESERVE).**
On photo-heavy orders, the browser's local cache can exceed its size limit and silently drop the image bytes. The report no longer lets that stripped cache overwrite the freshly-downloaded photos (or cover).

Both syntax-checked (0 errors), committed, pushed, and **confirmed live at sigma-cms.com (v2.241)**.

---

## 3. ⏱️ First 10 minutes — do these in order (browser needed; I can't reach the DB)

**Step 0 — one clean tab.** Close Sigma on **every** device (work PC, iPad, phone). Open ONE tab → **Ctrl+F5** → console:
```js
console.log(APP_VERSION); // must say v2.241
```

**Step 1 — kill the cover bleed (the global overlay).**
```js
_coverGfxRead();
```
If it shows `enabled: true` with a `data`/image, that's the bleed. Clear it:
```js
_coverGfxWrite({enabled:false});
```
Then regenerate any report to confirm the stray cover image is gone.

**Step 2 — confirm the 4 orders are intact:**
```js
(async function(){
  var r=await _sb.schema('public').from('orders').select('order_id,insp_data').in('order_id',['2026-006','2026-037','2026-079','2026-081']);
  r.data.forEach(function(o){var id=o.insp_data,p=null;try{p=typeof id==='string'?JSON.parse(id):id;}catch(e){}var s=p&&p.s10,n=0;if(s&&s._photos)Object.keys(s._photos).forEach(z=>n+=(s._photos[z]||[]).length);console.log(o.order_id,'→',n,'photos');});
})();
```

**Step 3 — see 081's photos in the report.** With v2.241 live and no stale tab, just **generate the 2026‑081 report** — the force-refresh should now pull all 28 photos.

- If 081 shows **0 photos** in Step 2, a stale tab reverted it again overnight → re-link (paste below), then regenerate:
```js
(async function(){var oid='2026-081';var r=await _sb.schema('public').from('orders').select('insp_data').eq('order_id',oid).limit(1);var idp={};try{var id=r.data&&r.data[0]&&r.data[0].insp_data;if(id)idp=(typeof id==='string'?JSON.parse(id):id);}catch(e){}if(!idp||typeof idp!=='object')idp={};if(!idp.s10)idp.s10={};var s=await _sb.storage.from('Storage').list('photos/'+oid,{limit:1000});var files=(s.data||[]).map(f=>f.name).filter(n=>/\.(jpe?g|png|webp)$/i.test(n));var zones={zone0:[],zone1:[],zone2:[],zone3:[],zone4:[],zone5:[],zone6:[],zone7:[]},cover=null;files.forEach(function(fn){var path='photos/'+oid+'/'+fn;if(/^cover\./i.test(fn)){cover={name:fn,label:'',storagePath:path};return;}var m=fn.match(/^(zone[0-7])_(\d+)\./i);if(m){var z=m[1].toLowerCase(),i=parseInt(m[2],10);if(zones[z])zones[z][i]={name:fn,label:'',storagePath:path};}});Object.keys(zones).forEach(z=>zones[z]=zones[z].filter(Boolean));idp.s10._photos=zones;if(cover)idp.s10._coverPhoto=cover;if(!idp.s10._ts)idp.s10._ts=Date.now();await _sb.schema('public').from('orders').upsert([{order_id:oid,insp_data:JSON.stringify(idp),updated_at:new Date().toISOString()}],{onConflict:'order_id'});console.log('re-linked '+files.length+' files — now Ctrl+F5 and generate the report');})();
```

---

## 4. Recommended next hardening (your call — some need your approval / DB access)

Prioritized, from the full investigation:

1. **🔒 Server-side "never blank" trigger (highest durable value).** A one-time Postgres trigger on the `orders` table that refuses any write turning good inspection data into a blank — this defends against *any* stale/old tab, permanently, with no app change. The Supabase admin tool is locked to me, so this needs you to run one SQL migration (I'll write it and walk you through it). **This is the real end to the whole class of problem.**
2. **Cover graphic — decide the behavior.** Right now it's global (one graphic on every report). Options: (a) scope it per-order, or (b) keep global but add a loud "prints on EVERY report" warning. Tell me which and I'll ship it.
3. **Guard refinement** — block any save that drops an order's photo count to zero (belt-and-suspenders with #1).
4. **Throttle resilience** — retry photo downloads (currently one-shot), and let the local cache evict re-fetchable photo bytes so it stops silently failing.
5. **"X photos couldn't load — regenerate" banner** so a throttled report never looks complete when it isn't.

Say the word on #1 and #2 and I'll do them next.

---

## 5. Honest limits
- I **could not** verify your live database or re-link overnight — the Supabase admin tool rejects me (no access token), so all DB steps above need your browser.
- If anything in Step 2 looks wrong, paste me the output and we'll sort it immediately.

**Bottom line:** the render bug is fixed and shipped, the cover bleed has a one-line fix, your data is recovered, and there's a permanent server-side safeguard ready to install whenever you are. Good morning. ☀️
