import * as functions from 'firebase-functions/v1';
import { TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER } from './secrets';

/**
 * Sends the reply to an inbound STOP, START or HELP, and nothing else.
 *
 * It lives alone in this file so the customer-gate coverage check can exempt
 * exactly this function (see scripts/check_outbound_gate_coverage.js): the
 * reply goes only to the number that just texted [inboundTo], carriers require
 * it whatever our launch state, and withholding a STOP confirmation is the
 * non-compliant outcome. Any other send added to the webhook is still checked.
 */
export async function sendKeywordReply(params: {
  /** The number that texted us; the reply goes back to it. */
  replyTo: string;
  /** The number they texted; the reply comes from it. */
  inboundTo: string | null | undefined;
  message: string;
  requestId: string;
}): Promise<void> {
  const { replyTo, inboundTo, message, requestId } = params;
  try {
    const twilioAccountSid = TWILIO_ACCOUNT_SID.value().trim();
    const twilioAuthToken = TWILIO_AUTH_TOKEN.value().trim();
    const fromNumber = inboundTo || TWILIO_PHONE_NUMBER.value().trim();
    const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`;
    const auth = Buffer.from(`${twilioAccountSid}:${twilioAuthToken}`).toString('base64');
    const formData = new URLSearchParams();
    formData.append('To', replyTo);
    formData.append('From', fromNumber);
    formData.append('Body', message);
    await fetch(twilioUrl, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${auth}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: formData.toString(),
    });
  } catch (twilioError: unknown) {
    const msg = twilioError instanceof Error ? twilioError.message : String(twilioError);
    functions.logger.error('Error sending compliance response', { requestId, error: msg });
  }
}
