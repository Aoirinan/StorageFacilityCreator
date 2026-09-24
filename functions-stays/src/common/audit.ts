import { writeAuditLog } from '@sfc/functions-shared/audit/writeAuditLog';
import { STAYS_AUDIT_EVENT_TYPES, StaysAuditEventType } from '@sfc/functions-shared/stays/contracts';

/** One Stays audit record (spec §6.11), written through the shared writeAuditLog. */
export interface StaysAuditEntry {
  eventType: StaysAuditEventType;
  actorUid: string;
  targetType: string;
  targetId: string;
  /** Ids, counts and statuses only: no guest contact details, codes or URLs. */
  metadata?: Record<string, unknown>;
}

export type StaysAuditWriter = (facilityId: string, entry: StaysAuditEntry) => Promise<void>;

/** Production writer. writeAuditLog swallows its own failures: an audit hiccup never undoes a booking. */
export const defaultAuditWriter: StaysAuditWriter = async (facilityId, entry) => {
  await writeAuditLog(facilityId, {
    eventType: entry.eventType,
    actorUid: entry.actorUid,
    targetType: entry.targetType,
    targetId: entry.targetId,
    metadata: entry.metadata ?? {},
  });
};

export function isStaysAuditEventType(value: string): value is StaysAuditEventType {
  return (STAYS_AUDIT_EVENT_TYPES as readonly string[]).includes(value);
}
