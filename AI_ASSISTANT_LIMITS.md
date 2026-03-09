# AI Assistant Limits & Caps

## Current Limits (Production-Safe)

### ✅ **Rate Limiting**
- **Per User:** 10 requests per minute
- **Per Facility:** 30 requests per minute
- **Purpose:** Prevent abuse and API spam

### ✅ **Daily Usage Caps**
- **Per Facility:** 100 messages/day (configurable)
- **Per User:** 50 messages/day (configurable)
- **Purpose:** Control costs and prevent runaway usage

### ✅ **Token Limits**
- **Max Tokens per Request:** 1000 tokens (configurable)
- **Model:** `gpt-4o-mini` (cost-effective)
- **Purpose:** Limit response length and control costs

### ✅ **Message Limits**
- **Max Message Length:** 2000 characters
- **Purpose:** Prevent extremely long inputs

### ✅ **Conversation History**
- **Max Messages in History:** 10 messages (configurable)
- **Purpose:** Limit context size and token usage

### ✅ **Feature Flags**
- **Kill Switch:** Can disable globally instantly
- **Per-Facility Enable:** Only enabled facilities can use
- **Allowlist:** Can restrict to specific facilities

## Cost Controls

### Estimated Costs (with limits):
- **Per Request:** ~$0.0005 - $0.001 (500-1000 tokens)
- **Per Facility/Day (100 messages):** ~$0.05 - $0.10
- **Per User/Day (50 messages):** ~$0.025 - $0.05
- **Monthly (100 facilities, 100 msgs/day each):** ~$150 - $300

### Cost Mitigation:
1. ✅ **Model Choice:** Using `gpt-4o-mini` (cheapest GPT-4 variant)
2. ✅ **Token Limits:** Capped at 1000 tokens per response
3. ✅ **Daily Caps:** Prevents runaway usage
4. ✅ **Rate Limiting:** Prevents spam/abuse
5. ✅ **Conversation History:** Limited to 10 messages (reduces input tokens)

## Configurable Limits (via Firestore)

All limits can be adjusted in `appConfig/aiAssistant`:

```json
{
  "enabled": true,
  "allowlistFacilityIds": [],
  "killSwitch": false,
  "provider": "openai",
  "maxTokensPerRequest": 1000,
  "maxMessagesPerDay": 100,
  "maxMessagesPerUser": 50,
  "maxConversationHistory": 10,
  "maxMessageLength": 2000
}
```

## Monitoring

### Usage Tracking:
- Daily usage stored in:
  - `facilities/{facilityId}/aiUsage/{date}` - Facility daily usage
  - `users/{userId}/aiUsage/{date}` - User daily usage
- Rate limits tracked in:
  - `facilities/{facilityId}/rateLimits/{key}_{windowStart}`

### Logs:
- All API calls logged to Firebase Functions logs
- Errors logged with full context
- Usage counters updated in real-time

## Safety Features

1. **Kill Switch:** Instant global disable
2. **Feature Flag:** Per-facility control
3. **Rate Limiting:** Prevents abuse
4. **Daily Caps:** Prevents cost overruns
5. **Token Limits:** Controls response size
6. **Message Validation:** Prevents malformed inputs
7. **Error Handling:** Falls back to keyword-based responses if API fails

## Adjusting Limits

### To Increase Limits:
Update `appConfig/aiAssistant` in Firestore:
```json
{
  "maxMessagesPerDay": 200,  // Increase facility limit
  "maxMessagesPerUser": 100,  // Increase user limit
  "maxTokensPerRequest": 2000 // Increase response length
}
```

### To Decrease Limits (Cost Control):
```json
{
  "maxMessagesPerDay": 50,   // Reduce facility limit
  "maxMessagesPerUser": 25,  // Reduce user limit
  "maxTokensPerRequest": 500 // Reduce response length
}
```

### Emergency Kill Switch:
```json
{
  "killSwitch": true  // Instantly disables for all facilities
}
```

---

**All limits are production-safe and designed to prevent cost overruns while allowing reasonable usage.**
