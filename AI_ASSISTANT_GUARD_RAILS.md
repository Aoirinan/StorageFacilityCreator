# AI Assistant (OpenAI) Guard Rails

The AI assistant only answers questions about **storage facility management**. These guard rails run in both the app (client) and Cloud Functions (backend).

---

## 1. Topic check: “Storage facility related”

Your message must look like it’s about storage facilities. The app checks for **storage-related keywords** (and rejects obvious off-topic).

- **Pass:** Message contains at least one storage-related keyword, **or** it’s short (≤35 chars) and not off-topic.
- **Fail:** No storage keyword and either (a) message is long, or (b) it contains off-topic keywords (movies, recipes, pets, etc.).

### Storage-related keywords (updated so normal storage-facility questions pass)

- Core: `storage`, `facility`, `facilities`, `tenant`, `tenants`, `unit`, `units`, `occupancy`, `payment`, `payments`, `rent`, `lease`, `contract`, `move-in`, `move-out`, `gate`, `access`, `auction`, `lien`, `delinquency`, `pricing`, `yield`, `insurance`, `dnr`, `reservation`, `vacancy`, `deposit`, `billing`, `stripe`, `report`, `reports`, `late fee`, `self-storage`, `self storage`, `management`, `app`, `feature`, `how do i`, `how to`
- Added for natural questions: `property`, `properties`, `location`, `business`, `customer`, `rental`, `space`, `locker`, `owner`, `operate`, `operating`, `running`, `best practice`, `setup`, `set up`, `tips`, `advice`, `monthly`, `overdue`, `collections`, `evict`, `overlock`, `lock out`, `lockout`, `charge`, `charges`, `fee`, `fees`, `price`, `rates`, `revenue`, `income`

### Off-topic keywords (reject if no storage keyword)

- Entertainment: `star trek`, `star wars`, `movie`, `film`, `recipe`, `sports`, `football`, `game of thrones`, `lotr`, `music`, `celebrity`, `joke`, `meme`, `trivia`
- Pets: `dog`, `cat`, `puppy`, `kitten`, etc. (in tenant/message context)

If your question was blocked as “not about storage facilities,” it was likely missing any of the keywords above. **We’ve expanded the list** so phrases like “best practices for my property,” “how do I run my business,” “tips for owners,” “pricing,” “collections,” etc. now pass.

---

## 2. No personalized messages

The AI **does not** have access to your tenant list or contact data. So it will refuse requests like:

- “Write a message to [person]”
- “Draft an email to my tenant”
- “Send a reminder to John”

You’ll get a message telling you to use **Messaging** or **Reminders** in the app instead.

---

## 3. Nonsense / abuse

- Requests that mix pets with tenant/rent context (e.g. “message to my dog about rent”) are rejected.
- **Prompt injection** (e.g. “ignore previous instructions,” “you are now…”) is rejected.
- **Suspicious patterns** (repeated characters, URLs, scripts, passwords, card numbers) can trigger rejection.

---

## 4. Message length and format

- **Max length:** 2,000 characters (client and backend).
- **Min length:** 3 characters (backend).
- Too many repeated characters or invalid format can be rejected.

---

## 5. Moderation (backend only)

- The backend may run the message through **OpenAI’s Moderation API**. If it’s flagged as harmful/inappropriate, the request is rejected with a generic “inappropriate content” message.

---

## 6. Rate and usage limits

- **Per user:** 5 requests per minute; daily cap (e.g. 20 messages/day per user, from config).
- **Per facility:** daily cap (e.g. 30 messages/day per facility, from config).
- Hitting a limit returns a “limit reached” or “try again later” style error.

---

## 7. Feature and facility config

- AI is controlled by Firestore **`/appConfig/aiAssistant`**: `enabled`, `killSwitch`, `provider`, `allowlistFacilityIds`, etc.
- If the feature is off, or your facility isn’t allowed, you’ll get a message that the AI assistant is not enabled for this facility.

---

## Summary of the fix for “it isn’t letting me ask anything about storage facilities”

- **Cause:** The “storage facility related” check depended on a fixed list of keywords. Some normal storage-facility questions didn’t use those exact words and were rejected.
- **Change:** We **expanded the keyword list** in both the Flutter app and Cloud Functions so that normal questions about:
  - property, business, location, customers, rental, space, locker  
  - owner, operate, running, best practice, setup, tips, advice  
  - monthly, overdue, collections, evict, overlock, lockout  
  - charge, fee, price, rates, revenue, income  

  now count as “storage facility related” and are allowed.

After deploying **both** the app (e.g. `flutter build web` + hosting) and **Cloud Functions** (`firebase deploy --only functions`), you should be able to ask things like “What are best practices for my property?” or “How do I handle collections?” without being blocked.
