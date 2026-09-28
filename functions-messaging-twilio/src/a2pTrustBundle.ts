/**
 * Builds the TrustHub bundles A2P 10DLC brand registration requires.
 *
 * Before this existed the onboarding flow created a customer profile and trust
 * product carrying only a friendlyName and email — empty shells — and then
 * submitted a brand against them. That can never be approved: the carrier needs
 * the legal entity, its EIN, its registered address and a named authorized
 * representative, none of which were ever sent.
 *
 * Rules that shape everything here:
 *
 *  1. Nothing is submitted until Twilio's *free* evaluation says the bundle is
 *     compliant. Brand registration charges a non-refundable fee per attempt
 *     and is reviewed over days, so a failed evaluation must stop the flow
 *     rather than become a rejection notice a week later.
 *
 *  2. The full EIN is never persisted. Carrier vetting needs all nine digits,
 *     but the app stores only the last four, so the bundle is built while the
 *     owner's submission is still in memory and the number is then dropped.
 *
 *  3. The two bundles are separate stages. The secondary customer profile goes
 *     to Twilio first; the A2P trust product can only be evaluated once the
 *     profile is in review. A profile that is already in review or approved is
 *     left alone and the product is still built, evaluated and submitted —
 *     refusing the whole save at that point stranded a facility whose profile
 *     passed but whose product failed.
 *
 *  4. Both bundles are created and evaluated against Twilio's documented ISV
 *     policies, pinned by SID. Picking policies by friendly-name matching
 *     evaluated a trust product against the wrong policy (it demanded brand,
 *     business, representative and address items the A2P product never holds).
 *
 * Every resource SID is recorded on the facility so a re-run updates the
 * existing end users instead of stacking up duplicates against the profile.
 */
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import {
  buildA2pMessagingProfileAttributes,
  buildAddressPayload,
  buildAuthorizedRepresentativeAttributes,
  buildBusinessInformationAttributes,
  formatEvaluationFailures,
  mapBusinessType,
  summarizeEvaluation,
  type EvaluationSummary,
  type TrustBundleInput,
} from '@sfc/functions-shared';
import type {
  A2PTwilioClient,
  TrustHubAssignmentList,
  TrustHubBundleContext,
  TrustHubBundleRecord,
} from './a2pTwilioTypes';

/**
 * Twilio's ISV A2P 10DLC policies
 * (https://www.twilio.com/docs/messaging/compliance/a2p-10dlc/onboarding-isv-api).
 * Policy SIDs are global to Twilio, not per account.
 */
export const SECONDARY_CUSTOMER_PROFILE_POLICY_SID = 'RNdfbf3fae0e1107f8aded0e7cead80bf5';
export const A2P_TRUST_PRODUCT_POLICY_SID = 'RNb0d4771c2c98518d916a3d4cd70a8f8b';

const POLICY_SID_PATTERN = /^RN[0-9a-f]{32}$/;

export interface A2PPolicySids {
  customerProfilePolicySid: string;
  trustProductPolicySid: string;
}

/**
 * The policies to build and evaluate against.
 *
 * An environment override is honoured only when it is a well-formed policy SID;
 * anything else is logged and ignored in favour of the documented SID, so a
 * typo in an env file cannot silently send bundles to a different policy.
 */
export function resolveA2PPolicySids(
  env: Record<string, string | undefined> = process.env,
): A2PPolicySids {
  const pick = (name: string, raw: string | undefined, pinned: string): string => {
    const value = (raw || '').trim();
    if (!value) return pinned;
    if (POLICY_SID_PATTERN.test(value)) return value;
    functions.logger.error(
      `${name} is not a TrustHub policy SID (expected RN + 32 hex); using the documented policy ${pinned}`,
    );
    return pinned;
  };

  const sids: A2PPolicySids = {
    customerProfilePolicySid: pick(
      'TWILIO_SECONDARY_CUSTOMER_PROFILE_POLICY_SID',
      env.TWILIO_SECONDARY_CUSTOMER_PROFILE_POLICY_SID,
      SECONDARY_CUSTOMER_PROFILE_POLICY_SID,
    ),
    trustProductPolicySid: pick(
      'TWILIO_A2P_TRUST_PRODUCT_POLICY_SID',
      env.TWILIO_A2P_TRUST_PRODUCT_POLICY_SID || env.TWILIO_A2P_POLICY_SID,
      A2P_TRUST_PRODUCT_POLICY_SID,
    ),
  };
  functions.logger.info('A2P TrustHub policies in use', sids);
  return sids;
}

/**
 * Policy of the platform's own Primary Customer Profile.
 *
 * A facility's profile is a *secondary* profile in Twilio's ISV model: it is
 * only valid when it references an approved primary profile belonging to the
 * platform. Verified against the live account — an otherwise complete secondary
 * profile evaluates as "Primary customer profile bundle is null" without it,
 * and "compliant" with it.
 */
const PRIMARY_CUSTOMER_PROFILE_POLICY_SID = 'RN6433641899984f951173ef1738c3bdd0';

/** Resolved once per instance; the platform's primary profile does not change. */
let cachedPrimaryProfileSid: string | undefined;

/** Test hook: forget the cached primary profile. */
export function resetPrimaryCustomerProfileCache(): void {
  cachedPrimaryProfileSid = undefined;
}

/**
 * Find the platform's approved Primary Customer Profile.
 *
 * Every facility's bundle hangs off this one profile, so it is resolved rather
 * than hard-coded: the SID differs between the production account and any test
 * account, and pinning it in source would silently break the other.
 */
export async function resolvePrimaryCustomerProfileSid(twilio: A2PTwilioClient): Promise<string> {
  const override = (process.env.TWILIO_PRIMARY_CUSTOMER_PROFILE_SID || '').trim();
  if (override) return override;
  if (cachedPrimaryProfileSid) return cachedPrimaryProfileSid;

  // Filtered server-side: scanning the first page of every customer profile on
  // the account would miss the primary once facility profiles outnumber it.
  const profiles = await twilio.trusthub.v1.customerProfiles.list({
    policySid: PRIMARY_CUSTOMER_PROFILE_POLICY_SID,
    status: 'twilio-approved',
    limit: 20,
  });
  const approved = profiles.find(
    (p) =>
      p?.policySid === PRIMARY_CUSTOMER_PROFILE_POLICY_SID &&
      String(p?.status || '').toLowerCase() === 'twilio-approved',
  );

  if (!approved?.sid) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'The platform does not have an approved Primary Customer Profile in Twilio, so ' +
        'facility business profiles cannot be registered. This is a platform-level ' +
        'setup step, not something the facility owner can fix.',
    );
  }

  cachedPrimaryProfileSid = approved.sid;
  return cachedPrimaryProfileSid;
}

/** Bundle statuses meaning Twilio has it: submitted, being reviewed, or approved. */
const BUNDLE_WITH_TWILIO = new Set(['pending-review', 'in-review', 'twilio-approved']);
/** Bundle statuses meaning a review is running right now. */
const BUNDLE_IN_REVIEW = new Set(['pending-review', 'in-review']);
/** Bundle statuses a wrong-policy bundle may be abandoned from. */
const BUNDLE_REPLACEABLE = new Set(['draft', 'twilio-rejected']);

const lower = (value: unknown): string => String(value || '').trim().toLowerCase();

/** True when the bundle is submitted, in review or approved: edits are unsafe. */
export function isBundleWithTwilio(status: unknown): boolean {
  return BUNDLE_WITH_TWILIO.has(lower(status));
}

/** True while Twilio is reviewing the bundle. */
export function isBundleInReview(status: unknown): boolean {
  return BUNDLE_IN_REVIEW.has(lower(status));
}

/** The live TrustHub state of a facility's bundles, or null where none exists. */
export interface TrustBundleState {
  profile: TrustHubBundleRecord | null;
  product: TrustHubBundleRecord | null;
}

/**
 * Read both bundles from Twilio.
 *
 * A SID recorded on the facility can point at a bundle deleted in the console;
 * that reads as "no bundle" so the build creates a fresh one instead of wedging.
 */
export async function fetchTrustBundleState(
  twilio: A2PTwilioClient,
  facilityData: Record<string, any>,
): Promise<TrustBundleState> {
  const profileSid = String(facilityData.twilioTrustProfileSid || '').trim();
  const productSid = String(facilityData.twilioTrustProductSid || '').trim();

  const read = async (
    label: string,
    sid: string,
    fetch: () => Promise<TrustHubBundleRecord>,
  ): Promise<TrustHubBundleRecord | null> => {
    if (!sid) return null;
    try {
      const record = await fetch();
      return {
        sid: record.sid || sid,
        status: lower(record.status),
        policySid: String(record.policySid || ''),
      };
    } catch (error: any) {
      if (Number(error?.status) === 404) {
        functions.logger.warn(`A2P ${label} ${sid} no longer exists in Twilio; a new one will be created`);
        return null;
      }
      throw error;
    }
  };

  const [profile, product] = await Promise.all([
    read('customer profile', profileSid, () => twilio.trusthub.v1.customerProfiles(profileSid).fetch()),
    read('trust product', productSid, () => twilio.trusthub.v1.trustProducts(productSid).fetch()),
  ]);
  return { profile, product };
}

/**
 * Refuse a save while the trust product is in review. It is the one bundle a
 * save might rewrite, so it is the only review that blocks one; a customer
 * profile in review is simply left alone.
 */
export function assertTrustProductEditable(state: TrustBundleState): void {
  if (state.product && isBundleInReview(state.product.status)) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Your A2P messaging registration is being reviewed by Twilio and cannot be changed ' +
        'until that review finishes (usually about a business day). No action is needed; ' +
        'this page updates on its own.',
    );
  }
}

/**
 * What the owner may still change on the business-details form, and why not.
 *
 * The form used to lock as soon as a trust profile SID existed, which stranded
 * owners whose saved details were wrong; then it locked only on the profile
 * being in review while the server refused every save once the profile was in
 * review, so a facility whose profile passed but whose A2P product failed saw
 * an editable form that always errored. The two bundles are now separate:
 *
 *  - brand filed / carrier review under way, the trust product in review, or
 *    both bundles approved: nothing to save (`businessDetailsLocked`).
 *  - the customer profile with Twilio: its fields are read-only
 *    (`profileDetailsLocked`), but saving still rebuilds the trust product.
 */
export function describeBusinessDetailsLock(facilityData: Record<string, any>): {
  businessDetailsLocked: boolean;
  profileDetailsLocked: boolean;
  lockReason: string | null;
} {
  const profileStatus = String(facilityData.a2pBundleProfileStatus || '').toLowerCase();
  const productStatus = String(facilityData.a2pBundleProductStatus || '').toLowerCase();
  const a2pStatus = String(facilityData.a2pStatus || 'draft').toLowerCase();

  if (
    facilityData.twilioBrandSid ||
    a2pStatus === 'approved' ||
    a2pStatus === 'submitted' ||
    a2pStatus === 'pending'
  ) {
    return {
      businessDetailsLocked: true,
      profileDetailsLocked: true,
      lockReason:
        'Your brand has been filed with the carriers, so these details are locked. If the ' +
        'registration is rejected you can reset it and correct them.',
    };
  }
  if (isBundleInReview(productStatus)) {
    return {
      businessDetailsLocked: true,
      profileDetailsLocked: true,
      lockReason:
        'Twilio is reviewing your business profile and A2P messaging registration (usually ' +
        'about a business day). Nothing can be changed until it finishes; no action is needed.',
    };
  }
  if (profileStatus === 'twilio-approved' && productStatus === 'twilio-approved') {
    return {
      businessDetailsLocked: true,
      profileDetailsLocked: true,
      lockReason: 'Twilio approved your business profile. Continue to submit your registration.',
    };
  }
  if (isBundleWithTwilio(profileStatus)) {
    return {
      businessDetailsLocked: false,
      profileDetailsLocked: true,
      lockReason:
        (profileStatus === 'twilio-approved'
          ? 'Twilio approved your business profile, so its details are locked. '
          : 'Your business profile is with Twilio for review, so its details are locked until ' +
            'the review finishes. ') +
        'Saving again rebuilds and resubmits only the A2P messaging registration; the ' +
        '"doing business as" name can still be changed.',
    };
  }
  return { businessDetailsLocked: false, profileDetailsLocked: false, lockReason: null };
}

/** SIDs of the TrustHub resources that make up a facility's A2P bundle. */
export interface TrustBundleSids {
  trustProfileSid: string;
  trustProductSid: string;
  businessInfoEndUserSid: string | null;
  authorizedRepEndUserSid: string | null;
  a2pProfileEndUserSid: string;
  addressSid: string | null;
  addressDocumentSid: string | null;
}

export interface BundleBuildResult {
  sids: TrustBundleSids;
  customerProfileEvaluation: EvaluationSummary;
  trustProductEvaluation: EvaluationSummary;
  /** Customer profile status after this run (draft, pending-review, ...). */
  profileStatus: string;
  /** Trust product status after this run. */
  productStatus: string;
  /** True when this run left the profile untouched because Twilio already had it. */
  profileSkipped: boolean;
  /** SID of a wrong-policy trust product this run abandoned for a fresh one. */
  replacedProductSid?: string;
  /** SID of a wrong-policy customer profile this run abandoned for a fresh one. */
  replacedProfileSid?: string;
  /** Both bundles passed evaluation and are with Twilio (submitted or approved). */
  readyForBrand: boolean;
  /** Both bundles are twilio-approved; brand registration can go ahead. */
  approved: boolean;
}

/** Minimal facility document handle, so tests can pass a recorder. */
export interface FacilityDocRef {
  id: string;
  set(data: Record<string, unknown>, options: { merge: true }): Promise<unknown>;
}

/**
 * Create an end user, or update the existing one in place.
 *
 * Updating matters: end users are assigned to the profile by SID, so replacing
 * one on every save would leave the profile pointing at a stale record while
 * orphaned end users accumulate on the account.
 */
async function upsertEndUser(
  twilio: A2PTwilioClient,
  existingSid: string | undefined,
  friendlyName: string,
  type: string,
  attributes: Record<string, string>,
): Promise<string> {
  const sid = existingSid?.trim();
  if (sid) {
    try {
      await twilio.trusthub.v1.endUsers(sid).update({ attributes });
      return sid;
    } catch (error: any) {
      // A SID recorded on the facility can be gone if it was deleted in the
      // Twilio console. Fall through and make a new one rather than wedging
      // the owner's onboarding on a resource they cannot see.
      functions.logger.warn(
        `A2P end user ${sid} could not be updated (${error?.message}); creating a replacement`,
      );
    }
  }
  const created = await twilio.trusthub.v1.endUsers.create({
    friendlyName,
    type,
    attributes,
  });
  return created.sid;
}

/**
 * Make a bundle's assignments exactly `expected`.
 *
 * Only called on bundles this run is allowed to write (new, draft or
 * rejected). A reused bundle can carry leftovers — an abandoned customer
 * profile, a replaced end user, a duplicate A2P end user — and TrustHub
 * evaluates everything assigned, so extras are removed, not just missing items
 * added. "Already assigned" on create counts as success: Twilio rejects a
 * duplicate assignment rather than ignoring it.
 */
async function reconcileAssignments(
  assignmentList: TrustHubAssignmentList,
  expected: string[],
  bundleSid: string,
): Promise<void> {
  const wanted = new Set(expected);
  const existing = await assignmentList.list({ limit: 100 });
  for (const assignment of existing) {
    if (wanted.has(assignment.objectSid)) continue;
    try {
      await assignmentList(assignment.sid).remove();
      functions.logger.info('A2P bundle: removed unexpected assignment', {
        bundleSid,
        objectSid: assignment.objectSid,
      });
    } catch (error: any) {
      throw new functions.https.HttpsError(
        'internal',
        `Could not detach ${assignment.objectSid} from ${bundleSid}: ${error?.message}`,
      );
    }
  }
  const present = new Set(existing.map((a) => a.objectSid));
  for (const objectSid of expected) {
    if (present.has(objectSid)) continue;
    try {
      await assignmentList.create({ objectSid });
    } catch (error: any) {
      const message = String(error?.message || '');
      if (/already/i.test(message)) continue;
      throw new functions.https.HttpsError(
        'internal',
        `Could not attach ${objectSid} to ${bundleSid}: ${message}`,
      );
    }
  }
}

/** A verdict for a bundle this run did not evaluate because Twilio already has it. */
function withTwilioSummary(status: string, policySid: string): EvaluationSummary {
  return { compliant: true, status, failures: [], policySid };
}

/**
 * Build (or refresh) the customer profile and A2P trust product for a facility
 * and evaluate both against their carrier policies.
 *
 * Returns the evaluation verdicts instead of throwing on a non-compliant
 * bundle: the caller stores them so the owner can be shown exactly which field
 * the carrier policy rejected. Throws only when the trust product itself is in
 * review (nothing may be changed underneath the reviewer) or on bad input.
 */
export async function buildAndEvaluateTrustBundle(
  twilio: A2PTwilioClient,
  facilityRef: FacilityDocRef,
  facilityData: Record<string, any>,
  input: TrustBundleInput,
  policySids: A2PPolicySids,
  prefetchedState?: TrustBundleState,
): Promise<BundleBuildResult> {
  const mapping = mapBusinessType(input.businessType);
  if (!mapping) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      `Unsupported business type: ${String(input.businessType)}`,
    );
  }
  if (mapping.soleProprietor) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Sole proprietors use a separate Twilio registration path with its own ' +
        'limits and mobile verification, and cannot be registered as a standard ' +
        'brand. Contact support to start sole-proprietor registration.',
    );
  }

  const { customerProfilePolicySid, trustProductPolicySid } = policySids;
  const state = prefetchedState ?? (await fetchTrustBundleState(twilio, facilityData));

  assertTrustProductEditable(state);

  // ---- customer profile ----------------------------------------------------
  let profile = state.profile;
  let replacedProfileSid: string | undefined;
  if (
    profile &&
    profile.policySid &&
    profile.policySid !== customerProfilePolicySid &&
    BUNDLE_REPLACEABLE.has(profile.status)
  ) {
    functions.logger.warn('A2P customer profile was created under the wrong policy; creating a fresh one', {
      facilityId: facilityRef.id,
      oldProfileSid: profile.sid,
      oldPolicySid: profile.policySid,
      expectedPolicySid: customerProfilePolicySid,
    });
    replacedProfileSid = profile.sid;
    profile = null;
  }

  let trustProfileSid = profile?.sid ?? '';
  let profileStatus = profile?.status ?? '';
  let businessInfoEndUserSid: string | null =
    String(facilityData.twilioBusinessInfoEndUserSid || '').trim() || null;
  let authorizedRepEndUserSid: string | null =
    String(facilityData.twilioAuthorizedRepEndUserSid || '').trim() || null;
  let addressSid: string | null = String(facilityData.twilioAddressSid || '').trim() || null;
  let addressDocumentSid: string | null =
    String(facilityData.twilioAddressDocumentSid || '').trim() || null;

  const profileSkipped = Boolean(profile) && isBundleWithTwilio(profileStatus);
  let customerProfileEvaluation: EvaluationSummary;

  if (profileSkipped) {
    // Already submitted or approved. Writing to it would either be refused or
    // restart the review, and none of its contents are needed to fix the
    // product, so move straight on.
    functions.logger.info('A2P customer profile already with Twilio; building the trust product only', {
      facilityId: facilityRef.id,
      trustProfileSid,
      profileStatus,
    });
    customerProfileEvaluation = withTwilioSummary(profileStatus, profile?.policySid || customerProfilePolicySid);
  } else {
    // Built before any Twilio write, so a missing or partial EIN stops the
    // run before it leaves half a bundle behind.
    let businessInfoAttributes: Record<string, string>;
    try {
      businessInfoAttributes = buildBusinessInformationAttributes(input);
    } catch (error: any) {
      throw new functions.https.HttpsError('invalid-argument', String(error?.message || error));
    }

    if (!trustProfileSid) {
      const created = await twilio.trusthub.v1.customerProfiles.create({
        friendlyName: `SFC ${facilityRef.id} ${input.legalBusinessName}`.slice(0, 60),
        email: input.supportEmail,
        policySid: customerProfilePolicySid,
      });
      trustProfileSid = created.sid;
      profileStatus = lower(created.status) || 'draft';
    }

    businessInfoEndUserSid = await upsertEndUser(
      twilio,
      businessInfoEndUserSid ?? undefined,
      `SFC ${facilityRef.id} business info`.slice(0, 60),
      'customer_profile_business_information',
      businessInfoAttributes,
    );

    authorizedRepEndUserSid = await upsertEndUser(
      twilio,
      authorizedRepEndUserSid ?? undefined,
      `SFC ${facilityRef.id} authorized rep`.slice(0, 60),
      'authorized_representative_1',
      buildAuthorizedRepresentativeAttributes(input),
    );

    // ---- registered address + its supporting document ----
    const addressPayload = buildAddressPayload(input);
    if (addressSid) {
      try {
        await twilio.addresses(addressSid).update(addressPayload);
      } catch (error: any) {
        functions.logger.warn(
          `A2P address ${addressSid} could not be updated (${error?.message}); creating a replacement`,
        );
        addressSid = null;
      }
    }
    if (!addressSid) {
      const address = await twilio.addresses.create(addressPayload);
      addressSid = address.sid;
    }

    const documentAttributes = { address_sids: addressSid };
    if (addressDocumentSid) {
      try {
        await twilio.trusthub.v1
          .supportingDocuments(addressDocumentSid)
          .update({ attributes: documentAttributes });
      } catch (error: any) {
        functions.logger.warn(
          `A2P address document ${addressDocumentSid} could not be updated (${error?.message}); creating a replacement`,
        );
        addressDocumentSid = null;
      }
    }
    if (!addressDocumentSid) {
      const doc = await twilio.trusthub.v1.supportingDocuments.create({
        friendlyName: `SFC ${facilityRef.id} address`.slice(0, 60),
        type: 'customer_profile_address',
        attributes: documentAttributes,
      });
      addressDocumentSid = doc.sid;
    }

    // The secondary profile is only valid once it references the platform's
    // approved primary profile; without this the evaluation fails with
    // "Primary customer profile bundle is null".
    const primaryProfileSid = await resolvePrimaryCustomerProfileSid(twilio);

    const profileContext = twilio.trusthub.v1.customerProfiles(trustProfileSid);
    await reconcileAssignments(
      profileContext.customerProfilesEntityAssignments,
      [businessInfoEndUserSid, authorizedRepEndUserSid, addressDocumentSid, primaryProfileSid],
      trustProfileSid,
    );

    // Order matters. The A2P trust product's policy requires the secondary
    // customer profile to be "at least in review state", so the profile has
    // to be evaluated and submitted before the product is evaluated.
    customerProfileEvaluation = summarizeEvaluation(
      await profileContext.customerProfilesEvaluations.create({ policySid: customerProfilePolicySid }),
    );

    if (customerProfileEvaluation.compliant) {
      profileStatus = await submitBundleForReview(profileContext, 'business profile');
    }
  }

  // ---- A2P trust product ---------------------------------------------------
  let product = state.product;
  let replacedProductSid: string | undefined;
  if (product && BUNDLE_REPLACEABLE.has(product.status)) {
    const wrongPolicy = Boolean(product.policySid) && product.policySid !== trustProductPolicySid;
    // A fresh profile means the old product still points at the abandoned one.
    if (wrongPolicy || replacedProfileSid) {
      functions.logger.warn('A2P trust product cannot be reused; creating a fresh one', {
        facilityId: facilityRef.id,
        oldProductSid: product.sid,
        oldPolicySid: product.policySid,
        expectedPolicySid: trustProductPolicySid,
        reason: wrongPolicy ? 'wrong policy' : 'customer profile replaced',
      });
      // The old product is left in place, not deleted: it is harmless in
      // draft/rejected, and keeping it preserves its evaluation history.
      replacedProductSid = product.sid;
      product = null;
    }
  }

  let trustProductSid = product?.sid ?? '';
  let productStatus = product?.status ?? '';
  const a2pProfileAttributes = buildA2pMessagingProfileAttributes(input);
  let a2pProfileEndUserSid = String(facilityData.twilioA2pProfileEndUserSid || '').trim();
  let trustProductEvaluation: EvaluationSummary;

  if (product && productStatus === 'twilio-approved') {
    trustProductEvaluation = withTwilioSummary(productStatus, product.policySid || trustProductPolicySid);
  } else {
    if (!trustProductSid) {
      const created = await twilio.trusthub.v1.trustProducts.create({
        friendlyName: `SFC ${facilityRef.id} A2P`.slice(0, 60),
        email: input.supportEmail,
        policySid: trustProductPolicySid,
      });
      trustProductSid = created.sid;
      productStatus = lower(created.status) || 'draft';
    }

    a2pProfileEndUserSid = await upsertEndUser(
      twilio,
      a2pProfileEndUserSid || undefined,
      `SFC ${facilityRef.id} A2P profile`.slice(0, 60),
      'us_a2p_messaging_profile_information',
      a2pProfileAttributes,
    );

    // The trust product holds exactly two things: the secondary customer
    // profile and the A2P messaging end user.
    const productContext = twilio.trusthub.v1.trustProducts(trustProductSid);
    await reconcileAssignments(
      productContext.trustProductsEntityAssignments,
      [trustProfileSid, a2pProfileEndUserSid],
      trustProductSid,
    );

    if (isBundleWithTwilio(profileStatus)) {
      trustProductEvaluation = summarizeEvaluation(
        await productContext.trustProductsEvaluations.create({ policySid: trustProductPolicySid }),
      );
      if (trustProductEvaluation.compliant) {
        productStatus = await submitBundleForReview(productContext, 'A2P messaging profile');
      }
    } else {
      trustProductEvaluation = {
        compliant: false,
        status: 'blocked',
        failures: [
          {
            objectType: 'A2P messaging profile',
            field: 'business profile',
            reason: 'Cannot be checked until the business profile above passes and enters review.',
          },
        ],
        policySid: trustProductPolicySid,
      };
    }
  }

  const sids: TrustBundleSids = {
    trustProfileSid,
    trustProductSid,
    businessInfoEndUserSid,
    authorizedRepEndUserSid,
    a2pProfileEndUserSid,
    addressSid,
    addressDocumentSid,
  };

  // "Ready" means both bundles passed evaluation and are with Twilio. Brand
  // submission separately requires both to be twilio-approved.
  const readyForBrand = isBundleWithTwilio(profileStatus) && isBundleWithTwilio(productStatus);
  const approved = profileStatus === 'twilio-approved' && productStatus === 'twilio-approved';

  const issues = readyForBrand
    ? ''
    : [formatEvaluationFailures(customerProfileEvaluation), formatEvaluationFailures(trustProductEvaluation)]
        .filter(Boolean)
        .join(' | ');

  functions.logger.info('A2P bundle run complete', {
    facilityId: facilityRef.id,
    trustProfileSid,
    trustProductSid,
    profileStatus,
    productStatus,
    profileSkipped,
    replacedProductSid: replacedProductSid ?? null,
    replacedProfileSid: replacedProfileSid ?? null,
    customerProfilePolicySid,
    trustProductPolicySid,
    profileEvaluationSid: customerProfileEvaluation.evaluationSid ?? null,
    productEvaluationSid: trustProductEvaluation.evaluationSid ?? null,
  });

  // Persist SIDs, statuses and the evaluation verdicts. No EIN: `input.ein` is
  // used above and deliberately never written here.
  const update: Record<string, unknown> = {
    twilioTrustProfileSid: trustProfileSid,
    twilioTrustProductSid: trustProductSid,
    twilioA2pProfileEndUserSid: a2pProfileEndUserSid,
    a2pBundleProfilePolicySid: customerProfilePolicySid,
    a2pBundleProductPolicySid: trustProductPolicySid,
    a2pBundleProfileStatus: profileStatus,
    a2pBundleProductStatus: productStatus,
    a2pBundleReady: readyForBrand,
    a2pBundleApproved: approved,
    a2pBundleEvaluatedAt: admin.firestore.FieldValue.serverTimestamp(),
    a2pBundleStatusUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    a2pBundleIssues: issues ? issues : admin.firestore.FieldValue.delete(),
  };
  if (businessInfoEndUserSid) update.twilioBusinessInfoEndUserSid = businessInfoEndUserSid;
  if (authorizedRepEndUserSid) update.twilioAuthorizedRepEndUserSid = authorizedRepEndUserSid;
  if (addressSid) update.twilioAddressSid = addressSid;
  if (addressDocumentSid) update.twilioAddressDocumentSid = addressDocumentSid;
  const abandoned = [replacedProductSid, replacedProfileSid].filter(Boolean) as string[];
  if (abandoned.length) {
    update.a2pAbandonedBundleSids = admin.firestore.FieldValue.arrayUnion(...abandoned);
  }
  await facilityRef.set(update, { merge: true });

  return {
    sids,
    customerProfileEvaluation,
    trustProductEvaluation,
    profileStatus,
    productStatus,
    profileSkipped,
    ...(replacedProductSid ? { replacedProductSid } : {}),
    ...(replacedProfileSid ? { replacedProfileSid } : {}),
    readyForBrand,
    approved,
  };
}

/**
 * Hand one bundle to Twilio for review.
 *
 * Bundle review is free and is the step that turns a compliant draft into the
 * `twilio-approved` state brand registration requires. Without it a perfectly
 * valid bundle sits in `draft` forever and the owner never gets a brand.
 *
 * Only call this once evaluation is compliant: submitting a draft that fails
 * policy just gets it rejected and forces the owner to start over.
 */
async function submitBundleForReview(bundle: TrustHubBundleContext, label: string): Promise<string> {
  const current = await bundle.fetch();
  const status = lower(current.status);
  if (BUNDLE_WITH_TWILIO.has(status)) return status;
  try {
    const updated = await bundle.update({ status: 'pending-review' });
    return lower(updated.status) || 'pending-review';
  } catch (error: any) {
    throw new functions.https.HttpsError(
      'internal',
      `Could not submit the ${label} for Twilio review: ${error?.message}`,
    );
  }
}
