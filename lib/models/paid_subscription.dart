import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';

/// How long past its recorded trial end a card-backed trial still counts as
/// paid: the webhook that moves it to `active` (or `pastDue`) can lag the
/// trial end. Same value as `CARD_TRIAL_GRACE_MS` in functions-shared and
/// `duration.value(3, 'd')` in the rules.
const Duration cardTrialGrace = Duration(days: 3);

/// Whether a platform subscription counts as paid for: `active`, or
/// `trialing` with a Stripe subscription behind it whose [trialEnd], plus
/// [cardTrialGrace], is still ahead of [now] (default: the current time).
///
/// The first free month is Stripe trial time (functions-shared
/// `stripe/platformCheckoutTrial.ts`), so an owner who subscribes with a card
/// reads `trialing` for up to two months before the first charge. Every
/// entitlement and every screen treats that subscription like `active` until
/// the trial end: nothing tells the owner their trial ended or asks them to
/// subscribe. At the trial end Stripe charges and the webhook moves the status
/// on; a `trialing` record with a subscription id whose trial end is long
/// past, or missing, is stale and does not count.
///
/// The unpaid app trial also reads `trialing`: `startTrial` and the super
/// admin approve/grant actions write it with no Stripe subscription id. That
/// one keeps its trial limits and still ends at `subscriptionTrialEnd`.
///
/// [status] is an account's `subscriptionStatus` or a facility's
/// `platformSubscriptionStatus`; [stripeSubscriptionId] is the account's
/// `stripeSubscriptionId` or the facility's `stripePlatformSubscriptionId`;
/// [trialEnd] is the account's `subscriptionTrialEnd` or the facility's
/// `platformSubscriptionTrialEnd`. Same rule as
/// `hasPaidOrCardTrialSubscription` in functions-shared
/// (`src/subscription/paidSubscription.ts`) and the DNR rules.
bool hasPaidOrCardTrialSubscription({
  required String? status,
  required String? stripeSubscriptionId,
  required DateTime? trialEnd,
  DateTime? now,
}) {
  if (status == 'active') return true;
  if (status != 'trialing') return false;
  if ((stripeSubscriptionId ?? '').trim().isEmpty) return false;
  if (trialEnd == null) return false;
  return (now ?? DateTime.now()).isBefore(trialEnd.add(cardTrialGrace));
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
