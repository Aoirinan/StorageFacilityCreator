# Step 4: Create AI Assistant Feature Flag Config

## Quick Method (Firebase Console)

1. Go to: https://console.firebase.google.com/project/YOUR_PROJECT_ID/firestore
2. Navigate to `appConfig` collection (create it if it doesn't exist)
3. Create document with ID: `aiAssistant`
4. Add these fields:

```json
{
  "enabled": false,
  "allowlistFacilityIds": [],
  "killSwitch": false,
  "provider": "openai"
}
```

## Script Method

Run the script I created:

```bash
node scripts/create_ai_assistant_config.js
```

**Note:** The script will use your default Firebase credentials. If you need to configure credentials, see the script file for details.

## What This Does

- Creates `appConfig/aiAssistant` document in Firestore
- Sets feature flag to OFF by default (`enabled: false`)
- Allows you to enable per-facility via `allowlistFacilityIds`
- Can be enabled globally by setting `enabled: true`

## After Creating Config

1. Add a test facility ID to `allowlistFacilityIds` array
2. Set `enabled: true` (or leave false and use allowlist)
3. Test the AI Assistant feature

---

**Status:** ✅ Script created at `scripts/create_ai_assistant_config.js`
