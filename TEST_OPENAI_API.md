# Testing OpenAI API Integration

## Current Status Check

### ✅ Code Implementation
- ✅ OpenAI SDK installed: `openai@4.104.0` (verified)
- ✅ Code implemented in `functions/src/index.ts`
- ✅ Secret definition: `OPENAI_API_KEY` configured
- ✅ Error handling: Falls back to keyword-based responses if API fails

### ⏳ Required Setup Steps

To make the API **actually work**, you need to complete these steps:

1. **Set Firebase Secret** (if not done):
   ```bash
   firebase functions:secrets:set OPENAI_API_KEY
   ```
   Paste your OpenAI API key when prompted.

2. **Deploy Function** (if not done):
   ```bash
   cd functions
   npm run build
   firebase deploy --only functions:aiAssistant
   ```

3. **Enable Feature Flag** (if not done):
   - Create `appConfig/aiAssistant` in Firestore
   - Set `enabled: true` or add facility to `allowlistFacilityIds`

## How to Test

### Option 1: Check Function Logs
```bash
firebase functions:log --only aiAssistant
```

Look for:
- ✅ "OpenAI API error:" = API key missing or invalid
- ✅ Successful API calls = Working!
- ✅ "OpenAI API key not configured" = Secret not set

### Option 2: Test in App
1. Navigate to AI Assistant screen
2. Send a message like "Hello, what can you help me with?"
3. **If working:** You'll get natural language responses
4. **If not working:** You'll get keyword-based fallback responses

### Option 3: Check Secret Status
```bash
firebase functions:secrets:access OPENAI_API_KEY
```
- If it shows the key (masked) = ✅ Secret is set
- If it errors = ❌ Secret not set

## Expected Behavior

### ✅ Working (API Key Set & Deployed):
- Natural, contextual responses
- Mentions facility name, occupancy rate
- Proposes actions intelligently
- Maintains conversation context

### ⚠️ Fallback Mode (No API Key or API Fails):
- Keyword-based responses
- Still proposes actions for common phrases
- Less intelligent, but functional

## Quick Diagnostic

Run this to check everything:
```bash
# 1. Check if secret exists
firebase functions:secrets:access OPENAI_API_KEY

# 2. Check if function is deployed
firebase functions:list | findstr aiAssistant

# 3. Check recent logs
firebase functions:log --only aiAssistant --limit 10
```

## Common Issues

### "OpenAI API key not configured"
- **Fix:** Run `firebase functions:secrets:set OPENAI_API_KEY`

### "AI assistant is not enabled"
- **Fix:** Enable in Firestore: `appConfig/aiAssistant.enabled = true`

### API Errors in Logs
- Check API key is valid at https://platform.openai.com
- Check account has credits/billing set up
- Verify key starts with `sk-`

---

**Next Step:** Check if the secret is set and function is deployed!
