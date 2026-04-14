import 'package:cloud_firestore/cloud_firestore.dart';

/// Subscription status enum
enum SubscriptionStatus {
  active,
  pastDue,
  cancelled,
  trialing,
  incomplete,
  incompleteExpired,
  unpaid,
  /// Account created but not yet approved by admin. Trial clock has not started.
  pendingApproval,
}

/// Facility Creator Account model
/// Represents a paying SFC customer who can manage one or more facilities
class FacilityCreatorAccountModel {
  final String accountId;
  final String ownerUid; // Firebase Auth UID of the account owner
  final String ownerEmail;
  final String ownerName;
  
  // Subscription fields
  final SubscriptionStatus subscriptionStatus;
  final String? stripeSubscriptionId; // Stripe subscription ID (sub_...)
  final String? stripeCustomerId; // Stripe customer ID (cus_...)
  final DateTime? subscriptionCurrentPeriodStart;
  final DateTime? subscriptionCurrentPeriodEnd;
  final bool subscriptionCancelAtPeriodEnd;
  final DateTime? subscriptionCanceledAt;
  final DateTime? subscriptionTrialEnd;
  final bool suspended;
  final String? suspensionReason;
  final DateTime? suspendedAt;
  final String? suspendedByEmail;
  
  // Account metadata
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> facilityIds; // List of facility IDs owned by this account
  final Map<String, dynamic>? metadata;

  const FacilityCreatorAccountModel({
    required this.accountId,
    required this.ownerUid,
    required this.ownerEmail,
    required this.ownerName,
    required this.subscriptionStatus,
    this.stripeSubscriptionId,
    this.stripeCustomerId,
    this.subscriptionCurrentPeriodStart,
    this.subscriptionCurrentPeriodEnd,
    this.subscriptionCancelAtPeriodEnd = false,
    this.subscriptionCanceledAt,
    this.subscriptionTrialEnd,
    this.suspended = false,
    this.suspensionReason,
    this.suspendedAt,
    this.suspendedByEmail,
    required this.createdAt,
    required this.updatedAt,
    this.facilityIds = const [],
    this.metadata,
  });

  /// Create from Firestore document
  factory FacilityCreatorAccountModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    
    // Parse subscription status
    SubscriptionStatus status = SubscriptionStatus.active;
    final statusStr = data?['subscriptionStatus'] as String?;
    if (statusStr != null) {
      status = SubscriptionStatus.values.firstWhere(
        (e) => e.name == statusStr,
        orElse: () => SubscriptionStatus.active,
      );
    }

    return FacilityCreatorAccountModel(
      accountId: doc.id,
      ownerUid: data?['ownerUid'] ?? '',
      ownerEmail: data?['ownerEmail'] ?? '',
      ownerName: data?['ownerName'] ?? '',
      subscriptionStatus: status,
      stripeSubscriptionId: data?['stripeSubscriptionId'],
      stripeCustomerId: data?['stripeCustomerId'],
      subscriptionCurrentPeriodStart: (data?['subscriptionCurrentPeriodStart'] as Timestamp?)?.toDate(),
      subscriptionCurrentPeriodEnd: (data?['subscriptionCurrentPeriodEnd'] as Timestamp?)?.toDate(),
      subscriptionCancelAtPeriodEnd: data?['subscriptionCancelAtPeriodEnd'] ?? false,
      subscriptionCanceledAt: (data?['subscriptionCanceledAt'] as Timestamp?)?.toDate(),
      subscriptionTrialEnd: (data?['subscriptionTrialEnd'] as Timestamp?)?.toDate(),
      suspended: data?['suspended'] == true,
      suspensionReason: data?['suspensionReason'] as String?,
      suspendedAt: (data?['suspendedAt'] as Timestamp?)?.toDate(),
      suspendedByEmail: data?['suspendedByEmail'] as String?,
      createdAt: (data?['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data?['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      facilityIds: (data?['facilityIds'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      metadata: data?['metadata'] != null ? Map<String, dynamic>.from(data!['metadata']) : null,
    );
  }

  /// Convert to Firestore document
  Map<String, dynamic> toFirestore() {
    return {
      'ownerUid': ownerUid,
      'ownerEmail': ownerEmail,
      'ownerName': ownerName,
      'subscriptionStatus': subscriptionStatus.name,
      'stripeSubscriptionId': stripeSubscriptionId,
      'stripeCustomerId': stripeCustomerId,
      'subscriptionCurrentPeriodStart': subscriptionCurrentPeriodStart != null
          ? Timestamp.fromDate(subscriptionCurrentPeriodStart!)
          : null,
      'subscriptionCurrentPeriodEnd': subscriptionCurrentPeriodEnd != null
          ? Timestamp.fromDate(subscriptionCurrentPeriodEnd!)
          : null,
      'subscriptionCancelAtPeriodEnd': subscriptionCancelAtPeriodEnd,
      'subscriptionCanceledAt': subscriptionCanceledAt != null
          ? Timestamp.fromDate(subscriptionCanceledAt!)
          : null,
      'subscriptionTrialEnd': subscriptionTrialEnd != null
          ? Timestamp.fromDate(subscriptionTrialEnd!)
          : null,
      'suspended': suspended,
      'suspensionReason': suspensionReason,
      'suspendedAt': suspendedAt != null ? Timestamp.fromDate(suspendedAt!) : null,
      'suspendedByEmail': suspendedByEmail,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'facilityIds': facilityIds,
      'metadata': metadata,
    };
  }

  /// Create a copy with updated fields
  FacilityCreatorAccountModel copyWith({
    String? accountId,
    String? ownerUid,
    String? ownerEmail,
    String? ownerName,
    SubscriptionStatus? subscriptionStatus,
    String? stripeSubscriptionId,
    String? stripeCustomerId,
    DateTime? subscriptionCurrentPeriodStart,
    DateTime? subscriptionCurrentPeriodEnd,
    bool? subscriptionCancelAtPeriodEnd,
    DateTime? subscriptionCanceledAt,
    DateTime? subscriptionTrialEnd,
    bool? suspended,
    String? suspensionReason,
    DateTime? suspendedAt,
    String? suspendedByEmail,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? facilityIds,
    Map<String, dynamic>? metadata,
  }) {
    return FacilityCreatorAccountModel(
      accountId: accountId ?? this.accountId,
      ownerUid: ownerUid ?? this.ownerUid,
      ownerEmail: ownerEmail ?? this.ownerEmail,
      ownerName: ownerName ?? this.ownerName,
      subscriptionStatus: subscriptionStatus ?? this.subscriptionStatus,
      stripeSubscriptionId: stripeSubscriptionId ?? this.stripeSubscriptionId,
      stripeCustomerId: stripeCustomerId ?? this.stripeCustomerId,
      subscriptionCurrentPeriodStart: subscriptionCurrentPeriodStart ?? this.subscriptionCurrentPeriodStart,
      subscriptionCurrentPeriodEnd: subscriptionCurrentPeriodEnd ?? this.subscriptionCurrentPeriodEnd,
      subscriptionCancelAtPeriodEnd: subscriptionCancelAtPeriodEnd ?? this.subscriptionCancelAtPeriodEnd,
      subscriptionCanceledAt: subscriptionCanceledAt ?? this.subscriptionCanceledAt,
      subscriptionTrialEnd: subscriptionTrialEnd ?? this.subscriptionTrialEnd,
      suspended: suspended ?? this.suspended,
      suspensionReason: suspensionReason ?? this.suspensionReason,
      suspendedAt: suspendedAt ?? this.suspendedAt,
      suspendedByEmail: suspendedByEmail ?? this.suspendedByEmail,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      facilityIds: facilityIds ?? this.facilityIds,
      metadata: metadata ?? this.metadata,
    );
  }

  // Helper getters
  bool get hasActiveSubscription => subscriptionStatus == SubscriptionStatus.active;
  bool get hasTrial => subscriptionStatus == SubscriptionStatus.trialing;
  bool get isSubscriptionActive => 
      subscriptionStatus == SubscriptionStatus.active || 
      subscriptionStatus == SubscriptionStatus.trialing;
  bool get isSubscriptionPastDue => subscriptionStatus == SubscriptionStatus.pastDue;
  bool get isSubscriptionCancelled => subscriptionStatus == SubscriptionStatus.cancelled;
  bool get isPendingApproval => subscriptionStatus == SubscriptionStatus.pendingApproval;
  
  /// Check if subscription is valid for accessing the platform
  /// Note: Superadmins bypass this check (handled in UI layer)
  bool get canAccessPlatform {
    if (suspended) return false;
    // Pending approval accounts cannot access until admin approves
    if (isPendingApproval) return false;

    // Check if trial expired - expired trials cannot access
    if (hasTrial && isTrialExpired) {
      return false;
    }
    
    if (isSubscriptionActive) return true;
    if (isSubscriptionPastDue) {
      // Allow access for 7 days after past due (grace period)
      if (subscriptionCurrentPeriodEnd != null) {
        final daysPastDue = DateTime.now().difference(subscriptionCurrentPeriodEnd!).inDays;
        return daysPastDue <= 7;
      }
    }
    return false;
  }

  /// Check if user has access to premium features (DNR, etc.)
  /// Only active subscriptions have access - trials do not
  /// Note: Superadmins bypass this check (handled in UI layer)
  bool get hasPremiumAccess {
    return subscriptionStatus == SubscriptionStatus.active;
  }

  /// Permanent tenant delete (vs archive) requires paid active or a non-expired trial.
  /// Stricter than [canAccessPlatform] (excludes past-due grace and cancelled access windows).
  bool get allowsPermanentTenantDeletion {
    if (suspended) return false;
    if (isPendingApproval) return false;
    if (hasActiveSubscription) return true;
    if (hasTrial && !isTrialExpired) return true;
    return false;
  }

  /// Get days until subscription expires
  int? get daysUntilExpiration {
    if (subscriptionCurrentPeriodEnd == null) return null;
    final days = subscriptionCurrentPeriodEnd!.difference(DateTime.now()).inDays;
    return days > 0 ? days : 0;
  }

  /// Get days until trial expires (for trial users)
  int? get daysUntilTrialExpiration {
    if (subscriptionTrialEnd == null) return null;
    final days = subscriptionTrialEnd!.difference(DateTime.now()).inDays;
    return days > 0 ? days : 0;
  }

  /// Check if trial has expired
  bool get isTrialExpired {
    if (!hasTrial) return false;
    if (subscriptionTrialEnd == null) return false;
    return DateTime.now().isAfter(subscriptionTrialEnd!);
  }

  /// Check if trial is expiring soon (within 3 days)
  bool get isTrialExpiringSoon {
    if (!hasTrial || subscriptionTrialEnd == null) return false;
    final daysLeft = daysUntilTrialExpiration;
    return daysLeft != null && daysLeft <= 3 && daysLeft > 0;
  }

  /// Check if grace period has expired (for past_due subscriptions)
  bool get isGracePeriodExpired {
    if (!isSubscriptionPastDue) return false;
    return !canAccessPlatform; // canAccessPlatform already checks 7-day grace period
  }

  /// Get days remaining in grace period (for past_due subscriptions)
  int? get daysRemainingInGracePeriod {
    if (!isSubscriptionPastDue || subscriptionCurrentPeriodEnd == null) return null;
    final daysPastDue = DateTime.now().difference(subscriptionCurrentPeriodEnd!).inDays;
    final daysRemaining = 7 - daysPastDue;
    return daysRemaining > 0 ? daysRemaining : 0;
  }
}

/// Extension for subscription status display names
extension SubscriptionStatusExtension on SubscriptionStatus {
  String get displayName {
    switch (this) {
      case SubscriptionStatus.active:
        return 'Active';
      case SubscriptionStatus.pastDue:
        return 'Past Due';
      case SubscriptionStatus.cancelled:
        return 'Cancelled';
      case SubscriptionStatus.trialing:
        return 'Trial';
      case SubscriptionStatus.incomplete:
        return 'Incomplete';
      case SubscriptionStatus.incompleteExpired:
        return 'Incomplete Expired';
      case SubscriptionStatus.unpaid:
        return 'Unpaid';
      case SubscriptionStatus.pendingApproval:
        return 'Pending Approval';
    }
  }
}

