/**
 * Planning logic for connecting a facility's own domain to its website.
 *
 * Kept pure and separate from the Hosting API calls so the parts that decide
 * *what* to ask the operator for can be tested without touching Firebase. The
 * operator is a storage-facility owner editing DNS at their registrar, usually
 * for the first time — a wrong or duplicated row here costs them a support
 * conversation and a day of downtime.
 */

export interface DomainRecord {
  type: string;
  name: string;
  value: string;
  requiredAction?: string;
}

/** A hostname pair: the domain the operator typed, plus its www counterpart. */
export interface DomainPair {
  apex: string;
  www: string | null;
}

/** Strip scheme, path, port, trailing dots and case. */
export function normalizeDomainInput(raw: unknown): string {
  let value = typeof raw === 'string' ? raw.trim().toLowerCase() : '';
  if (!value) return '';
  value = value.replace(/^[a-z][a-z0-9+.-]*:\/\//, '');
  value = value.split('/')[0];
  value = value.split('?')[0];
  value = value.split('#')[0];
  value = value.split(':')[0];
  value = value.replace(/\.+$/, '');
  return value.trim();
}

/** A registrable hostname: at least two labels, valid characters, no wildcard. */
export function isValidDomain(value: string): boolean {
  if (!value || value.length > 253) return false;
  if (value.includes('*') || value.includes('_')) return false;
  const labels = value.split('.');
  if (labels.length < 2) return false;
  return labels.every(
    (label) =>
      label.length > 0 &&
      label.length <= 63 &&
      /^[a-z0-9-]+$/.test(label) &&
      !label.startsWith('-') &&
      !label.endsWith('-'),
  );
}

/**
 * Work out which hostnames to register for what the operator typed.
 *
 * Visitors type both "example.com" and "www.example.com", and a site that only
 * answers one of them looks broken to half its customers — so both are
 * registered whenever the input is an apex domain.
 *
 * A deeper hostname such as "rent.example.com" is left alone: prepending www to
 * it would produce "www.rent.example.com", which nobody will ever type, and
 * every extra hostname consumes part of the 20-subdomains-per-apex certificate
 * limit.
 */
export function planDomainPair(input: unknown): DomainPair | null {
  const normalized = normalizeDomainInput(input);
  if (!isValidDomain(normalized)) return null;

  // Treat a leading "www." as the operator naming their apex.
  const apex = normalized.startsWith('www.') ? normalized.slice(4) : normalized;
  if (!isValidDomain(apex)) return null;

  // Only apex domains get a www counterpart. Two labels is the common case
  // (example.com); anything deeper is already a subdomain.
  const isApex = apex.split('.').length === 2;
  return { apex, www: isApex ? `www.${apex}` : null };
}

/**
 * Merge the DNS rows for several hostnames into one list for the operator.
 *
 * Registering apex and www separately returns overlapping instructions — both
 * reference the same apex A record — and showing the same row twice invites
 * someone to create a duplicate record. Deduplicates on the full tuple and
 * keeps a stable order so the list does not reshuffle between status checks.
 */
export function mergeDomainRecords(groups: readonly DomainRecord[][]): DomainRecord[] {
  const seen = new Set<string>();
  const merged: DomainRecord[] = [];
  for (const group of groups) {
    for (const record of group) {
      if (!record?.type || !record?.name || !record?.value) continue;
      const key = `${record.type}|${record.name}|${record.value}`.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      merged.push(record);
    }
  }
  // ADD rows first: those are the ones the operator still has to act on.
  return merged.sort((a, b) => {
    const aAdd = a.requiredAction === 'ADD' ? 0 : 1;
    const bAdd = b.requiredAction === 'ADD' ? 0 : 1;
    if (aAdd !== bAdd) return aAdd - bAdd;
    return `${a.type}${a.name}`.localeCompare(`${b.type}${b.name}`);
  });
}

/** Per-hostname status as reported back to the operator. */
export interface HostnameStatus {
  hostname: string;
  status: string;
  certState?: string | null;
  ownershipState?: string | null;
  hostState?: string | null;
}

/**
 * Reduce several hostname statuses to the one the operator should be shown.
 *
 * Reports the *worst* state rather than the best: telling someone their domain
 * is live while www still serves a certificate error is how you get a support
 * ticket that says "you told me it was done".
 */
export function combineHostnameStatuses(statuses: readonly HostnameStatus[]): string {
  if (statuses.length === 0) return 'unknown';
  const rank: Record<string, number> = {
    unknown: 0,
    connected: 1,
    provisioning_ssl: 2,
    pending_dns: 3,
    certificate_issue: 4,
  };
  let worst = 'connected';
  let worstRank = rank.connected;
  let sawKnown = false;

  for (const entry of statuses) {
    const status = String(entry?.status || 'unknown');
    const value = rank[status];
    if (value === undefined) {
      // An unrecognised status is not something to report as connected.
      return status;
    }
    if (status !== 'unknown') sawKnown = true;
    if (value > worstRank) {
      worstRank = value;
      worst = status;
    }
  }
  return sawKnown ? worst : 'unknown';
}

/** True once every hostname is actually serving. */
export function isDomainLive(statuses: readonly HostnameStatus[]): boolean {
  return statuses.length > 0 && statuses.every((s) => s.status === 'connected');
}
