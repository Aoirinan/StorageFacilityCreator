import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';

/// Whether a platform subscription counts as paid for: `active`, or
/// `trialing` with a Stripe subscription behind it.
///
/// The first free month is Stripe trial time (functions-shared
/// `stripe/platformCheckoutTrial.ts`), so an owner who subscribes with a card
/// reads `trialing` for up to two months before the first charge. Every
/// entitlement and every screen treats that subscription exactly like
/// `active`: it never "expires" at a trial end date, and nothing tells the
/// owner their trial ended or asks them to subscribe.
///
/// The unpaid app trial also reads `trialing`: `startTrial` and the super
/// admin approve/grant actions write it with no Stripe subscription id. That
/// one keeps its trial limits and still ends at `subscriptionTrialEnd`.
///
/// [status] is an account's `subscriptionStatus` or a facility's
/// `platformSubscriptionStatus`; [stripeSubscriptionId] is the account's
/// `stripeSubscriptionId` or the facility's `stripePlatformSubscriptionId`.
/// Same rule as `hasPaidOrCardTrialSubscription` in functions-shared
/// (`src/subscription/paidSubscription.ts`) and the DNR rules.
bool hasPaidOrCardTrialSubscription({
  required String? status,
  required String? stripeSubscriptionId,
}) {
  if (status == 'active') return true;
  return status == 'trialing' && (stripeSubscriptionId ?? '').trim().isNotEmpty;
}

/// Whether the owner of [account] is subscribed: through the account's own
/// subscription ([FacilityCreatorAccountModel.hasActiveSubscription]), or
/// through a per-facility subscription on any facility in [facilities] that is
/// linked to the account ([FacilityModel.facilityCreatorAccountId]).
///
/// Under per-facility billing the account's status is a rollup of its
/// facilities and the account has no Stripe subscription id. During a
/// facility's free month the account therefore reads `trialing` with the app
/// trial's end date, and only the facility shows that there is a card. Checks
/// that read the account alone would call that owner a lapsed trial.
bool ownerHasPaidOrCardTrialSubscription(
  FacilityCreatorAccountModel? account,
  Iterable<FacilityModel> facilities,
) {
  if (account == null) return false;
  if (account.hasActiveSubscription) return true;
  return facilities.any((f) =>
      f.facilityCreatorAccountId == account.accountId &&
      f.hasPaidOrCardTrialPlatformSubscription);
}

/// The owner of [account] is on the unpaid app trial: the account reads
/// `trialing` ([FacilityCreatorAccountModel.hasTrial]) and there is no paid or
/// card-backed subscription on it or on its facilities in [facilities]. This
/// is who the trial limits (one facility, the trial email cap, no DNR) apply to.
bool ownerOnUnpaidAppTrial(
  FacilityCreatorAccountModel? account,
  Iterable<FacilityModel> facilities,
) {
  if (account == null || !account.hasTrial) return false;
  return !ownerHasPaidOrCardTrialSubscription(account, facilities);
}
