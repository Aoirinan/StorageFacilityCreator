import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';

import type { StayTaskDoc } from '@sfc/functions-shared/stays/contracts';
import { notificationId } from '@sfc/functions-shared/stays/ids';

import { shortDate, turnoverRoute } from '../bookings/shared';
import { StayNotificationInput, writeStayNotifications } from '../common/notify';
import { STAYS_RUNTIME } from '../common/guards';
import { TriggerDeps, automationZone, defaultTriggerDeps } from './onStayWrite';

/**
 * staysOnTaskWrite (spec §6.6): tells the owner, in the app, when a
 * turnover or to-do is done and when someone reports an issue on one. It
 * writes notifications only. The issue text itself stays on the task (it
 * can hold anything a cleaner typed); the notification just points to it.
 */

/** Supply chips such as "towels" or "toilet paper": plain words only go into a notification. */
function plainSupplies(supplies: unknown): string[] {
  if (!Array.isArray(supplies)) return [];
  return supplies.filter((s): s is string => typeof s === 'string' && /^[A-Za-z][A-Za-z '-]{0,29}$/.test(s)).slice(0, 6);
}

function what(task: Partial<StayTaskDoc>): string {
  const title = typeof task.title === 'string' && task.title.trim() ? task.title.trim() : 'A task';
  return typeof task.dueDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(task.dueDate) ? `${title} (${shortDate(task.dueDate)})` : title;
}

/** The notifications a task update calls for (pure). */
export function taskNotifications(
  facilityId: string,
  taskId: string,
  before: Partial<StayTaskDoc>,
  after: Partial<StayTaskDoc>,
): StayNotificationInput[] {
  const out: StayNotificationInput[] = [];
  const metadata = {
    taskId,
    ...(after.stayId ? { stayId: after.stayId } : {}),
    ...(after.listingId ? { listingId: after.listingId } : {}),
    route: turnoverRoute(facilityId, taskId),
  };
  if (after.status === 'done' && before.status !== 'done') {
    const low = plainSupplies(after.suppliesLow);
    out.push({
      id: notificationId({ kind: 'turnover_done', taskId }),
      type: 'STAY_TURNOVER_DONE',
      message: `${what(after)} is done.${low.length > 0 ? ` Running low on: ${low.join(', ')}.` : ''}`,
      metadata,
    });
  }
  const note = typeof after.issueNote === 'string' ? after.issueNote.trim() : '';
  const previous = typeof before.issueNote === 'string' ? before.issueNote.trim() : '';
  if (note && note !== previous) {
    out.push({
      id: notificationId({ kind: 'turnover_issue', taskId, note }),
      type: 'STAY_TURNOVER_ISSUE',
      message: `Issue reported on ${what(after)}. Open the task to see it.`,
      metadata,
    });
  }
  return out;
}

export async function handleTaskUpdate(
  facilityId: string,
  taskId: string,
  before: Partial<StayTaskDoc>,
  after: Partial<StayTaskDoc>,
  deps: TriggerDeps = defaultTriggerDeps(),
): Promise<string[]> {
  const notices = taskNotifications(facilityId, taskId, before, after);
  if (notices.length === 0) return [];
  const db = deps.db();
  const nowMs = deps.now();
  if (!(await automationZone(db, facilityId, nowMs, 'module'))) return [];
  const result = await writeStayNotifications(db, facilityId, notices, Timestamp.fromMillis(nowMs));
  return result.created;
}

export const staysOnTaskWrite = functions
  .runWith(STAYS_RUNTIME.trigger)
  .firestore.document('facilities/{facilityId}/stayTasks/{taskId}')
  .onUpdate(async (change, context) => {
    try {
      await handleTaskUpdate(
        context.params.facilityId as string,
        context.params.taskId as string,
        (change.before.data() ?? {}) as Partial<StayTaskDoc>,
        (change.after.data() ?? {}) as Partial<StayTaskDoc>,
      );
    } catch (error) {
      functions.logger.error('staysOnTaskWrite failed', {
        facilityId: context.params.facilityId,
        taskId: context.params.taskId,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  });
