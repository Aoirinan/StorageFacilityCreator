# Tenant email digests (two mechanisms)

The app uses **two separate digest-related flows**. They use **different Firestore shapes** and are **not interchangeable**.

## 1. Scheduled daily digest (Cloud Function)

- **Function:** `sendDailyDigests` (`functions/src/index.ts`), schedule **08:00 America/Chicago**.
- **Reads:** `facilities/{facilityId}/digests` documents with `status == 'pending'` and `digestKey == 'daily'`, grouped by `tenantEmail`.
- **Writes:** Marks those digest docs `sent` after a successful email (uses `sendFacilityEmailWithCompliance` — respects `emailSuppressions`).
- **Typical producer:** Reminder / automation paths that queue rows in this **flat** `digests` collection with the fields the job expects (`tenantEmail`, `digestKey`, etc.). Align any new writer with what `sendDailyDigests` queries.

## 2. Client “digest document + items” (Flutter)

- **Service:** `RemindersDigestService` (`lib/services/reminders_digest_service.dart`).
- **Writes:** `facilities/{facilityId}/digests/{digestId}/items/{itemId}` (subcollection) with `processed`, `templateId`, `templateVars`, etc.
- **Sends:** `sendDigestNow` builds per-tenant emails and sends them through **`RateLimitQueue` / email provider** — not the same queue as §1.
- **UI:** Reminder schedule option **“Queue for daily digest”** (`ReminderSendMode.digest` in `reminder_service.dart`) feeds this path.

## Practical guidance

- **Do not assume** queued items from §2 are picked up by **`sendDailyDigests`** unless you add an explicit bridge or migrate schema.
- Prefer **one canonical path** for new features: either extend the **scheduled job + flat `digests` docs**, or extend **`RemindersDigestService`** and a explicit “send now” / future scheduler — and document which you chose.
- **Compliance:** Server-side facility emails (including §1) use footer, List-Unsubscribe, suppression, and optional ASM where implemented.
