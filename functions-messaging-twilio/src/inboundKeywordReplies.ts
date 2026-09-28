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

export const PLATFORM_SENDER_NAME = 'Storage Facility Creator';

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
