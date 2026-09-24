import * as functions from 'firebase-functions/v1';
import type { Firestore, Timestamp } from 'firebase-admin/firestore';

import {
  STAY_COLLECTIONS,
  STAY_NOTIFICATION_TYPES,
  StayNotificationMetadata,
  StayNotificationType,
} from '@sfc/functions-shared/stays/contracts';

import { isAlreadyExists } from './errors';

/**
 * In-app notifications only (spec §6.11, §9): facilities/{fid}/Notifications,
 * the one channel Stays has in v1. Nothing here sends email or texts.
 */
export interface StayNotificationInput {
  /** From ids.ts notificationId(); the id is also the "already told them" marker. */
  id: string;
  type: StayNotificationType;
  message: string;
  metadata: StayNotificationMetadata;
}

export interface NotifyResult {
  created: string[];
  existed: string[];
  failed: string[];
}

/**
 * Creates each notification unless its id exists. Written after the
 * transaction commits, never inside it: a create() that finds its doc would
 * otherwise abort the booking it describes. Failures are logged and counted,
 * never thrown, for the same reason.
 */
export async function writeStayNotifications(
  db: Firestore,
  facilityId: string,
  notifications: StayNotificationInput[],
  createdAt: Timestamp,
): Promise<NotifyResult> {
  const result: NotifyResult = { created: [], existed: [], failed: [] };
  for (const n of notifications) {
    if (!(STAY_NOTIFICATION_TYPES as readonly string[]).includes(n.type)) {
      result.failed.push(n.id);
      functions.logger.error('stays: refusing a notification with an unknown type', { type: n.type, id: n.id });
      continue;
    }
    try {
      await db
        .collection('facilities')
        .doc(facilityId)
        .collection(STAY_COLLECTIONS.notifications)
        .doc(n.id)
        .create({
          facilityId,
          type: n.type,
          message: n.message,
          createdAt,
          readAt: null,
          metadata: n.metadata,
        });
      result.created.push(n.id);
    } catch (error) {
      if (isAlreadyExists(error)) {
        result.existed.push(n.id);
      } else {
        result.failed.push(n.id);
        functions.logger.error('stays: notification write failed', {
          id: n.id,
          message: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }
  return result;
}
