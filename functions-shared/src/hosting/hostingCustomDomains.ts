import * as functions from 'firebase-functions/v1';
import { GoogleAuth } from 'google-auth-library';
import * as admin from 'firebase-admin';

import { isSuperAdmin } from '../auth/superAdmin';
import { requireHostingConfig } from './hostingConfigRegistry';

function normalizeHostname(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, '')
    .replace(/^www\./, '')
    .split('/')[0]
    .replace(/\.$/, '');
}

function isValidHostname(value: string): boolean {
  if (!value || value.length > 253) return false;
  if (!value.includes('.')) return false;
  return /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(value);
}

function wrapFirestoreQueryError(error: unknown, fallbackMessage: string): never {
  const msg = String((error as { message?: string })?.message || error || '');
  if (msg.includes('FAILED_PRECONDITION') && msg.includes('index')) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Firestore is still building the custom-domain lookup index. Wait a few minutes and try again.',
    );
  }
  if (error instanceof functions.https.HttpsError) throw error;
  throw new functions.https.HttpsError('internal', fallbackMessage);
}

/** Keep Website Setup `customDomain` in sync with the hostname we just connected in Hosting. */
async function syncFacilityCustomDomain(facilityId: string, hostname: string): Promise<void> {
  const db = admin.firestore();
  const ref = db.doc(`facilities/${facilityId}/settings/public`);
  const snap = await ref.get();
  const current = normalizeHostname(String(snap.get('customDomain') || ''));
  if (current === hostname) return;

  // Guard against silently handing one facility's domain to another. `customDomain` is a
  // free-text field with no uniqueness enforcement, so if a *different* facility already has
  // this exact hostname on file, writing it here would create a collision: the public site
  // resolver (resolveSlug) would then have two facilities claiming the same domain and could
  // serve either one's content to real visitors. Provisioning a domain that's genuinely
  // changing hands requires clearing it from the old facility first.
  let existing;
  try {
    existing = await db.collectionGroup('settings').where('customDomain', '==', hostname).limit(10).get();
  } catch (error) {
    wrapFirestoreQueryError(error, 'Could not verify this domain is not already in use by another facility.');
  }
  const conflict = existing.docs.find((doc) => doc.ref.parent.parent?.id && doc.ref.parent.parent.id !== facilityId);
  if (conflict) {
    throw new functions.https.HttpsError(
      'already-exists',
      `Custom domain "${hostname}" is already set on a different facility (${conflict.ref.parent.parent?.id}). ` +
        "Clear it from that facility's Website Setup first if this domain is intentionally moving, then try again.",
    );
  }

  await ref.set(
    {
      customDomain: hostname,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  await db.doc(`customDomainClaims/${hostname}`).set(
    { facilityId, claimedAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true },
  );
}

async function resolveFacilitySlugFromInput(input: {
  facilityId?: string;
  slug?: string;
  hostname?: string;
}): Promise<{ facilityId: string; slug: string }> {
  const db = admin.firestore();
  const directFacilityId = String(input.facilityId || '').trim();
  const directSlug = String(input.slug || '').trim().toLowerCase();
  const normalizedHost = normalizeHostname(String(input.hostname || ''));

  if (directFacilityId) {
    const meta = await db.doc(`facilities/${directFacilityId}/mapEngine/meta`).get();
    const slug = String(meta.get('publicSlug') || '').trim().toLowerCase();
    if (!slug) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'This facility has no published Website URL name yet. Open Website Setup, set Website URL name, publish/save, then try again.',
      );
    }
    return { facilityId: directFacilityId, slug };
  }

  if (directSlug) {
    const mapSnap = await db.collection('publicFacilityMaps').doc(directSlug).get();
    if (!mapSnap.exists) {
      throw new functions.https.HttpsError(
        'not-found',
        'No published website found for that Website URL name. Confirm it in Website Setup, then try again.',
      );
    }
    const facilityId = String(mapSnap.get('facilityId') || '').trim();
    if (!facilityId) {
      throw new functions.https.HttpsError('failed-precondition', 'publicFacilityMaps entry is missing facilityId.');
    }
    return { facilityId, slug: directSlug };
  }

  if (normalizedHost) {
    let settings;
    try {
      settings = await db
        .collectionGroup('settings')
        .where('customDomain', '==', normalizedHost)
        .limit(10)
        .get();
    } catch (error) {
      wrapFirestoreQueryError(
        error,
        'Could not look up this website address. Enter Facility ID or Website URL name, or try again shortly.',
      );
    }
    const enabledMatches = settings.docs.filter((doc) => {
      const data = doc.data() as Record<string, unknown>;
      return data.enabled !== false;
    });
    // `customDomain` is free text on each facility's own settings doc — nothing enforces it's
    // unique. If more than one facility has it set, don't silently guess (that could point a
    // hostname lookup, and any provisioning that follows it, at the wrong facility).
    const distinctFacilityIds = new Set(
      enabledMatches.map((doc) => doc.ref.parent.parent?.id).filter((id): id is string => !!id),
    );
    if (distinctFacilityIds.size > 1) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        `Multiple facilities have Custom domain set to "${normalizedHost}" (${[...distinctFacilityIds].join(
          ', ',
        )}). Provide Facility ID or Website URL name to disambiguate, and clear the stale value from the wrong facility's Website Setup.`,
      );
    }
    const facilityId = enabledMatches[0]?.ref.parent.parent?.id;
    if (!facilityId) {
      throw new functions.https.HttpsError(
        'not-found',
        `No facility has Custom domain set to "${normalizedHost}" yet. ` +
          'In Website Setup, set Custom domain to this exact address and save, ' +
          'or enter Facility ID / Website URL name here (we will sync Custom domain automatically).',
      );
    }
    const meta = await db.doc(`facilities/${facilityId}/mapEngine/meta`).get();
    const slug = String(meta.get('publicSlug') || '').trim().toLowerCase();
    if (!slug) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Facility is missing a published Website URL name. Finish Website Setup publish/save first.',
      );
    }
    return { facilityId, slug };
  }

  throw new functions.https.HttpsError('invalid-argument', 'Provide facilityId, slug, or hostname.');
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function hostingApiRequest(path: string, init: RequestInit): Promise<any> {
  const auth = new GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/firebase', 'https://www.googleapis.com/auth/cloud-platform'],
  });
  const client = await auth.getClient();
  const token = await client.getAccessToken();
  const accessToken = token.token;
  if (!accessToken) {
    throw new functions.https.HttpsError('internal', 'Failed to obtain Google API access token.');
  }

  const response = await fetch(`https://firebasehosting.googleapis.com/v1beta1/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
  });
  const raw = await response.text();
  const json = raw ? JSON.parse(raw) : {};
  if (!response.ok) {
    const message = String(json?.error?.message || `Firebase Hosting API error (${response.status}).`);
    if (response.status === 404) {
      throw new functions.https.HttpsError('not-found', message);
    }
    throw new functions.https.HttpsError('internal', message);
  }
  return json;
}

type DomainRecord = {
  type: string;
  name: string;
  value: string;
  /** Firebase Hosting requiredAction, e.g. ADD / REMOVE / NONE */
  requiredAction?: string;
};

/**
 * Firebase Hosting v1beta1 shape:
 * requiredDnsUpdates.desired[] / .discovered[] → DnsRecordSet { domainName, records[] }
 * DnsRecord → { type, domainName, rdata, requiredAction }
 */
function flattenDnsRecords(customDomain: any): DomainRecord[] {
  const records: DomainRecord[] = [];
  const updates = customDomain?.requiredDnsUpdates;
  const sets: any[] = [];
  if (Array.isArray(updates?.desired)) sets.push(...updates.desired);
  if (Array.isArray(updates?.discovered)) sets.push(...updates.discovered);
  // Legacy / alternate shapes
  if (Array.isArray(updates?.records)) sets.push(updates);
  if (Array.isArray(customDomain?.dnsRecords)) sets.push({ records: customDomain.dnsRecords });

  for (const set of sets) {
    const setDomain = String(set?.domainName || '').trim();
    const items = Array.isArray(set?.records) ? set.records : [];
    for (const item of items) {
      const type = String(item?.type || '').toUpperCase();
      const name = String(item?.domainName || setDomain || '').trim();
      const action = String(item?.requiredAction || '').toUpperCase();
      const values: string[] = [];
      if (typeof item?.rdata === 'string' && item.rdata.trim()) values.push(item.rdata.trim());
      if (Array.isArray(item?.rrdata)) {
        for (const v of item.rrdata) {
          if (typeof v === 'string' && v.trim()) values.push(v.trim());
        }
      }
      for (const value of values) {
        records.push({ type, name, value, requiredAction: action || undefined });
      }
    }
  }

  // Prefer records the customer still needs to ADD; fall back to full list.
  // (A missing/empty requiredAction means Firebase considers the record already
  // satisfied — it must NOT be treated as still needing to be added.)
  const toAdd = records.filter((r) => r.requiredAction === 'ADD');
  const preferred = toAdd.length > 0 ? toAdd : records;

  const seen = new Set<string>();
  return preferred.filter((r) => {
    if (!r.type || !r.name || !r.value) return false;
    const key = `${r.type}|${r.name}|${r.value}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function summarizeStatus(customDomain: any): string {
  const cert = String(customDomain?.cert?.state || '').toUpperCase();
  const host = String(customDomain?.hostState || '').toUpperCase();
  const ownership = String(customDomain?.ownershipState || '').toUpperCase();
  const setup = String(customDomain?.status || '').toLowerCase();

  if (cert === 'CERT_ACTIVE' && (host === 'HOST_ACTIVE' || host === '')) return 'connected';
  // Certificate issued but hosting isn't routing traffic yet (e.g. HOST_MISMATCH) —
  // almost there, but NOT actually serving the site. Must not report as connected/Live.
  if (cert === 'CERT_ACTIVE') return 'provisioning_ssl';
  if (cert === 'CERT_PROPAGATING' || cert === 'CERT_PENDING') return 'provisioning_ssl';
  if (cert === 'CERT_VALIDATING' || cert === 'CERT_PREPARING') return 'pending_dns';
  if (ownership === 'OWNERSHIP_MISSING' || ownership === 'OWNERSHIP_PENDING') return 'pending_dns';
  if (host === 'HOST_UNHOSTED' || host === 'HOST_UNREACHABLE') return 'pending_dns';
  if (cert === 'CERT_EXPIRED' || cert === 'CERT_EXPIRING_SOON') return 'certificate_issue';
  if (setup === 'pending' || setup === 'pending_setup') return 'pending_dns';
  if (setup) return setup;
  if (cert) return cert.toLowerCase();
  return 'unknown';
}

function explainStatus(customDomain: any, records: DomainRecord[]): string {
  const cert = String(customDomain?.cert?.state || 'unknown');
  const host = String(customDomain?.hostState || 'unknown');
  const ownership = String(customDomain?.ownershipState || 'unknown');
  const issues = Array.isArray(customDomain?.issues)
    ? customDomain.issues
        .map((i: any) => String(i?.message || i?.details || '').trim())
        .filter(Boolean)
    : [];

  const lines: string[] = [];
  const needsAction = records.some((r) => r.requiredAction === 'ADD');
  if (needsAction) {
    lines.push(
      `Firebase needs ${records.filter((r) => r.requiredAction === 'ADD').length} DNS change(s) at GoDaddy before the site can go live. ` +
        'Add every row below exactly (Type / Name / Value), wait a few minutes, then tap Check progress.',
    );
  } else if (String(customDomain?.cert?.state || '').toUpperCase() === 'CERT_VALIDATING') {
    lines.push(
      'Firebase is validating DNS for the SSL certificate (CERT_VALIDATING). ' +
        'If GoDaddy still has old A/CNAME/forwarding records for this domain, remove or replace them with the records Firebase shows. ' +
        'Tap Check progress again in 1–2 minutes — records often appear after the next DNS check.',
    );
  } else if (records.length > 0) {
    lines.push(
      'DNS already matches what Firebase expects — nothing more to add at GoDaddy. ' +
        "Firebase is still finishing setup on its own end (certificate/routing). Tap Check progress again in a few minutes.",
    );
  } else {
    lines.push(
      'No DNS rows were returned on this check. Tap Check progress again shortly. ' +
        'You can also open Firebase Console → Hosting → Custom domains for the live record list.',
    );
  }
  lines.push(`Certificate: ${cert}`);
  lines.push(`Hosting state: ${host}`);
  lines.push(`Ownership: ${ownership}`);
  if (issues.length > 0) {
    lines.push(`Issues: ${issues.join(' | ')}`);
  }
  return lines.join('\n');
}

async function getCustomDomain(hostname: string): Promise<any> {
  const { getProjectId, getSiteId } = requireHostingConfig();
  const projectId = getProjectId().trim();
  const siteId = getSiteId().trim();
  const encoded = encodeURIComponent(hostname);
  return hostingApiRequest(`projects/${projectId}/sites/${siteId}/customDomains/${encoded}`, { method: 'GET' });
}

/** `customDomains.create` returns a long-running Operation; poll until finished. */
async function pollHostingOperation(operationName: string): Promise<any> {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    const op = await hostingApiRequest(operationName, { method: 'GET' });
    if (op?.done) {
      if (op.error) {
        const msg = String(op.error.message || JSON.stringify(op.error));
        throw new functions.https.HttpsError('internal', msg);
      }
      return op.response || {};
    }
    await sleep(2000);
  }
  throw new functions.https.HttpsError(
    'deadline-exceeded',
    'Timed out waiting for Firebase Hosting custom domain operation.',
  );
}

/**
 * After `customDomains.create`, the API returns an Operation (not a CustomDomain).
 * Resolve the CustomDomain payload for DNS / status fields.
 */
async function resolveCustomDomainAfterCreate(hostname: string, createResult: any): Promise<any> {
  if (!createResult || typeof createResult !== 'object') {
    throw new functions.https.HttpsError('internal', 'Unexpected response from Hosting customDomains.create.');
  }

  // Rare: already looks like a CustomDomain resource.
  if (typeof createResult.name === 'string' && createResult.name.includes('/customDomains/') && !createResult.name.includes('/operations/')) {
    if (createResult.requiredDnsUpdates != null || createResult.cert != null || createResult.status != null) {
      return createResult;
    }
  }

  const opName = typeof createResult.name === 'string' ? createResult.name : '';
  const isOperation = opName.includes('/operations/') || createResult.done === false || createResult.done === true;

  if (isOperation) {
    const op = createResult;
    if (op.done === true) {
      if (op.error) {
        const msg = String(op.error.message || JSON.stringify(op.error));
        throw new functions.https.HttpsError('internal', msg);
      }
      if (op.response && typeof op.response === 'object') {
        return op.response;
      }
    } else if (opName) {
      const polled = await pollHostingOperation(opName);
      if (polled && typeof polled === 'object' && Object.keys(polled).length > 0) {
        return polled;
      }
    }
  }

  // Fallback: GET the CustomDomain by id (may lag briefly after create).
  for (let i = 0; i < 20; i += 1) {
    try {
      return await getCustomDomain(hostname);
    } catch (e: any) {
      const code = e instanceof functions.https.HttpsError ? e.code : '';
      if (code === 'not-found' && i < 19) {
        await sleep(1500);
        continue;
      }
      throw e;
    }
  }
  throw new functions.https.HttpsError('internal', 'Could not load custom domain after create.');
}

export const superAdminProvisionHostingCustomDomain = functions.https.onCall(
  async (
    data: {
      hostname?: string;
      facilityId?: string;
      slug?: string;
    },
    context,
  ) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError('permission-denied', 'Only super admins can provision custom domains');
    }

    const hostname = normalizeHostname(String(data?.hostname || ''));
    if (!isValidHostname(hostname)) {
      throw new functions.https.HttpsError('invalid-argument', 'A valid hostname is required (e.g. rent.example.com).');
    }

    const resolved = await resolveFacilitySlugFromInput({
      facilityId: String(data?.facilityId || ''),
      slug: String(data?.slug || ''),
      hostname,
    });

    // Permanent sync: Website Setup Custom domain must match Hosting hostname for lookup + root redirect.
    await syncFacilityCustomDomain(resolved.facilityId, hostname);

    const { getProjectId, getSiteId } = requireHostingConfig();
    const projectId = getProjectId().trim();
    const siteId = getSiteId().trim();
    const parent = `projects/${projectId}/sites/${siteId}`;
    const query = new URLSearchParams({ customDomainId: hostname }).toString();

    let customDomain: any;
    try {
      const createResult = await hostingApiRequest(`${parent}/customDomains?${query}`, {
        method: 'POST',
        // Domain is specified by query param `customDomainId`; CustomDomain has no hostName field.
        body: JSON.stringify({}),
      });
      customDomain = await resolveCustomDomainAfterCreate(hostname, createResult);
    } catch (error: any) {
      const msg = String(error?.message || '');
      const alreadyExists = msg.includes('already exists') || msg.includes('ALREADY_EXISTS');
      if (!alreadyExists) throw error;
      customDomain = await getCustomDomain(hostname);
    }

    const records = flattenDnsRecords(customDomain);
    return {
      hostname,
      facilityId: resolved.facilityId,
      slug: resolved.slug,
      status: summarizeStatus(customDomain),
      detail: explainStatus(customDomain, records),
      records,
      certState: customDomain?.cert?.state || null,
      hostState: customDomain?.hostState || null,
      ownershipState: customDomain?.ownershipState || null,
      customDomainName: customDomain?.name || null,
      retrievedAt: new Date().toISOString(),
    };
  },
);

export const superAdminGetHostingCustomDomainStatus = functions.https.onCall(
  async (data: { hostname?: string }, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError('permission-denied', 'Only super admins can view custom domain status');
    }
    const hostname = normalizeHostname(String(data?.hostname || ''));
    if (!isValidHostname(hostname)) {
      throw new functions.https.HttpsError('invalid-argument', 'A valid hostname is required.');
    }

    const customDomain = await getCustomDomain(hostname);
    const resolved = await resolveFacilitySlugFromInput({ hostname });
    const records = flattenDnsRecords(customDomain);
    return {
      hostname,
      facilityId: resolved.facilityId,
      slug: resolved.slug,
      status: summarizeStatus(customDomain),
      detail: explainStatus(customDomain, records),
      records,
      certState: customDomain?.cert?.state || null,
      hostState: customDomain?.hostState || null,
      ownershipState: customDomain?.ownershipState || null,
      customDomainName: customDomain?.name || null,
      retrievedAt: new Date().toISOString(),
    };
  },
);

export const superAdminRemoveHostingCustomDomain = functions.https.onCall(
  async (
    data: {
      hostname?: string;
      facilityId?: string;
      slug?: string;
    },
    context,
  ) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError('permission-denied', 'Only super admins can remove custom domains');
    }

    const hostname = normalizeHostname(String(data?.hostname || ''));
    if (!isValidHostname(hostname)) {
      throw new functions.https.HttpsError('invalid-argument', 'A valid hostname is required (e.g. rent.example.com).');
    }

    const resolved = await resolveFacilitySlugFromInput({
      facilityId: String(data?.facilityId || ''),
      slug: String(data?.slug || ''),
      hostname,
    });

    const { getProjectId, getSiteId } = requireHostingConfig();
    const projectId = getProjectId().trim();
    const siteId = getSiteId().trim();
    const encoded = encodeURIComponent(hostname);

    try {
      await hostingApiRequest(`projects/${projectId}/sites/${siteId}/customDomains/${encoded}`, { method: 'DELETE' });
    } catch (error) {
      const code = error instanceof functions.https.HttpsError ? error.code : '';
      // Already gone from Hosting — treat as success so this callable is safely re-runnable.
      if (code !== 'not-found') throw error;
    }

    const db = admin.firestore();
    const settingsRef = db.doc(`facilities/${resolved.facilityId}/settings/public`);
    const settingsSnap = await settingsRef.get();
    const currentDomain = normalizeHostname(String(settingsSnap.get('customDomain') || ''));
    if (currentDomain === hostname) {
      await settingsRef.set(
        { customDomain: admin.firestore.FieldValue.delete(), updatedAt: admin.firestore.FieldValue.serverTimestamp() },
        { merge: true },
      );
    }

    const claimRef = db.doc(`customDomainClaims/${hostname}`);
    const claimSnap = await claimRef.get();
    if (claimSnap.exists && claimSnap.get('facilityId') === resolved.facilityId) {
      await claimRef.delete();
    }

    return {
      hostname,
      facilityId: resolved.facilityId,
      slug: resolved.slug,
      status: 'removed',
      detail: `Domain "${hostname}" was detached from Firebase Hosting and released for reuse.`,
      records: [] as DomainRecord[],
      certState: null,
      hostState: null,
      ownershipState: null,
      customDomainName: null,
      retrievedAt: new Date().toISOString(),
    };
  },
);
