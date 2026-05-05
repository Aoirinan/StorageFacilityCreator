import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import { SENDGRID_API_KEY, SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME } from './secrets';

let sgMailCached: unknown = null;
function getSgMail(): { setApiKey: (k: string) => void; send: (msg: unknown) => Promise<unknown[]> } {
  if (!sgMailCached) {
    const sgMailModule = require('@sendgrid/mail') as typeof import('@sendgrid/mail');
    sgMailCached = (sgMailModule as { default?: typeof sgMailModule }).default ?? sgMailModule;
  }
  return sgMailCached as { setApiKey: (k: string) => void; send: (msg: unknown) => Promise<unknown[]> };
}

function getPublicAppUrl(): string {
  const v = process.env.PUBLIC_APP_URL?.trim();
  const base = v && v.length > 0 ? v : 'https://app.storagefacilitycreator.com';
  return base.replace(/\/$/, '');
}

function getSendgridAsmGroupId(): number | null {
  const v = process.env.SENDGRID_ASM_GROUP_ID?.trim();
  if (!v) return null;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : null;
}

let sendGridInitialized = false;

function initializeSendGrid(): void {
  if (!sendGridInitialized) {
    functions.logger.info('[initializeSendGrid] Starting SendGrid initialization');

    const apiKey = SENDGRID_API_KEY.value();

    functions.logger.info('[initializeSendGrid] API key retrieved from secret', {
      keyExists: !!apiKey,
    });

    if (!apiKey) {
      functions.logger.error('[initializeSendGrid] SENDGRID_API_KEY is null or empty');
      throw new Error('SENDGRID_API_KEY environment variable is not set');
    }

    const fromEmail = SENDGRID_FROM_EMAIL.value();

    functions.logger.info('[initializeSendGrid] From email retrieved', {
      emailExists: !!fromEmail,
      email: fromEmail || 'N/A',
    });

    if (!fromEmail) {
      functions.logger.error('[initializeSendGrid] SENDGRID_FROM_EMAIL is null or empty');
      throw new Error('SENDGRID_SENDER_EMAIL environment variable is not set');
    }

    functions.logger.info('[initializeSendGrid] Setting API key on sgMail client');

    getSgMail().setApiKey(apiKey);
    sendGridInitialized = true;

    functions.logger.info('[initializeSendGrid] SendGrid initialization complete', {
      sendGridInitialized,
      fromEmail,
    });
  } else {
    functions.logger.info('[initializeSendGrid] SendGrid already initialized, skipping');
  }
}

function getEmailUnsubscribeSecretKey(sendGridApiKey: string): string {
  return crypto.createHash('sha256').update(`sfc-email-unsub-v1|${sendGridApiKey}`).digest('hex');
}

function buildEmailUnsubscribeToken(
  sendGridApiKey: string,
  facilityId: string,
  emailLower: string,
  tenantId: string,
): string {
  const exp = Math.floor(Date.now() / 1000) + 365 * 24 * 3600;
  const payload = `${facilityId}|${emailLower}|${tenantId}|${exp}`;
  const key = getEmailUnsubscribeSecretKey(sendGridApiKey);
  const sig = crypto.createHmac('sha256', key).update(payload).digest('hex');
  return Buffer.from(`${payload}|${sig}`).toString('base64url');
}

function escapeHtml(text: string): string {
  const map: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    '\'': '&#039;',
  };
  return text.replace(/[&<>"']/g, (m) => map[m]);
}

function buildFacilityFooter(
  facilityName: string,
  facilityAddress?: string | null,
  facilityPhone?: string | null,
  compliance?: { unsubscribeUrl?: string } | null,
): { html: string; text: string } {
  const lines: string[] = [];
  if (facilityAddress) lines.push(facilityAddress);
  if (facilityPhone) lines.push(facilityPhone);

  let htmlFooter = '<hr style="margin:16px 0;border:none;border-top:1px solid #e0e0e0;"/>';
  htmlFooter += '<div style="font-size:14px;line-height:1.4;color:#666;margin-top:16px;">';
  htmlFooter += `<strong>${escapeHtml(facilityName)}</strong>`;
  if (lines.length > 0) {
    htmlFooter += '<br/>';
    htmlFooter += lines.map((line) => escapeHtml(line)).join('<br/>');
  }
  htmlFooter += '</div>';

  if (compliance?.unsubscribeUrl) {
    const u = compliance.unsubscribeUrl;
    htmlFooter += '<p style="font-size:12px;color:#888;margin-top:14px;line-height:1.5;">';
    htmlFooter +=
      'You are receiving this email in connection with your business relationship with this facility. ';
    htmlFooter += `<a href="${escapeHtml(u)}" style="color:#555;text-decoration:underline;">Unsubscribe</a> `;
    htmlFooter +=
      'from non-essential facility emails. Time-sensitive or legally required notices may still be sent.</p>';
  }

  let textFooter = '\n--\n';
  textFooter += facilityName;
  if (lines.length > 0) {
    textFooter += `\n${lines.join('\n')}`;
  }
  if (compliance?.unsubscribeUrl) {
    textFooter +=
      '\n\nUnsubscribe from non-essential facility emails: ' +
      compliance.unsubscribeUrl +
      '\n(Time-sensitive or legally required notices may still be sent.)';
  }

  return { html: htmlFooter, text: textFooter };
}

async function isFacilityEmailSuppressed(facilityId: string, toEmail: string): Promise<boolean> {
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
  const apiKey = SENDGRID_API_KEY.value();
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
  const [result] = (await getSgMail().send({
    ...msg,
    html: payload.html,
    text: payload.text,
    headers: payload.headers,
    ...(payload.asm ? { asm: payload.asm } : {}),
  })) as [{ headers?: Record<string, string | string[] | undefined> }];
  const rawId = result.headers?.['x-message-id'];
  const messageId = Array.isArray(rawId) ? rawId[0] : rawId;
  return { sent: true, messageId: typeof messageId === 'string' ? messageId : undefined };
}
