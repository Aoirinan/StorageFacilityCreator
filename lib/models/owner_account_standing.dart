import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';

/// The owner's platform account, as copied onto each of their facilities by
/// functions-automation (`facilities/{id}.ownerAccountStanding`).
///
/// Invited team members cannot read the owner's account (the rules only let
/// its owner), so this copy is how their app knows whether the owner's
/// billing still covers them. Backend-only: the rules refuse it from clients.
class OwnerAccountStanding {
  final String accountId;
  final SubscriptionStatus subscriptionStatus;
  final DateTime? subscriptionTrialEnd;
  final DateTime? subscriptionCurrentPeriodEnd;
  final bool suspended;
  final bool billingExempt;

  const OwnerAccountStanding({
    required this.accountId,
    required this.subscriptionStatus,
    this.subscriptionTrialEnd,
    this.subscriptionCurrentPeriodEnd,
    this.suspended = false,
    this.billingExempt = false,
  });

  /// Null when [raw] is not a map (no copy yet, or the owner has no account).
  static OwnerAccountStanding? fromFirestore(Object? raw) {
    if (raw is! Map) return null;
    final status = raw['subscriptionStatus'];
    DateTime? date(Object? value) => value is Timestamp ? value.toDate() : null;
    return OwnerAccountStanding(
      accountId: raw['accountId'] is String ? raw['accountId'] as String : '',
      // An unknown status reads as pendingApproval, as the account model does.
      subscriptionStatus: SubscriptionStatus.values.firstWhere(
        (s) => s.name == status,
        orElse: () => SubscriptionStatus.pendingApproval,
      ),
      subscriptionTrialEnd: date(raw['subscriptionTrialEnd']),
      subscriptionCurrentPeriodEnd: date(raw['subscriptionCurrentPeriodEnd']),
      suspended: raw['suspended'] == true,
      billingExempt: raw['billingExempt'] == true,
    );
  }

  /// The owner's account as far as this copy goes, so the owner's own access
  /// rules (trial end, past-due grace, suspension) apply to it unchanged.
  FacilityCreatorAccountModel toAccount({required String ownerUid}) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return FacilityCreatorAccountModel(
      accountId: accountId,
      ownerUid: ownerUid,
      ownerEmail: '',
      ownerName: '',
      subscriptionStatus: subscriptionStatus,
      subscriptionTrialEnd: subscriptionTrialEnd,
      subscriptionCurrentPeriodEnd: subscriptionCurrentPeriodEnd,
      suspended: suspended,
      billingExempt: billingExempt,
      createdAt: epoch,
      updatedAt: epoch,
    );
  }
}
