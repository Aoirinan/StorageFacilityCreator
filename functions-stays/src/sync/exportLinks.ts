import * as functions from 'firebase-functions/v1';
import { Timestamp, Transaction } from 'firebase-admin/firestore';
import type { Firestore } from 'firebase-admin/firestore';

import {
  EXPORT_SCOPES,
  EXPORT_TARGET_PROVIDERS,
  ExportScope,
  ExportTargetProvider,
  STAYS_CURRENT_DOC_ID,
  STAYS_LIMITS,
  STAYS_SECRET_SUBCOLLECTION,
  STAY_TOP_LEVEL_COLLECTIONS,
  StaysCreateExportLinkResponse,
  StaysGetExportUrlResponse,
  StaysRevokeExportLinkResponse,
  StaysUpdateExportLinkResponse,
  StaysWarning,
} from '@sfc/functions-shared/stays/contracts';
import { exportTokenHash, isValidExportToken, newExportToken, randomId } from '@sfc/functions-shared/stays/ids';

import { staysError } from '../common/errors';
import {
  StaysCallContext,
  StaysDeps,
  auditStays,
  defaultStaysDeps,
  requireDocId,
  requireRequestId,
  runStaysGuards,
  staysCallable,
} from '../common/guards';
import { exportLinksCol, exportUrlForToken, listingsCol, providerLabel } from './common';

/**
 * Export links (spec §1.1 G, §6.5): one iCal URL per listing and target
 * channel, for the owner to paste into that channel's "Import calendar".
 *
 * The raw token lives only in stayExportLinks/{id}/secret/current, which no
 * client can read; the endpoint finds a link through
 * stayCalendarExportTokens/{sha256(token)}, so it never stores or logs the
 * token itself. The URL is handed out only by these owner/manager callables,
 * and every time it is shown is audited. Revoking deactivates the lookup at
 * once (the feed answers 404 and is never cached); rotating does the same
 * and returns a new link to re-paste.
 */

const OM = ['owner', 'manager'] as const;
const LABEL_MAX = 60;

function asTarget(value: unknown): ExportTargetProvider {
  if (!(EXPORT_TARGET_PROVIDERS as readonly unknown[]).includes(value)) {
    throw staysError('invalid-argument', 'invalid_argument', 'Pick which site will import this calendar.', { field: 'targetProvider' });
  }
  return value as ExportTargetProvider;
}

function asScope(value: unknown, fallback?: ExportScope): ExportScope {
  if (value === undefined && fallback) return fallback;
  if (!(EXPORT_SCOPES as readonly unknown[]).includes(value)) {
    throw staysError('invalid-argument', 'invalid_argument', 'Pick what the link sends.', { field: 'scope' });
  }
  return value as ExportScope;
}

function asLabel(value: unknown, fallback: string): string {
  if (value !== undefined && value !== null && typeof value !== 'string') {
    throw staysError('invalid-argument', 'invalid_argument', 'The name must be text.', { field: 'label' });
  }
  const label = (typeof value === 'string' ? value : '').replace(/\s+/g, ' ').trim().slice(0, LABEL_MAX);
  return label || fallback;
}

function tokensCol(db: Firestore) {
  return db.collection(STAY_TOP_LEVEL_COLLECTIONS.exportTokens);
}

interface NewLinkInput {
  listingId: string;
  targetProvider: ExportTargetProvider;
  label: string;
  scope: ExportScope;
  rotated: boolean;
  /** `xl_{requestId}` when the caller sent one, so a retry finds the link it made. */
  linkId?: string;
}

/** A create's link id from its requestId: a double tap or a retry lands on the same doc. */
export function exportLinkIdForRequest(requestId: string): string {
  return `xl_${requestId}`;
}

/** Writes a link, its secret token and the token lookup in a transaction; returns its id and URL. */
function createLinkInTx(tx: Transaction, ctx: StaysCallContext, input: NewLinkInput): StaysCreateExportLinkResponse {
  const now = Timestamp.fromMillis(ctx.nowMs);
  const linkId = input.linkId ?? randomId('xl');
  const token = newExportToken();
  const ref = exportLinksCol(ctx.db, ctx.facilityId).doc(linkId);
  tx.create(ref, {
    facilityId: ctx.facilityId,
    listingId: input.listingId,
    targetProvider: input.targetProvider,
    label: input.label,
    scope: input.scope,
    active: true,
    stats: { lastFetchedAt: null, lastFetcher: null, lastStatus: null, statsWrittenAt: null },
    createdAt: now,
    createdBy: ctx.uid,
    rotatedAt: input.rotated ? now : null,
    revokedAt: null,
  });
  tx.create(ref.collection(STAYS_SECRET_SUBCOLLECTION).doc(STAYS_CURRENT_DOC_ID), { token });
  tx.create(tokensCol(ctx.db).doc(exportTokenHash(token)), {
    facilityId: ctx.facilityId,
    listingId: input.listingId,
    linkId,
    active: true,
    createdAt: now,
  });
  return { linkId, url: exportUrlForToken(token) };
}

async function activeLinkCount(tx: Transaction, ctx: StaysCallContext, listingId: string): Promise<number> {
  const snap = await tx.get(exportLinksCol(ctx.db, ctx.facilityId).where('listingId', '==', listingId).where('active', '==', true));
  return snap.size;
}

// ---------------------------------------------------------------------------

export async function createExportLinkHandler(
  raw: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysCreateExportLinkResponse> {
  const ctx = await runStaysGuards(
    raw,
    context,
    {
      callable: 'staysCreateExportLink',
      roles: OM,
      validate: (d) => {
        requireDocId(d, 'listingId');
        asTarget(d.targetProvider);
        asScope(d.scope, 'blocks_only');
        // Null means "none", as it does for the other optional fields a client may send as null.
        if (d.requestId !== undefined && d.requestId !== null) requireRequestId(d);
      },
      rateLimit: { key: 'stays_export_create', windowSeconds: 3600, perFacility: 30 },
    },
    deps,
  );
  const d = ctx.data;
  const listingId = d.listingId as string;
  const targetProvider = asTarget(d.targetProvider);
  const scope = asScope(d.scope, 'blocks_only');
  const label = asLabel(d.label, `SFC to ${providerLabel(targetProvider)}`);
  const requestId = d.requestId !== undefined && d.requestId !== null ? requireRequestId(d) : null;
  const listing = await listingsCol(ctx.db, ctx.facilityId).doc(listingId).get();
  if (!listing.exists) throw staysError('not-found', 'not_found', 'That listing was not found.', { listingId });
  if (listing.get('archived') === true) throw staysError('failed-precondition', 'listing_inactive', 'That listing is archived.', { listingId });

  const outcome = await ctx.db.runTransaction(async (tx) => {
    const linkId = requestId ? exportLinkIdForRequest(requestId) : undefined;
    if (linkId) {
      const ref = exportLinksCol(ctx.db, ctx.facilityId).doc(linkId);
      const [link, secret] = await tx.getAll(ref, ref.collection(STAYS_SECRET_SUBCOLLECTION).doc(STAYS_CURRENT_DOC_ID));
      if (link.exists) {
        // A double tap or a retry: the link this request already made, not a second live token.
        const token = secret.exists ? secret.get('token') : null;
        if (link.get('listingId') !== listingId || link.get('targetProvider') !== targetProvider) {
          throw staysError('invalid-argument', 'invalid_argument', 'That request was already used for another link.', { field: 'requestId' });
        }
        if (link.get('active') !== true || !isValidExportToken(token)) {
          throw staysError('not-found', 'not_found', 'That export link was revoked. Create a new one.', { linkId });
        }
        return { created: false, link: { linkId, url: exportUrlForToken(token) } };
      }
    }
    if ((await activeLinkCount(tx, ctx, listingId)) >= STAYS_LIMITS.exportLinksPerListing) {
      throw staysError(
        'failed-precondition',
        'limit_reached',
        `A listing can have at most ${STAYS_LIMITS.exportLinksPerListing} export links. Revoke one first.`,
      );
    }
    return { created: true, link: createLinkInTx(tx, ctx, { listingId, targetProvider, label, scope, rotated: false, linkId }) };
  });
  // A repeat hands the URL out again, so it is audited the way staysGetExportUrl is.
  await auditStays(ctx, {
    eventType: outcome.created ? 'stays.export_link.created' : 'stays.export_link.url_viewed',
    targetType: 'stayExportLink',
    targetId: outcome.link.linkId,
    metadata: outcome.created ? { listingId, targetProvider, scope } : { listingId },
  });
  return outcome.link;
}

export async function getExportUrlHandler(
  raw: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysGetExportUrlResponse> {
  const ctx = await runStaysGuards(
    raw,
    context,
    {
      callable: 'staysGetExportUrl',
      roles: OM,
      validate: (d) => void requireDocId(d, 'linkId'),
      // Seeing the URL is seeing the secret: 30 an hour per person, each one audited.
      rateLimit: { key: 'stays_export_url', windowSeconds: 3600, perUser: 30 },
    },
    deps,
  );
  const linkId = ctx.data.linkId as string;
  const ref = exportLinksCol(ctx.db, ctx.facilityId).doc(linkId);
  const [link, secret] = await ctx.db.getAll(ref, ref.collection(STAYS_SECRET_SUBCOLLECTION).doc(STAYS_CURRENT_DOC_ID));
  const token = secret.exists ? secret.get('token') : null;
  if (!link.exists || link.get('active') !== true || !isValidExportToken(token)) {
    throw staysError('not-found', 'not_found', 'That export link was not found or was revoked.', { linkId });
  }
  await auditStays(ctx, {
    eventType: 'stays.export_link.url_viewed',
    targetType: 'stayExportLink',
    targetId: linkId,
    metadata: { listingId: link.get('listingId') },
  });
  return { url: exportUrlForToken(token) };
}

export async function updateExportLinkHandler(
  raw: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysUpdateExportLinkResponse> {
  const ctx = await runStaysGuards(
    raw,
    context,
    {
      callable: 'staysUpdateExportLink',
      roles: OM,
      validate: (d) => {
        requireDocId(d, 'linkId');
        if (d.scope !== undefined) asScope(d.scope);
        if (d.label !== undefined) asLabel(d.label, '');
      },
      rateLimit: { key: 'stays_export_update', windowSeconds: 60, perFacility: 30 },
    },
    deps,
  );
  const linkId = ctx.data.linkId as string;
  const ref = exportLinksCol(ctx.db, ctx.facilityId).doc(linkId);
  const result = await ctx.db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.get('active') !== true) {
      throw staysError('not-found', 'not_found', 'That export link was not found or was revoked.', { linkId });
    }
    const before = snap.get('scope') as ExportScope;
    const scope = ctx.data.scope !== undefined ? asScope(ctx.data.scope) : before;
    const label = ctx.data.label !== undefined ? asLabel(ctx.data.label, snap.get('label') as string) : (snap.get('label') as string);
    tx.update(ref, { scope, label });
    return { scope, label, before };
  });
  if (result.scope !== result.before) {
    await auditStays(ctx, {
      eventType: 'stays.export_link.scope_changed',
      targetType: 'stayExportLink',
      targetId: linkId,
      metadata: { from: result.before, to: result.scope },
    });
  }
  return { linkId, scope: result.scope, label: result.label };
}

export async function revokeExportLinkHandler(
  raw: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysRevokeExportLinkResponse> {
  const ctx = await runStaysGuards(
    raw,
    context,
    {
      callable: 'staysRevokeExportLink',
      roles: OM,
      validate: (d) => {
        requireDocId(d, 'linkId');
        if (d.rotate !== undefined && typeof d.rotate !== 'boolean') {
          throw staysError('invalid-argument', 'invalid_argument', 'rotate must be true or false.', { field: 'rotate' });
        }
      },
      rateLimit: { key: 'stays_export_revoke', windowSeconds: 60, perFacility: 30 },
    },
    deps,
  );
  const linkId = ctx.data.linkId as string;
  const rotate = ctx.data.rotate === true;
  const ref = exportLinksCol(ctx.db, ctx.facilityId).doc(linkId);
  const secretRef = ref.collection(STAYS_SECRET_SUBCOLLECTION).doc(STAYS_CURRENT_DOC_ID);
  const now = Timestamp.fromMillis(ctx.nowMs);

  const outcome = await ctx.db.runTransaction(async (tx) => {
    const [link, secret] = await tx.getAll(ref, secretRef);
    if (!link.exists) throw staysError('not-found', 'not_found', 'That export link was not found.', { linkId });
    const wasActive = link.get('active') === true;
    if (!wasActive && rotate) {
      throw staysError('failed-precondition', 'not_found', 'That link was already revoked. Create a new one instead.', { linkId });
    }
    const token = secret.exists ? secret.get('token') : null;
    const tokenRef = isValidExportToken(token) ? tokensCol(ctx.db).doc(exportTokenHash(token)) : null;
    const tokenSnap = tokenRef ? await tx.get(tokenRef) : null;
    if (!wasActive) return { wasActive, rotated: undefined };
    tx.update(ref, { active: false, revokedAt: now });
    if (tokenRef && tokenSnap?.exists) tx.update(tokenRef, { active: false });
    if (secret.exists) tx.delete(secretRef);
    const rotated = rotate
      ? createLinkInTx(tx, ctx, {
          listingId: link.get('listingId') as string,
          targetProvider: link.get('targetProvider') as ExportTargetProvider,
          label: (link.get('label') as string) || 'SFC',
          scope: link.get('scope') as ExportScope,
          rotated: true,
        })
      : undefined;
    return { wasActive, rotated };
  });

  const warnings: StaysWarning[] = [];
  if (outcome.rotated) {
    warnings.push({
      code: 'repaste_required',
      message: 'The old link has stopped working. Paste the new link into the channel’s Import calendar and remove the old one there.',
    });
  }
  if (outcome.wasActive) {
    await auditStays(ctx, {
      eventType: outcome.rotated ? 'stays.export_link.rotated' : 'stays.export_link.revoked',
      targetType: 'stayExportLink',
      targetId: linkId,
      metadata: outcome.rotated ? { newLinkId: outcome.rotated.linkId } : {},
    });
  }
  return { linkId, revoked: true, ...(outcome.rotated ? { rotated: outcome.rotated } : {}), warnings };
}

export const staysCreateExportLink = staysCallable('staysCreateExportLink', (data, context) => createExportLinkHandler(data, context));
export const staysGetExportUrl = staysCallable('staysGetExportUrl', (data, context) => getExportUrlHandler(data, context));
export const staysUpdateExportLink = staysCallable('staysUpdateExportLink', (data, context) => updateExportLinkHandler(data, context));
export const staysRevokeExportLink = staysCallable('staysRevokeExportLink', (data, context) => revokeExportLinkHandler(data, context));
