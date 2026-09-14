import * as crypto from 'crypto';
import { escapeHtml } from '../email/footers';

/**
 * Tenant portal invites: the email that hands a tenant their access code and
 * the portal link, and the code generator that matches the operator app's
 * (same alphabet: no 0/O/1/I so codes survive being read over the phone).
 */

export const PORTAL_ACCESS_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const PORTAL_ACCESS_CODE_LENGTH = 8;

export function generatePortalAccessCode(
  length: number = PORTAL_ACCESS_CODE_LENGTH,
  randomInt: (maxExclusive: number) => number = (max) => crypto.randomInt(max),
): string {
  let out = '';
  for (let i = 0; i < length; i += 1) {
    out += PORTAL_ACCESS_CODE_ALPHABET[randomInt(PORTAL_ACCESS_CODE_ALPHABET.length)];
  }
  return out;
}

export interface PortalInviteEmailInput {
  facilityName: string;
  tenantName: string;
  unitNumber?: string | null;
  /** The tenant's email on file; they log in with it. */
  email: string;
  accessCode: string;
  portalUrl: string;
  facilityPhone?: string | null;
  /** Whether the facility can take card payments, so the autopay pitch is true. */
  autopayAvailable: boolean;
}

export interface EmailContent {
  subject: string;
  html: string;
  text: string;
}

function firstName(name: string): string {
  const trimmed = (name || '').trim();
  return trimmed ? trimmed.split(/\s+/)[0] : '';
}

export function buildTenantPortalInviteEmail(input: PortalInviteEmailInput): EmailContent {
  const facility = input.facilityName || 'your storage facility';
  const hi = firstName(input.tenantName) ? `Hi ${firstName(input.tenantName)},` : 'Hi,';
  const unit = input.unitNumber ? ` for unit ${input.unitNumber}` : '';
  const subject = `Your ${facility} tenant portal is ready`;

  const autopayText = input.autopayAvailable
    ? 'Save a card once and turn on autopay, and rent takes care of itself each month. You can turn it off any time.'
    : 'You can review your account, update your contact details, and see your payment history.';
  const phoneText = input.facilityPhone ? ` or call ${input.facilityPhone}` : '';

  const text = [
    hi,
    '',
    `${facility} set up an online portal${unit} so you can handle your storage account from your phone or computer.`,
    '',
    `Portal: ${input.portalUrl}`,
    `Email: ${input.email}`,
    `Access code: ${input.accessCode}`,
    '',
    autopayText,
    '',
    `Questions? Reply to this email${phoneText}.`,
    '',
    facility,
  ].join('\n');

  const html = `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; color:#222;">
      <p>${escapeHtml(hi)}</p>
      <p><strong>${escapeHtml(facility)}</strong> set up an online portal${escapeHtml(unit)} so you can handle your storage account from your phone or computer.</p>
      <div style="background:#f5f7fb; border-radius:8px; padding:16px 20px; margin:16px 0;">
        <p style="margin:0 0 8px;"><strong>Portal:</strong> <a href="${escapeHtml(input.portalUrl)}">${escapeHtml(input.portalUrl)}</a></p>
        <p style="margin:0 0 8px;"><strong>Email:</strong> ${escapeHtml(input.email)}</p>
        <p style="margin:0;"><strong>Access code:</strong> <span style="font-family:monospace; font-size:18px; letter-spacing:2px;">${escapeHtml(input.accessCode)}</span></p>
      </div>
      <p>${escapeHtml(autopayText)}</p>
      <p>Questions? Reply to this email${escapeHtml(phoneText)}.</p>
      <p>${escapeHtml(facility)}</p>
    </div>`;
  return { subject, html, text };
}
