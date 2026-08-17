/**
 * Builds the TrustHub bundles A2P 10DLC brand registration requires.
 *
 * Before this existed the onboarding flow created a customer profile and trust
 * product carrying only a friendlyName and email — empty shells — and then
 * submitted a brand against them. That can never be approved: the carrier needs
 * the legal entity, its EIN, its registered address and a named authorized
 * representative, none of which were ever sent.
 *
 * Two rules shape everything here:
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

/** SIDs of the TrustHub resources that make up a facility's A2P bundle. */
export interface TrustBundleSids {
  trustProfileSid: string;
  trustProductSid: string;
  businessInfoEndUserSid: string;
  authorizedRepEndUserSid: string;
  a2pProfileEndUserSid: string;
  addressSid: string;
  addressDocumentSid: string;
}

export interface BundleBuildResult {
  sids: TrustBundleSids;
  customerProfileEvaluation: EvaluationSummary;
  trustProductEvaluation: EvaluationSummary;
  /** True only when both bundles pass; brand submission is gated on this. */
  readyForBrand: boolean;
}

/**
 * Create an end user, or update the existing one in place.
 *
 * Updating matters: end users are assigned to the profile by SID, so replacing
 * one on every save would leave the profile pointing at a stale record while
 * orphaned end users accumulate on the account.
 */
async function upsertEndUser(
  twilio: any,
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
 * Assign an object to a bundle, treating "already assigned" as success.
 *
 * Re-running the build must be safe, and Twilio rejects a duplicate assignment
 * rather than ignoring it.
 */
async function ensureAssignment(
  assignmentList: any,
  objectSid: string,
  bundleSid: string,
): Promise<void> {
  const existing = await assignmentList.list({ limit: 100 });
  if (existing.some((a: any) => a.objectSid === objectSid)) return;
  try {
    await assignmentList.create({ objectSid });
  } catch (error: any) {
    const message = String(error?.message || '');
    if (/already/i.test(message)) return;
    throw new functions.https.HttpsError(
      'internal',
      `Could not attach ${objectSid} to ${bundleSid}: ${message}`,
    );
  }
}

/**
 * Build (or refresh) the customer profile and A2P trust product for a facility
 * and evaluate both against their carrier policies.
 *
 * Returns the evaluation verdicts instead of throwing on a non-compliant
 * bundle: the caller stores them so the owner can be shown exactly which field
 * the carrier policy rejected.
 */
export async function buildAndEvaluateTrustBundle(
  twilio: any,
  facilityRef: admin.firestore.DocumentReference,
  facilityData: Record<string, any>,
  input: TrustBundleInput,
  policySids: { customerProfilePolicySid: string; trustProductPolicySid: string },
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

  // ---- customer profile shell ----
  let trustProfileSid = (facilityData.twilioTrustProfileSid as string | undefined)?.trim();
  if (!trustProfileSid) {
    const profile = await twilio.trusthub.v1.customerProfiles.create({
      friendlyName: `SFC ${facilityRef.id} ${input.legalBusinessName}`.slice(0, 60),
      email: input.supportEmail,
      policySid: customerProfilePolicySid,
    });
    trustProfileSid = profile.sid as string;
  }

  // ---- business information + authorized representative ----
  const businessInfoEndUserSid = await upsertEndUser(
    twilio,
    facilityData.twilioBusinessInfoEndUserSid,
    `SFC ${facilityRef.id} business info`.slice(0, 60),
    'customer_profile_business_information',
    buildBusinessInformationAttributes(input),
  );

  const authorizedRepEndUserSid = await upsertEndUser(
    twilio,
    facilityData.twilioAuthorizedRepEndUserSid,
    `SFC ${facilityRef.id} authorized rep`.slice(0, 60),
    'authorized_representative_1',
    buildAuthorizedRepresentativeAttributes(input),
  );

  // ---- registered address + its supporting document ----
  // Addresses are immutable enough in practice that updating in place is
  // simplest, but a missing/deleted one must not wedge onboarding.
  const addressPayload = buildAddressPayload(input);
  let addressSid = (facilityData.twilioAddressSid as string | undefined)?.trim();
  if (addressSid) {
    try {
      await twilio.addresses(addressSid).update(addressPayload);
    } catch (error: any) {
      functions.logger.warn(
        `A2P address ${addressSid} could not be updated (${error?.message}); creating a replacement`,
      );
      addressSid = undefined;
    }
  }
  if (!addressSid) {
    const address = await twilio.addresses.create(addressPayload);
    addressSid = address.sid as string;
  }

  let addressDocumentSid = (facilityData.twilioAddressDocumentSid as string | undefined)?.trim();
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
      addressDocumentSid = undefined;
    }
  }
  if (!addressDocumentSid) {
    const doc = await twilio.trusthub.v1.supportingDocuments.create({
      friendlyName: `SFC ${facilityRef.id} address`.slice(0, 60),
      type: 'customer_profile_address',
      attributes: documentAttributes,
    });
    addressDocumentSid = doc.sid as string;
  }

  const profileAssignments = twilio.trusthub.v1.customerProfiles(trustProfileSid)
    .customerProfilesEntityAssignments;
  for (const objectSid of [businessInfoEndUserSid, authorizedRepEndUserSid, addressDocumentSid]) {
    await ensureAssignment(profileAssignments, objectSid, trustProfileSid);
  }

  // ---- A2P trust product ----
  let trustProductSid = (facilityData.twilioTrustProductSid as string | undefined)?.trim();
  if (!trustProductSid) {
    const product = await twilio.trusthub.v1.trustProducts.create({
      friendlyName: `SFC ${facilityRef.id} A2P`.slice(0, 60),
      email: input.supportEmail,
      policySid: trustProductPolicySid,
    });
    trustProductSid = product.sid as string;
  }

  const a2pProfileEndUserSid = await upsertEndUser(
    twilio,
    facilityData.twilioA2pProfileEndUserSid,
    `SFC ${facilityRef.id} A2P profile`.slice(0, 60),
    'us_a2p_messaging_profile_information',
    buildA2pMessagingProfileAttributes(input),
  );

  const productAssignments = twilio.trusthub.v1.trustProducts(trustProductSid)
    .trustProductsEntityAssignments;
  // The trust product references the customer profile itself, plus the A2P
  // messaging end user.
  for (const objectSid of [trustProfileSid, a2pProfileEndUserSid]) {
    await ensureAssignment(productAssignments, objectSid, trustProductSid);
  }

  // ---- evaluate both bundles (free) ----
  const customerProfileEvaluation = summarizeEvaluation(
    await twilio.trusthub.v1
      .customerProfiles(trustProfileSid)
      .customerProfilesEvaluations.create({ policySid: customerProfilePolicySid }),
  );
  const trustProductEvaluation = summarizeEvaluation(
    await twilio.trusthub.v1
      .trustProducts(trustProductSid)
      .trustProductsEvaluations.create({ policySid: trustProductPolicySid }),
  );

  const sids: TrustBundleSids = {
    trustProfileSid,
    trustProductSid,
    businessInfoEndUserSid,
    authorizedRepEndUserSid,
    a2pProfileEndUserSid,
    addressSid,
    addressDocumentSid,
  };

  const readyForBrand = customerProfileEvaluation.compliant && trustProductEvaluation.compliant;

  // Persist SIDs and the evaluation verdicts. No EIN: `input.ein` is used above
  // and deliberately never written here.
  await facilityRef.set(
    {
      twilioTrustProfileSid: sids.trustProfileSid,
      twilioTrustProductSid: sids.trustProductSid,
      twilioBusinessInfoEndUserSid: sids.businessInfoEndUserSid,
      twilioAuthorizedRepEndUserSid: sids.authorizedRepEndUserSid,
      twilioA2pProfileEndUserSid: sids.a2pProfileEndUserSid,
      twilioAddressSid: sids.addressSid,
      twilioAddressDocumentSid: sids.addressDocumentSid,
      a2pBundleReady: readyForBrand,
      a2pBundleEvaluatedAt: admin.firestore.FieldValue.serverTimestamp(),
      a2pBundleIssues: readyForBrand
        ? admin.firestore.FieldValue.delete()
        : [
            formatEvaluationFailures(customerProfileEvaluation),
            formatEvaluationFailures(trustProductEvaluation),
          ]
            .filter(Boolean)
            .join(' | '),
    },
    { merge: true },
  );

  return { sids, customerProfileEvaluation, trustProductEvaluation, readyForBrand };
}

/** Bundle statuses that mean review is already done or under way. */
const BUNDLE_REVIEW_IN_FLIGHT = new Set(['pending-review', 'in-review', 'twilio-approved']);

/**
 * Hand both bundles to Twilio for review.
 *
 * Bundle review is free and is the step that turns a compliant draft into the
 * `twilio-approved` state that brand registration requires. Without it a
 * perfectly valid bundle sits in `draft` forever and the owner never gets a
 * brand — which is exactly the state every existing facility is in.
 *
 * Only call this once evaluation is compliant: submitting a draft that fails
 * policy just gets it rejected and forces the owner to start over.
 */
export async function submitBundlesForReview(
  twilio: any,
  sids: Pick<TrustBundleSids, 'trustProfileSid' | 'trustProductSid'>,
): Promise<{ profileStatus: string; productStatus: string }> {
  const submit = async (fetchUpdate: any, label: string): Promise<string> => {
    const current = await fetchUpdate.fetch();
    const status = String(current.status || '').toLowerCase();
    if (BUNDLE_REVIEW_IN_FLIGHT.has(status)) return status;
    try {
      const updated = await fetchUpdate.update({ status: 'pending-review' });
      return String(updated.status || 'pending-review').toLowerCase();
    } catch (error: any) {
      throw new functions.https.HttpsError(
        'internal',
        `Could not submit the ${label} for Twilio review: ${error?.message}`,
      );
    }
  };

  const profileStatus = await submit(
    twilio.trusthub.v1.customerProfiles(sids.trustProfileSid),
    'business profile',
  );
  const productStatus = await submit(
    twilio.trusthub.v1.trustProducts(sids.trustProductSid),
    'A2P messaging profile',
  );

  return { profileStatus, productStatus };
}
