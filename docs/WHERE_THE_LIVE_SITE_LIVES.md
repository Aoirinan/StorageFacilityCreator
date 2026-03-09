# Where The Live Site Lives

This is the current production mapping for the public website.

## Canonical website host

- **Host**: Vercel
- **Project source**: `marketing` (Next.js)
- **Domains**:
  - `storagefacilitycreator.com`
  - `www.storagefacilitycreator.com`

## DNS ownership

DNS is managed at your registrar/DNS provider (for example GoDaddy).  
Those records must point `@` and `www` to the values shown in the Vercel Domains panel.

## What Firebase still does

- Firebase remains the backend stack (Auth, Firestore, Functions, Storage).
- Firebase Hosting can still be used for app/internal endpoints on default Firebase domains (`*.web.app`, `*.firebaseapp.com`).
- Public custom domains for the website should remain **only on Vercel**.

## Quick verification checklist

1. `https://storagefacilitycreator.com` loads the Next.js marketing home.
2. `https://www.storagefacilitycreator.com` resolves correctly (or redirects to root, if configured).
3. Legal and marketing routes load:
   - `/privacy`
   - `/terms`
   - `/contact`
   - `/features`
   - `/pricing`

## If you see an old page

- Confirm Vercel deployment is current.
- Confirm DNS records still match Vercel instructions.
- Hard refresh / test in incognito to bypass local cache.
