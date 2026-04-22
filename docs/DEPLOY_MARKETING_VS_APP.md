# Marketing site vs Flutter app — where each one goes live

Two different surfaces ship from this repo. **They do not share one deploy button.**

| What | Code folder | Where it runs | How it usually goes live |
|------|----------------|---------------|---------------------------|
| **Public marketing site** (SEO, pricing, compare, contact) | `marketing/` | **Vercel** → `https://www.storagefacilitycreator.com` | **Git push to `main`** if the Vercel project is connected to this repo with root directory `marketing`. |
| **Operator Flutter web app** (dashboard, tenants, billing, map) | `lib/`, etc. | **Firebase Hosting** (e.g. `app.storagefacilitycreator.com`, `*.web.app`) | **`./deploy.ps1`** or `firebase deploy --only hosting` (and Functions when backend changed). **Git push alone does not update Firebase** unless you added CI to do that. |

## Quick rule of thumb

- Changed **`marketing/`** only → expect **Vercel** to build after push (verify in Vercel → Deployments).
- Changed **`lib/`**, **`functions/`**, **`web/index.html`**, **`pubspec.yaml`** for the app → run **`deploy.ps1`** (or your documented Firebase deploy) for production app + functions.

## See also

- [SEO setup checklist](SEO_SETUP_CHECKLIST.md) (Search Console, sitemap, optional edge redirects)
- [marketing/README.md](../marketing/README.md) — Vercel import / root directory
