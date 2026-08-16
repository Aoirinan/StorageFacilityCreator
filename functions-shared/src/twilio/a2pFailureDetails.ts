/**
 * Turns Twilio A2P brand/campaign failure payloads into something a facility
 * owner can act on.
 *
 * The status sync previously stored only the bare status string, so a rejected
 * campaign surfaced to the operator as "FAILED" with no reason. Twilio returns
 * the actual detail in an `errors` array (and, for brands, a deprecated
 * `failureReason`); a real rejection looks like:
 *
 *   code 30909 — "Campaign Verification: CTA/message flow could not be
 *   verified... provide the exact URL where users sign up."
 *
 * Which is the difference between an owner knowing what to fix and filing a
 * support ticket.
 */

/** One Twilio-reported problem with a brand or campaign submission. */
export interface A2PFailureDetail {
  code?: string;
  description?: string;
}

const MAX_REASON_LENGTH = 1500;

/** Pull `{ code, description }` out of Twilio's loosely-typed errors array. */
export function parseA2PErrors(errors: unknown): A2PFailureDetail[] {
  if (!Array.isArray(errors)) return [];

  const details: A2PFailureDetail[] = [];
  for (const raw of errors) {
    if (!raw || typeof raw !== 'object') continue;
    const entry = raw as Record<string, unknown>;

    // Twilio is inconsistent across resources: error_code vs code, and
    // description vs message.
    const codeValue = entry.error_code ?? entry.errorCode ?? entry.code;
    const descriptionValue = entry.description ?? entry.message ?? entry.detail;

    const code =
      codeValue === undefined || codeValue === null ? undefined : String(codeValue).trim();
    const description =
      typeof descriptionValue === 'string' && descriptionValue.trim()
        ? descriptionValue.trim()
        : undefined;

    if (code || description) {
      details.push({ ...(code ? { code } : {}), ...(description ? { description } : {}) });
    }
  }
  return details;
}

/**
 * Build the human-readable rejection reason stored on the facility.
 *
 * Prefers the structured errors, falls back to the brand's deprecated
 * `failureReason`, and only then to the bare status — so the owner always gets
 * the most specific thing Twilio gave us. Returns null when nothing indicates a
 * failure, so callers can clear the field on recovery.
 */
export function buildA2PRejectionReason(input: {
  campaignErrors?: unknown;
  brandErrors?: unknown;
  brandFailureReason?: unknown;
  campaignStatus?: string | null;
  brandStatus?: string | null;
}): string | null {
  const details = [
    ...parseA2PErrors(input.campaignErrors),
    ...parseA2PErrors(input.brandErrors),
  ];

  if (details.length > 0) {
    const rendered = details
      .map((d) => (d.code ? `Error ${d.code}: ${d.description ?? 'no description provided'}` : d.description))
      .filter(Boolean)
      .join(' | ');
    if (rendered) return truncate(rendered);
  }

  if (typeof input.brandFailureReason === 'string' && input.brandFailureReason.trim()) {
    return truncate(input.brandFailureReason.trim());
  }

  const status = (input.campaignStatus || input.brandStatus || '').trim();
  if (!status) return null;
  if (!/fail|reject|suspend/i.test(status)) return null;

  return `Twilio reported status ${status}. No further detail was provided; check the Twilio Console for the full review notes.`;
}

function truncate(value: string): string {
  return value.length <= MAX_REASON_LENGTH
    ? value
    : `${value.slice(0, MAX_REASON_LENGTH - 1)}…`;
}
