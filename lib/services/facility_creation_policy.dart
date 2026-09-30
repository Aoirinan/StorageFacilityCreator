import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/paid_subscription.dart';

/// Which billing model governs whether an owner may add another facility.
///
/// Legacy accounts carry one subscription on the account record, and the
/// account's trial or status decides how many facilities they may create.
/// Per-facility accounts (docs/PER_FACILITY_SUBSCRIPTION_DESIGN.md) subscribe
/// each facility separately right after it is created, so the account-level
/// fields are leftovers and must not block creation. The bug this replaces
/// told a per-facility owner "Your trial has expired" when adding a second
/// facility, because the account record's old trial had lapsed.
bool usesPerFacilityBilling(Iterable<String?> platformSubscriptionIds) {
  return platformSubscriptionIds.any((id) => (id ?? '').trim().isNotEmpty);
}

/// What the facility creation wizard does before it creates another facility
/// for an owner who already has at least one.
enum WizardAddFacilityCheck {
  /// The unpaid app trial: limited to one facility.
  trialLimit,

  /// No subscription: subscribe first.
  subscriptionRequired,

  /// Subscribed: confirm the added $75/month before creating it.
  confirmAddedCharge,
}

/// [WizardAddFacilityCheck] for [account] and the owner's [facilities].
///
/// A card-backed subscription, on the account or on a facility linked to it,
/// counts as subscribed through its free month, like `active`
/// ([ownerHasPaidOrCardTrialSubscription]); the account can then still read
/// `trialing`, so the trial limit applies only to the unpaid app trial.
WizardAddFacilityCheck wizardAddFacilityCheck(
  FacilityCreatorAccountModel account,
  Iterable<FacilityModel> facilities,
) {
  final subscribed = ownerHasPaidOrCardTrialSubscription(account, facilities);
  if (account.hasTrial && !subscribed) return WizardAddFacilityCheck.trialLimit;
  if (!subscribed) return WizardAddFacilityCheck.subscriptionRequired;
  return WizardAddFacilityCheck.confirmAddedCharge;
}
