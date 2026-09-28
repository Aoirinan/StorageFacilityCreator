import {
  A2P_TRUST_PRODUCT_POLICY_SID,
  SECONDARY_CUSTOMER_PROFILE_POLICY_SID,
} from '../a2pTrustBundle';
import type { A2PTwilioClient } from '../a2pTwilioTypes';

// --- fake Twilio -------------------------------------------------------------
//
// Records every call so tests can assert exactly what would have been sent.
// Only the surface in A2PTwilioClient exists; anything else (for example the
// policies list the old code searched by name) is a decoy that must never be
// consulted.

export type Call = { op: string; target?: string; params?: any };

interface Bundle {
  sid: string;
  status: string;
  policySid: string;
  assignments: string[];
}

interface FakeOptions {
  profile?: Partial<Bundle> & { sid: string };
  product?: Partial<Bundle> & { sid: string };
  profileEvaluation?: { status: string; results: any[] };
  productEvaluation?: { status: string; results: any[] };
  brandStatus?: string;
  campaignStatus?: string;
}

const PRIMARY_POLICY = 'RN6433641899984f951173ef1738c3bdd0';

export function fakeTwilio(options: FakeOptions = {}) {
  const calls: Call[] = [];
  let counter = 0;
  const nextSid = (prefix: string) => `${prefix}${String(++counter).padStart(32, '0')}`;
  const profiles = new Map<string, Bundle>();
  const products = new Map<string, Bundle>();
  if (options.profile) {
    profiles.set(options.profile.sid, {
      status: 'draft',
      policySid: SECONDARY_CUSTOMER_PROFILE_POLICY_SID,
      assignments: [],
      ...options.profile,
    });
  }
  if (options.product) {
    products.set(options.product.sid, {
      status: 'draft',
      policySid: A2P_TRUST_PRODUCT_POLICY_SID,
      assignments: [],
      ...options.product,
    });
  }

  const bundleContext = (kind: 'profile' | 'product', map: Map<string, Bundle>, sid: string) => {
    const bundle = () => {
      const b = map.get(sid);
      if (!b) throw Object.assign(new Error(`${sid} not found`), { status: 404 });
      return b;
    };
    // Assignment SIDs are "BV:<objectSid>" so remove() can find the object.
    const assignments: any = (assignmentSid: string) => ({
      remove: async () => {
        const objectSid = assignmentSid.slice(3);
        calls.push({ op: `${kind}.unassign`, target: sid, params: objectSid });
        bundle().assignments = bundle().assignments.filter((o) => o !== objectSid);
        return true;
      },
    });
    assignments.list = async () =>
      bundle().assignments.map((objectSid) => ({ sid: `BV:${objectSid}`, objectSid }));
    assignments.create = async ({ objectSid }: { objectSid: string }) => {
      calls.push({ op: `${kind}.assign`, target: sid, params: objectSid });
      bundle().assignments.push(objectSid);
      return { sid: `BV:${objectSid}` };
    };
    const evaluations = {
      create: async ({ policySid }: { policySid: string }) => {
        calls.push({ op: `${kind}.evaluate`, target: sid, params: policySid });
        const ev =
          (kind === 'profile' ? options.profileEvaluation : options.productEvaluation) ??
          { status: 'compliant', results: [] };
        return { sid: nextSid('EL'), policySid, ...ev };
      },
    };
    const ctx: any = {
      fetch: async () => ({ sid, status: bundle().status, policySid: bundle().policySid }),
      update: async (params: any) => {
        calls.push({ op: `${kind}.update`, target: sid, params });
        if (params.status) bundle().status = params.status;
        return { sid, status: bundle().status, policySid: bundle().policySid };
      },
    };
    if (kind === 'profile') {
      ctx.customerProfilesEntityAssignments = assignments;
      ctx.customerProfilesEvaluations = evaluations;
    } else {
      ctx.trustProductsEntityAssignments = assignments;
      ctx.trustProductsEvaluations = evaluations;
    }
    return ctx;
  };

  const customerProfiles: any = (sid: string) => bundleContext('profile', profiles, sid);
  customerProfiles.create = async (params: any) => {
    calls.push({ op: 'profile.create', params });
    const sid = nextSid('BU');
    profiles.set(sid, { sid, status: 'draft', policySid: params.policySid, assignments: [] });
    return { sid, status: 'draft', policySid: params.policySid };
  };
  customerProfiles.list = async (params: any) => {
    calls.push({ op: 'profile.list', params });
    return [
      { sid: 'BUprimary0000000000000000000000000', status: 'twilio-approved', policySid: PRIMARY_POLICY },
    ];
  };

  const trustProducts: any = (sid: string) => bundleContext('product', products, sid);
  trustProducts.create = async (params: any) => {
    calls.push({ op: 'product.create', params });
    const sid = nextSid('BU');
    products.set(sid, { sid, status: 'draft', policySid: params.policySid, assignments: [] });
    return { sid, status: 'draft', policySid: params.policySid };
  };

  const endUsers: any = (sid: string) => ({
    update: async (params: any) => {
      calls.push({ op: 'endUser.update', target: sid, params });
      return { sid };
    },
  });
  endUsers.create = async (params: any) => {
    calls.push({ op: 'endUser.create', params });
    return { sid: nextSid('IT') };
  };

  const supportingDocuments: any = (sid: string) => ({
    update: async (params: any) => {
      calls.push({ op: 'document.update', target: sid, params });
      return { sid };
    },
  });
  supportingDocuments.create = async (params: any) => {
    calls.push({ op: 'document.create', params });
    return { sid: nextSid('RD') };
  };

  const addresses: any = (sid: string) => ({
    update: async (params: any) => {
      calls.push({ op: 'address.update', target: sid, params });
      return { sid };
    },
  });
  addresses.create = async (params: any) => {
    calls.push({ op: 'address.create', params });
    return { sid: nextSid('AD') };
  };

  const brandRegistrations: any = (sid: string) => ({
    fetch: async () => ({ sid, status: options.brandStatus ?? 'APPROVED', errors: [], failureReason: '' }),
  });
  brandRegistrations.create = async (params: any) => {
    calls.push({ op: 'brand.create', params });
    return { sid: nextSid('BN') };
  };

  const services = (mg: string) => {
    const usAppToPerson: any = (qe: string) => ({
      fetch: async () => {
        calls.push({ op: 'campaign.fetch', target: `${mg}/${qe}` });
        return { sid: qe, campaignId: 'CM' + '1'.repeat(32), campaignStatus: options.campaignStatus ?? 'VERIFIED', errors: [] };
      },
      remove: async () => {
        calls.push({ op: 'campaign.remove', target: `${mg}/${qe}` });
        return true;
      },
    });
    usAppToPerson.create = async (params: any) => {
      calls.push({ op: 'campaign.create', target: mg, params });
      return { sid: 'QE' + '2'.repeat(32), campaignId: 'CM' + '3'.repeat(32), campaignStatus: 'PENDING', errors: [] };
    };
    usAppToPerson.list = async () => [
      { sid: 'QE' + '4'.repeat(32), campaignId: 'CMlegacy', campaignStatus: 'IN_PROGRESS', errors: [] },
    ];
    return { usAppToPerson };
  };

  // A decoy the old name-matching resolver would have picked first.
  const policies = {
    list: async () => {
      calls.push({ op: 'policies.list' });
      return [
        { sid: 'RN' + 'd'.repeat(32), friendlyName: 'A2P Messaging: Starter Brand (decoy)' },
        { sid: 'RN' + 'e'.repeat(32), friendlyName: 'Secondary Customer Profile of a Business (decoy)' },
      ];
    },
  };

  const client = {
    trusthub: { v1: { customerProfiles, trustProducts, endUsers, supportingDocuments, policies } },
    addresses,
    messaging: { v1: { brandRegistrations, services } },
  };
  return { client: client as unknown as A2PTwilioClient, calls, profiles, products };
}


export const ops = (calls: Call[], op: string) => calls.filter((c) => c.op === op);
