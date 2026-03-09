# SFC App — New User Onboarding Sheet

This sheet is for **new software users** (facility owners and managers) so they know what to do and see for a successful first experience. It is based on an audit of the Storage Facility Creator (SFC) app.

---

## 1. Before You Start

- **Product:** SFC is a Flutter web app for managing self-storage facilities (tenants, units, contracts, payments, delinquency, insurance, and more).
- **Users:** Primary users are **facility owners/managers**. Staff can be added later via **invites** (Settings → Permissions / accept-invite link).
- **Access:** Web only; use a modern browser (Chrome recommended). If Firebase fails to load, use the **Retry** button and check the console for details.

---

## 2. First-Time User Path (Do in This Order)

### Step 1: Create an account and verify email

1. Go to the app (e.g. your deployed URL).
2. **Sign up** with name, email, and password.
3. Accept the **Terms of Service** (required).
4. You will be sent to **email verification**. Check your inbox and **verify your email**.
5. **Log in** with the same email and password.

**See:** Login screen → Sign up → Email verification screen → Login again.

---

### Step 2: Create your first facility

1. After login you land on the **Dashboard**.
2. If you have **no facilities**, go to the sidebar → **Facilities** (or use the “Create Facility” path from the Dashboard when a feature needs a facility).
3. On the Facilities page, click **“Create Facility”** (or the empty-state **“Create your first facility to get started”** button).
4. Complete the **Facility Creation Wizard**:
   - **Name**, **address**, **phone**, **email**
   - **Time zone** (default: Eastern)
   - **Grace period** (days before late fee; default 5)
   - **Late fee** (flat or percentage; e.g. $25 flat)
   - **Total units** (optional but useful for capacity)
5. Submit. Your **first facility** is created (trial allows one facility; more require a subscription).

**See:** Dashboard → Facilities → “Create Facility” → Facility Creation Wizard → Facility list with your new facility.

---

### Step 3: Add units (so you can assign tenants)

1. In the sidebar, open **Units** and choose **Unit Map** (or **Unit List**).
2. Select your facility if you have more than one.
3. **Create units**:
   - From **Unit List**: use “Create unit” / add unit flow (unit number, monthly rate, type, status, optional dimensions/features).
   - From **Unit Map**: use the map editor to add/arrange units.
4. Ensure you have at least a few units in **Available** status so you can move tenants in.

**See:** Units → Unit Map or Unit List → Create/add units → See available units.

---

### Step 4: (Optional but recommended) Set up contracts and lease templates

1. **Contracts** (sidebar) → **Contract Templates** (or **Lease Templates** from the Contracts area).
2. Create at least one **contract template** (and, if you use e-sign, a **lease template** with Dropbox Sign template ID).
3. This lets you assign a standard lease when creating tenants or using the Move-In Wizard.

**See:** Contracts → Contract Templates / Lease Templates → Create template(s).

---

### Step 5: (Optional but recommended) Enable online payments (Stripe Connect)

1. In the sidebar, go to **Billing** or **Stripe Connect** (or via Settings / subscription area if linked there).
2. Open **Stripe Connect** for the facility.
3. Complete **Stripe Connect onboarding** (create/link Stripe account) so you can receive tenant payments online.

**See:** Billing / Stripe Connect → Connect account → Complete Stripe onboarding in the webview.

---

### Step 6: Add your first tenant(s)

Choose one of these:

- **Move-In Wizard (recommended for first tenant):**  
  **Move-In** (or Move-In Wizard from the right route) → Select facility → Step 1: Tenant & unit → Step 2: Financial (rent, fees, deposit, prorate) → Step 3: Contract → Step 4: Payment. Completes move-in in one flow.
- **Create Tenant:**  
  **Tenants** → Select facility → **Create Tenant** → Fill details and optional lease/e-sign.
- **CSV Import:**  
  **Tenants** → Select facility → **Import CSV** → Follow the 5-step wizard (upload, map columns, preview, handle duplicates, confirm). See `docs/USER_GUIDE.md` for CSV column requirements.

**See:** Tenants (or Move-In) → Create Tenant / Move-In Wizard / Import CSV → Tenant list and tenant detail.

---

### Step 7: Confirm the Dashboard and key numbers

1. Go back to **Dashboard**.
2. You should see:
   - **Welcome** section (facility name or “All Facilities”).
   - **Metrics:** Total Tenants, Total Units, Occupancy, Monthly Revenue, Past Due.
   - **Quick Actions:** Tenants, Units, Billing, etc.
3. Use **“Sync counts”** if occupancy or counts look wrong (same as on Facilities page).

**See:** Dashboard with metrics and quick actions; “Sync counts” if needed.

---

## 3. What to See and Where (Checklist)

Use this as a short “tour” so new users know where everything lives.

| Area | Where | What to see/do |
|------|--------|----------------|
| **Dashboard** | Sidebar → Dashboard | Welcome, metrics, occupancy, quick actions, sync counts. |
| **Facilities** | Sidebar → Facilities | List of facilities, “Create Facility”, “Sync counts”. |
| **Tenants** | Sidebar → Tenants | Tenant list (by facility), Create Tenant, Import CSV. |
| **Messaging** | Sidebar → Messaging | Select facility → email/SMS (if configured). |
| **Payments** | Sidebar → Payments | Payments list, create payment, filters. |
| **Delinquency** | Sidebar → Delinquency | Late dashboard, reminders, past-due focus. |
| **Billing** | Sidebar → Billing | Invoices, billing overview, subscription. |
| **Manager Overlock** | Sidebar → Manager Overlock | Overlock status, bulk overlock (delinquency). |
| **Units** | Sidebar → Units | Unit List / Unit Map, create units, map editor. |
| **Contracts** | Sidebar → Contracts | Contract list, templates, create contract. |
| **Reports** | Sidebar → Reports | Financial and other reports. |
| **Yield Mgmt** | Sidebar → Yield Mgmt | Yield/pricing (if used). |
| **Insurance** | Sidebar → Insurance | Insurance plans, claims (if used). |
| **Access Codes** | Sidebar → Access | Gate access (if used). |
| **Calendar** | Sidebar → Calendar | Facility calendar. |
| **AI Assistant** | Sidebar → AI Assistant | In-app AI help (if enabled). |
| **Settings** | Sidebar → Settings | Profile, 2FA, notifications, appearance, links to legal/subscription. |

---

## 4. Subscription and trial

- **Trial:** New accounts can create **one facility** on a trial. To add more facilities, you must **upgrade** (Subscription).
- **Subscription:** Billing / Subscription (or “Subscription & Payments” in the user menu) → manage plan, add facilities ($75/month per facility in current model).
- If you hit “Upgrade Required” when creating a second facility, go to **Subscription** and complete the upgrade flow.

**See:** User menu → Subscription & Payments, or sidebar Billing → Subscription; Facility Creation Wizard when adding 2nd facility.

---

## 5. Invited users (staff / managers)

- **Accept invite:** Open the **accept-invite** link (e.g. `/#/accept-invite?facilityId=...&inviteId=...`) sent by the facility owner.
- **Log in** (or sign up with the invited email) and accept the invite. You then have access to the facility (and its areas) according to your role.
- **Permissions:** Owners can invite and manage roles from **Settings → Permissions** (or Permission Management screen).

**See:** Accept-invite screen → Login/Sign up → Dashboard with assigned facility.

---

## 6. Recommended “first day” checklist (summary)

1. Sign up, verify email, log in.  
2. Create your first facility (Facilities → Create Facility → wizard).  
3. Add units (Units → Unit Map or Unit List).  
4. (Optional) Create a contract/lease template (Contracts → Templates).  
5. (Optional) Connect Stripe for payments (Billing / Stripe Connect).  
6. Add at least one tenant (Move-In Wizard or Tenants → Create Tenant or Import CSV).  
7. Open Dashboard and run “Sync counts” if needed.  
8. Skim Settings (profile, 2FA, notifications).  

---

## 7. Troubleshooting and help

- **“No facilities found” / “Create a facility first”:** Create a facility from **Facilities** before using Units, Tenants, Payments, etc.
- **Dashboard counts wrong:** Use **“Sync counts”** on Dashboard or Facilities page to recompute occupancy and tenant counts.
- **Subscription / access:** Ensure network is stable; subscription guard is fail-closed on errors. Use **Subscription & Payments** to manage plan.
- **E-sign (lease signing):** Requires Dropbox Sign API keys and lease templates. See `docs/USER_GUIDE.md` for CSV and E-sign details.
- **Report a bug:** Use **Report a Bug** in the sidebar footer; include what you were doing and what you expected.

---

**Last updated:** March 2026 (from codebase audit).  
**Related:** `docs/USER_GUIDE.md` (CSV import, E-sign), `README.md` (run/build/deploy).
