# Making the Current Marketing the Live Site (www.storagefacilitycreator.com)

If visitors see an **old** marketing page at **www.storagefacilitycreator.com** or **storagefacilitycreator.com**, the live site is not yet showing the **current** front end from this repo.

## How it works in this repo

- The **current marketing** is the Flutter landing page: **`lib/screens/marketing_landing_page.dart`**.
- It is the **front** of the app: the router uses **`/`** (root) for this page (`AppRoute.landing`).
- The Flutter web app is built to **`build/web`** and deployed to **Firebase Hosting** (target **prod**). That single deploy serves both the marketing at `/` and the rest of the app (login, dashboard, etc.).

So: **the “current front end” is already the Flutter app with this marketing.** To have the **website** show it, the domain must point at that Firebase Hosting deploy and you must deploy the latest build.

## Why you might still see an old version

1. **Domain points elsewhere**  
   **www.storagefacilitycreator.com** (or the root domain) might be pointed at a **different** host—for example the separate **Next.js** marketing site in the **`marketing/`** folder, deployed on Vercel/Netlify. That would show an older or different design.

2. **Old Firebase Hosting build**  
   The domain might already point to Firebase Hosting, but the last deploy was a long time ago, so the live site is an old Flutter build.

## What to do: use the current marketing as the live site

### 1. Use Firebase Hosting as the only live site

- In **Firebase Console** → **Hosting** for project **storage-facility-creator**:
  - Add **storagefacilitycreator.com** as a custom domain if it’s not already.
  - Add **www.storagefacilitycreator.com** as a custom domain.
- In your **DNS** (where you manage the domain):
  - Point **storagefacilitycreator.com** and **www.storagefacilitycreator.com** to the targets Firebase shows (usually **A** and/or **CNAME** for Firebase Hosting).
- If **www** (or the root) is currently pointed at another host (e.g. Vercel for the old `marketing/` site), **change that** so both root and www point to **Firebase Hosting**. Then only the Flutter app (and thus the current marketing) will be served.

### 2. Deploy the current Flutter app

From the project root:

```bash
flutter clean
flutter pub get
flutter build web --release --no-wasm-dry-run
firebase deploy --only hosting:prod
```

Or use the full deploy script (which also deploys functions, Firestore, storage):

```powershell
.\deploy.ps1
```

After a successful deploy, **Firebase Hosting** serves the latest **`build/web`**, so the **current** marketing (and app) is what visitors see at **storagefacilitycreator.com** and **www.storagefacilitycreator.com**.

### 3. Confirm and hard-refresh

- Open **https://www.storagefacilitycreator.com** and **https://storagefacilitycreator.com**.
- Do a **hard refresh** (e.g. Ctrl+Shift+R or Cmd+Shift+R) so the browser doesn’t use an old cache.
- You should see the current Flutter marketing landing (hero, features, pricing, etc. from **MarketingLandingPage**).

## Summary

| Goal | Action |
|------|--------|
| “Current marketing” in code | Already the front: `/` → **MarketingLandingPage** in the Flutter app. |
| “Current marketing” on the website | Point **storagefacilitycreator.com** and **www** to **Firebase Hosting**, then deploy with `flutter build web` + `firebase deploy --only hosting:prod` (or `.\deploy.ps1`). |
| Old Next.js site in **marketing/** | Optional/legacy. For the main domain, point DNS to Firebase Hosting so the Flutter app (current marketing) is the live site. |
