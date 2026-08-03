# Enable AI Assistant Feature Flag - Step by Step

## 🔗 Direct Link to Firestore Console

**Click here to go directly to Firestore:**
https://console.firebase.google.com/project/storage-facility-creator/firestore

---

## 📋 Step-by-Step Instructions

### Step 1: Open Firestore Console
1. Click the link above, OR
2. Go to https://console.firebase.google.com
3. Select your project: **storage-facility-creator**
4. Click **"Firestore Database"** in the left sidebar

### Step 2: Navigate to appConfig Collection
1. In the Firestore data viewer, look for the **`appConfig`** collection
2. If it doesn't exist, click **"Start collection"** and name it `appConfig`
3. If it exists, click on it to view its documents

### Step 3: Create aiAssistant Document
1. Click **"Add document"** (or the **+** button)
2. **Document ID:** Type `aiAssistant` (exactly as shown)
3. Click **"Auto-ID"** to turn it off, then type `aiAssistant`
4. Click **"Save"**

### Step 4: Add Fields
Click **"Add field"** for each of these fields:

#### Field 1: `enabled`
- **Field name:** `enabled`
- **Type:** `boolean`
- **Value:** `true` (or `false` for testing)

#### Field 2: `allowlistFacilityIds`
- **Field name:** `allowlistFacilityIds`
- **Type:** `array`
- **Value:** Leave empty `[]` OR add facility IDs like `["facility-id-1", "facility-id-2"]`

#### Field 3: `killSwitch`
- **Field name:** `killSwitch`
- **Type:** `boolean`
- **Value:** `false`

#### Field 4: `provider`
- **Field name:** `provider`
- **Type:** `string`
- **Value:** `openai`

#### Field 5: `maxTokensPerRequest` (Optional)
- **Field name:** `maxTokensPerRequest`
- **Type:** `number`
- **Value:** `1000`

#### Field 6: `maxMessagesPerDay` (Optional)
- **Field name:** `maxMessagesPerDay`
- **Type:** `number`
- **Value:** `100`

#### Field 7: `maxMessagesPerUser` (Optional)
- **Field name:** `maxMessagesPerUser`
- **Type:** `number`
- **Value:** `50`

#### Field 8: `maxConversationHistory` (Optional)
- **Field name:** `maxConversationHistory`
- **Type:** `number`
- **Value:** `10`

#### Field 9: `maxMessageLength` (Optional)
- **Field name:** `maxMessageLength`
- **Type:** `number`
- **Value:** `2000`

### Step 5: Save
Click **"Update"** or **"Save"** to save the document

---

## 🎯 Quick Setup (Minimum Required)

**For quick testing, you only need these 4 fields:**

```json
{
  "enabled": true,
  "allowlistFacilityIds": [],
  "killSwitch": false,
  "provider": "openai"
}
```

The other fields will use defaults if not specified.

---

## 🧪 Testing Mode (Safer)

**To test with just one facility first:**

```json
{
  "enabled": false,
  "allowlistFacilityIds": ["your-facility-id-here"],
  "killSwitch": false,
  "provider": "openai"
}
```

Replace `"your-facility-id-here"` with an actual facility ID from your `facilities` collection.

---

## 📸 Visual Guide

### Where to Find appConfig:
```
Firestore Database
  └── appConfig (collection)
      └── aiAssistant (document) ← Create this
```

### Document Structure:
```
appConfig/aiAssistant
├── enabled: true
├── allowlistFacilityIds: []
├── killSwitch: false
├── provider: "openai"
├── maxTokensPerRequest: 1000
├── maxMessagesPerDay: 100
├── maxMessagesPerUser: 50
├── maxConversationHistory: 10
└── maxMessageLength: 2000
```

---

## ✅ Verification

After creating the document, verify it exists:
1. You should see `appConfig` collection
2. Inside it, you should see `aiAssistant` document
3. Click on `aiAssistant` to view/edit its fields

---

## 🚨 Emergency: Disable Instantly

If you need to disable AI Assistant immediately:
1. Open `appConfig/aiAssistant` document
2. Change `killSwitch` to `true`
3. Click **"Update"**

This instantly disables AI Assistant for ALL facilities, regardless of other settings.

---

## 📝 Alternative: Using Firebase CLI

If you prefer command line:

```bash
# Create the document via CLI (requires Firebase CLI)
firebase firestore:set appConfig/aiAssistant '{
  "enabled": true,
  "allowlistFacilityIds": [],
  "killSwitch": false,
  "provider": "openai"
}'
```

---

**Once you create this document, the AI Assistant will be enabled and ready to use!** 🚀
