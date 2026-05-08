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
  TWILIO_ACCOUNT_SID,
  TWILIO_AUTH_TOKEN,
  TWILIO_PHONE_NUMBER,
  TWILIO_SECRETS,
} from './secrets';
import { isSMSComplianceFeatureEnabled } from './smsCompliance';
import { verifyTwilioWebhookSignature } from './twilioWebhookSignature';

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

    if (to && isSfcLeadLineMatch(to)) {
      await processSfcLeadInboundSMSWebhook({
        res,
        from,
        to,
        body,
        messageSid,
        requestId,
      });
      return;
    }

    const inboundFacilityId = await findFacilityIdByInboundNumber(to);
    functions.logger.info('Incoming SMS webhook', {
      requestId,
      fromMasked: `${from?.substring(0, 4)}****${from?.substring(Math.max(0, from.length - 4))}`,
      toMasked: `${to?.substring(0, 4)}****${to?.substring(Math.max(0, to.length - 4))}`,
      messageSid,
      inboundFacilityId: inboundFacilityId || null,
    });

    async function sendComplianceResponse(message: string) {
      try {
        const twilioAccountSid = TWILIO_ACCOUNT_SID.value().trim();
        const twilioAuthToken = TWILIO_AUTH_TOKEN.value().trim();
        const defaultTwilioPhoneNumber = TWILIO_PHONE_NUMBER.value().trim();
        const fromNumber = to || defaultTwilioPhoneNumber;
        const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`;
        const auth = Buffer.from(`${twilioAccountSid}:${twilioAuthToken}`).toString('base64');
        const formData = new URLSearchParams();
        formData.append('To', from);
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
        functions.logger.error('Error sending compliance response', {
          requestId,
          error: msg,
        });
      }
    }

    if (isStopKeyword(body)) {
      const confirmationMessage = await handleSMSOptOut(from, inboundFacilityId);
      if (confirmationMessage) {
        await sendComplianceResponse(confirmationMessage);
      }
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    if (isStartKeyword(body)) {
      await handleSMSOptIn(from, inboundFacilityId);
      await sendComplianceResponse('You have been subscribed to SMS messages. Reply STOP to opt out.');
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    if (isHelpKeyword(body)) {
      const normalizedFrom = formatPhoneNumber(from);
      if (normalizedFrom) {
        const tenant = await findTenantByPhoneNumber(normalizedFrom, inboundFacilityId);
        if (tenant) {
          const facilityDoc = await admin.firestore()
            .collection('facilities')
            .doc(tenant.facilityId)
            .get();
          const facilityData = facilityDoc.data() as Record<string, unknown> | undefined;
          const smsSettings = facilityData?.smsSettings as Record<string, unknown> | undefined;
          const helpMessage = smsSettings?.helpMessage as string | undefined;

          const message = helpMessage ||
            'Reply STOP to opt out of SMS messages. Reply START to opt back in. For support, contact your facility directly.';

          await sendComplianceResponse(message);
        }
      }
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    const normalizedFrom = formatPhoneNumber(from);
    if (!normalizedFrom) {
      functions.logger.warn(`Invalid phone number format: ${from}`);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    const tenant = await findTenantByPhoneNumber(normalizedFrom, inboundFacilityId);

    if (!tenant) {
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

async function findTenantByPhoneNumber(
  phoneNumber: string,
  facilityIdHint?: string | null,
): Promise<{ facilityId: string; id: string; phone: string } | null> {
  try {
    const phoneVariations = [
      phoneNumber,
      phoneNumber.replace('+', ''),
      phoneNumber.replace(/^\+1/, ''),
      phoneNumber.replace(/^\+1/, '1'),
    ];

    if (facilityIdHint) {
      for (const phoneVar of phoneVariations) {
        const scopedQuery = await admin.firestore()
          .collection('facilities')
          .doc(facilityIdHint)
          .collection('tenants')
          .where('phone', '==', phoneVar)
          .where('isActive', '==', true)
          .limit(1)
          .get();
        if (!scopedQuery.empty) {
          const tenantDoc = scopedQuery.docs[0];
          const tenantData = tenantDoc.data() as Record<string, unknown>;
          return {
            facilityId: facilityIdHint,
            id: tenantDoc.id,
            phone: tenantData.phone as string,
          };
        }
      }
    }

    for (const phoneVar of phoneVariations) {
      const tenantsQuery = await admin.firestore()
        .collectionGroup('tenants')
        .where('phone', '==', phoneVar)
        .where('isActive', '==', true)
        .limit(1)
        .get();

      if (!tenantsQuery.empty) {
        const tenantDoc = tenantsQuery.docs[0];
        const tenantData = tenantDoc.data();
        const facilityId = tenantDoc.ref.parent.parent?.id;

        if (facilityId) {
          return {
            facilityId,
            id: tenantDoc.id,
            phone: tenantData.phone as string,
          };
        }
      }
    }

    return null;
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error finding tenant by phone: ${msg}`, error);
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

async function handleSMSOptOut(phoneNumber: string, facilityIdHint?: string | null): Promise<string | null> {
  try {
    const normalizedPhone = formatPhoneNumber(phoneNumber);
    if (!normalizedPhone) return null;

    const tenant = await findTenantByPhoneNumber(normalizedPhone, facilityIdHint);
    if (!tenant) return null;

    const complianceEnabled = await isSMSComplianceFeatureEnabled('enhancedOptOut', tenant.facilityId);

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

    if (complianceEnabled) {
      const facilityRef = admin.firestore().collection('facilities').doc(tenant.facilityId);
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

    functions.logger.info(`Tenant ${tenant.id} opted out of SMS`);

    return 'You have been unsubscribed from SMS messages. Reply START to opt back in.';
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error handling SMS opt-out: ${msg}`, error);
    return null;
  }
}

async function handleSMSOptIn(phoneNumber: string, facilityIdHint?: string | null): Promise<void> {
  try {
    const normalizedPhone = formatPhoneNumber(phoneNumber);
    if (!normalizedPhone) return;

    const tenant = await findTenantByPhoneNumber(normalizedPhone, facilityIdHint);
    if (!tenant) return;

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
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error handling SMS opt-in: ${msg}`, error);
  }
}
