import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import {
  cancelSubscriptions,
  getStripeClient,
  isOrphanedSubscription,
  summarizeCancelOutcomes,
} from '@sfc/functions-shared';
import { getSuperAdminEmails } from '@sfc/functions-shared/auth/superAdmin';
import { escapeHtml } from '@sfc/functions-shared/email/footers';
import { getSgMail, initializeSendGrid } from '@sfc/functions-shared/email/sendgridLazy';

import {
  SENDGRID_FROM_EMAIL,
  SENDGRID_FROM_NAME,
  SENDGRID_SECRETS,
  STRIPE_SECRETS,
} from './secrets';

/**
 * Nightly: cancel Stripe subscriptions whose facility or account no longer
 * exists.
 *
 * The deletion and offboarding paths now cancel as they go, so in a healthy
 * week this finds nothing. It exists for the weeks that are not healthy: a
 * function that half-ran, a record removed straight from the console, a code
 * path nobody thought of. Billing a customer for something that no longer
 * exists is the kind of bug that is invisible to us and obvious on their
 * statement, so it deserves a backstop rather than trust.
 *
 * Deliberately conservative. A subscription is only touched when its metadata
 * names a facility or account AND that record is gone. Subscriptions with no
 * metadata are reported, never cancelled: we cannot prove who they belong to,
 * and cancelling a paying customer by mistake is far worse than leaving one
 * stray record for a human to read.
 */

/** Blast-radius cap. More than this in one night means something systemic. */
const MAX_CANCELS_PER_RUN = 25;

interface OrphanRecord {
  subscriptionId: string;
  customerEmail: string | null;
  facilityId: string | null;
  accountId: string | null;
  amountLabel: string;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function sendAdminSummary(subject: string, html: string, text: string): Promise<void> {
  initializeSendGrid();
  const mail = getSgMail() as { send: (msg: unknown) => Promise<unknown> };
  for (const to of getSuperAdminEmails()) {
    try {
      await mail.send({
        to,
        from: { email: SENDGRID_FROM_EMAIL.value(), name: SENDGRID_FROM_NAME.value() },
        subject,
        html,
        text,
      });
    } catch (error) {
      functions.logger.error('Could not send orphaned-subscription summary', {
        to,
        error: errorMessage(error),
      });
    }
  }
}

function describe(o: OrphanRecord): string {
  const who = o.customerEmail || 'unknown customer';
  const what = o.facilityId ? `facility ${o.facilityId}` : `account ${o.accountId}`;
  return `${o.subscriptionId} (${o.amountLabel}) for ${who}, ${what} no longer exists`;
}

export const sweepOrphanedSubscriptions = functions
  .runWith({ secrets: [...STRIPE_SECRETS, ...SENDGRID_SECRETS], timeoutSeconds: 540, memory: '512MB' })
  .pubsub.schedule('30 7 * * *')
  .timeZone('UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const stripe = getStripeClient();

    // Cache existence lookups: many subscriptions share one account.
    const facilityCache = new Map<string, boolean>();
    const accountCache = new Map<string, boolean>();
    const exists = async (collection: string, id: string, cache: Map<string, boolean>) => {
      const hit = cache.get(id);
      if (hit !== undefined) return hit;
      const snap = await db.collection(collection).doc(id).get();
      cache.set(id, snap.exists);
      return snap.exists;
    };

    const orphans: OrphanRecord[] = [];
    const unattributed: string[] = [];
    let scanned = 0;

    try {
      // Only statuses that can still take money. A subscription already
      // canceled or incomplete_expired bills nobody.
      for (const status of ['active', 'past_due', 'trialing', 'unpaid'] as const) {
        for await (const sub of stripe.subscriptions.list({ status, limit: 100, expand: ['data.customer'] })) {
          scanned += 1;
          const metadata = (sub.metadata || {}) as Record<string, string>;
          const facilityId = (metadata.facilityId || '').trim();
          const accountId = (metadata.accountId || '').trim();

          if (!facilityId && !accountId) {
            unattributed.push(sub.id);
            continue;
          }

          const facilityLives = facilityId ? await exists('facilities', facilityId, facilityCache) : false;
          const accountLives = accountId
            ? await exists('facilityCreatorAccounts', accountId, accountCache)
            : false;

          const orphaned = isOrphanedSubscription({
            metadata,
            facilityExists: () => facilityLives,
            accountExists: () => accountLives,
          });
          if (!orphaned) continue;

          const customer = sub.customer as { email?: string | null } | string;
          const amount = sub.items.data.reduce(
            (sum, item) => sum + (item.price.unit_amount ?? 0) * (item.quantity ?? 1),
            0,
          );
          orphans.push({
            subscriptionId: sub.id,
            customerEmail: typeof customer === 'string' ? null : customer?.email ?? null,
            facilityId: facilityId || null,
            accountId: accountId || null,
            amountLabel: `$${(amount / 100).toFixed(2)}/${sub.items.data[0]?.price.recurring?.interval ?? 'month'}`,
          });
        }
      }
    } catch (error) {
      functions.logger.error('Orphaned-subscription sweep could not list subscriptions', {
        error: errorMessage(error),
      });
      return null;
    }

    if (orphans.length === 0) {
      functions.logger.info('Orphaned-subscription sweep: nothing to do', {
        scanned,
        unattributed: unattributed.length,
      });
      return null;
    }

    // A large number means a bad delete script or a bad query, not a real
    // week's churn. Report it and cancel nothing rather than mass-cancel.
    if (orphans.length > MAX_CANCELS_PER_RUN) {
      const lines = orphans.map(describe);
      functions.logger.error('Orphaned-subscription sweep found too many to cancel safely', {
        found: orphans.length,
        cap: MAX_CANCELS_PER_RUN,
      });
      await sendAdminSummary(
        `Action needed: ${orphans.length} orphaned Stripe subscriptions found`,
        `<p><strong>${orphans.length}</strong> subscriptions point at a facility or account that no longer exists. That is more than the safety cap of ${MAX_CANCELS_PER_RUN}, so <strong>none were cancelled</strong>; this looks more like a bad delete than a normal week.</p><ul>${lines
          .map((l) => `<li>${escapeHtml(l)}</li>`)
          .join('')}</ul>`,
        `${orphans.length} orphaned subscriptions found, above the cap of ${MAX_CANCELS_PER_RUN}, so none were cancelled:\n\n${lines.join('\n')}`,
      );
      return null;
    }

    const outcomes = await cancelSubscriptions(
      stripe,
      orphans.map((o) => ({ id: o.subscriptionId, label: 'platform' as const })),
    );
    functions.logger.info('Orphaned-subscription sweep cancelled subscriptions', {
      scanned,
      cancelled: orphans.length,
      outcomes: summarizeCancelOutcomes(outcomes),
    });

    const lines = orphans.map((o, i) => `${describe(o)} — ${outcomes[i]?.status ?? 'unknown'}`);
    await sendAdminSummary(
      `Cancelled ${orphans.length} orphaned Stripe subscription${orphans.length === 1 ? '' : 's'}`,
      `<p>These subscriptions were still billing for a facility or account that no longer exists, so they were cancelled.</p><ul>${lines
        .map((l) => `<li>${escapeHtml(l)}</li>`)
        .join('')}</ul><p>Scanned ${scanned} live subscriptions. ${unattributed.length} had no facility or account metadata and were left alone.</p>`,
      `Cancelled ${orphans.length} orphaned subscriptions:\n\n${lines.join('\n')}\n\nScanned ${scanned}. ${unattributed.length} had no metadata and were left alone.`,
    );
    return null;
  });
