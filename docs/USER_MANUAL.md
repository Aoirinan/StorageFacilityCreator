# Storage Facility Creator (SFC) — User Manual

This guide describes how to use **Storage Facility Creator (SFC)** from the perspective of a **facility operator or staff member** using the main web/desktop app. It is based on the application’s navigation, screens, and routes as implemented in the codebase.

---

## 1. What SFC is for

SFC is operations software for **self-storage businesses**: multiple facilities, tenants, units, rent and fees, contracts, messaging, access codes, delinquency workflows, reporting, optional insurance and retail (POS), and integrations such as Stripe and accounting tools.

---

## 2. Getting access

### Sign up and sign in

- Open the app URL you were given (on the production web host, you typically land on **Login**).
- **Sign up** creates a Firebase-authenticated account; you may be asked to **verify your email** before continuing.
- **Login** uses your email and password. **Forgot password** is available on the login flow.
- **Two-factor authentication (2FA)** can be turned on or off under **Settings** (see Section 8). When enabled, sign-in requires the second factor.

### Invitations and approval

- **Accept invite** links let you join an existing team with a controlled role.
- Some accounts may see **Pending approval** until an administrator activates them.

### Who this manual does *not* deep-cover

- **Super Admin** (`/super-admin`) is for platform operators, not day-to-day facility staff.
- **End renters** often use **public links** (pay, sign lease, tenant portal) without signing into SFC; those flows are summarized in Section 11.

---

## 3. How the workspace is organized

### Left sidebar (OPS)

After you sign in, most work happens under the **OPS** section:

| Item | Purpose |
|------|--------|
| **Dashboard** | Home: metrics, activity, shortcuts, and global search. |
| **Facilities** | List and manage facilities; create new facilities via the wizard. |
| **Tenants** | Tenant (customer) list, detail, add/edit, CSV import. |
| **Messaging** | Employee chat, bulk messaging, email, SMS, message history (facility-scoped). |
| **Payments** | Payment records and workflows tied to the business. |
| **Retail** | Point of sale and inventory (opens with **facility selection** if needed). |
| **Delinquency** | Late accounts: overview, past due, reminders, DNR (Do Not Rent). |
| **Billing** | **Invoices** list for the selected facility (create, filter, open invoice detail). The app also has a separate **Ledger** route for ledger views where linked from the UI. |
| **Calendar** | Facility calendar. |
| **Manager Overlock** | Overlock workflows for managers. |
| **Contracts** | Leases/contracts list, creation, templates, signing test tools. |
| **Units** | **Unit list** and **Map editor** for layout and units. |
| **Reports** | Financial and other reporting (including consolidated views where configured). |
| **Yield Mgmt** | Pricing / yield management. |
| **Insurance** | Insurance enrollment and claims (where enabled). |
| **Access Codes** | Gate/access code management (facility may be chosen when you open it). |
| **AI Assistant** | In-app assistant for help with SFC tasks. |
| **Settings** | Account, facility options, permissions, notifications, appearance, onboarding tab. |

The **SFC** logo at the top of the sidebar returns you to the **Dashboard**.

### Facility switcher

- Use the **facility switcher** in the app bar to choose which facility’s data you are viewing, or an **“All facilities”** style context where supported.
- If you were added as a **team member** (not the owner), the switcher indicates **Team member** for clarity.

### Subscription and access

- **Trials and subscriptions** are enforced in the app. If your trial expires or billing blocks access, the app may redirect you to **Billing & Payments** until resolved.
- A **subscription warning** may appear at the top of the shell; some navigation can be limited until billing is in good standing.

### Global search (Dashboard)

- On the **Dashboard**, the search field searches across entities (tenants, units, etc., per your account’s data) with short debounce as you type.
- Results let you jump to relevant records.

### Syncing facility counts (operators)

- The Dashboard can offer an action to **recompute facility stats** (occupancy-style counts). Use it if cards or dashboard numbers look out of date; wait for the confirmation snackbar.

### Report a Bug

- The sidebar footer includes **Report a Bug** to send feedback/issues.

---

## 4. Facilities

- **Facilities** lists sites you can access.
- **Create facility** runs a **wizard** to capture facility details.
- You can edit facility information from facility management flows (including links from delinquency and other screens where **Edit facility** appears).

---

## 5. Tenants (customers)

- **Tenants** opens the main **client list**: search, filters, and actions depend on your **permissions**.
- From a tenant row, open **Tenant detail** for full profile, units, payments, documents, and communication history as your role allows.
- **Add tenant** uses the tenant creation flow.
- **Import CSV** runs a dedicated **CSV import wizard** for bulk onboarding.
- **Delinquency** badges and grace behavior can reflect **facility billing settings** (e.g. grace days).

---

## 6. Units and map

Under **Units** in the sidebar:

- **Unit list** — create, edit, and open **unit detail**; manage status and linkage to tenants as the product allows.
- **Map editor** — visual map of the facility layout and units.

---

## 7. Contracts and leases

- **Contracts** — list agreements, open **contract detail**, and create new contracts.
- **Contract templates** — manage reusable templates; create and edit template content.
- **Lease templates** — separate template area where the app routes lease-specific templates.
- **Signing test** — internal route for testing signing without a live tenant campaign.

Tenants sign via a **public contract signing** URL with a **token** (see Section 11).

---

## 8. Settings (account and facility)

Open **Settings** from the sidebar. The screen has two top tabs:

### Settings tab

- **Account**
  - **Profile** — edit profile (email shown on the tile).
  - **Billing & Payments** — goes to the combined **subscription / Stripe / accounting** area (same as subscription management).
  - **Two-Factor Authentication** — toggle 2FA on or off (follow prompts; disabling may require identity verification depending on policy).
- **Facility** (many items ask you to **pick a facility** if you have more than one)
  - **Permissions** — user permissions for the facility.
  - **Notifications** — automated messages and reminders (per facility).
  - **Website setup** — one **public marketing / rentals website** per facility.
  - **Email opt-outs** — subscribers who opted out; you can allow mail again per policy.
  - **SMS opt-outs** — tenants who texted **STOP** and related block list.
  - **Texting** — when the feature is enabled for your environment: dedicated number and **A2P** (carrier compliance) setup for SMS.
- **General**
  - **Appearance** — theme / display preferences.
  - Legal links may open the marketing site (privacy, terms, etc.).

### Onboarding tab

- Checklist-style help for new accounts (content is maintained in-app).

---

## 9. Billing, payments, and money

### Billing & Payments screen (tabs)

Accessible from **Settings → Billing & Payments** (and subscription redirects):

1. **Your Subscription** — SFC platform subscription, trials, plan changes.
2. **Payment Processing** — **Stripe Connect** onboarding and status for taking tenant card payments **per facility** (uses the **active facility** when a specific facility is required).
3. **Accounting** — QuickBooks-related integration entry points where configured.

### Payments (sidebar)

- Record and track **payments**, open **payment detail**, **create payment**, and **reconciliation** where your role allows.

### Invoices, deposits, liens, recurring charges

- Routes exist for **invoices**, **deposits**, **liens**, **recurring charges**, **autopay activity**, **transfers**, and **payment links** management — use the navigation or in-app links from Billing/Payments and tenant contexts to reach them.

---

## 10. Operations: delinquency, messaging, access, retail

### Delinquency

**Delinquency** is a single screen with **tabs**:

- **Overview** — summary of late situation for the selected facility.
- **Past Due** — accounts past due (ties into payment/tenant data).
- **Reminders** — reminder management (sidebar also treats **Reminders** routes as part of this area for highlighting).
- **Global DNR System** — Do Not Rent list at the configured scope.

Facility selection aligns with the **active facility** when possible so it stays consistent with the Dashboard.

### Messaging

**Messaging** is **facility-specific**. Tabs include:

- **Employee Chat** — internal team conversations; **unread count** can show on the sidebar **Messaging** item.
- **Bulk Messaging**
- **Email**
- **SMS** — requires texting to be set up where applicable.
- **Message History** — filterable history of tenant-related messages.

There is also a dedicated **SMS conversations** route for threaded SMS views when you navigate there from links or bookmarks.

### Access codes

**Access Codes** opens gate/access management; the app may prompt for **facility selection** if you have multiple sites.

### Retail (POS)

**Retail** opens **POS** with **facility selection** when needed. **Inventory** and **retail sales history** are reachable from POS-related navigation inside those screens.

---

## 11. Public and renter-facing flows (no SFC login)

These URLs are meant for **tenants or prospects**, not for staff daily use:

| Route pattern (conceptual) | Typical use |
|----------------------------|-------------|
| **Tenant portal** | Renters sign in or verify access to a limited portal (feature-flagged in some environments). |
| **Contract sign** (`/contracts/sign?token=…`) | Electronic signature of a lease or addendum using a secure token. |
| **Public payment** (`/pay`) | Pay rent or fees via a shared link. |
| **Public rental / move-in** | Online rental or move-in from the facility’s public website flow. |
| **Public facility / map** | Marketing and unit availability on the public site. |

Staff usually **copy these links** from contract, payment, or website-setup workflows rather than typing paths manually.

---

## 12. Automation, integrations, and advanced areas

From routes wired in the app (often linked from Settings, Billing, or facility tools):

- **API keys** and **Webhooks** — integrations for external systems.
- **Escalation workflows** and **Conditional rules** — automation for collections and operations.
- **Email sequences** and **Report scheduling** — scheduled communications and reports.
- **Email / SMS templates** and **Communication analytics** — template libraries and performance views.
- **Stripe Connect** — dedicated onboarding screen when linked from billing.
- **Data integrity** — tools to detect and fix inconsistent records (admin-style use).
- **Coupons**, **Yield management**, **Document center / attachments**, **Contact logs**, **Audit logs**, **Exports**, **Move-in wizard**, **Move-out**, **DNR** list screen, **Online rentals** management — all exist as first-class routes; open them from the UI entry points your administrator exposes (some depend on **permissions** or **feature flags**).

---

## 13. Permissions and feature flags

- Your **role** may hide actions (e.g. messaging, payments, or facility settings). If something is missing, ask an **owner** to update **Permissions** under **Settings**.
- Some features (e.g. **Tenant portal**, **Texting onboarding**) can be toggled off for the whole platform — you would see an **“unavailable”** message rather than the screen.

---

## 14. Language and platform

- **Language** can be changed where the app exposes a **language selector** (e.g. on the Dashboard per implementation).
- SFC targets **web** and other Flutter targets; behavior is richest on **web** for operator workflows.

---

## 15. Getting help

- Use **AI Assistant** in the sidebar for guided help inside the product.
- Use **Report a Bug** for defects.
- For account and billing issues, use **Billing & Payments** and your organization’s support channel.

---

*This manual reflects the application structure as of the documentation date. Labels and exact menu positions may change slightly in new releases; the sidebar and Settings remain the primary map of the product.*
