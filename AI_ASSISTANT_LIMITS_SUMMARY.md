# AI Assistant Hard Limits - Cost Protection

**Date:** January 24, 2026  
**Status:** ✅ All Limits Active and Enforced

---

## 🛡️ Active Hard Limits

### 1. **Rate Limits (Per Minute)**
- ✅ **10 requests per user per minute** - Prevents spam/abuse
- ✅ **30 requests per facility per minute** - Facility-wide throttling

### 2. **Daily Message Limits**
- ✅ **100 messages per facility per day** - Default (configurable in Firestore)
- ✅ **50 messages per user per day** - Default (configurable in Firestore)
- ✅ **Usage counters tracked** in Firestore:
  - `facilities/{facilityId}/aiUsage/{date}` - Daily facility usage
  - `users/{userId}/aiUsage/{date}` - Daily user usage

### 3. **Token Limits**
- ✅ **700 tokens max per response** - Hard-coded limit
- ✅ **1000 tokens max per request** - Configurable in Firestore (default)
- ✅ **Model:** `gpt-4o-mini` - Cost-effective model (~$0.15/$0.60 per 1M tokens)

### 4. **Input Limits**
- ✅ **2000 characters max per message** - Prevents oversized requests
- ✅ **Client-side validation** - Rejects before sending to function

### 5. **Kill Switch**
- ✅ **Global kill switch** - Set `killSwitch: true` in Firestore to instantly disable
- ✅ **Feature flag** - Set `enabled: false` to disable globally
- ✅ **Allowlist** - Restrict to specific facilities via `allowlistFacilityIds`

---

## 💰 Cost Estimates (with current limits)

### Per Request:
- **Input:** ~50-200 tokens (typical message)
- **Output:** Up to 700 tokens (hard limit)
- **Total:** ~750-900 tokens per request
- **Cost:** ~$0.0001 - $0.0005 per request

### Daily Maximums (if limits hit):
- **Per Facility:** 100 messages/day × $0.0003 = **~$0.03/day**
- **Per User:** 50 messages/day × $0.0003 = **~$0.015/day**

### Monthly Estimates:
- **1 facility, 1 user:** ~$0.90/month (if hitting daily limits)
- **10 facilities, 5 users each:** ~$9/month (if all hitting limits)
- **100 facilities, 10 users each:** ~$90/month (if all hitting limits)

**Note:** These are maximums if limits are hit. Actual usage will likely be much lower.

---

## 🔧 How to Adjust Limits

### Via Firestore Config (`appConfig/aiAssistant`):

```json
{
  "enabled": true,
  "killSwitch": false,
  "provider": "openai",
  "allowlistFacilityIds": [],
  "maxTokensPerRequest": 1000,      // Max tokens per request
  "maxMessagesPerDay": 100,         // Max messages per facility per day
  "maxMessagesPerUser": 50,         // Max messages per user per day
  "maxMessageLength": 2000          // Max characters per message
}
```

### To Reduce Costs:
1. **Lower daily limits:**
   - `maxMessagesPerDay: 50` (instead of 100)
   - `maxMessagesPerUser: 25` (instead of 50)

2. **Lower token limits:**
   - `maxTokensPerRequest: 500` (instead of 1000)
   - Note: Output is hard-capped at 700 tokens

3. **Use allowlist:**
   - Add only specific facility IDs to `allowlistFacilityIds`
   - Empty array = all facilities (if enabled)

4. **Emergency disable:**
   - Set `killSwitch: true` - Instantly disables for ALL facilities
   - Set `enabled: false` - Disables globally

---

## 📊 Monitoring Usage

### Check Daily Usage:
1. **Firestore Console:**
   - `facilities/{facilityId}/aiUsage/{date}` - See facility usage
   - `users/{userId}/aiUsage/{date}` - See user usage

2. **Cloud Function Logs:**
   ```bash
   firebase functions:log --only aiAssistantChat
   ```
   Look for:
   - `tokensUsed` - Token consumption per request
   - `facilityUsageCount` - Current daily count
   - `userUsageCount` - Current daily count

### Set Up Alerts:
- Monitor Firestore `aiUsage` collections
- Set up Cloud Monitoring alerts on function invocations
- Track token usage in logs

---

## ✅ Verification Checklist

- [x] Rate limiting enforced (10/user/min, 30/facility/min)
- [x] Daily limits enforced (100/facility/day, 50/user/day)
- [x] Token limits enforced (700 output, 1000 max)
- [x] Input length limits enforced (2000 chars)
- [x] Kill switch available (`killSwitch` field)
- [x] Feature flag available (`enabled` field)
- [x] Usage counters tracked in Firestore
- [x] Error messages show limit reached

---

## 🚨 Emergency Procedures

### If costs spike unexpectedly:
1. **Immediate:** Set `killSwitch: true` in `appConfig/aiAssistant`
2. **Check logs:** Review `firebase functions:log` for unusual activity
3. **Review usage:** Check `aiUsage` collections in Firestore
4. **Adjust limits:** Lower `maxMessagesPerDay` and `maxMessagesPerUser`

### If a user hits limits:
- They'll see: "Daily limit reached... Try again tomorrow"
- Limits reset at midnight UTC
- No charges for rejected requests

---

**All limits are server-side enforced and cannot be bypassed by client manipulation.**
