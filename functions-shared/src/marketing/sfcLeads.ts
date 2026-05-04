import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import { formatPhoneNumber } from '../utils/phoneFormat';
import { requireSfcLeadConfigProvider } from './sfcLeadConfigRegistry';

export function escapeXml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export function getConfiguredSfcLeadLine(): string | null {
  const configured = requireSfcLeadConfigProvider().getLeadLine().trim();
  if (!configured) return null;
  return formatPhoneNumber(configured) || configured;
}

export function isSfcLeadLineMatch(toPhoneNumber: string): boolean {
  const configured = getConfiguredSfcLeadLine();
  if (!configured) return false;
  const normalizedTo = formatPhoneNumber(toPhoneNumber) || toPhoneNumber;
  return normalizedTo === configured;
}

/**
 * Idempotently upserts a `marketing_leads` doc for an inbound SMS or call,
 * appending a per-channel activity entry. Used by both the dedicated SFC lead
 * webhooks (functions-marketing) and the general inbound SMS webhook
 * (functions-messaging) when the inbound destination matches the lead line.
 */
export async function upsertSfcLeadFromInboundContact(params: {
  channel: 'sms' | 'call';
  fromRaw: string;
  toRaw: string;
  messageBody?: string;
  messageSid?: string;
  callSid?: string;
  callStatus?: string;
}): Promise<{ leadId: string }> {
  const { channel, fromRaw, toRaw, messageBody, messageSid, callSid, callStatus } = params;
  const db = admin.firestore();
  const normalizedFrom = formatPhoneNumber(fromRaw) || fromRaw || 'unknown';
  const normalizedTo = formatPhoneNumber(toRaw) || toRaw || null;
  const leadsRef = db.collection('marketing_leads');

  let leadSnap = await leadsRef.where('phone', '==', normalizedFrom).limit(1).get();
  if (leadSnap.empty && normalizedFrom !== fromRaw && fromRaw) {
    leadSnap = await leadsRef.where('phone', '==', fromRaw).limit(1).get();
  }

  const now = admin.firestore.FieldValue.serverTimestamp();
  let leadRef: admin.firestore.DocumentReference;
  let created = false;

  if (leadSnap.empty) {
    created = true;
    leadRef = leadsRef.doc();
    const last4 = normalizedFrom.replace(/\D/g, '').slice(-4);
    const displayLast4 = last4 ? `-${last4}` : '';
    await leadRef.set({
      source: channel === 'sms' ? 'twilio_inbound_sms' : 'twilio_inbound_call',
      status: 'new',
      intent: 'demo',
      name: `Inbound Lead${displayLast4}`,
      email: '',
      facilityName: 'Storage Facility Creator',
      phone: normalizedFrom,
      unitCount: null,
      message: channel === 'sms' ? (messageBody || null) : null,
      smsConsent: false,
      assignedToUid: null,
      assignedToEmail: null,
      assignedToName: null,
      lastCalledAt: channel === 'call' ? now : null,
      saleStatus: 'pending',
      saleAmount: null,
      leadPhoneNumber: normalizedFrom,
      leadLineNumber: normalizedTo,
      createdAt: now,
      updatedAt: now,
    });
  } else {
    leadRef = leadSnap.docs[0].ref;
    const update: Record<string, unknown> = {
      updatedAt: now,
      leadPhoneNumber: normalizedFrom,
      leadLineNumber: normalizedTo,
    };
    if (channel === 'sms' && messageBody && messageBody.trim()) {
      update.message = messageBody.trim();
    }
    if (channel === 'call') {
      update.lastCalledAt = now;
    }
    await leadRef.set(update, { merge: true });
  }

  const summary = channel === 'sms'
    ? `Inbound SMS from ${normalizedFrom}${messageBody ? `: ${messageBody.substring(0, 500)}` : ''}`
    : `Inbound call from ${normalizedFrom}${callStatus ? ` (${callStatus})` : ''}`;

  await leadRef.collection('activities').add({
    type: channel === 'sms' ? 'inbound_sms' : 'inbound_call',
    summary,
    actorUid: 'system',
    actorEmail: 'system',
    actorName: 'System',
    messageSid: messageSid || null,
    callSid: callSid || null,
    callStatus: callStatus || null,
    createdAt: now,
  });

  if (created) {
    await leadRef.collection('activities').add({
      type: 'lead_created',
      summary: `Lead created from inbound ${channel}.`,
      actorUid: 'system',
      actorEmail: 'system',
      actorName: 'System',
      createdAt: now,
    });
  }

  return { leadId: leadRef.id };
}

/**
 * Logs the inbound SMS as an SFC lead and replies with the configured TwiML
 * auto-reply. Mirrors the legacy default-codebase implementation.
 */
export async function processSfcLeadInboundSMSWebhook(params: {
  res: functions.Response<unknown>;
  from: string;
  to: string;
  body: string;
  messageSid?: string;
  requestId?: string;
}): Promise<void> {
  const { res, from, to, body, messageSid, requestId } = params;
  const lead = await upsertSfcLeadFromInboundContact({
    channel: 'sms',
    fromRaw: from,
    toRaw: to,
    messageBody: body,
    messageSid,
  });
  functions.logger.info('Logged inbound SMS as SFC lead', {
    requestId: requestId || null,
    leadId: lead.leadId,
    messageSid: messageSid || null,
  });

  const autoReply = requireSfcLeadConfigProvider().getSmsAutoReply().trim();
  const xml = autoReply
    ? `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${escapeXml(autoReply)}</Message></Response>`
    : '<?xml version="1.0" encoding="UTF-8"?><Response></Response>';
  res.status(200).contentType('text/xml').send(xml);
}
