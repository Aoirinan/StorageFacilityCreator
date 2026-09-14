import { escapeHtml } from '../email/footers';

/**
 * Email copy for facility offboarding. Pure: takes plain data, returns
 * subject/html/text. The automation sweep decides who gets what and when.
 */

export interface OffboardingEmailInput {
  facilityName: string;
  ownerName?: string | null;
  /** Day the tenant data is removed and Stripe is detached. */
  offboardingDate: Date;
  /** Where the owner goes to reactivate or export. */
  appUrl: string;
  supportEmail: string;
}

export interface EmailContent {
  subject: string;
  html: string;
  text: string;
}

function formatDate(d: Date): string {
  return d.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });
}

function greeting(ownerName?: string | null): string {
  const name = (ownerName || '').trim();
  return name ? `Hi ${name},` : 'Hi,';
}

/** Sent once, after the platform subscription ends, at the start of the grace period. */
export function buildOffboardingNoticeEmail(input: OffboardingEmailInput): EmailContent {
  const when = formatDate(input.offboardingDate);
  const facility = input.facilityName || 'your facility';
  const subject = `Your Storage Facility Creator subscription for ${facility} has ended`;
  const text = [
    greeting(input.ownerName),
    '',
    `The Storage Facility Creator subscription for ${facility} has ended. Nothing has been removed yet. Here is what happens next and what you may want to do.`,
    '',
    `On ${when}:`,
    `- Tenant names, contact details, IDs and saved cards for ${facility} are removed from Storage Facility Creator.`,
    '- Storage Facility Creator disconnects from your Stripe account. Your Stripe account, your balance and your payouts are yours and keep working; only our access ends.',
    '- Unit history and payment ledgers stay, without personal details, so your records still add up.',
    '',
    `Before ${when}:`,
    `- Export anything you need (tenant list, ledgers, contracts) from ${input.appUrl}.`,
    `- To keep using Storage Facility Creator, reactivate your subscription at ${input.appUrl} and nothing will be removed.`,
    '',
    `Questions? Reply to this email or write to ${input.supportEmail}.`,
    '',
    'Storage Facility Creator',
  ].join('\n');
  const html = `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; color:#222;">
      <p>${escapeHtml(greeting(input.ownerName))}</p>
      <p>The Storage Facility Creator subscription for <strong>${escapeHtml(facility)}</strong> has ended. Nothing has been removed yet. Here is what happens next and what you may want to do.</p>
      <h3 style="margin-bottom:4px;">On ${escapeHtml(when)}</h3>
      <ul>
        <li>Tenant names, contact details, IDs and saved cards for ${escapeHtml(facility)} are removed from Storage Facility Creator.</li>
        <li>Storage Facility Creator disconnects from your Stripe account. Your Stripe account, your balance and your payouts are yours and keep working; only our access ends.</li>
        <li>Unit history and payment ledgers stay, without personal details, so your records still add up.</li>
      </ul>
      <h3 style="margin-bottom:4px;">Before ${escapeHtml(when)}</h3>
      <ul>
        <li>Export anything you need (tenant list, ledgers, contracts) from <a href="${escapeHtml(input.appUrl)}">${escapeHtml(input.appUrl)}</a>.</li>
        <li>To keep using Storage Facility Creator, <a href="${escapeHtml(input.appUrl)}">reactivate your subscription</a> and nothing will be removed.</li>
      </ul>
      <p>Questions? Reply to this email or write to <a href="mailto:${escapeHtml(input.supportEmail)}">${escapeHtml(input.supportEmail)}</a>.</p>
      <p>Storage Facility Creator</p>
    </div>`;
  return { subject, html, text };
}

/** Sent once, after the grace period, when the removal has happened. */
export function buildOffboardedEmail(input: OffboardingEmailInput): EmailContent {
  const when = formatDate(input.offboardingDate);
  const facility = input.facilityName || 'your facility';
  const subject = `${facility}: tenant data removed and Stripe disconnected`;
  const text = [
    greeting(input.ownerName),
    '',
    `As we let you know earlier, the offboarding for ${facility} completed on ${when}.`,
    '',
    '- Tenant personal details and saved cards have been removed from Storage Facility Creator.',
    '- Storage Facility Creator no longer has access to your Stripe account. Your Stripe account keeps working on its own.',
    '- Unit history and ledgers remain, without personal details.',
    '',
    `You are welcome back any time at ${input.appUrl}. A new subscription starts fresh; removed tenant details cannot be restored.`,
    '',
    `Questions? Reply to this email or write to ${input.supportEmail}.`,
    '',
    'Storage Facility Creator',
  ].join('\n');
  const html = `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; color:#222;">
      <p>${escapeHtml(greeting(input.ownerName))}</p>
      <p>As we let you know earlier, the offboarding for <strong>${escapeHtml(facility)}</strong> completed on ${escapeHtml(when)}.</p>
      <ul>
        <li>Tenant personal details and saved cards have been removed from Storage Facility Creator.</li>
        <li>Storage Facility Creator no longer has access to your Stripe account. Your Stripe account keeps working on its own.</li>
        <li>Unit history and ledgers remain, without personal details.</li>
      </ul>
      <p>You are welcome back any time at <a href="${escapeHtml(input.appUrl)}">${escapeHtml(input.appUrl)}</a>. A new subscription starts fresh; removed tenant details cannot be restored.</p>
      <p>Questions? Reply to this email or write to <a href="mailto:${escapeHtml(input.supportEmail)}">${escapeHtml(input.supportEmail)}</a>.</p>
      <p>Storage Facility Creator</p>
    </div>`;
  return { subject, html, text };
}

export interface OffboardingSweepSummary {
  runAt: Date;
  noticesSent: Array<{ facilityId: string; facilityName: string; offboardingDate: Date }>;
  offboarded: Array<{ facilityId: string; facilityName: string; tenantsRedacted: number; stripe: string }>;
  orphansDetached: Array<{ accountId: string; facilityId: string }>;
  waiting: number;
  errors: Array<{ where: string; message: string }>;
}

/** Whether the nightly summary is worth sending at all. */
export function sweepSummaryHasActivity(s: OffboardingSweepSummary): boolean {
  return s.noticesSent.length > 0 || s.offboarded.length > 0 || s.orphansDetached.length > 0 || s.errors.length > 0;
}

function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

/** One email to the super admins, only on nights something happened. */
export function buildOffboardingAdminSummaryEmail(s: OffboardingSweepSummary): EmailContent {
  const parts: string[] = [];
  if (s.offboarded.length) parts.push(`${s.offboarded.length} offboarded`);
  if (s.noticesSent.length) parts.push(`${plural(s.noticesSent.length, 'notice')} sent`);
  if (s.orphansDetached.length) parts.push(`${plural(s.orphansDetached.length, 'orphan')} detached`);
  if (s.errors.length) parts.push(plural(s.errors.length, 'error'));
  const subject = `[SFC] Facility offboarding: ${parts.join(', ') || 'no activity'}`;

  const lines: string[] = [`Facility offboarding sweep, ${formatDate(s.runAt)} (UTC)`, ''];
  const htmlSections: string[] = [];

  if (s.noticesSent.length) {
    lines.push('Cancellation notices sent (grace period started):');
    for (const n of s.noticesSent) lines.push(`- ${n.facilityName} (${n.facilityId}), removal on ${formatDate(n.offboardingDate)}`);
    lines.push('');
    htmlSections.push(
      `<h3>Cancellation notices sent</h3><ul>${s.noticesSent
        .map((n) => `<li>${escapeHtml(n.facilityName)} (${escapeHtml(n.facilityId)}), removal on ${escapeHtml(formatDate(n.offboardingDate))}</li>`)
        .join('')}</ul>`,
    );
  }
  if (s.offboarded.length) {
    lines.push('Offboarded (Stripe detached, tenant PII removed):');
    for (const o of s.offboarded) lines.push(`- ${o.facilityName} (${o.facilityId}): ${o.tenantsRedacted} tenants redacted, Stripe ${o.stripe}`);
    lines.push('');
    htmlSections.push(
      `<h3>Offboarded</h3><ul>${s.offboarded
        .map((o) => `<li>${escapeHtml(o.facilityName)} (${escapeHtml(o.facilityId)}): ${o.tenantsRedacted} tenants redacted, Stripe ${escapeHtml(o.stripe)}</li>`)
        .join('')}</ul>`,
    );
  }
  if (s.orphansDetached.length) {
    lines.push('Orphaned Stripe accounts detached (facility already deleted):');
    for (const o of s.orphansDetached) lines.push(`- ${o.accountId} (was facility ${o.facilityId})`);
    lines.push('');
    htmlSections.push(
      `<h3>Orphaned Stripe accounts detached</h3><ul>${s.orphansDetached
        .map((o) => `<li>${escapeHtml(o.accountId)} (was facility ${escapeHtml(o.facilityId)})</li>`)
        .join('')}</ul>`,
    );
  }
  if (s.errors.length) {
    lines.push('Errors:');
    for (const e of s.errors) lines.push(`- ${e.where}: ${e.message}`);
    lines.push('');
    htmlSections.push(
      `<h3 style="color:#b00020;">Errors</h3><ul>${s.errors
        .map((e) => `<li>${escapeHtml(e.where)}: ${escapeHtml(e.message)}</li>`)
        .join('')}</ul>`,
    );
  }
  lines.push(`Still in grace period: ${s.waiting}`);
  lines.push('', 'Nothing to do unless an error is listed. This mail is sent only on nights with activity.');

  const html = `
    <div style="font-family: Arial, sans-serif; max-width: 640px; margin: 0 auto; color:#222;">
      <p><strong>Facility offboarding sweep</strong>, ${escapeHtml(formatDate(s.runAt))} (UTC)</p>
      ${htmlSections.join('')}
      <p>Still in grace period: ${s.waiting}</p>
      <p style="color:#666;font-size:12px;">Nothing to do unless an error is listed. This mail is sent only on nights with activity.</p>
    </div>`;
  return { subject, html, text: lines.join('\n') };
}
