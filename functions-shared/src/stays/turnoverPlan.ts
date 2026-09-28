/**
 * Planning a stay's turnover task (spec §1.1 H, §6.6): what the automatic
 * `turnover_{stayId}` task should say, and a digest of it, so the trigger
 * writes only when the plan actually changed.
 *
 * The window runs from the stay's checkout (checkout day at its checkout
 * time) to the next arrival on the same listing (its check-in day and time),
 * or to 23:59 on checkout day when nothing follows. A next arrival on
 * checkout day is a same-day turn, which is high priority. Pure: the zone
 * comes from the controls and nothing is read or written here.
 */
import type {
  HourMinute,
  StayChecklistTemplateItem,
  StayControlsDoc,
  StayDoc,
  StayListingInput,
  StayTaskPriority,
  Ymd,
} from './contracts';
import { ACTIVE_STAY_STATUSES } from './contracts';
import { canonicalIanaZone, isValidHourMinute, localDateTimeToUtc, utcToLocalString } from './dates';
import { sha256Hex, taskIdTurnover } from './ids';

export type TurnoverStay = Pick<
  StayDoc,
  'listingId' | 'kind' | 'status' | 'arrivalState' | 'checkIn' | 'checkOut' | 'checkInTime' | 'checkOutTime'
> & { stayId: string };

export type TurnoverListing = Pick<StayListingInput, 'name' | 'turnover' | 'times'>;

export type TurnoverControls = Pick<StayControlsDoc, 'timeZone' | 'defaultCheckInTime' | 'defaultCheckOutTime'>;

/** The fields of a turnover task the plan decides. */
export interface PlannedTurnover {
  taskId: string;
  category: 'turnover';
  listingId: string;
  stayId: string;
  nextStayId: string | null;
  title: string;
  dueStartAtMs: number;
  dueStartLocal: string;
  dueByAtMs: number;
  dueByLocal: string;
  /** Checkout day. */
  dueDate: Ymd;
  sameDayTurn: boolean;
  priority: StayTaskPriority;
  mode: 'full' | 'quick_check';
  /** Copied onto the task only when it is created. */
  checklist: StayChecklistTemplateItem[];
  /** Written only when the task is created. */
  assigneeUid: string | null;
  assigneeName: string | null;
}

export interface TurnoverPlan {
  task: PlannedTurnover;
  digest: string;
}

function holdsNights(status: string): boolean {
  return (ACTIVE_STAY_STATUSES as readonly string[]).includes(status);
}

function timeOr(...candidates: (string | null | undefined)[]): HourMinute {
  for (const c of candidates) if (isValidHourMinute(c)) return c;
  throw new Error('planTurnover: no valid time');
}

/**
 * Whether a stay gets a turnover at all: it holds its nights (not cancelled,
 * removed or a no-show), the listing does turnovers, and it is a booking, or
 * an owner-use block on a listing set to clean after those. Maintenance
 * blocks never do.
 */
export function wantsTurnover(stay: Omit<TurnoverStay, 'stayId'>, listing: Pick<StayListingInput, 'turnover'>): boolean {
  if (!holdsNights(stay.status) || stay.arrivalState === 'no_show') return false;
  const mode = listing.turnover?.mode;
  if (mode !== 'full' && mode !== 'quick_check') return false;
  if (stay.kind === 'reservation') return true;
  return stay.kind === 'owner_block' && listing.turnover.afterOwnerBlocks === true;
}

/** Whether a stay counts as the next arrival after a checkout: a booking or owner stay that holds its nights. */
export function isArrival(stay: Pick<StayDoc, 'kind' | 'status' | 'arrivalState'>): boolean {
  return holdsNights(stay.status) && stay.arrivalState !== 'no_show' && (stay.kind === 'reservation' || stay.kind === 'owner_block');
}

/**
 * The digest the trigger stores when a stay no longer wants a turnover and
 * it cancelled (or flagged) the task: it tells a system cancellation apart
 * from one a manager made, so only the former is reopened later.
 */
export function inactiveTurnoverDigest(stayId: string): string {
  return `inactive:${sha256Hex(stayId).slice(0, 24)}`;
}

export function isInactiveTurnoverDigest(digest: unknown): boolean {
  return typeof digest === 'string' && digest.startsWith('inactive:');
}

/**
 * The plan for `stay`'s turnover, or null when it should have none (see
 * wantsTurnover). `nextStay` is the next arrival on the listing, if any; one
 * that does not start on or after this checkout is ignored. Throws when the
 * controls hold no valid zone: a turnover is never timed in a guessed one.
 */
export function planTurnover(
  stay: TurnoverStay,
  nextStay: TurnoverStay | null,
  listing: TurnoverListing,
  controls: TurnoverControls,
): TurnoverPlan | null {
  if (!wantsTurnover(stay, listing)) return null;
  const tz = canonicalIanaZone(controls.timeZone);
  if (!tz) throw new Error('planTurnover: the facility zone is not set');

  const next =
    nextStay &&
    nextStay.stayId !== stay.stayId &&
    nextStay.listingId === stay.listingId &&
    isArrival(nextStay) &&
    nextStay.checkIn >= stay.checkOut
      ? nextStay
      : null;

  const checkOutTime = timeOr(stay.checkOutTime, listing.times?.checkOut, controls.defaultCheckOutTime, '11:00');
  const dueStart = localDateTimeToUtc(stay.checkOut, checkOutTime, tz).getTime();
  let dueBy = next
    ? localDateTimeToUtc(next.checkIn, timeOr(next.checkInTime, listing.times?.checkIn, controls.defaultCheckInTime, '15:00'), tz).getTime()
    : localDateTimeToUtc(stay.checkOut, '23:59', tz).getTime();
  // A next check-in set earlier than this checkout still cannot end the window before it starts.
  if (dueBy < dueStart) dueBy = dueStart;

  const mode = listing.turnover.mode === 'quick_check' ? 'quick_check' : 'full';
  const what = stay.kind === 'owner_block' ? 'Turnover after owner stay' : mode === 'quick_check' ? 'Site check' : 'Turnover';
  const sameDayTurn = next !== null && next.checkIn === stay.checkOut;

  const task: PlannedTurnover = {
    taskId: taskIdTurnover(stay.stayId),
    category: 'turnover',
    listingId: stay.listingId,
    stayId: stay.stayId,
    nextStayId: next?.stayId ?? null,
    title: `${what} · ${listing.name}`.slice(0, 120),
    dueStartAtMs: dueStart,
    dueStartLocal: utcToLocalString(dueStart, tz),
    dueByAtMs: dueBy,
    dueByLocal: utcToLocalString(dueBy, tz),
    dueDate: stay.checkOut,
    sameDayTurn,
    priority: sameDayTurn ? 'high' : 'normal',
    mode,
    checklist: (listing.turnover.checklistTemplate ?? []).map((i) => ({ id: i.id, label: i.label })),
    assigneeUid: listing.turnover.defaultAssigneeUid ?? null,
    assigneeName: listing.turnover.defaultAssigneeName ?? null,
  };
  // Only what the trigger re-times goes in: the checklist and assignee are
  // written once, at creation, and a change to them is not a new plan.
  const digest = sha256Hex(
    JSON.stringify([
      1,
      task.listingId,
      task.stayId,
      task.nextStayId,
      task.title,
      task.dueStartAtMs,
      task.dueByAtMs,
      task.dueDate,
      task.sameDayTurn,
    ]),
  ).slice(0, 32);
  return { task, digest };
}
