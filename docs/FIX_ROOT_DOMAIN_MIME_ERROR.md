# Fix: Site Not Loading / MIME Type Error on storagefacilitycreator.com

## The error

```
Refused to execute script from 'https://storagefacilitycreator.com/main.dart.js' because its MIME type ('text/html') is not executable
```

## Why it happens

- **www.storagefacilitycreator.com** → CNAME to **storage-facility-creator.web.app** (Firebase Hosting). That works: Firebase serves the real app and sends `main.dart.js` as JavaScript.
- **storagefacilitycreator.com** (no www) → **A record to 199.36.158.100** (GoDaddy). So the **root domain** is served by GoDaddy, not Firebase.  
  GoDaddy returns an HTML page for (almost) every request. When the browser asks for `main.dart.js`, GoDaddy still returns HTML, so the browser sees MIME type `text/html` and refuses to run it. Result: blank/white page and the console error.

## Fix: Point the root domain to Firebase Hosting

You want **both** `storagefacilitycreator.com` and `www.storagefacilitycreator.com` to serve the Flutter app from Firebase so the marketing (and app) load correctly.

### 1. Get Firebase’s A records for the root domain

1. Open [Firebase Console](https://console.firebase.google.com) → project **storage-facility-creator** → **Hosting**.
2. Click **Add custom domain** (or **Manage** if you already added one).
3. Add **storagefacilitycreator.com** (without `www`).
4. Firebase will show you the records to add. For the **root (apex)** domain you usually get **two A records** with two IP addresses (e.g. from the `151.101.x.x` range). Copy both IPs and, if shown, any **TXT** record for verification.

### 2. Update DNS in GoDaddy

1. Log in to **GoDaddy** → **My Products** → **DNS** for **storagefacilitycreator.com**.
2. Find the **A** record for **@** (root) that points to **199.36.158.100**.
3. **Edit** that A record:
   - Change the value from **199.36.158.100** to the **first IP** Firebase gave you (e.g. **151.101.1.195**).
4. If Firebase gave you a **second A** for @:
   - Add another **A** record: **@** → second IP (e.g. **151.101.65.195**).  
   (Some hosts allow only one A for @; if so, use the first IP only and complete verification in Firebase; they may still accept it.)
5. If Firebase showed a **TXT** record for domain verification, add that TXT for **@** as well.
6. **Save** DNS. Remove any **forwarding** or **redirect** from the root domain to another URL if it’s set; the root should only have the A (and TXT) records pointing to Firebase.

### 3. Wait and verify in Firebase

- DNS can take **5–30 minutes** (up to 48 hours).
- In Firebase Hosting, finish the **Verify** step for **storagefacilitycreator.com**.
- After verification, traffic to **storagefacilitycreator.com** (no www) will go to Firebase Hosting and the app (and marketing) will load; the MIME type error will go away.

### 4. Use www in the meantime

Until the root domain points to Firebase, use **https://www.storagefacilitycreator.com**. That URL already goes to Firebase and should show the full marketing and app without the MIME error.

## After the fix

- **https://storagefacilitycreator.com** → Firebase → app loads, marketing shows.
- **https://www.storagefacilitycreator.com** → Firebase → same.
- No more “MIME type 'text/html'” for `main.dart.js` once the root is on Firebase.
