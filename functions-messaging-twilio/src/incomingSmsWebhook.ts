import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import {
  formatPhoneNumber,
  isSfcLeadLineMatch,
  processSfcLeadInboundSMSWebhook,
} from '@sfc/functions-shared';
import { isHelpKeyword, isStartKeyword, isStopKeyword } from '@sfc/functions-shared';
import {
  TWILIO_AUTH_TOKEN,
  TWILIO_SECRETS,
} from './secrets';
import { isSMSComplianceFeatureEnabled } from './smsCompliance';
import { verifyTwilioWebhookSignature } from './twilioWebhookSignature';
import { findTenantsByPhoneNumber, TenantPhoneMatch } from './tenantPhoneLookup';
import {
  buildHelpReply,
  buildStartReply,
  helpFacilityIds,
  KeywordReplyFacility,
  startRestorableMatches,
} from './inboundKeywordReplies';
import { sendKeywordReply } from './keywordReplySender';

/**
 * Phase 12: Two-Way SMS Messaging — inbound Twilio webhook.
 */
export const handleIncomingSMS = functions.runWith({
  secrets: TWILIO_SECRETS,
}).https.onRequest(async (req, res) => {
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

    const from = req.body.From as string;
    const to = req.body.To as string;
    const body = ((req.body.Body as string) || '').trim();
    const messageSid = req.body.MessageSid as string;
    const requestId = crypto.randomUUID();

    // The shared toll-free number is also the marketing lead line, so a tenant
    // whose text went out from it will reply to it. Compliance keywords
    // (STOP/START/HELP) and known-tenant replies must be handled as such
    // FIRST; only genuinely unknown, non-keyword inbound to the lead line is
    // treated as a new sales lead further down. Handling the lead line before
    // the keyword checks (as this used to) meant a customer's STOP was filed
    // as a lead and never opted them out.
    const isLeadLine = Boolean(to && isSfcLeadLineMatch(to));

    const inboundFacilityId = await findFacilityIdByInboundNumber(to);
    functions.logger.info('Incoming SMS webhook', {
      requestId,
      fromMasked: `${from?.substring(0, 4)}****${from?.substring(Math.max(0, from.length - 4))}`,
      toMasked: `${to?.substring(0, 4)}****${to?.substring(Math.max(0, to.length - 4))}`,
      messageSid,
      inboundFacilityId: inboundFacilityId || null,
    });

    const sendComplianceResponse = (message: string) =>
      sendKeywordReply({ replyTo: from, inboundTo: to, message, requestId });

    if (isStopKeyword(body)) {
      const confirmationMessage = await handleSMSOptOut(from, inboundFacilityId);
      if (confirmationMessage) {
        await sendComplianceResponse(confirmationMessage);
      }
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    if (isStartKeyword(body)) {
      const optedIn = await handleSMSOptIn(from, inboundFacilityId);
      const facilities = await loadKeywordFacilities(optedIn.map((t) => t.facilityId));
      await sendComplianceResponse(buildStartReply(facilities));
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    if (isHelpKeyword(body)) {
      // HELP always gets an answer, naming the facility (and its phone) when
      // the number belongs to a tenant, and the platform otherwise.
      const normalizedFrom = formatPhoneNumber(from);
      let matches: TenantPhoneMatch[] = [];
      if (normalizedFrom) {
        try {
          matches = await findTenantsByPhoneNumber(normalizedFrom, inboundFacilityId);
        } catch (error: unknown) {
          const msg = error instanceof Error ? error.message : String(error);
          functions.logger.error(`Error finding tenant for HELP: ${msg}`);
        }
      }
      // Only active tenancies are named (and on a facility's own line, only
      // that facility), so HELP never reveals where a number used to rent.
      const facilities = await loadKeywordFacilities(helpFacilityIds(matches, inboundFacilityId));
      await sendComplianceResponse(buildHelpReply(facilities));
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    const normalizedFrom = formatPhoneNumber(from);
    if (!normalizedFrom) {
      functions.logger.warn(`Invalid phone number format: ${from}`);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    let tenant: TenantPhoneMatch | null = null;
    try {
      tenant = (await findTenantsByPhoneNumber(normalizedFrom, inboundFacilityId))[0] ?? null;
    } catch (error: unknown) {
      // A lookup failure must not turn a tenant's reply into a sales lead
      // with the lead auto-reply. Acknowledge and drop it instead.
      const msg = error instanceof Error ? error.message : String(error);
      functions.logger.error(`Error finding tenant by phone: ${msg}`);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    if (!tenant) {
      // Not a compliance keyword and not a known tenant. If it arrived on the
      // lead line it is a genuine new inbound lead; log it and auto-reply.
      // Otherwise there is nowhere to file it.
      if (isLeadLine) {
        await processSfcLeadInboundSMSWebhook({ res, from, to, body, messageSid, requestId });
        return;
      }
      functions.logger.warn(`Incoming SMS from unknown number: ${from}`);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    const conversationId = await getOrCreateSMSConversation(tenant.facilityId, tenant.id, normalizedFrom);

    await storeIncomingSMSMessage(conversationId, tenant.facilityId, tenant.id, normalizedFrom, body, messageSid);

    await createContactLogForSMSReply(tenant.facilityId, tenant.id, body, normalizedFrom, messageSid);

    functions.logger.info(`Stored incoming SMS from tenant ${tenant.id} in facility ${tenant.facilityId}`);

    res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error handling incoming SMS: ${msg}`, error);
    res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
  }
});

/** Name, phone and HELP wording of each facility, in the order given, once each. */
async function loadKeywordFacilities(facilityIds: string[]): Promise<KeywordReplyFacility[]> {
  const unique = Array.from(new Set(facilityIds)).slice(0, 5);
  const out: KeywordReplyFacility[] = [];
  for (const facilityId of unique) {
    try {
      const doc = await admin.firestore().collection('facilities').doc(facilityId).get();
      const data = doc.data() as Record<string, unknown> | undefined;
      if (!data) continue;
      const smsSettings = data.smsSettings as Record<string, unknown> | undefined;
      out.push({
        name: (data.name as string | undefined) ?? null,
        phone: (data.phone as string | undefined) ?? null,
        helpMessage: (smsSettings?.helpMessage as string | undefined) ?? null,
      });
    } catch (error: unknown) {
      const msg = error instanceof Error ? error.message : String(error);
      functions.logger.warn('Could not read facility for keyword reply', { facilityId, error: msg });
    }
  }
  return out;
}

async function findFacilityIdByInboundNumber(toPhoneNumber: string): Promise<string | null> {
  try {
    const normalized = formatPhoneNumber(toPhoneNumber);
    if (!normalized) return null;
    const snapshot = await admin.firestore()
      .collection('facilities')
      .where('twilioPhoneNumberE164', '==', normalized)
      .limit(1)
      .get();
    if (!snapshot.empty) {
      return snapshot.docs[0].id;
    }
    return null;
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.warn('Failed to resolve inbound facility by number', { error: msg });
    return null;
  }
}

async function getOrCreateSMSConversation(
  facilityId: string,
  tenantId: string,
  phoneNumber: string,
): Promise<string> {
  try {
    const conversationsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations');

    const existingQuery = await conversationsRef
      .where('tenantId', '==', tenantId)
      .where('phoneNumber', '==', phoneNumber)
      .limit(1)
      .get();

    if (!existingQuery.empty) {
      return existingQuery.docs[0].id;
    }

    const conversationRef = await conversationsRef.add({
      tenantId,
      phoneNumber,
      lastMessage: '',
      lastMessageAt: admin.firestore.FieldValue.serverTimestamp(),
      lastMessageDirection: 'incoming',
      unreadCount: 0,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return conversationRef.id;
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error creating SMS conversation: ${msg}`, error);
    throw error;
  }
}

async function storeIncomingSMSMessage(
  conversationId: string,
  facilityId: string,
  tenantId: string,
  phoneNumber: string,
  messageBody: string,
  messageSid: string,
): Promise<void> {
  try {
    const now = admin.firestore.FieldValue.serverTimestamp();

    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations')
      .doc(conversationId)
      .collection('messages')
      .add({
        direction: 'incoming',
        phoneNumber,
        body: messageBody,
        status: 'received',
        messageSid,
        timestamp: now,
        read: false,
      });

    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations')
      .doc(conversationId)
      .update({
        lastMessage: messageBody.substring(0, 100),
        lastMessageAt: now,
        lastMessageDirection: 'incoming',
        unreadCount: admin.firestore.FieldValue.increment(1),
        updatedAt: now,
      });
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error storing incoming SMS message: ${msg}`, error);
    throw error;
  }
}

async function createContactLogForSMSReply(
  facilityId: string,
  tenantId: string,
  messageBody: string,
  phoneNumber: string,
  messageSid: string,
): Promise<void> {
  try {
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('contactLogs')
      .add({
        type: 'sms_reply',
        subject: 'SMS Reply from Tenant',
        message: messageBody,
        contactMethod: phoneNumber,
        direction: 'incoming',
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        metadata: {
          messageSid,
        },
      });
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.warn(`Failed to create contact log for SMS reply: ${msg}`);
  }
}

/**
 * Records a STOP on every tenant with this number, at every facility and
 * whether or not they are still active. One person may rent at several
 * facilities that all text from the shared number; an opt-out is theirs, not
 * one tenancy's, and over-honouring STOP is the safe direction.
 */
async function handleSMSOptOut(phoneNumber: string, facilityIdHint?: string | null): Promise<string | null> {
  try {
    const normalizedPhone = formatPhoneNumber(phoneNumber);
    if (!normalizedPhone) return null;

    const tenants = await findTenantsByPhoneNumber(normalizedPhone, facilityIdHint);
    if (tenants.length === 0) return null;

    for (const tenant of tenants) {
      await admin.firestore()
        .collection('facilities')
        .doc(tenant.facilityId)
        .collection('tenants')
        .doc(tenant.id)
        .update({
          smsOptOut: true,
          smsConsentStatus: 'opted_out',
          smsConsentTimestamp: admin.firestore.FieldValue.serverTimestamp(),
          smsConsentSource: 'inbound_stop',
          smsOptOutDate: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }

    const facilityIds = Array.from(new Set(tenants.map((t) => t.facilityId)));
    for (const facilityId of facilityIds) {
      const complianceEnabled = await isSMSComplianceFeatureEnabled('enhancedOptOut', facilityId);
      if (!complianceEnabled) continue;
      const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
      const facilityDoc = await facilityRef.get();
      const facilityData = facilityDoc.data() as Record<string, unknown> | undefined;

      const smsSettings = facilityData?.smsSettings || {};
      const blockList = (smsSettings as { blockList?: string[] }).blockList || [];

      if (!blockList.includes(normalizedPhone)) {
        blockList.push(normalizedPhone);
        await facilityRef.update({
          'smsSettings.blockList': blockList,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    functions.logger.info('Inbound STOP recorded', {
      tenants: tenants.length,
      facilities: facilityIds.length,
    });

    return 'You have been unsubscribed from SMS messages. Reply START to opt back in.';
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error handling SMS opt-out: ${msg}`, error);
    return null;
  }
}

async function handleSMSOptIn(
  phoneNumber: string,
  facilityIdHint?: string | null,
): Promise<TenantPhoneMatch[]> {
  try {
    const normalizedPhone = formatPhoneNumber(phoneNumber);
    if (!normalizedPhone) return [];

    // START only undoes this person's own STOP on active tenancies (and on a
    // facility's own line, only that facility's). It never writes consent
    // onto a record that had none, or onto a former tenancy; those get the
    // generic confirmation and nothing is recorded. See isStartRestorable.
    const allMatches = await findTenantsByPhoneNumber(normalizedPhone, facilityIdHint);
    const matches = startRestorableMatches(allMatches, facilityIdHint);
    if (matches.length < allMatches.length) {
      functions.logger.info('START not applied to tenancies without a prior inbound STOP', {
        restored: matches.length,
        skipped: allMatches.length - matches.length,
      });
    }
    for (const tenant of matches) {
      await optInTenant(tenant, normalizedPhone);
    }
    return matches;
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error handling SMS opt-in: ${msg}`, error);
    return [];
  }
}

async function optInTenant(tenant: TenantPhoneMatch, normalizedPhone: string): Promise<void> {
  const complianceEnabled = await isSMSComplianceFeatureEnabled('enhancedOptOut', tenant.facilityId);

  const updateData: Record<string, unknown> = {
    smsOptOut: false,
    smsConsentStatus: 'opted_in',
    smsConsentTimestamp: admin.firestore.FieldValue.serverTimestamp(),
    smsConsentSource: 'inbound_start',
    smsOptInDate: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  if (complianceEnabled) {
    const facilityRef = admin.firestore().collection('facilities').doc(tenant.facilityId);
    const facilityDoc = await facilityRef.get();
    const facilityData = facilityDoc.data() as Record<string, unknown> | undefined;
    const smsSettings = facilityData?.smsSettings as { blockList?: string[] } | undefined;

    if (smsSettings?.blockList?.length) {
      const updatedBlockList = smsSettings.blockList.filter((phone) => phone !== normalizedPhone);

      await facilityRef.update({
        'smsSettings.blockList': updatedBlockList,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }

  await admin.firestore()
    .collection('facilities')
    .doc(tenant.facilityId)
    .collection('tenants')
    .doc(tenant.id)
    .update(updateData);

  functions.logger.info(`Tenant ${tenant.id} opted in to SMS`);
}
