import * as functions from 'firebase-functions/v1';
import { defineString } from 'firebase-functions/params';
import { GoogleAuth } from 'google-auth-library';
import * as admin from 'firebase-admin';

const HOSTING_PROJECT_ID = defineString('HOSTING_PROJECT_ID', { default: 'storage-facility-creator' });
const HOSTING_SITE_ID = defineString('HOSTING_SITE_ID', { default: 'storage-facility-creator' });

const SUPER_ADMIN_EMAILS_HARDCODED = [
  'russell_forsyth_1992@outlook.com',
  'russellforsyth09091992@gmail.com',
  'kennethgriggs03@gmail.com',
];

function getSuperAdminEmails(): string[] {
  const envValue = process.env.SUPER_ADMIN_EMAILS;
  return envValue && envValue.trim()
    ? envValue.split(',').map((e: string) => e.trim()).filter((e: string) => e.length > 0)
    : SUPER_ADMIN_EMAILS_HARDCODED;
}

function isSuperAdmin(email?: string): boolean {
  const lower = String(email || '').trim().toLowerCase();
  if (!lower) return false;
  return getSuperAdminEmails().some((item) => item.toLowerCase() === lower);
}

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
    const customDomainId = encodeURIComponent(hostname);

    let customDomain: any;
    try {
      customDomain = await hostingApiRequest(
        `${parent}/customDomains?customDomainId=${customDomainId}`,
        {
          method: 'POST',
          body: JSON.stringify({ hostName: hostname }),
        },
      );
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
