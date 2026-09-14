// Single implementation lives in functions-shared so the marketing lead
// webhooks and this package cannot drift apart again (the two copies had
// identical bugs for months).
export { verifyTwilioWebhookSignature, twilioWebhookUrl } from '@sfc/functions-shared';
