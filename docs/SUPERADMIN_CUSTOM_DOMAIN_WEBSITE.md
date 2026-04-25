# Super Admin: Custom domain + SFC public website (walkthrough)

> **Day-to-day:** In the app, use **Super Admin → Custom domain** for the short checklist, copy buttons, and email draft. This file is the long-form reference.

**Audience:** Storage Facility Creator (SFC) super admins and internal support.  
**Goal:** A facility keeps the **same SFC-hosted public website** we host, but visitors use **their** domain (e.g. `https://rent.theirstorage.com/...`).

**Important:** Their domain’s **DNS** must be updated at whoever **owns/registers** that domain (the customer or their IT). SFC cannot push DNS changes to GoDaddy, Namecheap, etc. without their registrar credentials. This guide covers **what you do in Firebase/SFC** and **what you ask the customer to do in DNS**.

---

## Concepts (30 seconds)

| Item | Who controls it |
|------|------------------|
| Website HTML (template), inventory, “Powered by SFC” | **SFC** (Firebase Hosting + Cloud Functions) |
| TLS certificate for their hostname | **Google** (after domain is connected + DNS correct) |
| “This hostname points to Google’s servers” | **Customer’s DNS** at their registrar |

**Working link without any custom domain:**  
`https://app.storagefacilitycreator.com/w/<public-slug>`  
No DNS work for the customer.

**Their domain on our Hosting:**  
Same Hosting project as the app; you add the hostname in **Firebase Hosting → Custom domains**; they add the **TXT/CNAME (or A)** records Firebase shows; then HTTPS works for that host.

---

## Information to collect before you start (copy/paste checklist)

Use a ticket or internal note; fill every box before touching production.

- [ ] **Facility name** and **Firebase facility ID** (`facilities/{facilityId}`)
- [ ] **Public website slug** (from operator **Website Setup** or `mapEngine/meta.publicSlug`) — must match `publicFacilityMaps/{slug}`
- [ ] **Exact hostname** the customer wants (examples: `rent.theirstorage.com`, `www.theirstorage.com`). **No** `https://`, **no** trailing path.
- [ ] **Who can edit DNS** for that domain (email / phone). Super admin usually does **not** have registrar login.
- [ ] **Registrar / DNS host** (GoDaddy, Cloudflare, Namecheap, etc.) — instructions vary slightly.
- [ ] Confirm **Website Setup** in the app has **the same hostname** in **Custom domain** (normalized: lowercase, no `https://`). This must match what you add in Firebase and what they put in DNS.
- [ ] Confirm the facility has **published** their public map / website data (save + publish in Website Setup) so `/w/<slug>` works on `app.storagefacilitycreator.com` first.

**Firestore / app fields (for verification)**

| Location | Field | Purpose |
|----------|--------|--------|
| `facilities/{facilityId}/settings/public` | `customDomain` | Must equal the hostname (e.g. `rent.theirstorage.com`). Used for domain → facility lookup. |
| `facilities/{facilityId}/settings/public` | `publicRentalSlug` / Website URL name | Public slug segment in `/w/<slug>`. |
| `facilities/{facilityId}/mapEngine/meta` | `publicSlug` | Should stay in sync with published slug (used when resolving by domain). |

See also: [WEBSITE_FACTORY_MVP.md](./WEBSITE_FACTORY_MVP.md) (domain lookup order).

---

## Master checklist (order matters)

### Phase A — SFC app (operator or super admin on behalf)

- [ ] Open **Website Setup** for the facility.
- [ ] Set **Website URL Name** (slug) and confirm **`https://app.storagefacilitycreator.com/w/<slug>`** loads the marketing site.
- [ ] Set **Custom domain** to the **exact** hostname (e.g. `rent.theirstorage.com`).
- [ ] Click **Save Website** (writes `settings/public` and republishes as needed).

### Phase B — Firebase Hosting (Google Cloud / Firebase Console)

**You need:** Firebase project access (Editor or similar) for the SFC production project.

- [ ] Firebase Console → **Hosting** → **Add custom domain**.
- [ ] Enter the **same** hostname as in Website Setup.
- [ ] Complete **domain verification** (Firebase will show a **TXT** record). Copy the name + value exactly for the customer (or add it if you manage DNS for them).
- [ ] After verification, Firebase shows **routing** records (commonly **A** records to Google IPs and/or a **CNAME** target such as `ghs.googlehosted.com`). The UI is authoritative — **always copy from the current Firebase screen**, not from an old screenshot.
- [ ] Wait until Hosting shows the domain as **Connected** / certificate **Provisioned** (can take minutes to a few hours after DNS propagates).

**Official reference:** [Connect a custom domain (Firebase Hosting)](https://firebase.google.com/docs/hosting/custom-domain)

### Phase C — Customer DNS (their registrar)

Send them a short email template (below). They must:

- [ ] Add **verification TXT** (if not already done).
- [ ] Add **Hosting routing** records exactly as Firebase lists (CNAME and/or A).
- [ ] **No** accidental `www.` mismatch: if the hostname is `rent.example.com`, records must be for `rent`, not only `www`.

**Propagation:** DNS can take **minutes to 48 hours** (often &lt; 1 hour). Use `nslookup rent.example.com` or Google’s [Dig](https://toolbox.googleapps.com/apps/dig/) to confirm the hostname resolves to Google.

### Phase D — Firebase Authentication (if they sign in on that hostname)

If operators or renters will use **the Flutter app** loaded from **this same custom domain** (not typical for a marketing-only `rent.*` host, but possible):

- [ ] Firebase Console → **Authentication** → **Settings** → **Authorized domains** → **Add domain** → add `rent.theirstorage.com` (and `theirstorage.com` if you use apex).

If the custom host is **only** for the static `/w/...` marketing site and everyone uses `app.storagefacilitycreator.com` for the app, this step may be optional.

### Phase E — Verification (super admin)

- [ ] **HTTPS:** `https://<hostname>/w/<slug>` loads the public marketing site (no certificate warning).
- [ ] **Content:** Matches what you see on `https://app.storagefacilitycreator.com/w/<slug>` (same facility).
- [ ] **Optional:** `https://<hostname>/api/public-website?slug=<slug>` returns JSON (Hosting rewrite to `getPublicWebsiteConfig`).

**Note on bare `/` (now implemented):**  
For mapped facility custom domains, `https://<hostname>/` now redirects to `https://<hostname>/w/<slug>` via `routeCustomDomainRoot`.  
For the operator app host (`app.storagefacilitycreator.com`), root still resolves to the Flutter app shell (`/index.html`).

---

## Email template for the customer (DNS)

Subject: DNS records for your Storage Facility Creator website

Hi [Name],

To use **[exact hostname, e.g. rent.theirstorage.com]** with your Storage Facility Creator website, please add the following DNS records at **[their registrar]** exactly as shown (names, types, and values must match; do not add `https://` in DNS).

**1) Verification (if still required)**  
[Paste TXT name and value from Firebase Hosting custom domain setup]

**2) Hosting / SSL (required for the site to load)**  
[Paste A and/or CNAME records from Firebase Hosting — use the live console]

After saving, DNS may take up to a few hours. We will confirm when the site is live.

If you use a DNS proxy (e.g. Cloudflare “orange cloud”), follow Firebase’s guidance for proxy compatibility; when in doubt, start with **DNS only** / gray cloud for that hostname until SSL provisions.

Thanks,  
[Support name]

---

## Troubleshooting (quick reference)

| Symptom | Likely cause |
|---------|----------------|
| `DNS_PROBE_FINISHED_NXDOMAIN` | No DNS record for that hostname at registrar, or typo in hostname. |
| Certificate / SSL pending forever | TXT/A/CNAME not exactly as Firebase shows; conflicting old records; proxy interfering. |
| Wrong facility or “not found” | `customDomain` in Firestore ≠ hostname on request, or slug not published; fix Website Setup and republish. |
| Site works on `app....` but not on custom host | Custom domain not added in **Hosting**, or DNS not pointed to Google yet. |
| App login errors on custom domain | Add hostname to **Authentication → Authorized domains**. |

---

## Hosting API automation (implemented)

Super Admin now has callable-backed provisioning for Hosting custom domains:

- `superAdminProvisionHostingCustomDomain` (Cloud Functions callable): creates or reuses `projects.sites.customDomains` entry and returns DNS records + status.
- `superAdminGetHostingCustomDomainStatus` (Cloud Functions callable): refreshes provisioning/certificate status and record guidance.

Both functions are super-admin gated (email list policy), and both use ADC/service-account credentials from Cloud Functions runtime to call Firebase Hosting v1beta1.

### IAM and env requirements

- Cloud Functions runtime identity needs Firebase Hosting Admin permissions (e.g. `roles/firebasehosting.admin` on project `storage-facility-creator`).
- Optional function params if using non-default project/site:
  - `HOSTING_PROJECT_ID` (default `storage-facility-creator`)
  - `HOSTING_SITE_ID` (default `storage-facility-creator`)
- No JSON service-account key is required in code and no secrets should be committed.

### Tradeoff note

Firebase Hosting config cannot cleanly do host-conditional root behavior in `firebase.json` alone.  
Using `routeCustomDomainRoot` keeps `app.storagefacilitycreator.com` intact while redirecting mapped custom-domain root requests to the facility marketing route.

---

## Revision

- Document created for internal super-admin + support use; align steps with your live Firebase project name and Hosting targets if you use multiple sites.
