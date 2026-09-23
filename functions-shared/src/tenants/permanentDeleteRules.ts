/**
 * Permanent tenant delete: who may be deleted, and who may delete.
 *
 * Permanent delete is only for tenants entered by mistake. Deleting a tenant
 * with billing or legal history orphaned their ledger (the balance fell out
 * of AR and the history could no longer be opened), and deleting an occupant
 * freed their unit and listed it as rentable. The deleteTenantsPermanently
 * callable enforces these rules with admin reads inside its transaction, so
 * an old browser tab or a direct API call cannot get round them.
 *
 * PARITY: every rule here mirrors TenantService in
 * lib/services/tenant_service.dart (isLiveLedgerRow, isLiveInvoiceRow,
 * isLivePaymentRow, isLiveCardPaymentRow, hasAutopaySubscription,
 * isActiveFlagSet, scanLiveRows, permanentDeleteBlockers, unitsHeldByTenant,
 * loadDeletePlan and _assertFacilityAllowsPermanentTenantDeletion). The app
 * runs its copy as a fast pre-check and shows these reason strings to owners
 * verbatim, so they must match word for word. Both test suites run the cases
 * in src/test/fixtures/tenantDeleteParity.json: change a rule on one side,
 * change the other and add a case there.
 */

export type DocData = Record<string, unknown>;

/** Rows read per source when checking a tenant for history. */
export const TENANT_DELETE_SCAN_LIMIT = 10;

function statusOf(row: DocData): string {
  const status = row.status;
  return status === null || status === undefined ? '' : String(status).trim().toLowerCase();
}

/** Posted or pending. A voided entry was reversed and leaves nothing behind. */
export function isLiveLedgerRow(row: DocData): boolean {
  return statusOf(row) !== 'voided';
}

/** Draft, sent, paid and overdue invoices are all history; only voided is not. */
export function isLiveInvoiceRow(row: DocData): boolean {
  return statusOf(row) !== 'voided';
}

/** Payment statuses that never moved money ('canceled' is Stripe's spelling). */
const DEAD_PAYMENT_STATUSES = new Set(['failed', 'cancelled', 'canceled']);

/**
 * Failed and cancelled payments never moved money, and archived ones were
 * removed on purpose. Everything else, including statuses not known here, is
 * real history.
 */
export function isLivePaymentRow(row: DocData): boolean {
  return row.isActive !== false && !DEAD_PAYMENT_STATUSES.has(statusOf(row));
}

/**
 * A row of tenants/{id}/payments. The card-payment callables write it as
 * 'processing' before Stripe charges and only the webhook writes the ledger,
 * so deleting in between left the webhook recording money for nobody.
 */
export function isLiveCardPaymentRow(row: DocData): boolean {
  return !DEAD_PAYMENT_STATUSES.has(statusOf(row));
}

/** billing/default holds the tenant's Stripe autopay subscription while armed. */
export function hasAutopaySubscription(billing: DocData | null | undefined): boolean {
  const id = billing?.stripeSubscriptionId;
  return typeof id === 'string' && id.trim().length > 0;
}

/** Saved cards and gate codes count as on unless switched off. */
export function isActiveFlagSet(data: DocData | null | undefined): boolean {
  return data?.isActive !== false;
}

/**
 * How many rows of a capped scan are live. A row that can't be read counts
 * as live. A full page with none live is inconclusive: rows past the cap may
 * be live, so deleting on a guess could orphan them.
 */
export function scanLiveRows<T>(
  rows: Iterable<T>,
  isLive: (row: T) => boolean,
  scanLimit: number,
): { live: number; inconclusive: boolean } {
  let total = 0;
  let live = 0;
  for (const row of rows) {
    total++;
    let rowIsLive: boolean;
    try {
      rowIsLive = isLive(row);
    } catch {
      rowIsLive = true;
    }
    if (rowIsLive) live++;
  }
  return { live, inconclusive: live === 0 && total >= scanLimit };
}

export type TenantHistoryCounts = {
  liveLedgerEntries?: number;
  liveInvoices?: number;
  livePayments?: number;
  liveCardPayments?: number;
  contracts?: number;
  liens?: number;
  activeSavedCards?: number;
  hasAutopaySubscription?: boolean;
  moreThanChecked?: boolean;
};

/**
 * History that rules out a permanent delete; empty means none. Gated on
 * history, not balance: a tenant charged $150 who paid $150 owes nothing but
 * is still a real customer.
 */
export function permanentDeleteBlockers(counts: TenantHistoryCounts = {}): string[] {
  const n = (v: number | undefined) => v ?? 0;
  const counted = (count: number, one: string, many: string) => (count === 1 ? one : many);
  const reasons: string[] = [];
  if (n(counts.liveLedgerEntries) > 0) reasons.push('charges or payments on the ledger');
  if (n(counts.liveInvoices) > 0) reasons.push(counted(n(counts.liveInvoices), 'an invoice', 'invoices'));
  if (n(counts.livePayments) > 0) {
    reasons.push(counted(n(counts.livePayments), 'a payment record', 'payment records'));
  }
  if (n(counts.liveCardPayments) > 0) reasons.push('a card payment in progress or payment history');
  if (n(counts.contracts) > 0) reasons.push(counted(n(counts.contracts), 'a contract', 'contracts'));
  if (n(counts.liens) > 0) reasons.push(counted(n(counts.liens), 'a lien', 'liens'));
  if (n(counts.activeSavedCards) > 0) {
    reasons.push(counted(n(counts.activeSavedCards), 'a saved card', 'saved cards'));
  }
  if (counts.hasAutopaySubscription === true) reasons.push('an autopay subscription');
  // Its own reason, and only when nothing else blocks: a full page of voided
  // rows is not "charges on the ledger".
  if (reasons.length === 0 && counts.moreThanChecked === true) {
    reasons.push('more records than could be checked here');
  }
  return reasons;
}

/** UnitStatus names in lib/models/unit_model.dart. */
export const UNIT_STATUSES = [
  'available',
  'occupied',
  'reserved',
  'maintenance',
  'outOfOrder',
  'overlocked',
  'lockout',
  'auction',
] as const;
export type UnitStatus = (typeof UNIT_STATUSES)[number];

/** A unit's status as UnitModel.fromFirestore reads it: unknown reads as available. */
export function unitStatusOf(unit: DocData): UnitStatus {
  const status = unit.status;
  return (UNIT_STATUSES as readonly unknown[]).includes(status) ? (status as UnitStatus) : 'available';
}

export type LinkedDoc = { id: string; data: DocData };
export type HeldUnit = { unitNumber: string; status: UnitStatus };

/** Units the tenant list skips (TenantService's linkedUnits drops them too). */
export function isArchivedUnit(unit: DocData): boolean {
  return unit.archived === true;
}

/**
 * Units that still show [tenantId] as their occupant. A unit marked available
 * with a stale link is not held: it has no Unassign button, so counting it
 * would leave the owner stuck.
 */
export function unitsHeldByTenant(tenantId: string, units: DocData[]): HeldUnit[] {
  const held: HeldUnit[] = [];
  for (const unit of units) {
    const status = unitStatusOf(unit);
    if (unit.tenantId === tenantId && status !== 'available') {
      held.push({ unitNumber: String(unit.unitNumber ?? ''), status });
    }
  }
  return held;
}

export function tenantDisplayName(tenant: DocData | null | undefined, tenantId: string): string {
  const name = typeof tenant?.name === 'string' ? tenant.name.trim() : '';
  return name.length === 0 ? tenantId : name;
}

/** What the check read for one tenant, each source capped at the scan limit. */
export type TenantDeleteRecords = {
  tenant: DocData | null;
  ledgers: DocData[];
  invoices: DocData[];
  payments: DocData[];
  contracts: DocData[];
  liens: DocData[];
  /** tenants/{id}/paymentMethods */
  paymentMethods: DocData[];
  /** tenants/{id}/payments */
  tenantPayments: DocData[];
  /** tenants/{id}/billing/default */
  billing: DocData | null;
  /** Every unit whose tenantId is the tenant, archived or not. */
  units: LinkedDoc[];
  /** Every gateAccess row whose tenantId is the tenant. */
  gateAccess: LinkedDoc[];
};

export type TenantDeletePlan = {
  tenantId: string;
  tenantName: string;
  before: DocData | null;
  /** Billing or legal history that rules the delete out. */
  reasons: string[];
  /** Units the tenant still occupies; any one rules the delete out too. */
  heldUnits: HeldUnit[];
  /** Non-archived units linked to the tenant; the delete unlinks them. */
  unitIds: string[];
  activeGateAccessIds: string[];
};

/** TenantService.loadDeletePlan, over records already read. */
export function buildTenantDeletePlan(
  tenantId: string,
  records: TenantDeleteRecords,
  scanLimit: number = TENANT_DELETE_SCAN_LIMIT,
): TenantDeletePlan {
  let moreThanChecked = false;
  const live = (rows: DocData[], isLive: (row: DocData) => boolean): number => {
    const scan = scanLiveRows(rows, isLive, scanLimit);
    moreThanChecked = moreThanChecked || scan.inconclusive;
    return scan.live;
  };
  // Any contract or lien counts, active or not: an ended contract or a
  // released lien is still a legal record.
  const anyRow = () => true;

  const liveLedgerEntries = live(records.ledgers, isLiveLedgerRow);
  const liveInvoices = live(records.invoices, isLiveInvoiceRow);
  const livePayments = live(records.payments, isLivePaymentRow);
  const contracts = live(records.contracts, anyRow);
  const liens = live(records.liens, anyRow);
  const activeSavedCards = live(records.paymentMethods, isActiveFlagSet);
  const liveCardPayments = live(records.tenantPayments, isLiveCardPaymentRow);
  const reasons = permanentDeleteBlockers({
    liveLedgerEntries,
    liveInvoices,
    livePayments,
    liveCardPayments,
    contracts,
    liens,
    activeSavedCards,
    hasAutopaySubscription: hasAutopaySubscription(records.billing),
    moreThanChecked,
  });

  const units = records.units.filter((u) => !isArchivedUnit(u.data));
  return {
    tenantId,
    tenantName: tenantDisplayName(records.tenant, tenantId),
    before: records.tenant,
    reasons,
    heldUnits: unitsHeldByTenant(
      tenantId,
      units.map((u) => u.data),
    ),
    unitIds: units.map((u) => u.id),
    activeGateAccessIds: records.gateAccess.filter((g) => isActiveFlagSet(g.data)).map((g) => g.id),
  };
}

export function isTenantDeleteBlocked(plan: TenantDeletePlan): boolean {
  return plan.reasons.length > 0 || plan.heldUnits.length > 0;
}

/** What the client needs to explain a refusal (TenantDeleteBlock in Dart). */
export type TenantDeleteBlock = {
  tenantId: string;
  tenantName: string;
  reasons: string[];
  heldUnits: HeldUnit[];
};

export function toTenantDeleteBlock(plan: TenantDeletePlan): TenantDeleteBlock {
  return {
    tenantId: plan.tenantId,
    tenantName: plan.tenantName,
    reasons: plan.reasons,
    heldUnits: plan.heldUnits,
  };
}

// --- Who may delete ------------------------------------------------------

export const PERMANENT_TENANT_DELETE_NOT_ENTITLED_MESSAGE =
  'Permanent tenant deletion requires an active paid subscription or an active trial. ' +
  'Use archive to remove a tenant from day-to-day operations, or subscribe / start a trial to delete.';

/** Epoch ms of a Firestore Timestamp, Date or number; null for anything else. */
export function timestampMillis(value: unknown): number | null {
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (value && typeof (value as { toMillis?: unknown }).toMillis === 'function') {
    return (value as { toMillis: () => number }).toMillis();
  }
  return null;
}

/** FacilityModel.hasActivePlatformSubscription. */
function facilityHasActivePlatformSubscription(facility: DocData, nowMs: number): boolean {
  const status = facility.platformSubscriptionStatus;
  if (status === 'active') return true;
  const trialEnd = timestampMillis(facility.platformSubscriptionTrialEnd);
  return status === 'trialing' && trialEnd !== null && trialEnd > nowMs;
}

/** FacilityCreatorAccountModel.allowsPermanentTenantDeletion. */
function accountAllowsPermanentTenantDelete(account: DocData, nowMs: number): boolean {
  if (account.suspended === true) return false;
  // A missing or unknown status parses as pendingApproval in the app.
  const status = account.subscriptionStatus;
  if (status === 'active') return true;
  if (status !== 'trialing') return false;
  const trialEnd = timestampMillis(account.subscriptionTrialEnd);
  return trialEnd === null || nowMs <= trialEnd;
}

/**
 * _assertFacilityAllowsPermanentTenantDeletion, less its super admin bypass
 * (the caller decides that): a paid or trialing platform subscription on the
 * facility, or on its creator account. [account] is the doc named by the
 * facility's facilityCreatorAccountId, or null.
 */
export function facilityAllowsPermanentTenantDelete(
  facility: DocData,
  account: DocData | null,
  nowMs: number,
): boolean {
  if (facilityHasActivePlatformSubscription(facility, nowMs)) return true;
  return account !== null && accountAllowsPermanentTenantDelete(account, nowMs);
}

/** The creator account a facility bills through, or null. */
export function facilityCreatorAccountIdOf(facility: DocData): string | null {
  const id = facility.facilityCreatorAccountId;
  return typeof id === 'string' && id.length > 0 ? id : null;
}
