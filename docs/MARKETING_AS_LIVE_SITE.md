# Marketing Site Is Live On Vercel

This project now uses the **Next.js marketing app in `marketing`** as the public website.

## Source of truth

- **Public website** (`storagefacilitycreator.com`, `www.storagefacilitycreator.com`): Vercel project built from `marketing`.
- **Flutter app** (`build/web`): separate app surface (can remain on Firebase default domains for app/internal use).

## Local development

```bash
cd marketing
npm install
npm run dev
```

Open `http://localhost:3000`.

## Production deployment

1. Deploy `marketing` to Vercel (root directory = `marketing`).
2. In Vercel Domains, keep:
   - `storagefacilitycreator.com`
   - `www.storagefacilitycreator.com`
3. Keep these custom domains removed from Firebase Hosting to avoid split traffic/certificate conflicts.

## Post-deploy verification

- `https://storagefacilitycreator.com`
- `https://www.storagefacilitycreator.com`
- `https://storagefacilitycreator.com/privacy`
- `https://storagefacilitycreator.com/terms`
- `https://storagefacilitycreator.com/contact`

## Historical note

Older documentation in this repo referenced serving marketing from Flutter/Firebase Hosting. That is no longer the production website path.
