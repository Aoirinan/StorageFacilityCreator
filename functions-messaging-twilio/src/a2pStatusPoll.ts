import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  buildA2PRejectionReason,
  computeA2PStatus,
  type A2PStatus,
} from '@sfc/functions-shared';
import { getA2PTwilioClient, isTwilioDryRunEnabled } from './twilioClient';
import { TWILIO_SECRETS } from './secrets';
import { fetchTrustBundleState } from './a2pTrustBundle';
import {
  campaignFilingFields,
  fetchUsAppToPersonCampaign,
  fileCampaignWhenBrandApproved,
  prepareCampaignSamples,
} from './a2pCampaign';
import type { A2PTwilioClient } from './a2pTwilioTypes';

/**
 * Poll Twilio for A2P brand/campaign outcomes.
 *
 * Status was previously only refreshed by `refreshTextingOnboardingStatus`,
 * an onCall triggered by a button in the operator UI. Carrier review takes days
 * and the result arrives by email to whoever owns the Twilio account — so
 * unless a facility owner happened to open the texting page and press refresh,
 * a rejection never reached the product at all. Keepsake sat on a2pStatus
 * 'draft' with a null rejection reason for months while its campaign had
 * actually failed.
 *
 * Runs hourly: carrier review is measured in days, so this is purely about not
 * needing a human to poll.
 */
/**
 * Refresh the TrustHub bundle review state for facilities waiting on it.
 *
 * Records the outcome on the facility so the UI can tell the owner whether the
 * profile is still with Twilio, approved and ready for brand registration, or
 * rejected and in need of corrections. Skips facilities that already have a
 * brand, since the bundle stage is behind them.
 *
 * Every facility with a customer profile is checked, not only those whose
 * bundle was marked ready: a facility whose profile passed but whose A2P trust
 * product failed evaluation was never marked ready, so the profile's own
 * review outcome never reached the page or the form lock.
 *
 * Returns how many facilities were checked.
 */
async function pollTrustBundleReviews(
  twilio: A2PTwilioClient,
  docs: admin.firestore.QueryDocumentSnapshot[],
): Promise<number> {
  let checked = 0;

  for (const doc of docs) {
    const data = doc.data();
    if (data.twilioBrandSid) continue;
    const profileSid = (data.twilioTrustProfileSid as string | undefined)?.trim();
    if (!profileSid) continue;

    try {
      const { profile, product } = await fetchTrustBundleState(twilio, data);
      checked += 1;

      const profileStatus = profile?.status ?? '';
      const productStatus = product?.status ?? '';
      if (
        profileStatus === (data.a2pBundleProfileStatus ?? '') &&
        productStatus === (data.a2pBundleProductStatus ?? '')
      ) {
        continue;
      }

      const approved = profileStatus === 'twilio-approved' && productStatus === 'twilio-approved';
      const rejected = profileStatus === 'twilio-rejected' || productStatus === 'twilio-rejected';

      await doc.ref.set(
        {
          a2pBundleProfileStatus: profileStatus,
          a2pBundleProductStatus: productStatus,
          a2pBundleApproved: approved,
          ...(product?.policySid ? { a2pBundleProductPolicySid: product.policySid } : {}),
          // A rejected bundle has to be rebuilt before anything else can
          // happen, so clear the ready flag that gates brand submission.
          ...(rejected ? { a2pBundleReady: false } : {}),
          a2pBundleStatusUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      functions.logger.info(
        `A2P poll: facility ${doc.id} bundle profile=${profileStatus} product=${productStatus}`,
      );
    } catch (error: any) {
      functions.logger.error(`A2P poll: bundle check failed for facility ${doc.id}:`, error);
    }
  }

  return checked;
}

export const pollA2PRegistrationStatus = functions
  .runWith({ secrets: TWILIO_SECRETS, timeoutSeconds: 540, memory: '256MB' })
  .pubsub.schedule('15 * * * *')
  .timeZone('UTC')
  .onRun(async () => {
    if (isTwilioDryRunEnabled()) {
      functions.logger.info('Twilio dry-run enabled; skipping A2P status poll');
      return null;
    }

    // Only facilities mid-review. Approved and draft facilities have nothing
    // pending, so polling them would waste Twilio API calls every hour.
    const snapshot = await admin
      .firestore()
      .collection('facilities')
      .where('a2pStatus', 'in', ['submitted', 'pending'])
      .get();

    const twilio = getA2PTwilioClient();

    // Facilities whose TrustHub bundle is with Twilio but whose brand has not
    // been submitted yet sit at a2pStatus 'draft', so the query above misses
    // them entirely. Bundle review is the step before brand registration and
    // takes about a business day; without this the owner has no way to learn it
    // finished short of opening the page and pressing refresh. Any facility
    // with a profile SID qualifies (the brand filter is applied per document).
    const awaitingBundle = await admin
      .firestore()
      .collection('facilities')
      .where('twilioTrustProfileSid', '>', '')
      .get();
    const bundleChecked = await pollTrustBundleReviews(twilio, awaitingBundle.docs);

    if (snapshot.empty) {
      functions.logger.info(
        `A2P poll: no facilities awaiting registration (${bundleChecked} bundle review(s) checked)`,
      );
      return null;
    }

    functions.logger.info(`A2P poll: checking ${snapshot.size} facility registration(s)`);
    let changed = 0;

    for (const doc of snapshot.docs) {
      const facilityData = doc.data();
      try {
        let brandStatus: string | undefined;
        let campaignStatus: string | undefined;
        let brandErrors: unknown;
        let brandFailureReason: unknown;
        let campaignErrors: unknown;

        if (facilityData.twilioBrandSid) {
          const brand = await twilio.messaging.v1
            .brandRegistrations(facilityData.twilioBrandSid)
            .fetch();
          brandStatus = brand.status;
          brandErrors = brand.errors;
          brandFailureReason = brand.failureReason;
        }
        if (facilityData.twilioCampaignSid && facilityData.twilioMessagingServiceSid) {
          // Campaigns live under the messaging service (usAppToPerson); there
          // is no top-level campaigns resource in the SDK.
          const campaign = await fetchUsAppToPersonCampaign(
            twilio,
            String(facilityData.twilioMessagingServiceSid),
            String(facilityData.twilioCampaignSid),
          );
          campaignStatus = campaign?.campaignStatus;
          campaignErrors = campaign?.errors;
        } else if (
          facilityData.a2pCampaignPending === true &&
          String(brandStatus || '').toUpperCase() === 'APPROVED' &&
          facilityData.twilioMessagingServiceSid
        ) {
          // The owner submitted while the brand was still in review; file the
          // campaign they asked for now that the brand has cleared.
          const samples = Array.isArray(facilityData.textingSampleMessages)
            ? (facilityData.textingSampleMessages as string[])
            : [];
          const filing = await fileCampaignWhenBrandApproved(
            twilio,
            facilityData,
            prepareCampaignSamples(facilityData, samples),
          );
          await doc.ref.set(
            {
              ...campaignFilingFields(filing),
              a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
          campaignStatus = filing.campaignStatus ?? undefined;
          functions.logger.info(`A2P poll: facility ${doc.id} deferred campaign filed=${filing.filed}`);
        }

        const current = ((facilityData.a2pStatus as string) || 'draft') as A2PStatus;
        const next = computeA2PStatus(current, brandStatus, campaignStatus);
        if (next === current) continue;

        const update: Record<string, any> = {
          a2pStatus: next,
          a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
          a2pLastError: null,
          a2pRejectionReason:
            next === 'rejected'
              ? (buildA2PRejectionReason({
                  campaignErrors,
                  brandErrors,
                  brandFailureReason,
                  campaignStatus,
                  brandStatus,
                }) ?? 'Rejected by Twilio')
              : null,
          ...(next !== 'approved'
            ? {
                textingPlatformApproved: false,
                textingPlatformApprovedAt: null,
                textingPlatformApprovedBy: null,
              }
            : {}),
        };
        if (next === 'approved') {
          update.a2pApprovedAt = admin.firestore.FieldValue.serverTimestamp();
        }
        if (next === 'rejected') {
          update.a2pRejectedAt = admin.firestore.FieldValue.serverTimestamp();
        }

        await doc.ref.set(update, { merge: true });
        changed += 1;
        functions.logger.info(
          `A2P poll: facility ${doc.id} ${current} -> ${next}` +
            (next === 'rejected' ? ` (${update.a2pRejectionReason})` : ''),
        );
      } catch (error: any) {
        // One facility's Twilio error must not stop the rest of the sweep.
        functions.logger.error(`A2P poll failed for facility ${doc.id}:`, error);
      }
    }

    functions.logger.info(`A2P poll complete: ${changed} facility status change(s)`);
    return null;
  });
