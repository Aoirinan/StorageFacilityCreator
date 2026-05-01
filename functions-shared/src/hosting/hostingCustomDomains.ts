import * as functions from 'firebase-functions/v1';
import { defineString } from 'firebase-functions/params';
import { GoogleAuth } from 'google-auth-library';
import * as admin from 'firebase-admin';

import { isSuperAdmin } from '../auth/superAdmin';

const HOSTING_PROJECT_ID = defineString('HOSTING_PROJECT_ID', { default: 'storage-facility-creator' });
const HOSTING_SITE_ID = defineString('HOSTING_SITE_ID', { default: 'storage-facility-creator' });

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
        'facilityId is valid but no published public slug was found.',
      );
    }
    return { facilityId: directFacilityId, slug };
  }

  if (directSlug) {
    const mapSnap = await db.collection('publicFacilityMaps').doc(directSlug).get();
    if (!mapSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'No public facility map found for slug.');
    }
    const facilityId = String(mapSnap.get('facilityId') || '').trim();
    if (!facilityId) {
      throw new functions.https.HttpsError('failed-precondition', 'publicFacilityMaps entry is missing facilityId.');
    }
    return { facilityId, slug: directSlug };
  }

  if (normalizedHost) {
    const settings = await db
      .collectionGroup('settings')
      .where('customDomain', '==', normalizedHost)
      .limit(10)
      .get();
    const enabled = settings.docs.find((doc) => {
      const data = doc.data() as Record<string, unknown>;
      return data.enabled !== false;
    });
    const facilityId = enabled?.ref.parent.parent?.id;
    if (!facilityId) {
      throw new functions.https.HttpsError('not-found', 'No enabled facility settings found for hostname.');
    }
    const meta = await db.doc(`facilities/${facilityId}/mapEngine/meta`).get();
    const slug = String(meta.get('publicSlug') || '').trim().toLowerCase();
    if (!slug) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility is missing published public slug.');
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

type DomainRecord = { type: string; name: string; value: string };

function flattenDnsRecords(customDomain: any): DomainRecord[] {
  const records: DomainRecord[] = [];
  const blocks = [
    customDomain?.requiredDnsUpdates,
    customDomain?.requiredDnsUpdates?.desired,
    customDomain?.requiredDnsUpdates?.discovered,
  ];
  for (const block of blocks) {
    const additions = Array.isArray(block?.records) ? block.records : [];
    for (const item of additions) {
      const values = Array.isArray(item?.rrdata) ? item.rrdata : [];
      for (const value of values) {
        records.push({
          type: String(item?.type || '').toUpperCase(),
          name: String(item?.domainName || '').trim(),
          value: String(value || '').trim(),
        });
      }
    }
  }
  return records.filter((r) => r.type && r.name && r.value);
}

function summarizeStatus(customDomain: any): string {
  const cert = String(customDomain?.cert?.state || '').toLowerCase();
  const setup = String(customDomain?.status || '').toLowerCase();
  if (cert === 'active') return 'connected';
  if (cert === 'provisioning') return 'provisioning_ssl';
  if (setup === 'pending' || setup === 'pending_setup') return 'pending_dns';
  if (setup) return setup;
  return 'unknown';
}

async function getCustomDomain(hostname: string): Promise<any> {
  const projectId = HOSTING_PROJECT_ID.value().trim();
  const siteId = HOSTING_SITE_ID.value().trim();
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

    const projectId = HOSTING_PROJECT_ID.value().trim();
    const siteId = HOSTING_SITE_ID.value().trim();
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

    return {
      hostname,
      facilityId: resolved.facilityId,
      slug: resolved.slug,
      status: summarizeStatus(customDomain),
      records: flattenDnsRecords(customDomain),
      certState: customDomain?.cert?.state || null,
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
    return {
      hostname,
      facilityId: resolved.facilityId,
      slug: resolved.slug,
      status: summarizeStatus(customDomain),
      records: flattenDnsRecords(customDomain),
      certState: customDomain?.cert?.state || null,
      customDomainName: customDomain?.name || null,
      retrievedAt: new Date().toISOString(),
    };
  },
);
