# AI Assistant Setup Guide
**Date:** January 23, 2026  
**Status:** Ready for API Key Configuration

---

## ✅ What's Been Done

1. **OpenAI SDK Added** - `openai` package added to `functions/package.json`
2. **Secret Definition** - `OPENAI_API_KEY` secret defined in `functions/src/index.ts`
3. **Function Updated** - `aiAssistant()` function now calls OpenAI API
4. **Prompt Engineering** - System prompt configured for action-based responses
5. **Error Handling** - Falls back to keyword-based responses if API fails
6. **Conversation History** - Loads and uses conversation context

---

## 🔧 What You Need to Do

### Step 1: Get OpenAI API Key

1. **Sign up/Login:**
   - Go to https://platform.openai.com
   - Create account or login
   - Navigate to API Keys section

2. **Create API Key:**
   - Click "Create new secret key"
   - Name it (e.g., "StorageFacilityCreator")
   - Copy the key (you won't see it again!)

### Step 2: Add API Key to Firebase Secrets

```bash
firebase functions:secrets:set OPENAI_API_KEY
```

When prompted, paste your OpenAI API key.

### Step 3: Install Dependencies

```bash
cd functions
npm install
```

This will install the `openai` package.

### Step 4: Build and Deploy

```bash
npm run build
firebase deploy --only functions:aiAssistant
```

### Step 5: Enable Feature Flag

Create or update `appConfig/aiAssistant` in Firestore:

```json
{
  "enabled": false,
  "allowlistFacilityIds": ["your-test-facility-id"],
  "killSwitch": false,
  "provider": "openai"
}
```

Replace `"your-test-facility-id"` with an actual facility ID for testing.

### Step 6: Test

1. Navigate to AI Assistant screen in your app
2. Try asking:
   - "How do I create a tenant?"
   - "Create a tenant named John Doe"
   - "What's my occupancy rate?"
   - "Send a reminder to tenant John"

---

## 📋 Quick Command Reference

```bash
# Set API key
firebase functions:secrets:set OPENAI_API_KEY

# Install dependencies
cd functions
npm install

# Build
npm run build

# Deploy
firebase deploy --only functions:aiAssistant

# Or deploy all functions
firebase deploy --only functions
```

---

## 🎯 Expected Behavior

### With API Key Configured:
- AI responds with natural language
- Proposes actions when user requests to do something
- Actions require confirmation before execution
- Conversation history is maintained

### Without API Key (Fallback):
- Uses keyword-based responses
- Still proposes actions for common requests
- Works but less intelligent

---

## 💰 Cost Considerations

- **Model Used:** `gpt-4o-mini` (cost-effective)
- **Estimated Cost:** ~$0.15 per 1M input tokens, ~$0.60 per 1M output tokens
- **Typical Request:** ~500-1000 tokens (very cheap)
- **Monthly Estimate:** $5-20 for moderate usage

**To Upgrade:**
- Change `model: 'gpt-4o-mini'` to `model: 'gpt-4'` in `functions/src/index.ts` line ~11260
- More expensive but more capable

---

## 🐛 Troubleshooting

### Error: "OpenAI API key not configured"
- **Fix:** Make sure you ran `firebase functions:secrets:set OPENAI_API_KEY`
- **Verify:** Check Firebase Console > Functions > Secrets

### Error: "Module not found: openai"
- **Fix:** Run `cd functions && npm install`

### Error: "AI assistant is not enabled"
- **Fix:** Set `appConfig/aiAssistant.enabled = true` or add facility to `allowlistFacilityIds`

### API Errors
- Check Firebase Functions logs: `firebase functions:log`
- Verify API key is valid at https://platform.openai.com
- Check your OpenAI account has credits/billing set up

---

## ✅ Success Indicators

When working correctly, you should see:
1. ✅ Natural language responses (not just keyword matching)
2. ✅ Context-aware answers (mentions facility name, occupancy, etc.)
3. ✅ Action proposals when you ask to do something
4. ✅ Conversation history maintained across messages

---

## 📝 Next Steps After AI Assistant Works

1. **Fine-tune Prompts** - Adjust system prompt for better action detection
2. **Implement Action Execution** - Complete `aiAssistantExecuteAction()` function
3. **Add More Actions** - Extend action types as needed
4. **Monitor Costs** - Check OpenAI usage dashboard
5. **Move to Next Integration** - 2FA OTP generation

---

**Status:** Ready for your API key! 🚀
