# Where the Live Site Lives (DNS & Website Forwarding)

This doc explains how to find where **storagefacilitycreator.com** is pointed and how to show the **current local marketing** (Flutter app) there instead.

---

## 1. Find where the domain points (DNS)

**Option A – Quick DNS lookup (see the target host)**

1. Open **https://dnschecker.org** (or any “DNS lookup” tool).
2. Enter **storagefacilitycreator.com**.
3. Check **A** and **CNAME** results:
   - **Firebase Hosting** often shows:
     - **A**: `151.101.1.195` / `151.101.65.195` (Fastly) or IPs shown in Firebase Console.
     - **CNAME**: `storage-facility-creator.web.app` or similar `*.web.app` / `*.firebaseapp.com`.
   - **Vercel**: CNAME like `cname.vercel-dns.com`.
   - **Netlify**: CNAME like `apex-loadbalancer.netlify.com` or a custom subdomain.
   - **Other hosts**: You’ll see their IPs or CNAMEs.

That tells you **which service is currently serving** the live page.

**Option B – Where you manage DNS**

- You manage DNS wherever you **registered** the domain or where you pointed **nameservers** (e.g. GoDaddy, Namecheap, Google Domains, Cloudflare, etc.).
- Log in there and open **DNS settings** for **storagefacilitycreator.com**.
- Look at **A** and **CNAME** records for the root domain and **www**:
  - What **hostname** or **IP** they point to = where the “junk” page lives.

---

## 2. Where “this page” usually lives

- If DNS points to **Firebase Hosting** → the live site is the **last build** you deployed with `firebase deploy --only hosting:prod` (from `build/web`). The “junk” is an older Flutter build; updating it = redeploy (see below).
- If DNS points to **Vercel / Netlify / other** → the live site is the **separate** app (e.g. the **Next.js** site in the **`marketing/`** folder) that you deployed there. The “junk” is that deployment. To use the Flutter marketing instead, you point the domain to **Firebase Hosting** and deploy the Flutter app there.

---

## 3. Point the domain to Firebase Hosting (so the local marketing is the website)

To have **storagefacilitycreator.com** (and optionally **www**) show the **same marketing you see locally** (Flutter):

1. **Firebase Console**
   - Go to [Firebase Console](https://console.firebase.google.com) → project **storage-facility-creator** → **Hosting**.
   - Click **Add custom domain**.
   - Add **storagefacilitycreator.com** (and if you want, **www.storagefacilitycreator.com**).
   - Firebase will show you the exact **A** and **CNAME** records (and sometimes a **TXT** for verification). Leave this tab open.

2. **Your DNS provider** (from step 1)
   - Remove or change any existing **A** / **CNAME** for **storagefacilitycreator.com** (and **www**) that point to the **old** host (Vercel, Netlify, etc.).
   - Add the **A** and **CNAME** records Firebase shows. For **www**, Firebase usually gives a CNAME to your **web.app** URL.
   - Save. DNS can take a few minutes up to 48 hours (often 5–30 minutes).

3. **Verification**
   - Back in Firebase Hosting, complete the “Verify” step once DNS has propagated. After that, traffic to **storagefacilitycreator.com** (and **www** if added) goes to Firebase Hosting.

---

## 4. Deploy the local marketing so it’s the live site

After the domain points to Firebase Hosting, the **content** shown is whatever you last deployed. To put the **current local marketing** live:

```bash
flutter clean
flutter pub get
flutter build web --release --no-wasm-dry-run
firebase deploy --only hosting:prod
```

Or run **`.\deploy.ps1`** for a full deploy.

Then open **https://storagefacilitycreator.com** and hard-refresh (Ctrl+Shift+R). You should see the same marketing you see when running the app locally.

---

## 5. Summary

| Goal | Where to look / what to do |
|------|----------------------------|
| **Where does this page live?** | DNS: use dnschecker.org or your registrar’s DNS page; the **A**/CNAME target is the host (Firebase, Vercel, Netlify, etc.). |
| **Where is forwarding set?** | Same place: DNS **A**/CNAME records *are* the “forwarding” to the server. Any “URL redirect” or “forwarding” rules are in the same DNS/hosting dashboard (e.g. “Redirect www to non-www” or vice versa). |
| **Show local marketing on the site** | Point **storagefacilitycreator.com** (and **www** if you use it) to **Firebase Hosting** in DNS, then run the four commands above so the live site is the current Flutter build. |

If you tell me where your domain is registered (e.g. GoDaddy, Cloudflare), I can outline the exact record names and values to add there.
