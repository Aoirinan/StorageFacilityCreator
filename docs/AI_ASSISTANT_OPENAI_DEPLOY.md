# AI Assistant OpenAI – Deploy & Test

## Summary

The AI Assistant page now uses **OpenAI via the `aiAssistantChat` Cloud Function** when Firestore config allows it. Otherwise it falls back to **canned tips**. Config lives at **`/appConfig/aiAssistant`**.

---

## 1. Firestore config: `/appConfig/aiAssistant`

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Master switch for OpenAI-backed chat |
| `killSwitch` | bool | When true, OpenAI is disabled regardless of `enabled` |
| `provider` | string | Must be `"openai"` to use OpenAI |
| `allowlistFacilityIds` | array of strings | Empty = allow all facilities; non‑empty = only listed facility IDs |

**Use OpenAI when:**  
`enabled === true` **and** `killSwitch === false` **and** `provider === "openai"` **and**  
(`allowlistFacilityIds` is empty **or** current `facilityId` is in the array).

**Example (allow all facilities):**
```json
{
  "enabled": true,
  "killSwitch": false,
  "provider": "openai",
  "allowlistFacilityIds": []
}
```

**Example (allowlist):**
```json
{
  "enabled": true,
  "killSwitch": false,
  "provider": "openai",
  "allowlistFacilityIds": ["facility-id-1", "facility-id-2"]
}
```

Create or update this document in the Firebase Console (Firestore) under `appConfig` → `aiAssistant`.

---

## 2. OpenAI secret

Store the OpenAI API key in **Firebase Secret Manager** (used by Cloud Functions):

```bash
cd functions
firebase functions:secrets:set OPENAI_API_KEY
```

Paste your OpenAI API key when prompted.  
**Do not** expose this key to the client; it is only used in the `aiAssistantChat` function.

---

## 3. Deploy Cloud Functions

```bash
firebase deploy --only functions
```

This deploys (among others) the **`aiAssistantChat`** callable.  
Optionally, redeploy Firestore rules if you changed them:

```bash
firebase deploy --only firestore:rules
```

---

## 4. Quick test checklist

- [ ] **Network**
  - Open DevTools → Network.
  - On the AI Assistant page, send a message (with config set to use OpenAI).
  - Confirm a **callable** request to the `aiAssistantChat` Cloud Function (HTTPS), not only Firestore webchannel traffic.

- [ ] **Function logs**
  - `firebase functions:log` (or Cloud Console → Logging).
  - Trigger a chat from the app.
  - Confirm log entries for `aiAssistantChat` include `providerUsed=openai` (and typically `model`, `tokensUsed`, `latencyMs`, `allowlistPassed`).

- [ ] **UI debug line**
  - Run the app in **debug** (e.g. `flutter run -d chrome`).
  - Send a message that goes through OpenAI.
  - Under the assistant reply, a small debug line appears:  
    `provider: openai | model: ... | tokens: ... | requestId: ...`
  - Same line is printed to the **console** (e.g. via `debugPrint`).

- [ ] **Canned fallback**
  - Set `enabled: false` or `killSwitch: true` or `provider` to something other than `"openai"` (or use a facility not in the allowlist when it’s non‑empty).
  - Send a message.
  - Replies should be **canned tips** only; no `aiAssistantChat` call, no debug line.

- [ ] **Rate limits / errors**
  - Send many messages in a short time to hit the per‑user rate limit.
  - Confirm a **friendly error** (e.g. “Rate limit exceeded… try again shortly”) and no crash.
  - Send a very long message (> 2000 chars); confirm a clear “Message too long” style error.

---

## 5. `aiAssistantChat` contract

- **Inputs:** `facilityId`, `userId`, `message`; optional: `conversationId`, `facilityName`.
- **Outputs:** `replyText`, `providerUsed`, `model`, `requestId`, `tokensUsed`, `latencyMs`.
- **Limits:** max input length 2000 chars, max output tokens 700, max 10 requests per user per minute.
- **Logging:** `facilityId`, hashed `userId`, `providerUsed`, `latencyMs`, `tokensUsed`, `allowlistPassed`.

---

## 6. `user_roles` fix

The **`[cloud_firestore/not-found] No document to update: .../user_roles/owner-...`** issue is addressed by using **`set(..., { merge: true })`** instead of **`update()`** when upserting role documents in `assignRole` (e.g. synthetic owner roles). Permissions behavior is unchanged; the error should no longer occur.
