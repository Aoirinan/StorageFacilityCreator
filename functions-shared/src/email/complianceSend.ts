import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import * as functions from 'firebase-functions/v1';

import { buildFacilityFooter } from './footers';
import { getPublicAppUrl } from './urls';
import { buildEmailUnsubscribeToken } from './unsubscribe';
import { getSendgridAsmGroupId, getSgMail, initializeSendGrid } from './sendgridLazy';
import { requireSendgridMailConfigProvider } from './sendgridRegistry';

export async function isFacilityEmailSuppressed(facilityId: string, toEmail: string): Promise<boolean> {
  const toLower = String(toEmail).trim().toLowerCase();
  if (!toLower.includes('@')) return false;
  const suppressId = crypto.createHash('sha256').update(`${facilityId}|${toLower}`).digest('hex');
  const snap = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('emailSuppressions')
    .doc(suppressId)
    .get();
  return snap.exists;
}

function buildFacilityOutboundEmailPayload(
  sendGridApiKey: string,
  input: {
    facilityId: string;
    to: string;
    tenantId?: string | null;
    facilityName: string;
    facilityAddress?: string | null;
    facilityPhone?: string | null;
    htmlBody: string;
    textBody?: string | null;
  },
): { html: string; text: string; headers: Record<string, string>; asm?: { group_id: number } } {
  const toLower = String(input.to).trim().toLowerCase();
  const token = buildEmailUnsubscribeToken(
    sendGridApiKey,
    input.facilityId,
    toLower,
    String(input.tenantId ?? '').trim(),
  );
  const unsubscribeUrl = `${getPublicAppUrl()}/api/email-unsubscribe?token=${encodeURIComponent(token)}`;
  const footer = buildFacilityFooter(
    input.facilityName,
    input.facilityAddress,
    input.facilityPhone,
    { unsubscribeUrl },
  );
  const html = input.htmlBody + footer.html;
  const textBase =
    input.textBody ??
    input.htmlBody.replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').trim();
  const text = `${textBase}${footer.text}`;
  const headers: Record<string, string> = {
    'List-Unsubscribe': `<${unsubscribeUrl}>`,
    'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
  };
  const asmNum = getSendgridAsmGroupId();
  const out: { html: string; text: string; headers: Record<string, string>; asm?: { group_id: number } } = {
    html,
    text,
    headers,
  };
  if (asmNum != null) out.asm = { group_id: asmNum };
  return out;
}

/**
 * Facility → recipient email with footer, List-Unsubscribe, ASM, and suppression check.
 * Returns { sent: false } if recipient unsubscribed. Does not throw on suppression.
 */
export async function sendFacilityEmailWithCompliance(
  msg: { to: string; from: { email: string; name: string }; subject: string },
  htmlBody: string,
  textBody: string | null | undefined,
  ctx: {
    facilityId: string;
    tenantId?: string | null;
    facilityName: string;
    facilityAddress?: string | null;
    facilityPhone?: string | null;
  },
): Promise<{ sent: boolean; messageId?: string }> {
  if (await isFacilityEmailSuppressed(ctx.facilityId, msg.to)) {
    functions.logger.info('Skipping facility email (recipient unsubscribed)', {
      facilityId: ctx.facilityId,
      to: msg.to,
      subject: msg.subject,
    });
    return { sent: false };
  }
  initializeSendGrid();
  const apiKey = requireSendgridMailConfigProvider().getApiKey();
  const payload = buildFacilityOutboundEmailPayload(apiKey, {
    facilityId: ctx.facilityId,
    to: msg.to,
    tenantId: ctx.tenantId,
    facilityName: ctx.facilityName,
    facilityAddress: ctx.facilityAddress,
    facilityPhone: ctx.facilityPhone,
    htmlBody,
    textBody,
  });
  const [result] = await (getSgMail() as {
    send: (m: unknown) => Promise<Array<{ headers?: Record<string, string> }>>;
  }).send({
    ...msg,
    html: payload.html,
    text: payload.text,
    headers: payload.headers,
    ...(payload.asm ? { asm: payload.asm } : {}),
  });
  const messageId = (result.headers?.['x-message-id'] as string) || undefined;
  return { sent: true, messageId };
}
