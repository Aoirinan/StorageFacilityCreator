/**
 * Replies to the START and HELP keywords.
 *
 * Carriers expect both replies to name the program, and the opt-in reply
 * filed with the A2P campaign reads
 *   "{Facility}: you're opted in to account texts about your storage unit.
 *    Msg frequency varies. Msg & data rates may apply. Reply HELP for help,
 *    STOP to opt out."
 * The webhook used to answer START with an anonymous "You have been
 * subscribed", which names no one. A number that matches no tenant still gets
 * a compliant reply under the platform's own name.
 */

import type { TenantPhoneMatch } from './tenantPhoneLookup';

export const PLATFORM_SENDER_NAME = 'Storage Facility Creator';

/**
 * Which tenancies a START may opt back in.
 *
 * START only undoes the person's own STOP: an active tenancy whose record says
 * it was opted out by an inbound STOP. It must not create consent that was
 * never given, so a record with no consent history, one opted out some other
 * way (the operator, a form), or a former tenancy is left as it is. A START on
 * a facility's own line is limited to that facility.
 */
export function isStartRestorable(match: TenantPhoneMatch): boolean {
  if (match.isActive !== true) return false;
  if (String(match.smsConsentSource ?? '') !== 'inbound_stop') return false;
  return match.smsOptOut === true || String(match.smsConsentStatus ?? '').toLowerCase() === 'opted_out';
}

export function startRestorableMatches(
  matches: TenantPhoneMatch[],
  facilityIdHint?: string | null,
): TenantPhoneMatch[] {
  return matches
    .filter((m) => !facilityIdHint || m.facilityId === facilityIdHint)
    .filter(isStartRestorable);
}

/**
 * Facilities a HELP reply may name. Only active tenancies, so a HELP never
 * tells anyone where a number used to rent; on a facility's own line, only that
 * facility. Empty means the generic platform reply.
 */
export function helpFacilityIds(matches: TenantPhoneMatch[], facilityIdHint?: string | null): string[] {
  const active = matches.filter((m) => m.isActive === true);
  const scoped = facilityIdHint ? active.filter((m) => m.facilityId === facilityIdHint) : active;
  return Array.from(new Set(scoped.map((m) => m.facilityId)));
}

export interface KeywordReplyFacility {
  name?: string | null;
  phone?: string | null;
  /** smsSettings.helpMessage, the facility's own HELP wording, if set. */
  helpMessage?: string | null;
}

function clean(value: string | null | undefined): string {
  return String(value ?? '').trim();
}

/** "Keepsake Self Storage", or "A, B" when one number rents at two facilities. */
export function senderLabel(facilities: KeywordReplyFacility[]): string {
  const names = Array.from(new Set(facilities.map((f) => clean(f.name)).filter((n) => n.length > 0)));
  return names.length > 0 ? names.join(', ') : PLATFORM_SENDER_NAME;
}

export function buildStartReply(facilities: KeywordReplyFacility[]): string {
  if (facilities.length === 0) {
    return (
      `${PLATFORM_SENDER_NAME}: you're opted in to account texts. Msg frequency varies. ` +
      'Msg & data rates may apply. Reply HELP for help, STOP to opt out.'
    );
  }
  return (
    `${senderLabel(facilities)}: you're opted in to account texts about your storage unit. ` +
    'Msg frequency varies. Msg & data rates may apply. Reply HELP for help, STOP to opt out.'
  );
}

export function buildHelpReply(facilities: KeywordReplyFacility[]): string {
  const first = facilities[0];
  const custom = clean(first?.helpMessage);
  if (facilities.length === 1 && custom) {
    const label = senderLabel(facilities);
    // The facility's own wording, still under its name.
    return custom.toLowerCase().startsWith(label.toLowerCase()) ? custom : `${label}: ${custom}`;
  }
  if (facilities.length === 0) {
    return (
      `${PLATFORM_SENDER_NAME}: account texts from your storage facility. For help, contact ` +
      'your facility directly. Msg & data rates may apply. Reply STOP to opt out.'
    );
  }
  const contacts = facilities
    .map((f) => ({ name: clean(f.name), phone: clean(f.phone) }))
    .filter((f) => f.phone.length > 0);
  const uniqueContacts = Array.from(new Map(contacts.map((c) => [`${c.name}|${c.phone}`, c])).values());
  let help: string;
  if (uniqueContacts.length === 1) {
    help = `For help call ${uniqueContacts[0].phone}.`;
  } else if (uniqueContacts.length > 1) {
    help = `For help call ${uniqueContacts.map((c) => `${c.name || 'your facility'} ${c.phone}`).join(' or ')}.`;
  } else {
    help = 'For help contact your facility directly.';
  }
  return (
    `${senderLabel(facilities)}: account texts about your storage unit. ${help} ` +
    'Msg & data rates may apply. Reply STOP to opt out.'
  );
}
