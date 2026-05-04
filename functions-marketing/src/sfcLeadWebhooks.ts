import * as crypto from 'crypto';
import * as functions from 'firebase-functions/v1';
import {
  escapeXml,
  formatPhoneNumber,
  processSfcLeadInboundSMSWebhook,
  upsertSfcLeadFromInboundContact,
  verifyTwilioWebhookSignature,
} from '@sfc/functions-shared';

import { SFC_LEAD_FORWARD_TO_NUMBER, SFC_LEAD_TWILIO_SECRETS, TWILIO_AUTH_TOKEN } from './secrets';

/**
 * Dedicated Twilio webhook for the SFC lead line (SMS).
 * Twilio is pointed at this URL directly for the lead number.
 */
export const handleSfcLeadSMS = functions
  .runWith({ secrets: SFC_LEAD_TWILIO_SECRETS })
  .https.onRequest(async (req, res) => {
    res.set('Access-Control-Allow-Origin', '*');
    res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.set('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
      res.status(200).send('');
      return;
    }

    if (req.method !== 'POST') {
      res.status(405).send('Method Not Allowed');
      return;
    }

    try {
      if (!verifyTwilioWebhookSignature(req, res, TWILIO_AUTH_TOKEN.value())) {
        return;
      }
      const from = String(req.body.From || '').trim();
      const to = String(req.body.To || '').trim();
      const body = String(req.body.Body || '').trim();
      const messageSid = String(req.body.MessageSid || '').trim();
      const requestId = crypto.randomUUID();

      await processSfcLeadInboundSMSWebhook({
        res,
        from,
        to,
        body,
        messageSid: messageSid || undefined,
        requestId,
      });
    } catch (error: any) {
      functions.logger.error('Error handling SFC lead SMS webhook', { error: error?.message });
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
    }
  });

/**
 * Dedicated Twilio webhook for voice calls to the SFC lead line.
 * Logs inbound call activity and forwards the call to a configured personal number.
 */
export const handleSfcLeadCall = functions
  .runWith({ secrets: SFC_LEAD_TWILIO_SECRETS })
  .https.onRequest(async (req, res) => {
    res.set('Access-Control-Allow-Origin', '*');
    res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.set('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
      res.status(200).send('');
      return;
    }

    if (req.method !== 'POST') {
      res.status(405).send('Method Not Allowed');
      return;
    }

    try {
      if (!verifyTwilioWebhookSignature(req, res, TWILIO_AUTH_TOKEN.value())) {
        return;
      }
      const from = String(req.body.From || '').trim();
      const to = String(req.body.To || '').trim();
      const callSid = String(req.body.CallSid || '').trim();
      const callStatus = String(req.body.CallStatus || '').trim();

      const lead = await upsertSfcLeadFromInboundContact({
        channel: 'call',
        fromRaw: from,
        toRaw: to,
        callSid: callSid || undefined,
        callStatus: callStatus || undefined,
      });

      const forwardToRaw = SFC_LEAD_FORWARD_TO_NUMBER.value().trim();
      const forwardTo = formatPhoneNumber(forwardToRaw) || forwardToRaw;

      functions.logger.info('Inbound SFC lead call received', {
        leadId: lead.leadId,
        callSid: callSid || null,
        callStatus: callStatus || null,
        hasForwardTarget: Boolean(forwardTo),
      });

      const xml = forwardTo
        ? `<?xml version="1.0" encoding="UTF-8"?><Response><Dial answerOnBridge="true"><Number>${escapeXml(forwardTo)}</Number></Dial></Response>`
        : '<?xml version="1.0" encoding="UTF-8"?><Response><Say voice="alice">Thanks for calling Storage Facility Creator. Please text this number and we will follow up shortly.</Say></Response>';

      res.status(200).contentType('text/xml').send(xml);
    } catch (error: any) {
      functions.logger.error('Error handling SFC lead call webhook', { error: error?.message });
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
    }
  });
