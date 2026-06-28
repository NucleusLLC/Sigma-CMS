# Sigma-CMS

Appraisal Intelligent CMS — real-estate appraisal report generator. Single-file HTML app, Supabase backend.

**Live:** auto-deployed to Cloudflare Pages from this repo.
**Repo:** https://github.com/NucleusLLC/Sigma-CMS

## Contents

- `index.html` — current production build
- `_headers` — security headers applied by Cloudflare Pages
- `.gitignore` — keep working files out

## Shipping a new version

1. Replace `index.html` with the latest build from the dev workspace.
2. Commit + push:
   ```
   git add index.html
   git commit -m "deploy: vX.YYY <short note>"
   git push
   ```
3. Cloudflare Pages auto-builds and deploys in ~30 seconds.

## Local preview

```
npx serve -l 3000
```
Or just double-click `index.html`.

## Rollback

```
git revert HEAD && git push
```
Pages redeploys the previous `index.html`.

## Stack

- **Frontend:** single HTML file, no build step
- **Database:** Supabase Pro (`public.orders`, `public.contacts`, `public.report_templates`)
- **File storage:** Supabase Storage bucket `Storage`
- **Auth:** Supabase Auth (email + password)
- **Hosting:** Cloudflare Pages (static, global edge)
