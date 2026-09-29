import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/paid_subscription.dart';

/// What the subscription screen says about trials, for an account and the
/// owner's facilities.
///
/// An owner who subscribed with a card, on the account or on a facility, is
/// paid for, like `active`, through the free month before the first charge
/// ([ownerHasPaidOrCardTrialSubscription]). They get no trial countdown, no
/// "Trial expired" line or dialog, and the account is shown as active; a
/// card-backed trial on the account shows the date of the first charge
/// instead. The unpaid app trial keeps every trial notice.
class SubscriptionTrialNotice {
  /// The owner is subscribed with a card (or paying).
  final bool ownerSubscribed;

  /// The status chip.
  final SubscriptionStatus displayStatus;

  /// Whether the account's own "Until `<period end>`" line applies. Not when the
  /// account reads `trialing` only as the rollup of a facility's free month:
  /// its period dates are then the app trial's, not billing's.
  final bool showAccountPeriod;

  /// "First charge `<date>`": the Stripe trial end of a card-backed trial on
  /// the account. Null otherwise.
  final DateTime? firstCharge;

  /// "Trial: N days left".
  final bool showTrialDaysLeft;

  /// "Trial expired. Subscribe to continue."
  final bool showTrialExpired;

  /// "Trial ends in N days."
  final bool showTrialEndingSoon;

  const SubscriptionTrialNotice._({
    required this.ownerSubscribed,
    required this.displayStatus,
    required this.showAccountPeriod,
    required this.firstCharge,
    required this.showTrialDaysLeft,
    required this.showTrialExpired,
    required this.showTrialEndingSoon,
  });

  factory SubscriptionTrialNotice.of(
    FacilityCreatorAccountModel account,
    Iterable<FacilityModel> facilities,
  ) {
    final subscribed = ownerHasPaidOrCardTrialSubscription(account, facilities);
    final trialing = account.subscriptionStatus == SubscriptionStatus.trialing;
    final appTrialNotices = account.hasTrial && !subscribed;
    return SubscriptionTrialNotice._(
      ownerSubscribed: subscribed,
      displayStatus: trialing && subscribed
          ? SubscriptionStatus.active
          : account.subscriptionStatus,
      showAccountPeriod:
          !(trialing && subscribed && !account.hasCardBackedTrial),
      firstCharge: account.hasCardBackedTrial ? account.subscriptionTrialEnd : null,
      showTrialDaysLeft: appTrialNotices &&
          account.daysUntilTrialExpiration != null &&
          !account.isTrialExpired,
      showTrialExpired: appTrialNotices && account.isTrialExpired,
      showTrialEndingSoon: appTrialNotices &&
          !account.isTrialExpired &&
          account.isTrialExpiringSoon,
    );
  }

  /// Whether the screen opens with the trial-expired dialog.
  /// [redirectedForExpiredTrial] is the route guard's `?trialExpired=1`.
  bool showTrialExpiredDialog({required bool redirectedForExpiredTrial}) =>
      !ownerSubscribed && (redirectedForExpiredTrial || showTrialExpired);

  /// The first charge of a facility's card-backed free month (its Stripe
  /// trial end), shown on its plan line instead of the raw `trialing`. Null
  /// for any other facility.
  static DateTime? facilityFirstCharge(FacilityModel facility) {
    if (facility.platformSubscriptionStatus != 'trialing') return null;
    if (!facility.hasPaidOrCardTrialPlatformSubscription) return null;
    return facility.platformSubscriptionTrialEnd;
  }
}
