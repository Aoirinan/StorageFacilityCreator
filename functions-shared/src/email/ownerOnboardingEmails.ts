import { escapeHtml } from './footers';

/**
 * Email copy for facility-owner onboarding. Pure: takes plain data, returns
 * subject/html/text. The trigger decides who gets what and when.
 *
 * These are platform-to-owner transactional messages, not facility-to-tenant
 * mail, so they carry no facility footer, no unsubscribe group and no
 * suppression check. An owner who unsubscribes from one site's tenant mail
 * must still be told that their own account was approved.
 */

export interface EmailContent {
  subject: string;
  html: string;
  text: string;
}

export interface OwnerOnboardingEmailInput {
  ownerName?: string | null;
  /** Where the owner signs in. */
  appUrl: string;
  supportEmail: string;
  supportPhone: string;
}

export interface AccountApprovedEmailInput extends OwnerOnboardingEmailInput {
  /** Last day of the trial granted at approval. */
  trialEndDate: Date;
  /** Platform price per facility per month, in whole dollars. */
  priceMonthly: number;
  /** Optional public-website rentals add-on, per facility per month. */
  onlineRentalsAddonMonthly: number;
}

export interface NewAccountAdminAlertInput {
  ownerName?: string | null;
  ownerEmail: string;
  accountId: string;
  signedUpAt: Date;
  /** Platform Control, where the account is approved or rejected. */
  superAdminUrl: string;
}

function formatDate(d: Date): string {
  return d.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });
}

function formatDateTime(d: Date): string {
  return d.toLocaleString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'UTC',
    timeZoneName: 'short',
  });
}

/** First name only, so the greeting reads like a person wrote it. */
function greeting(ownerName?: string | null): string {
  const first = (ownerName || '').trim().split(/\s+/)[0] || '';
  return first ? `Hi ${first},` : 'Hi,';
}

function signatureText(input: OwnerOnboardingEmailInput): string[] {
  return ['Storage Facility Creator', input.supportEmail, input.supportPhone];
}

function signatureHtml(input: OwnerOnboardingEmailInput): string {
  return `
      <p style="margin-top:24px;color:#555;">
        Storage Facility Creator<br />
        <a href="mailto:${escapeHtml(input.supportEmail)}">${escapeHtml(input.supportEmail)}</a><br />
        ${escapeHtml(input.supportPhone)}
      </p>`;
}

function wrap(body: string): string {
  return `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; color:#222;">${body}
    </div>`;
}

/**
 * Sent the moment the account document is created, while it waits for a
 * super admin. The pending-approval screen in the app promises this message,
 * so it has to exist.
 */
export function buildAccountUnderReviewEmail(input: OwnerOnboardingEmailInput): EmailContent {
  const subject = 'We got your Storage Facility Creator signup';
  const text = [
    greeting(input.ownerName),
    '',
    'Thanks for signing up for Storage Facility Creator. Your account is created and under review, which usually takes less than one business day.',
    '',
    'You will get an email from us the moment it is approved, with everything you need to set up your first facility.',
    '',
    'If you want to tell us about your facility in the meantime, reply to this message. It reaches a person.',
    '',
    ...signatureText(input),
  ].join('\n');
  const html = wrap(`
      <p>${escapeHtml(greeting(input.ownerName))}</p>
      <p>Thanks for signing up for Storage Facility Creator. Your account is created and under review, which usually takes less than one business day.</p>
      <p>You will get an email from us the moment it is approved, with everything you need to set up your first facility.</p>
      <p>If you want to tell us about your facility in the meantime, reply to this message. It reaches a person.</p>${signatureHtml(input)}`);
  return { subject, html, text };
}

/**
 * Sent when a super admin approves the account and the trial starts. This is
 * the one that has to carry everything an owner needs to get running, because
 * it replaces someone writing the same email by hand every time.
 */
export function buildAccountApprovedEmail(input: AccountApprovedEmailInput): EmailContent {
  const when = formatDate(input.trialEndDate);
  const subject = 'Your account is approved, here is how to get set up';
  const price = `$${input.priceMonthly}`;
  const addon = `$${input.onlineRentalsAddonMonthly}`;
  const text = [
    greeting(input.ownerName),
    '',
    `Your Storage Facility Creator account is approved and your trial is active through ${when}. You do not need to enter a card to start.`,
    '',
    `Sign in here: ${input.appUrl}`,
    '',
    'Three steps to get running:',
    '',
    '1. Create your facility. You will need the name, address, time zone, how many days of grace you give before a late fee, and what that late fee is.',
    '',
    '2. Add your units. Add them one at a time, or turn on "Create multiple units" and type a range like 101-160 to build a whole row at once. Do one pass per size and rate, so all the 10x10s go in together.',
    '',
    '3. Bring your tenants over. On the clients page choose Import CSV. It takes name, email, phone, unit number, monthly rate, and notes. Any unit number it does not already find, it creates for you. Outstanding balances are entered after the import rather than imported.',
    '',
    `After the trial it is ${price} per facility per month, with unlimited users and all core features included, and your first month is free. Renting units online from your own public page is an optional ${addon} per month.`,
    '',
    'Reply to this email with any question at all. It reaches a person.',
    '',
    ...signatureText(input),
  ].join('\n');
  const html = wrap(`
      <p>${escapeHtml(greeting(input.ownerName))}</p>
      <p>Your Storage Facility Creator account is approved and your trial is active through <strong>${escapeHtml(when)}</strong>. You do not need to enter a card to start.</p>
      <p><a href="${escapeHtml(input.appUrl)}" style="display:inline-block;padding:10px 18px;background:#1a56db;color:#fff;text-decoration:none;border-radius:6px;">Sign in to your account</a></p>
      <h3 style="margin-bottom:4px;">Three steps to get running</h3>
      <ol>
        <li style="margin-bottom:10px;"><strong>Create your facility.</strong> You will need the name, address, time zone, how many days of grace you give before a late fee, and what that late fee is.</li>
        <li style="margin-bottom:10px;"><strong>Add your units.</strong> Add them one at a time, or turn on &quot;Create multiple units&quot; and type a range like 101-160 to build a whole row at once. Do one pass per size and rate, so all the 10x10s go in together.</li>
        <li style="margin-bottom:10px;"><strong>Bring your tenants over.</strong> On the clients page choose Import CSV. It takes name, email, phone, unit number, monthly rate, and notes. Any unit number it does not already find, it creates for you. Outstanding balances are entered after the import rather than imported.</li>
      </ol>
      <p>After the trial it is ${escapeHtml(price)} per facility per month, with unlimited users and all core features included, and your first month is free. Renting units online from your own public page is an optional ${escapeHtml(addon)} per month.</p>
      <p>Reply to this email with any question at all. It reaches a person.</p>${signatureHtml(input)}`);
  return { subject, html, text };
}

/**
 * Sent to the super admins when an account appears, so nobody waits in the
 * queue unnoticed. Not gated: this is internal mail, not customer contact.
 */
export function buildNewAccountAdminAlertEmail(input: NewAccountAdminAlertInput): EmailContent {
  const who = (input.ownerName || '').trim() || input.ownerEmail;
  const when = formatDateTime(input.signedUpAt);
  const subject = `New account pending approval: ${input.ownerEmail}`;
  const text = [
    `${who} signed up at ${when}.`,
    '',
    `Email: ${input.ownerEmail}`,
    `Account: ${input.accountId}`,
    '',
    'Approve or reject in Platform Control, Accounts tab:',
    input.superAdminUrl,
  ].join('\n');
  const html = wrap(`
      <p><strong>${escapeHtml(who)}</strong> signed up at ${escapeHtml(when)}.</p>
      <p>Email: <a href="mailto:${escapeHtml(input.ownerEmail)}">${escapeHtml(input.ownerEmail)}</a><br />
         Account: ${escapeHtml(input.accountId)}</p>
      <p>Approve or reject in Platform Control, Accounts tab:<br />
         <a href="${escapeHtml(input.superAdminUrl)}">${escapeHtml(input.superAdminUrl)}</a></p>`);
  return { subject, html, text };
}
