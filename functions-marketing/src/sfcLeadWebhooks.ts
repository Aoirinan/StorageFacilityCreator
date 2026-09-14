import * as crypto from 'crypto';
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import {
  escapeXml,
  formatPhoneNumber,
  processSfcLeadInboundSMSWebhook,
  upsertSfcLeadFromInboundContact,
  twilioWebhookUrl,
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
const MENU_GREETING =
  'Thanks for calling Storage Facility Creator, management software for self storage facilities.';
const MENU_PROMPT =
  'Press 1 to talk to us about a demo. Press 2 for support with an existing account. Press 3 to hear our website address.';
const MENU_CHOICES: Record<string, 'demo' | 'support' | 'website'> = {
  '1': 'demo',
  '2': 'support',
  '3': 'website',
};

const WHISPERS: Record<string, string> = {
  demo: 'Demo request from the Storage Facility Creator eight five five line. Connecting the caller now.',
  support: 'Support call from the Storage Facility Creator eight five five line. Connecting the caller now.',
  general: 'Call forwarded from the Storage Facility Creator eight five five line. Connecting the caller now.',
};

function twiml(body: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><Response>${body}</Response>`;
}

function say(text: string): string {
  return `<Say voice="alice">${escapeXml(text)}</Say>`;
}

/** One-digit menu; on no input Twilio continues with whatever follows the Gather. */
function gather(baseUrl: string, leadId: string, prompt: string): string {
  const action = `${baseUrl}?step=choice${leadId ? `&lead=${encodeURIComponent(leadId)}` : ''}`;
  return `<Gather numDigits="1" timeout="6" action="${escapeXml(action)}" method="POST">${say(prompt)}</Gather>`;
}

function forwardTarget(): string {
  const raw = SFC_LEAD_FORWARD_TO_NUMBER.value().trim();
  return formatPhoneNumber(raw) || raw;
}

/** Dial the forward number with a whisper naming the menu choice, or explain there is nobody to reach. */
function forwardBody(baseUrl: string, whisper: keyof typeof WHISPERS): string {
  const forwardTo = forwardTarget();
  if (!forwardTo) {
    return say('Nobody is available to take your call right now. Please text this number and we will follow up shortly.');
  }
  const whisperUrl = `${baseUrl}?whisper=${whisper}`;
  return `<Dial answerOnBridge="true"><Number url="${escapeXml(whisperUrl)}">${escapeXml(forwardTo)}</Number></Dial>`;
}

function forwardTwiml(baseUrl: string, whisper: keyof typeof WHISPERS): string {
  return twiml(forwardBody(baseUrl, whisper));
}

function whisperTwiml(kind: string): string {
  return twiml(say(WHISPERS[kind] || WHISPERS.general));
}

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

      // Every later leg of the call comes back to this same function with a
      // query string. Twilio signs those requests with the query included,
      // which the shared URL rebuild preserves.
      const baseUrl = twilioWebhookUrl(req).split('?')[0];
      const step = String(req.query.step || '');
      const whisper = String(req.query.whisper || '');

      // Whisper leg: played to the forwarded-to phone after it answers and
      // before bridging, so whoever picks up knows this came through the SFC
      // line and what the caller chose. The caller hears ringing meanwhile.
      if (whisper) {
        res.status(200).contentType('text/xml').send(whisperTwiml(whisper));
        return;
      }

      // Menu keypress leg.
      if (step === 'choice') {
        const digits = String(req.body.Digits || '').trim();
        const leadId = String(req.query.lead || '').trim();
        const choice = MENU_CHOICES[digits];
        functions.logger.info('SFC lead call menu choice', { digits, choice: choice || null, leadId: leadId || null });
        if (leadId && choice) {
          await admin.firestore().collection('marketing_leads').doc(leadId).set(
            { lastCallMenuChoice: choice, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
            { merge: true },
          );
        }
        if (choice === 'demo' || choice === 'support') {
          res.status(200).contentType('text/xml').send(forwardTwiml(baseUrl, choice));
          return;
        }
        if (choice === 'website') {
          res.status(200).contentType('text/xml').send(
            twiml(
              `${say('Our website is storage facility creator dot com. That is storage, facility, creator, dot com.')}` +
              `<Pause length="1"/>${gather(baseUrl, leadId, MENU_PROMPT)}${say('Connecting you to our team.')}` +
              forwardBody(baseUrl, 'general'),
            ),
          );
          return;
        }
        res.status(200).contentType('text/xml').send(
          twiml(
            `${say('Sorry, I did not catch that.')}${gather(baseUrl, leadId, MENU_PROMPT)}` +
            `${say('Connecting you to our team.')}${forwardBody(baseUrl, 'general')}`,
          ),
        );
        return;
      }

      // First leg: the inbound call itself.
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

      functions.logger.info('Inbound SFC lead call received', {
        leadId: lead.leadId,
        callSid: callSid || null,
        callStatus: callStatus || null,
        hasForwardTarget: Boolean(forwardTarget()),
      });

      // Greeting, then the menu. If the caller presses nothing the Gather
      // falls through and we connect them anyway rather than dead-ending.
      res.status(200).contentType('text/xml').send(
        twiml(
          `${say(MENU_GREETING)}${gather(baseUrl, lead.leadId, MENU_PROMPT)}` +
          `${say('Connecting you to our team.')}${forwardBody(baseUrl, 'general')}`,
        ),
      );
    } catch (error: any) {
      functions.logger.error('Error handling SFC lead call webhook', { error: error?.message });
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
    }
  });
