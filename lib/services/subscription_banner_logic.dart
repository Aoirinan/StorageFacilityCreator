/// Decides what the subscription warning banner should say.
///
/// Pure: takes plain values, returns a decision. The widget maps models to
/// these inputs; the tests exercise the rules directly.
///
/// Two subscription models coexist (see docs/PER_FACILITY_SUBSCRIPTION_DESIGN.md):
/// the legacy account-level subscription, and one subscription per facility.
/// Once an account has any per-facility subscription, the account-level
/// fields are legacy leftovers and must not drive warnings. The bug this
/// replaces showed "Your trial has expired" for an owner whose facility was
/// mid-trial, because the account record's old trial had lapsed.
class FacilitySubscriptionState {
  final String name;

  /// True when the facility has its own Stripe platform subscription.
  final bool perFacility;

  /// active | trialing | past_due | cancelled | unpaid | incomplete_expired | null
  final String? status;
  final DateTime? trialEnd;

  const FacilitySubscriptionState({
    required this.name,
    required this.perFacility,
    this.status,
    this.trialEnd,
  });

  bool trialEndedBy(DateTime now) =>
      status == 'trialing' && trialEnd != null && !trialEnd!.isAfter(now);

  bool healthyAt(DateTime now) =>
      status == 'active' || (status == 'trialing' && !trialEndedBy(now));
}

class AccountSubscriptionState {
  /// active | pastDue | cancelled | trialing | incomplete | incompleteExpired | unpaid | pendingApproval | null
  final String? status;
  final DateTime? trialEnd;
  final DateTime? currentPeriodEnd;

  const AccountSubscriptionState({this.status, this.trialEnd, this.currentPeriodEnd});

  bool get hasTrial => status == 'trialing';

  /// True once a granted trial has run out and nothing has replaced it.
  ///
  /// Deliberately not tied to `status == 'trialing'`. A locally granted trial
  /// has no Stripe subscription behind it, so the nightly sweep moves the
  /// account to `cancelled` when the date passes. Keying off the status alone
  /// meant the "your trial has expired" banner vanished at exactly the moment
  /// the operator lost access and most needed to be told why.
  bool trialExpiredAt(DateTime now) =>
      trialEnd != null &&
      now.isAfter(trialEnd!) &&
      (status == 'trialing' || status == 'cancelled');
  bool get isActive => status == 'active' || status == 'trialing';
}

class SubscriptionBannerDecision {
  final bool show;
  final String? message;

  /// Critical banners are not dismissible.
  final bool critical;

  const SubscriptionBannerDecision.none()
      : show = false,
        message = null,
        critical = false;

  const SubscriptionBannerDecision.warn(this.message, {required this.critical}) : show = true;
}

SubscriptionBannerDecision decideSubscriptionBanner({
  required AccountSubscriptionState? account,
  required List<FacilitySubscriptionState> facilities,
  required DateTime now,
}) {
  if (account == null) return const SubscriptionBannerDecision.none();

  final perFacility = facilities.where((f) => f.perFacility).toList();
  if (perFacility.isNotEmpty) {
    return _decideFromFacilities(perFacility, now);
  }
  return _decideFromAccount(account, now);
}

SubscriptionBannerDecision _decideFromFacilities(List<FacilitySubscriptionState> facilities, DateTime now) {
  final unhealthy = facilities.where((f) => !f.healthyAt(now)).toList();
  if (unhealthy.isEmpty) return const SubscriptionBannerDecision.none();

  final first = unhealthy.first;
  final others = unhealthy.length - 1;
  final suffix = others == 0 ? '' : ' and $others other ${others == 1 ? 'facility' : 'facilities'}';
  final who = '${first.name}$suffix';

  String message;
  switch (first.status) {
    case 'trialing':
      message = 'The trial for $who has ended. Subscribe to keep using it.';
      break;
    case 'past_due':
      message = 'The subscription payment for $who is past due. Update payment to keep access.';
      break;
    case 'cancelled':
      message = 'The subscription for $who was cancelled. Resubscribe to keep using it.';
      break;
    default:
      message = 'Subscribe to keep using $who.';
  }
  return SubscriptionBannerDecision.warn(message, critical: true);
}

SubscriptionBannerDecision _decideFromAccount(AccountSubscriptionState account, DateTime now) {
  // Past due first: an operator who trialled, subscribed, then missed a payment
  // still has a trial end date in the past, and the billing problem is the more
  // useful thing to tell them about.
  if (account.status == 'pastDue') {
    return const SubscriptionBannerDecision.warn(
      'Your subscription payment is past due. Please renew your subscription to continue.',
      critical: true,
    );
  }
  if (account.trialExpiredAt(now)) {
    return const SubscriptionBannerDecision.warn(
      'Your trial has expired. Please subscribe to continue using the app.',
      critical: true,
    );
  }
  if (account.status == 'cancelled' &&
      account.currentPeriodEnd != null &&
      now.isBefore(account.currentPeriodEnd!)) {
    final endDate = account.currentPeriodEnd!.toString().split(' ')[0];
    return SubscriptionBannerDecision.warn(
      'Your subscription has been cancelled. You have access until $endDate.',
      critical: false,
    );
  }
  if (!account.isActive && !account.hasTrial) {
    return const SubscriptionBannerDecision.warn(
      'Please subscribe to continue using the app.',
      critical: true,
    );
  }
  return const SubscriptionBannerDecision.none();
}
