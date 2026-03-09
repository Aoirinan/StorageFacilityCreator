# Deploy AI Assistant to Production

## ✅ Pre-Deployment Checklist

- [x] OpenAI API key configured in Firebase Secrets
- [x] OpenAI SDK installed (`openai@4.104.0`)
- [x] Code implemented with safety limits
- [x] Rate limiting added
- [x] Daily usage caps added
- [x] Token limits configured
- [x] Error handling with fallback
- [ ] Build successful
- [ ] Deploy function
- [ ] Enable feature flag

## 🚀 Deployment Steps

### Step 1: Build
```bash
cd functions
npm run build
```

### Step 2: Deploy
```bash
firebase deploy --only functions:aiAssistant
```

Or deploy all functions:
```bash
firebase deploy --only functions
```

### Step 3: Enable Feature Flag

Create `appConfig/aiAssistant` in Firestore:

```json
{
  "enabled": true,
  "allowlistFacilityIds": [],  // Empty = all facilities (if enabled: true)
  "killSwitch": false,
  "provider": "openai",
  "maxTokensPerRequest": 1000,
  "maxMessagesPerDay": 100,
  "maxMessagesPerUser": 50,
  "maxConversationHistory": 10,
  "maxMessageLength": 2000
}
```

**For Testing (Safer):**
```json
{
  "enabled": false,
  "allowlistFacilityIds": ["your-test-facility-id"],
  "killSwitch": false,
  "provider": "openai"
}
```

## 📊 Limits Summary

### Rate Limits:
- **10 requests/minute per user**
- **30 requests/minute per facility**

### Daily Caps:
- **100 messages/day per facility**
- **50 messages/day per user**

### Token Limits:
- **1000 tokens per response** (configurable)

### Other Limits:
- **2000 characters max message length**
- **10 messages in conversation history**

## 💰 Cost Estimate

With these limits:
- **Per request:** ~$0.0005 - $0.001
- **Per facility/day (100 msgs):** ~$0.05 - $0.10
- **Per user/day (50 msgs):** ~$0.025 - $0.05
- **Monthly (100 facilities):** ~$150 - $300

## 🔍 Post-Deployment Testing

1. **Check Function Logs:**
   ```bash
   firebase functions:log --only aiAssistant
   ```

2. **Test in App:**
   - Navigate to AI Assistant screen
   - Send test message: "Hello, what can you help me with?"
   - Verify natural language response

3. **Test Limits:**
   - Try sending 11 messages in 1 minute (should hit rate limit)
   - Verify error message is clear

4. **Monitor Usage:**
   - Check `facilities/{facilityId}/aiUsage/{date}` in Firestore
   - Verify counters increment correctly

## 🛡️ Safety Features

1. **Kill Switch:** Set `killSwitch: true` to instantly disable globally
2. **Feature Flag:** `enabled: false` disables for all
3. **Allowlist:** Only specific facilities can use if `enabled: false`
4. **Rate Limiting:** Prevents abuse
5. **Daily Caps:** Prevents cost overruns
6. **Error Handling:** Falls back to keyword-based responses if API fails

## 📝 Quick Commands

```bash
# Deploy
cd functions
npm run build
firebase deploy --only functions:aiAssistant

# Check logs
firebase functions:log --only aiAssistant --limit 20

# Check if deployed
firebase functions:list | findstr aiAssistant
```

---

**Ready to deploy!** All safety limits are in place. 🚀
