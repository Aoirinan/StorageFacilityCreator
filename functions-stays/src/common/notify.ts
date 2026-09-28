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
 *
 * Employees can read that collection, so a message carries no more than the
 * stay doc itself shows staff: the listing, dates and guestDisplayName.
 * Never the full name (stayPrivate), a phone number or its last 4, an email
 * address, a door, gate, lockbox or wifi code, or a money amount; link to the
 * stay in metadata instead. writeStayNotifications refuses messages that
 * look like they break this (personalDataIn) rather than store them.
 */
export interface StayNotificationInput {
  /** From ids.ts notificationId(); the id is also the "already told them" marker. */
  id: string;
  type: StayNotificationType;
  /** Staff-visible text: see the rules above. */
  message: string;
  metadata: StayNotificationMetadata;
}

/**
 * What in a message looks like personal data, a code or money, or null.
 * A net for mistakes, not a proof: a full name cannot be recognised, so
 * callers build messages from guestDisplayName only.
 */
export function personalDataIn(message: string): 'money' | 'email' | 'phone' | 'access_code' | null {
  if (/\$\s?\d|\bUSD\b|\d\s?(?:dollars|usd)\b/i.test(message)) return 'money';
  if (/[^\s@]+@[^\s@]+\.[^\s@]+/.test(message)) return 'email';
  if (/\b(?:code|codes|pin|passcode|password|wifi|wi-fi|lockbox)\b\D{0,12}\d{3,}/i.test(message)) return 'access_code';
  // Dates and times are fine; a run of 7+ digits after them is a phone number.
  const withoutDates = message.replace(/\b\d{4}-\d{2}-\d{2}\b/g, ' ').replace(/\b\d{1,2}:\d{2}\b/g, ' ');
  if (/(?:\d[\s().+-]{0,2}){7,}/.test(withoutDates)) return 'phone';
  return null;
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
    const personal = personalDataIn(String(n.message ?? ''));
    if (personal) {
      result.failed.push(n.id);
      // The message itself is not logged: it is what must not spread.
      functions.logger.error('stays: refusing a notification whose text looks like personal data', {
        type: n.type,
        id: n.id,
        looksLike: personal,
      });
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
