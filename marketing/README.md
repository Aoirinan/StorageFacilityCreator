# Storage Facility Creator — Marketing Site

Static marketing site for **Storage Facility Creator**: multi-page, lead capture, A2P 10DLC–friendly SMS copy, and a placeholder Login link that you can point at your app.

## Tech stack

- **Next.js 14** (App Router) + **React 18** + **Tailwind CSS**
- TypeScript, ESLint
- No ecommerce, no Wix/site-members auth

## Quick start

```bash
cd marketing
npm install
# Add your assets (see Configuration below):
#   public/logo.png   — used in header and as favicon
#   public/demo.png   — product screenshot in hero and “How it works”
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Version

- **Current version:** `1.1.0` (shown in the footer on every page as “v1.1.0”).
- **Where to change it:** `src/config/site.ts` → `SITE_VERSION`. Bump this when you ship updates (e.g. `1.2.0`, `1.3.0`). Keep `package.json` `version` in sync if you like.

## Configuration

### 1. Login URL (placeholder)

**File:** `src/config/site.ts`

```ts
export const APP_LOGIN_URL = 'REPLACE_ME';
```

Replace `REPLACE_ME` with your production app login URL (e.g. `https://yourapp.com` or `https://yourapp.com/login`). This is used for:

- Header “Login” button
- Hero “Login” button
- Mobile nav “Login” link

### 2. Logo and demo images

**Paths in code:** `src/config/site.ts`

```ts
export const LOGO_PATH = '/logo.png';
export const DEMO_IMAGE_PATH = '/demo.png';
```

**What to do:**

1. Copy your **logo** into `marketing/public/logo.png`.  
   - Same file is used for the header and as the **favicon** (via `metadata.icons` in `src/app/layout.tsx`).  
   - If you prefer a separate favicon, add `public/favicon.ico` and change `layout.tsx` to use it.

2. Copy your **product demo screenshot** into `marketing/public/demo.png`.  
   - It appears in the hero and “How it works” with a window-frame style (see `src/components/DemoFrame.tsx`).

If your files have different names, either rename them to `logo.png` / `demo.png` in `public/`, or change `LOGO_PATH` and `DEMO_IMAGE_PATH` in `src/config/site.ts` to match (e.g. `/my-logo.png`).

**Extra screenshots:** To add more app screenshots (e.g. Delinquency, Reports), add the image files to `marketing/public/` (e.g. `delinquency.png`, `reports.png`). Then in `src/config/site.ts`, add entries to `EXTRA_DEMO_IMAGES`, e.g. `{ src: '/delinquency.png', alt: 'Delinquency and past due view' }`. They will appear in a “See the app” section on the homepage.

### 3. Support contact

In `src/config/site.ts`:

```ts
export const SUPPORT_EMAIL = 'support@example.com';
export const SUPPORT_PHONE = '(555) 123-4567';
```

Update these for footer, contact page, and A2P/support references.

## Form submissions (Contact / Schedule a Demo)

- **Endpoint:** `POST /api/contact`  
  - **File:** `src/app/api/contact/route.ts`
- **Payload:** JSON with `name`, `email`, `facilityName` (required); `phone`, `unitCount`, `message` (optional).
- **Behavior:**
  - Validates required fields and email format.
  - In production, you should send an email (e.g. SendGrid, Resend). The route currently logs the payload in development and returns success.
  - To receive notifications, set env var `CONTACT_NOTIFY_EMAIL` (e.g. your support address). The code uses it when sending; until you wire a mailer, it only affects the “to” address you’d use in that integration.
- **Fallback:** If the API is unavailable, the contact page could be updated to use a `mailto:` link as fallback; for now the form posts only to `/api/contact`.

## Deploy (live production)

You can run the site in production without running it locally. Deploy from this repo as follows.

### Vercel (recommended)

1. Push the repo (including the `marketing/` folder) to GitHub/GitLab/Bitbucket.
2. In [Vercel](https://vercel.com), **Import** the repo.
3. Set **Root Directory** to `marketing` (so Vercel builds from `marketing/`).
4. Leave **Build Command** as `npm run build` and **Output Directory** as default (Vercel detects Next.js).
5. Add env vars if needed (e.g. `CONTACT_NOTIFY_EMAIL` for demo-request notifications).
6. Deploy. Your live URL will be something like `https://your-project.vercel.app`. The contact form uses the serverless `api/contact` route automatically.

### Netlify

1. Push the repo and connect it in Netlify.
2. Set **Base directory** to `marketing`.
3. **Build command:** `npm run build`
4. **Publish directory:** `.next` (Netlify’s Next.js runtime will serve it; the `api/contact` route works with the Next.js plugin).
5. Deploy. Your site will be live at the Netlify URL.

### After deploy

- Replace `APP_LOGIN_URL` in `src/config/site.ts` with your real app login URL, then redeploy.
- Ensure `public/logo.png` and `public/demo.png` are in the repo (or add them in the deploy step) so the live site shows your logo and demo image.
- Bump `SITE_VERSION` in `src/config/site.ts` (and optionally `package.json`) when you ship changes; the new version will appear in the footer after the next deploy.

## A2P compliance checklist

Required SMS/consent language is implemented as follows:

| Requirement | Where it appears |
|------------|------------------|
| Opt-in required | Home (brief SMS block), FAQ (“How does opt-in work?”), Privacy, Terms |
| “Message frequency varies” | `src/config/site.ts` → `A2P_COMPLIANCE_PARAGRAPH`; FAQ “How often are messages sent?”; Privacy; Terms |
| “Message & data rates may apply” | Same paragraph; FAQ; Privacy; Terms |
| “Reply STOP to opt out” | Same paragraph; FAQ “How do tenants opt out?”; Privacy; Terms |
| “Reply HELP for help” | Same paragraph; FAQ “What if a tenant needs help?”; Privacy; Terms |
| Clear support contact | Footer (support email/phone); Contact page; Privacy; FAQ; `site.ts` (SUPPORT_EMAIL, SUPPORT_PHONE) |

**Files to check when editing copy:**

- **Config:** `src/config/site.ts` — `A2P_COMPLIANCE_PARAGRAPH`, `SUPPORT_EMAIL`, `SUPPORT_PHONE`
- **Components:** `src/components/A2pSnippet.tsx` — brief (Home) and full snippet
- **Pages:** `src/app/page.tsx` (home SMS block), `src/app/faq/page.tsx`, `src/app/privacy/page.tsx`, `src/app/terms/page.tsx`, `src/app/contact/page.tsx`, `src/app/security/page.tsx`

We do **not** claim “approved by carriers”; wording describes the process and opt-in/opt-out/help clearly.

## Site map

| Page | Route |
|------|--------|
| Home | `/` |
| Features | `/features` |
| Pricing | `/pricing` |
| Security | `/security` |
| FAQ | `/faq` |
| Contact | `/contact` |
| Privacy Policy | `/privacy` |
| Terms of Service | `/terms` |

Footer on every page links to: Privacy Policy, Terms of Service, Contact, plus support email/phone.

## Scripts

- `npm run dev` — development server
- `npm run build` — production build
- `npm run start` — run production build
- `npm run lint` — ESLint

## Accessibility & SEO

- Semantic HTML, heading order, and focus-visible styles for keyboard users.
- Meta title/description and Open Graph tags in `src/app/layout.tsx` and per-page `metadata` where needed.
- Favicon via `metadata.icons` (logo.png). No stock photos; hero uses your demo image only.
