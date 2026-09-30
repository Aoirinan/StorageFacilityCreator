/// Account fields for the super-admin "revoke trial" action.
///
/// Revoking clears `subscriptionTrialEnd`, which was the only record of the trial
/// for accounts granted one before `platformTrialUsedAt` existed. Checkout reads
/// that marker (functions-shared `platformCheckoutTrial.ts`) so an owner never gets
/// a second trial; without it a revoked trial would reopen a fresh 30-day one.
/// The marker is only written when missing, so the first-use time is kept.
///
/// [stamp] is the value to write for the marker and `updatedAt`
/// (`FieldValue.serverTimestamp()` in production).
Map<String, dynamic> revokeTrialFields(
  Map<String, dynamic>? current, {
  required Object stamp,
}) {
  final fields = <String, dynamic>{
    'subscriptionStatus': 'cancelled',
    'subscriptionTrialEnd': null,
    'subscriptionCurrentPeriodEnd': null,
    'updatedAt': stamp,
  };
  if (current?['platformTrialUsedAt'] == null) {
    fields['platformTrialUsedAt'] = stamp;
  }
  return fields;
}

/// Account fields for the super-admin suspend / unsuspend action.
///
/// Suspending cancels the account and deletes `subscriptionTrialEnd` and
/// `subscriptionCurrentPeriodEnd`. For an account whose trial predates
/// `platformTrialUsedAt`, that trial end was the only record of the trial, so
/// (like [revokeTrialFields]) the marker is written when a trial is being
/// cleared and the marker is missing. Without it an account suspended and then
/// unsuspended looked brand new at checkout and got a fresh trial plus the
/// free month (now + 60 days).
///
/// [stamp] is the value for the timestamps (`FieldValue.serverTimestamp()` in
/// production) and [deleteValue] the one that removes a field
/// (`FieldValue.delete()`).
Map<String, dynamic> accountSuspensionFields(
  Map<String, dynamic>? current, {
  required bool suspended,
  String? reason,
  required String actorUid,
  required String actorEmail,
  required Object stamp,
  required Object deleteValue,
}) {
  final fields = <String, dynamic>{
    'suspended': suspended,
    'updatedAt': stamp,
    'suspendedByUid': suspended ? actorUid : null,
    'suspendedByEmail': suspended ? actorEmail : null,
    'suspendedAt': suspended ? stamp : null,
    'suspensionReason': suspended ? reason : null,
  };
  if (suspended) {
    fields['subscriptionStatus'] = 'cancelled';
    fields['subscriptionCurrentPeriodEnd'] = deleteValue;
    fields['subscriptionTrialEnd'] = deleteValue;
    final hadTrial = current?['subscriptionTrialEnd'] != null ||
        current?['subscriptionStatus'] == 'trialing';
    if (hadTrial && current?['platformTrialUsedAt'] == null) {
      fields['platformTrialUsedAt'] = stamp;
    }
  }
  return fields;
}

/// Shown when a super admin tries to grant, approve or extend the app trial
/// on an account that has a Stripe subscription id.
const String adminAppTrialStripeSubscriptionMessage =
    'This account has a Stripe subscription, so an app trial cannot be '
    'granted, approved or extended on it: its trial and billing come from '
    'Stripe. Change them in Stripe, or use Revoke Trial on a stale one.';

/// Why a super-admin action that writes the app trial (grant, approve,
/// extend) must not run on the account whose data is [current], or null when
/// it may. An account with a Stripe subscription id is billed by Stripe: the
/// app trial writes `trialing` and a new `subscriptionTrialEnd`, which on such
/// an account would read as a card-backed free month running to that date and
/// move its trial end away from Stripe's.
String? adminAppTrialRefusal(Map<String, dynamic>? current) {
  final id = current?['stripeSubscriptionId'];
  if (id is String && id.trim().isNotEmpty) {
    return adminAppTrialStripeSubscriptionMessage;
  }
  return null;
}

/// A super-admin trial action refused by [adminAppTrialRefusal]. Its
/// [toString] is the message, so the Accounts tab's error snackbar shows it.
class AdminAppTrialRefused implements Exception {
  final String message;
  const AdminAppTrialRefused(this.message);

  @override
  String toString() => message;
}

/// Which trial actions the super-admin Accounts tab offers for an account.
class AdminTrialActions {
  /// "Grant Trial": not trialing, not pending approval. The service still
  /// refuses it on an account with a Stripe subscription id, with a message.
  final bool grant;

  /// "Extend Trial": the unpaid app trial only. Never on an account with a
  /// Stripe subscription id, where it would stretch a card-backed trial.
  final bool extend;

  /// "Revoke Trial": whenever the account reads as on a trial the app no
  /// longer counts as paid: the unpaid app trial, or a stale card-backed
  /// trial (trial end long past, or none).
  final bool revoke;

  const AdminTrialActions({
    required this.grant,
    required this.extend,
    required this.revoke,
  });

  /// [onTrial] is `FacilityCreatorAccountModel.hasTrial` (trialing and not a
  /// card-backed trial that still counts as paid), [pendingApproval] and
  /// [hasStripeSubscription] the account's own flags.
  factory AdminTrialActions.of({
    required bool onTrial,
    required bool pendingApproval,
    required bool hasStripeSubscription,
  }) {
    return AdminTrialActions(
      grant: !onTrial && !pendingApproval,
      extend: onTrial && !hasStripeSubscription,
      revoke: onTrial,
    );
  }
}
