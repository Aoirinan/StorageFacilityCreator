# SEO setup checklist (Search Console + optional edge canonical)

Canonical public site: **`https://www.storagefacilitycreator.com`** (marketing app on Vercel).

## 1) Google Search Console (you do this in the browser)

1. Open [Google Search Console](https://search.google.com/search-console).
2. **Add property** → choose **Domain** (recommended).
3. Property: `storagefacilitycreator.com` (covers apex + `www` + subdomains in one property).
4. Copy the **DNS TXT** verification record Google shows.
5. In your **DNS provider** (Cloudflare, GoDaddy, Route 53, etc.), add that **TXT** at the root / as instructed. Save.
6. Wait until DNS propagates (often minutes, sometimes up to 48 hours), then click **Verify** in Search Console.
7. In Search Console, go **Sitemaps** → add:
   - `https://www.storagefacilitycreator.com/sitemap.xml`
8. Optional: under **Settings → Crawl stats / URL inspection**, spot-check the homepage and `/features` after deploy.

**Note:** I (the IDE agent) cannot log into your Google account or change DNS for you.

## 2) Optional: apex → `www` at the edge (301)

Your Next.js app already redirects **apex → `www`** in middleware. Adding a **301 at DNS / CDN** (e.g. Cloudflare **Bulk Redirect** or **Page Rules**) is still useful for:

- Crawlers and tools that hit apex first
- Consistent “single hop” canonical behavior

**Cloudflare (typical):**

1. Add site to Cloudflare, nameservers pointed from registrar.
2. **Rules** → **Redirect Rules** (or **Page Rules** on older plans).
3. Create rule: if hostname equals `storagefacilitycreator.com`, then **301** to `https://www.storagefacilitycreator.com/$1` preserving path (UI depends on product; use “Forwarding URL” / dynamic redirect as offered).

Keep **SSL/TLS = Full (strict)** and ensure `www` has a valid certificate on Vercel.

## 3) “More SEO” reality check

- **More deploys ≠ better rankings.** Quality content, clear titles, fast pages, and good links matter more than deploy frequency.
- After technical setup, the biggest lever is **useful pages** (features, comparisons, FAQs) that match what operators actually search for.
