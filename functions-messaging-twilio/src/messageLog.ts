import * as admin from 'firebase-admin';

/**
 * Create or update a message log in Firestore (same semantics as default functions bundle).
 */
export async function createOrUpdateMessageLog(
  facilityId: string,
  messageId: string,
  data: {
    tenantId?: string | null;
    tenantName?: string | null;
    tenantEmail?: string | null;
    tenantPhone?: string | null;
    channel: 'email' | 'sms';
    direction: 'outbound';
    source: 'manual' | 'bulk' | 'automation';
    templateId?: string | null;
    subject?: string | null;
    previewText?: string | null;
    bodyHtmlStored?: boolean;
    bodyTextStored?: boolean;
    status: 'queued' | 'sent' | 'failed';
    provider: 'sendgrid' | 'twilio';
    providerMessageId?: string | null;
    errorCode?: string | null;
    errorMessage?: string | null;
    sentAt?: admin.firestore.Timestamp | null;
    createdByUid: string;
    createdByEmail?: string | null;
  },
): Promise<void> {
  const messageLogRef = admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('messageLogs')
    .doc(messageId);

  const logData: Record<string, unknown> = {
    facilityId,
    tenantId: data.tenantId || null,
    tenantName: data.tenantName || null,
    tenantEmail: data.tenantEmail || null,
    tenantPhone: data.tenantPhone || null,
    channel: data.channel,
    direction: data.direction,
    source: data.source,
    templateId: data.templateId || null,
    subject: data.subject || null,
    previewText: data.previewText || null,
    bodyHtmlStored: data.bodyHtmlStored || false,
    bodyTextStored: data.bodyTextStored || false,
    status: data.status,
    provider: data.provider,
    providerMessageId: data.providerMessageId || null,
    errorCode: data.errorCode || null,
    errorMessage: data.errorMessage || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    sentAt: data.sentAt || null,
    createdByUid: data.createdByUid,
    createdByEmail: data.createdByEmail || null,
  };

  if (data.status === 'queued') {
    await messageLogRef.set(logData);
  } else {
    const updateData: Record<string, unknown> = {
      ...logData,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    await messageLogRef.set(updateData, { merge: true });
  }
}
