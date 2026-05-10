import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/sms_usage_model.dart';
import 'package:sfcapp/models/user_model.dart';
import 'package:sfcapp/services/email_usage_service.dart';
import 'package:sfcapp/services/sms_usage_service.dart';

// ---------------------------------------------------------------------------
// Data transfer objects for super admin views
// ---------------------------------------------------------------------------

class SuperAdminFacilityRow {
  final FacilityModel facility;
  final String ownerEmail;
  final String? subscriptionStatus;
  final DateTime? subscriptionPeriodEnd;

  const SuperAdminFacilityRow({
    required this.facility,
    required this.ownerEmail,
    this.subscriptionStatus,
    this.subscriptionPeriodEnd,
  });
}

class PlatformMetrics {
  final int totalFacilities;
  final int activeFacilities;
  final int totalUnits;
  final int occupiedUnits;
  final int totalAccounts;
  final int activeAccounts;
  final int trialingAccounts;
  final int pastDueAccounts;
  final int cancelledAccounts;
  final int totalUsers;

  const PlatformMetrics({
    required this.totalFacilities,
    required this.activeFacilities,
    required this.totalUnits,
    required this.occupiedUnits,
    required this.totalAccounts,
    required this.activeAccounts,
    required this.trialingAccounts,
    required this.pastDueAccounts,
    required this.cancelledAccounts,
    required this.totalUsers,
  });

  double get occupancyRate =>
      totalUnits == 0 ? 0 : (occupiedUnits / totalUnits * 100);
}

enum MarketingLeadStatus {
  newLead,
  contacted,
  qualified,
  won,
  lost,
}

extension MarketingLeadStatusDisplay on MarketingLeadStatus {
  String get value {
    switch (this) {
      case MarketingLeadStatus.newLead:
        return 'new';
      case MarketingLeadStatus.contacted:
        return 'contacted';
      case MarketingLeadStatus.qualified:
        return 'qualified';
      case MarketingLeadStatus.won:
        return 'won';
      case MarketingLeadStatus.lost:
        return 'lost';
    }
  }

  String get label {
    switch (this) {
      case MarketingLeadStatus.newLead:
        return 'New';
      case MarketingLeadStatus.contacted:
        return 'Contacted';
      case MarketingLeadStatus.qualified:
        return 'Qualified';
      case MarketingLeadStatus.won:
        return 'Won';
      case MarketingLeadStatus.lost:
        return 'Lost';
    }
  }

  static MarketingLeadStatus fromValue(String value) {
    switch (value) {
      case 'contacted':
        return MarketingLeadStatus.contacted;
      case 'qualified':
        return MarketingLeadStatus.qualified;
      case 'won':
        return MarketingLeadStatus.won;
      case 'lost':
        return MarketingLeadStatus.lost;
      default:
        return MarketingLeadStatus.newLead;
    }
  }
}

class MarketingLead {
  final String id;
  final String source;
  final String intent;
  final String name;
  final String email;
  final String facilityName;
  final String? phone;
  final String? unitCount;
  final String? message;
  final String? utmSource;
  final String? utmMedium;
  final String? utmCampaign;
  final String? utmTerm;
  final String? utmContent;
  final String? landingPath;
  final String? referrer;
  final bool smsConsent;
  final MarketingLeadStatus status;
  final String? assignedToUid;
  final String? assignedToEmail;
  final String? assignedToName;
  final DateTime? lastCalledAt;
  final String? lastCallOutcome;
  final DateTime? firstContactedAt;
  final DateTime? closedAt;
  final String? workedByName;
  final String? workedByEmail;
  final String saleStatus;
  final num? saleAmount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const MarketingLead({
    required this.id,
    required this.source,
    required this.intent,
    required this.name,
    required this.email,
    required this.facilityName,
    this.phone,
    this.unitCount,
    this.message,
    this.utmSource,
    this.utmMedium,
    this.utmCampaign,
    this.utmTerm,
    this.utmContent,
    this.landingPath,
    this.referrer,
    required this.smsConsent,
    required this.status,
    this.assignedToUid,
    this.assignedToEmail,
    this.assignedToName,
    this.lastCalledAt,
    this.lastCallOutcome,
    this.firstContactedAt,
    this.closedAt,
    this.workedByName,
    this.workedByEmail,
    required this.saleStatus,
    this.saleAmount,
    this.createdAt,
    this.updatedAt,
  });

  factory MarketingLead.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return MarketingLead(
      id: doc.id,
      source: (d['source'] ?? 'website_contact').toString(),
      intent: (d['intent'] ?? 'demo').toString(),
      name: (d['name'] ?? '').toString(),
      email: (d['email'] ?? '').toString(),
      facilityName: (d['facilityName'] ?? '').toString(),
      phone: d['phone'] as String?,
      unitCount: d['unitCount'] as String?,
      message: d['message'] as String?,
      utmSource: d['utmSource'] as String?,
      utmMedium: d['utmMedium'] as String?,
      utmCampaign: d['utmCampaign'] as String?,
      utmTerm: d['utmTerm'] as String?,
      utmContent: d['utmContent'] as String?,
      landingPath: d['landingPath'] as String?,
      referrer: d['referrer'] as String?,
      smsConsent: d['smsConsent'] == true,
      status: MarketingLeadStatusDisplay.fromValue(
          (d['status'] ?? 'new').toString()),
      assignedToUid: d['assignedToUid'] as String?,
      assignedToEmail: d['assignedToEmail'] as String?,
      assignedToName: d['assignedToName'] as String?,
      lastCalledAt: (d['lastCalledAt'] as Timestamp?)?.toDate(),
      lastCallOutcome: d['lastCallOutcome'] as String?,
      firstContactedAt: (d['firstContactedAt'] as Timestamp?)?.toDate(),
      closedAt: (d['closedAt'] as Timestamp?)?.toDate(),
      workedByName: d['workedByName'] as String?,
      workedByEmail: d['workedByEmail'] as String?,
      saleStatus: (d['saleStatus'] ?? 'pending').toString(),
      saleAmount: d['saleAmount'] as num?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

class MarketingLeadActivity {
  final String id;
  final String type;
  final String summary;
  final String actorUid;
  final String actorEmail;
  final String actorName;
  final DateTime? createdAt;

  const MarketingLeadActivity({
    required this.id,
    required this.type,
    required this.summary,
    required this.actorUid,
    required this.actorEmail,
    required this.actorName,
    this.createdAt,
  });

  factory MarketingLeadActivity.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return MarketingLeadActivity(
      id: doc.id,
      type: (d['type'] ?? 'note').toString(),
      summary: (d['summary'] ?? '').toString(),
      actorUid: (d['actorUid'] ?? '').toString(),
      actorEmail: (d['actorEmail'] ?? '').toString(),
      actorName: (d['actorName'] ?? '').toString(),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

class FacilityCommunicationUsage {
  final EmailUsage emailUsage;
  final SMSUsage smsUsage;

  const FacilityCommunicationUsage({
    required this.emailUsage,
    required this.smsUsage,
  });
}

class ReferralPendingItem {
  final String id;
  final String? reason;
  final String? error;
  final String? referrerAccountId;
  final String? refereeAccountId;
  final String? refereeFacilityId;
  final String? stripeInvoiceId;
  final DateTime? createdAt;
  final String status;
  final String? resolutionAction;
  final String? resolutionNote;
  final String? resolvedByEmail;
  final DateTime? resolvedAt;
  final String? resolvedAppliedToFacilityId;

  const ReferralPendingItem({
    required this.id,
    this.reason,
    this.error,
    this.referrerAccountId,
    this.refereeAccountId,
    this.refereeFacilityId,
    this.stripeInvoiceId,
    this.createdAt,
    this.status = 'open',
    this.resolutionAction,
    this.resolutionNote,
    this.resolvedByEmail,
    this.resolvedAt,
    this.resolvedAppliedToFacilityId,
  });
}

class ReferralFacilityAuditRow {
  final String facilityId;
  final String facilityName;
  final String? facilityCreatorAccountId;
  final String? referredByAccountId;
  final DateTime? rewardGrantedAt;
  final String? rewardStripeInvoiceId;
  final String? rewardAppliedToFacilityId;
  final bool rewardPendingManual;
  final bool rewardCapReached;

  const ReferralFacilityAuditRow({
    required this.facilityId,
    required this.facilityName,
    this.facilityCreatorAccountId,
    this.referredByAccountId,
    this.rewardGrantedAt,
    this.rewardStripeInvoiceId,
    this.rewardAppliedToFacilityId,
    this.rewardPendingManual = false,
    this.rewardCapReached = false,
  });
}

class CommissionPayoutPeriod {
  final String id;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String status;
  final bool commissionableOnly;
  final double minimumSaleAmount;
  final String rateType;
  final double rateValue;
  final DateTime? createdAt;
  final String createdByEmail;
  final double totalSales;
  final double totalCommission;
  final int totalWon;

  const CommissionPayoutPeriod({
    required this.id,
    required this.periodStart,
    required this.periodEnd,
    required this.status,
    required this.commissionableOnly,
    required this.minimumSaleAmount,
    required this.rateType,
    required this.rateValue,
    required this.createdAt,
    required this.createdByEmail,
    required this.totalSales,
    required this.totalCommission,
    required this.totalWon,
  });

  factory CommissionPayoutPeriod.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return CommissionPayoutPeriod(
      id: doc.id,
      periodStart: (d['periodStart'] as Timestamp?)?.toDate() ?? DateTime.now(),
      periodEnd: (d['periodEnd'] as Timestamp?)?.toDate() ?? DateTime.now(),
      status: (d['status'] ?? 'open').toString(),
      commissionableOnly: d['commissionableOnly'] == true,
      minimumSaleAmount: (d['minimumSaleAmount'] as num?)?.toDouble() ?? 0,
      rateType: (d['rateType'] ?? 'percent_of_sales').toString(),
      rateValue: (d['rateValue'] as num?)?.toDouble() ?? 0,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      createdByEmail: (d['createdByEmail'] ?? '').toString(),
      totalSales: (d['totalSales'] as num?)?.toDouble() ?? 0,
      totalCommission: (d['totalCommission'] as num?)?.toDouble() ?? 0,
      totalWon: (d['totalWon'] as num?)?.toInt() ?? 0,
    );
  }
}

class CommissionPayoutRepRow {
  final String id;
  final String rep;
  final int totalLeads;
  final int wonCount;
  final int commissionableWonCount;
  final double saleTotal;
  final double commissionableSaleTotal;
  final double commissionAmount;
  final bool paid;
  final DateTime? paidAt;
  final String? paidByEmail;

  const CommissionPayoutRepRow({
    required this.id,
    required this.rep,
    required this.totalLeads,
    required this.wonCount,
    required this.commissionableWonCount,
    required this.saleTotal,
    required this.commissionableSaleTotal,
    required this.commissionAmount,
    required this.paid,
    this.paidAt,
    this.paidByEmail,
  });

  factory CommissionPayoutRepRow.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return CommissionPayoutRepRow(
      id: doc.id,
      rep: (d['rep'] ?? '').toString(),
      totalLeads: (d['totalLeads'] as num?)?.toInt() ?? 0,
      wonCount: (d['wonCount'] as num?)?.toInt() ?? 0,
      commissionableWonCount:
          (d['commissionableWonCount'] as num?)?.toInt() ?? 0,
      saleTotal: (d['saleTotal'] as num?)?.toDouble() ?? 0,
      commissionableSaleTotal:
          (d['commissionableSaleTotal'] as num?)?.toDouble() ?? 0,
      commissionAmount: (d['commissionAmount'] as num?)?.toDouble() ?? 0,
      paid: d['paid'] == true,
      paidAt: (d['paidAt'] as Timestamp?)?.toDate(),
      paidByEmail: d['paidByEmail'] as String?,
    );
  }
}

class HostingDnsRecord {
  final String type;
  final String name;
  final String value;

  const HostingDnsRecord({
    required this.type,
    required this.name,
    required this.value,
  });

  factory HostingDnsRecord.fromMap(Map<String, dynamic> map) {
    return HostingDnsRecord(
      type: (map['type'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      value: (map['value'] ?? '').toString(),
    );
  }
}

class HostingCustomDomainProvisionResult {
  final String hostname;
  final String facilityId;
  final String slug;
  final String status;
  final String? certState;
  final DateTime? retrievedAt;
  final List<HostingDnsRecord> records;

  const HostingCustomDomainProvisionResult({
    required this.hostname,
    required this.facilityId,
    required this.slug,
    required this.status,
    this.certState,
    this.retrievedAt,
    required this.records,
  });

  factory HostingCustomDomainProvisionResult.fromMap(Map<String, dynamic> map) {
    final rawRecords = (map['records'] as List<dynamic>? ?? const []);
    return HostingCustomDomainProvisionResult(
      hostname: (map['hostname'] ?? '').toString(),
      facilityId: (map['facilityId'] ?? '').toString(),
      slug: (map['slug'] ?? '').toString(),
      status: (map['status'] ?? 'unknown').toString(),
      certState: (map['certState'] as String?)?.trim(),
      retrievedAt: DateTime.tryParse((map['retrievedAt'] ?? '').toString()),
      records: rawRecords
          .whereType<Map>()
          .map(
              (raw) => HostingDnsRecord.fromMap(Map<String, dynamic>.from(raw)))
          .toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// All facilities across the platform (superadmin only).
final allFacilitiesProvider = StreamProvider<List<FacilityModel>>((ref) {
  return FirebaseFirestore.instance
      .collection('facilities')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) =>
          snap.docs.map((d) => FacilityModel.fromFirestore(d)).toList());
});

/// All facilityCreatorAccounts (superadmin only).
final allAccountsProvider =
    StreamProvider<List<FacilityCreatorAccountModel>>((ref) {
  return FirebaseFirestore.instance
      .collection('facilityCreatorAccounts')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs
          .map((d) => FacilityCreatorAccountModel.fromFirestore(d))
          .toList());
});

/// All platform users (superadmin only).
final allUsersProvider = StreamProvider<List<UserModel>>((ref) {
  return FirebaseFirestore.instance
      .collection('users')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map((d) => UserModel.fromFirestore(d)).toList());
});

/// Facilities with referral-related fields present.
final referralFacilityAuditProvider =
    StreamProvider<List<ReferralFacilityAuditRow>>((ref) {
  return FirebaseFirestore.instance
      .collection('facilities')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) {
    return snap.docs
        .map((doc) {
          final d = doc.data();
          final referredBy =
              (d['platformReferralReferredByAccountId'] as String?)?.trim();
          final rewardGrantedAt =
              (d['platformReferralRewardGrantedAt'] as Timestamp?)?.toDate();
          final rewardPendingManual =
              d['platformReferralRewardPendingManual'] == true;
          final rewardCapReached =
              d['platformReferralRewardCapReached'] == true;
          if ((referredBy == null || referredBy.isEmpty) &&
              rewardGrantedAt == null &&
              !rewardPendingManual &&
              !rewardCapReached) {
            return null;
          }
          return ReferralFacilityAuditRow(
            facilityId: doc.id,
            facilityName: (d['name'] as String?) ?? doc.id,
            facilityCreatorAccountId:
                (d['facilityCreatorAccountId'] as String?)?.trim(),
            referredByAccountId: referredBy,
            rewardGrantedAt: rewardGrantedAt,
            rewardStripeInvoiceId:
                (d['platformReferralRewardStripeInvoiceId'] as String?)?.trim(),
            rewardAppliedToFacilityId:
                (d['platformReferralRewardAppliedToFacilityId'] as String?)
                    ?.trim(),
            rewardPendingManual: rewardPendingManual,
            rewardCapReached: rewardCapReached,
          );
        })
        .whereType<ReferralFacilityAuditRow>()
        .toList();
  });
});

/// Marketing leads captured from website demo/trial forms.
final marketingLeadsProvider = StreamProvider<List<MarketingLead>>((ref) {
  return FirebaseFirestore.instance
      .collection('marketing_leads')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map(MarketingLead.fromFirestore).toList());
});

final commissionPayoutPeriodsProvider =
    StreamProvider<List<CommissionPayoutPeriod>>((ref) {
  return FirebaseFirestore.instance
      .collection('commission_payout_periods')
      .orderBy('createdAt', descending: true)
      .limit(50)
      .snapshots()
      .map((snap) =>
          snap.docs.map(CommissionPayoutPeriod.fromFirestore).toList());
});

/// Derived: facilities enriched with owner email and subscription status.
final superAdminFacilityRowsProvider =
    Provider<AsyncValue<List<SuperAdminFacilityRow>>>((ref) {
  final facilitiesAsync = ref.watch(allFacilitiesProvider);
  final accountsAsync = ref.watch(allAccountsProvider);
  final usersAsync = ref.watch(allUsersProvider);

  return facilitiesAsync.when(
    loading: () => const AsyncValue.loading(),
    error: (e, s) => AsyncValue.error(e, s),
    data: (facilities) {
      return accountsAsync.when(
        loading: () => const AsyncValue.loading(),
        error: (e, s) => AsyncValue.error(e, s),
        data: (accounts) {
          return usersAsync.when(
            loading: () => const AsyncValue.loading(),
            error: (e, s) => AsyncValue.error(e, s),
            data: (users) {
              final userMap = {for (final u in users) u.uid: u};
              final accountByOwner = {for (final a in accounts) a.ownerUid: a};

              return AsyncValue.data(facilities.map((f) {
                final owner = userMap[f.ownerUid];
                final account = accountByOwner[f.ownerUid];
                return SuperAdminFacilityRow(
                  facility: f,
                  ownerEmail: owner?.email ?? f.email ?? 'Unknown',
                  subscriptionStatus: account?.subscriptionStatus.displayName,
                  subscriptionPeriodEnd: account?.subscriptionCurrentPeriodEnd,
                );
              }).toList());
            },
          );
        },
      );
    },
  );
});

/// Derived: platform-wide aggregate metrics.
final platformMetricsProvider = Provider<AsyncValue<PlatformMetrics>>((ref) {
  final facilitiesAsync = ref.watch(allFacilitiesProvider);
  final accountsAsync = ref.watch(allAccountsProvider);
  final usersAsync = ref.watch(allUsersProvider);

  return facilitiesAsync.when(
    loading: () => const AsyncValue.loading(),
    error: (e, s) => AsyncValue.error(e, s),
    data: (facilities) {
      return accountsAsync.when(
        loading: () => const AsyncValue.loading(),
        error: (e, s) => AsyncValue.error(e, s),
        data: (accounts) {
          return usersAsync.when(
            loading: () => const AsyncValue.loading(),
            error: (e, s) => AsyncValue.error(e, s),
            data: (users) {
              final active = facilities.where((f) => f.active).toList();
              return AsyncValue.data(PlatformMetrics(
                totalFacilities: facilities.length,
                activeFacilities: active.length,
                // `unitDocCount` is the count of actual unit documents under
                // each facility, mirrored onto the facility doc by
                // `FacilityStatsService.updateFacilityStats`. The user-set
                // `totalUnits` (capacity max) is intentionally not summed here.
                totalUnits: facilities.fold(0, (s, f) => s + f.unitDocCount),
                occupiedUnits:
                    facilities.fold(0, (s, f) => s + f.occupiedUnits),
                totalAccounts: accounts.length,
                activeAccounts: accounts
                    .where((a) =>
                        a.subscriptionStatus == SubscriptionStatus.active)
                    .length,
                trialingAccounts: accounts
                    .where((a) =>
                        a.subscriptionStatus == SubscriptionStatus.trialing)
                    .length,
                pastDueAccounts: accounts
                    .where((a) =>
                        a.subscriptionStatus == SubscriptionStatus.pastDue)
                    .length,
                cancelledAccounts: accounts
                    .where((a) =>
                        a.subscriptionStatus == SubscriptionStatus.cancelled)
                    .length,
                totalUsers: users.length,
              ));
            },
          );
        },
      );
    },
  );
});

// ---------------------------------------------------------------------------
// Super admin note model
// ---------------------------------------------------------------------------

/// Dry-run stats for emailing all unique facility owners (super admin).
class SuperAdminFacilityOwnerBroadcastPreview {
  final int facilityDocuments;
  final int uniqueOwnerUids;
  final int recipientCount;

  const SuperAdminFacilityOwnerBroadcastPreview({
    required this.facilityDocuments,
    required this.uniqueOwnerUids,
    required this.recipientCount,
  });
}

class SuperAdminFacilityOwnerBroadcastFailure {
  final String uid;
  final String email;
  final String error;

  const SuperAdminFacilityOwnerBroadcastFailure({
    required this.uid,
    required this.email,
    required this.error,
  });
}

/// Outcome of a facility-owner platform email broadcast.
class SuperAdminFacilityOwnerBroadcastResult {
  final int sent;
  final int failureCount;
  final int totalRecipients;
  final List<SuperAdminFacilityOwnerBroadcastFailure> failures;

  const SuperAdminFacilityOwnerBroadcastResult({
    required this.sent,
    required this.failureCount,
    required this.totalRecipients,
    required this.failures,
  });
}

class SuperAdminNote {
  final String id;
  final String targetId;
  final String targetType; // 'facility' | 'account' | 'user'
  final String note;
  final DateTime createdAt;
  final String createdBy;

  const SuperAdminNote({
    required this.id,
    required this.targetId,
    required this.targetType,
    required this.note,
    required this.createdAt,
    required this.createdBy,
  });

  factory SuperAdminNote.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>?;
    return SuperAdminNote(
      id: doc.id,
      targetId: d?['targetId'] ?? '',
      targetType: d?['targetType'] ?? '',
      note: d?['note'] ?? '',
      createdAt: (d?['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: d?['createdBy'] ?? '',
    );
  }

  Map<String, dynamic> toFirestore() => {
        'targetId': targetId,
        'targetType': targetType,
        'note': note,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': createdBy,
      };
}

class SuperAdminDataService {
  static final _db = FirebaseFirestore.instance;
  static final _functions = FirebaseFunctions.instance;

  static HttpsCallable _facilityOwnerBroadcastCallable({Duration? timeout}) {
    return _functions.httpsCallable(
      'superAdminBroadcastEmailToFacilityOwners',
      options: HttpsCallableOptions(
        timeout: timeout ?? const Duration(minutes: 6),
      ),
    );
  }

  /// How many facility documents and unique owner emails a broadcast would hit.
  static Future<SuperAdminFacilityOwnerBroadcastPreview>
      previewFacilityOwnerBroadcast({
    bool includeInactiveFacilities = false,
    /// `allOwners` = any owner of an (active) facility; `activePayingSubscribers` = Stripe active only ($75/mo).
    String recipientScope = 'activePayingSubscribers',
  }) async {
    final callable = _facilityOwnerBroadcastCallable(
      timeout: const Duration(seconds: 120),
    );
    final result = await callable.call<Map<String, dynamic>>({
      'dryRun': true,
      'includeInactiveFacilities': includeInactiveFacilities,
      'recipientScope': recipientScope,
    });
    final data = Map<String, dynamic>.from(result.data);
    return SuperAdminFacilityOwnerBroadcastPreview(
      facilityDocuments: (data['facilityDocuments'] as num?)?.toInt() ?? 0,
      uniqueOwnerUids: (data['uniqueOwnerUids'] as num?)?.toInt() ?? 0,
      recipientCount: (data['recipientCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// Send one platform email per unique facility owner inbox. Requires [acknowledgment] `BROADCAST`.
  static Future<SuperAdminFacilityOwnerBroadcastResult> sendFacilityOwnerBroadcast({
    required String subject,
    String? html,
    String? text,
    required String acknowledgment,
    bool includeInactiveFacilities = false,
    String recipientScope = 'activePayingSubscribers',
  }) async {
    final callable = _facilityOwnerBroadcastCallable();
    final result = await callable.call<Map<String, dynamic>>({
      'subject': subject.trim(),
      if (html != null && html.trim().isNotEmpty) 'html': html,
      if (text != null && text.trim().isNotEmpty) 'text': text,
      'acknowledgment': acknowledgment.trim(),
      'includeInactiveFacilities': includeInactiveFacilities,
      'recipientScope': recipientScope,
    });
    final data = Map<String, dynamic>.from(result.data);
    final rawFailures = data['failures'] as List<dynamic>? ?? const [];
    final failures = rawFailures.map((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      return SuperAdminFacilityOwnerBroadcastFailure(
        uid: (m['uid'] ?? '').toString(),
        email: (m['email'] ?? '').toString(),
        error: (m['error'] ?? '').toString(),
      );
    }).toList();
    return SuperAdminFacilityOwnerBroadcastResult(
      sent: (data['sent'] as num?)?.toInt() ?? 0,
      failureCount: (data['failureCount'] as num?)?.toInt() ?? 0,
      totalRecipients: (data['totalRecipients'] as num?)?.toInt() ?? 0,
      failures: failures,
    );
  }

  static Future<HostingCustomDomainProvisionResult>
      provisionHostingCustomDomain({
    required String hostname,
    String? facilityId,
    String? slug,
  }) async {
    final callable =
        _functions.httpsCallable('superAdminProvisionHostingCustomDomain');
    final result = await callable.call<Map<String, dynamic>>({
      'hostname': hostname.trim(),
      if (facilityId != null && facilityId.trim().isNotEmpty)
        'facilityId': facilityId.trim(),
      if (slug != null && slug.trim().isNotEmpty) 'slug': slug.trim(),
    });
    return HostingCustomDomainProvisionResult.fromMap(
      Map<String, dynamic>.from(result.data),
    );
  }

  static Future<HostingCustomDomainProvisionResult>
      getHostingCustomDomainStatus({
    required String hostname,
  }) async {
    final callable =
        _functions.httpsCallable('superAdminGetHostingCustomDomainStatus');
    final result = await callable.call<Map<String, dynamic>>({
      'hostname': hostname.trim(),
    });
    return HostingCustomDomainProvisionResult.fromMap(
      Map<String, dynamic>.from(result.data),
    );
  }

  static Future<List<ReferralPendingItem>> listReferralRewardsPending({
    int limit = 100,
  }) async {
    final callable =
        _functions.httpsCallable('superAdminListReferralRewardsPending');
    final result = await callable.call<Map<String, dynamic>>({'limit': limit});
    final data = result.data;
    final rawItems = (data['items'] as List<dynamic>? ?? const []);
    return rawItems.map((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      final createdMs = m['createdAt'] as num?;
      return ReferralPendingItem(
        id: (m['id'] ?? '').toString(),
        reason: m['reason'] as String?,
        error: m['error'] as String?,
        referrerAccountId: m['referrerAccountId'] as String?,
        refereeAccountId: m['refereeAccountId'] as String?,
        refereeFacilityId: m['refereeFacilityId'] as String?,
        stripeInvoiceId: m['stripeInvoiceId'] as String?,
        createdAt: createdMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(createdMs.toInt()),
        status: (m['status'] as String?) ?? 'open',
        resolutionAction: m['resolutionAction'] as String?,
        resolutionNote: m['resolutionNote'] as String?,
        resolvedByEmail: m['resolvedByEmail'] as String?,
        resolvedAt: (m['resolvedAt'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (m['resolvedAt'] as num).toInt()),
        resolvedAppliedToFacilityId:
            m['resolvedAppliedToFacilityId'] as String?,
      );
    }).toList();
  }

  static Future<void> resolveReferralPending({
    required String pendingId,
    required String action, // resolve_only | apply_reward
    String? note,
    String? targetFacilityId,
  }) async {
    final callable =
        _functions.httpsCallable('superAdminResolveReferralPending');
    await callable.call<Map<String, dynamic>>({
      'pendingId': pendingId,
      'action': action,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      if (targetFacilityId != null && targetFacilityId.trim().isNotEmpty)
        'targetFacilityId': targetFacilityId.trim(),
    });
  }

  /// Super admin only: permanently delete facility creator account document,
  /// all facilities owned by the account owner (full trees), and the owner's
  /// Firebase Auth user + `users/{uid}`. Requires typing the owner email to confirm.
  static Future<void> deleteFacilityCreatorAccount({
    required String accountId,
    required String ownerEmailConfirmation,
  }) async {
    final callable =
        _functions.httpsCallable('superAdminDeleteFacilityCreatorAccount');
    await callable.call<Map<String, dynamic>>({
      'accountId': accountId,
      'ownerEmailConfirmation': ownerEmailConfirmation.trim(),
    });
  }

  /// Super admin only: permanently delete one facility (full Firestore subtree),
  /// Firebase Storage files under `facilities/{id}/`, public website map entry when
  /// applicable, account membership, and Stripe quantity.
  /// [facilityNameConfirmation] must be the facility's display name exactly, or the
  /// facility document id when the facility has no name.
  static Future<void> deleteFacility({
    required String facilityId,
    required String facilityNameConfirmation,
  }) async {
    final callable = _functions.httpsCallable('superAdminDeleteFacility');
    await callable.call<Map<String, dynamic>>({
      'facilityId': facilityId.trim(),
      'facilityNameConfirmation': facilityNameConfirmation.trim(),
    });
  }

  /// Add an internal note for a facility, account, or user.
  static Future<void> addNote({
    required String targetId,
    required String targetType,
    required String note,
    required String createdBy,
  }) async {
    await _db.collection('superAdminNotes').add({
      'targetId': targetId,
      'targetType': targetType,
      'note': note,
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': createdBy,
    });
  }

  /// Stream notes for a specific target.
  static Stream<List<SuperAdminNote>> notesFor(String targetId) {
    return _db
        .collection('superAdminNotes')
        .where('targetId', isEqualTo: targetId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((s) => s.docs.map(SuperAdminNote.fromFirestore).toList());
  }

  /// Extend a trial by N days for a given account.
  static Future<void> extendTrial(String accountId, int days) async {
    final doc =
        await _db.collection('facilityCreatorAccounts').doc(accountId).get();
    if (!doc.exists) return;
    final data = doc.data()!;
    final currentEnd = (data['subscriptionTrialEnd'] as Timestamp?)?.toDate() ??
        DateTime.now();
    final newEnd = currentEnd.isAfter(DateTime.now())
        ? currentEnd.add(Duration(days: days))
        : DateTime.now().add(Duration(days: days));
    await _db
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .update({'subscriptionTrialEnd': Timestamp.fromDate(newEnd)});
  }

  /// Grant a fresh N-day trial to any account (admin-only).
  /// Sets status to trialing with a new trial end date regardless of current status.
  static Future<void> grantTrial(String accountId, {int days = 30}) async {
    final now = DateTime.now();
    final trialEnd = now.add(Duration(days: days));
    await _db.collection('facilityCreatorAccounts').doc(accountId).update({
      'subscriptionStatus': 'trialing',
      'subscriptionTrialEnd': Timestamp.fromDate(trialEnd),
      'subscriptionCurrentPeriodStart': Timestamp.fromDate(now),
      'subscriptionCurrentPeriodEnd': Timestamp.fromDate(trialEnd),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Revoke an active trial — sets status back to cancelled and clears trial end.
  static Future<void> revokeTrial(String accountId) async {
    await _db.collection('facilityCreatorAccounts').doc(accountId).update({
      'subscriptionStatus': 'cancelled',
      'subscriptionTrialEnd': null,
      'subscriptionCurrentPeriodEnd': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Approve a pending account: starts a 30-day trial immediately.
  /// This is the admin "accept" action for the two-stage activation flow.
  static Future<void> approveTrial(String accountId, {int days = 30}) async {
    final now = DateTime.now();
    final trialEnd = now.add(Duration(days: days));
    await _db.collection('facilityCreatorAccounts').doc(accountId).update({
      'subscriptionStatus': 'trialing',
      'subscriptionTrialEnd': Timestamp.fromDate(trialEnd),
      'subscriptionCurrentPeriodStart': Timestamp.fromDate(now),
      'subscriptionCurrentPeriodEnd': Timestamp.fromDate(trialEnd),
      'approvedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Reject a pending account — marks it cancelled so the user sees the
  /// subscription screen with an appropriate message.
  static Future<void> rejectAccount(String accountId) async {
    await _db.collection('facilityCreatorAccounts').doc(accountId).update({
      'subscriptionStatus': 'cancelled',
      'rejectedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Stream<List<MarketingLeadActivity>> marketingLeadActivities(
      String leadId) {
    return _db
        .collection('marketing_leads')
        .doc(leadId)
        .collection('activities')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((s) => s.docs.map(MarketingLeadActivity.fromFirestore).toList());
  }

  static Future<void> assignMarketingLead({
    required String leadId,
    String? assignedToUid,
    String? assignedToEmail,
    String? assignedToName,
    required String actorUid,
    required String actorEmail,
    required String actorName,
  }) async {
    final leadRef = _db.collection('marketing_leads').doc(leadId);
    await leadRef.update({
      'assignedToUid': assignedToUid,
      'assignedToEmail': assignedToEmail,
      'assignedToName': assignedToName,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await leadRef.collection('activities').add({
      'type': 'assignment',
      'summary':
          'Assigned to ${assignedToName ?? assignedToEmail ?? 'unassigned'}.',
      'actorUid': actorUid,
      'actorEmail': actorEmail,
      'actorName': actorName,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> updateMarketingLeadStatus({
    required String leadId,
    required MarketingLeadStatus status,
    String? saleStatus,
    num? saleAmount,
    bool markCalled = false,
    String? callOutcome,
    String? workedByName,
    String? workedByEmail,
    required String actorUid,
    required String actorEmail,
    required String actorName,
    String? summary,
  }) async {
    final leadRef = _db.collection('marketing_leads').doc(leadId);
    final leadSnap = await leadRef.get();
    final leadData = leadSnap.data() ?? const <String, dynamic>{};
    final update = <String, dynamic>{
      'status': status.value,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (saleStatus != null) update['saleStatus'] = saleStatus;
    if (saleAmount != null) update['saleAmount'] = saleAmount;
    if (markCalled) update['lastCalledAt'] = FieldValue.serverTimestamp();
    if (callOutcome != null) update['lastCallOutcome'] = callOutcome;
    if (workedByName != null) update['workedByName'] = workedByName;
    if (workedByEmail != null) update['workedByEmail'] = workedByEmail;
    if (markCalled && leadData['firstContactedAt'] == null) {
      update['firstContactedAt'] = FieldValue.serverTimestamp();
    }
    if ((status == MarketingLeadStatus.won ||
            status == MarketingLeadStatus.lost) &&
        leadData['closedAt'] == null) {
      update['closedAt'] = FieldValue.serverTimestamp();
    }

    await leadRef.update(update);
    await leadRef.collection('activities').add({
      'type': 'status_update',
      'summary': summary ?? 'Lead updated to ${status.label}.',
      'actorUid': actorUid,
      'actorEmail': actorEmail,
      'actorName': actorName,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> addMarketingLeadActivity({
    required String leadId,
    required String type,
    required String summary,
    required String actorUid,
    required String actorEmail,
    required String actorName,
  }) async {
    final leadRef = _db.collection('marketing_leads').doc(leadId);
    await leadRef.collection('activities').add({
      'type': type,
      'summary': summary,
      'actorUid': actorUid,
      'actorEmail': actorEmail,
      'actorName': actorName,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await leadRef.update({'updatedAt': FieldValue.serverTimestamp()});
  }

  static Future<FacilityCommunicationUsage> getFacilityCommunicationUsage(
      String facilityId) async {
    final results = await Future.wait([
      EmailUsageService.getEmailUsage(facilityId),
      SMSUsageService.getSMSUsage(facilityId),
    ]);
    return FacilityCommunicationUsage(
      emailUsage: results[0] as EmailUsage,
      smsUsage: results[1] as SMSUsage,
    );
  }

  static Stream<List<CommissionPayoutRepRow>> commissionPayoutPeriodReps(
      String periodId) {
    return _db
        .collection('commission_payout_periods')
        .doc(periodId)
        .collection('reps')
        .orderBy('commissionAmount', descending: true)
        .snapshots()
        .map((s) => s.docs.map(CommissionPayoutRepRow.fromFirestore).toList());
  }

  static Future<String> createCommissionPayoutPeriod({
    required DateTime periodStart,
    required DateTime periodEnd,
    required bool commissionableOnly,
    required double minimumSaleAmount,
    required String rateType,
    required double rateValue,
    required String createdByUid,
    required String createdByEmail,
    required List<Map<String, dynamic>> repRows,
    required double totalSales,
    required double totalCommission,
    required int totalWon,
  }) async {
    final periodRef = _db.collection('commission_payout_periods').doc();
    final batch = _db.batch();
    batch.set(periodRef, {
      'periodStart': Timestamp.fromDate(periodStart),
      'periodEnd': Timestamp.fromDate(periodEnd),
      'status': 'open',
      'commissionableOnly': commissionableOnly,
      'minimumSaleAmount': minimumSaleAmount,
      'rateType': rateType,
      'rateValue': rateValue,
      'createdByUid': createdByUid,
      'createdByEmail': createdByEmail,
      'totalSales': totalSales,
      'totalCommission': totalCommission,
      'totalWon': totalWon,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    for (final row in repRows) {
      final repRef = periodRef.collection('reps').doc();
      batch.set(repRef, {
        ...row,
        'paid': false,
        'paidAt': null,
        'paidByEmail': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    return periodRef.id;
  }

  static Future<void> closeCommissionPayoutPeriod(String periodId) async {
    await _db.collection('commission_payout_periods').doc(periodId).update({
      'status': 'closed',
      'updatedAt': FieldValue.serverTimestamp(),
      'closedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> reopenCommissionPayoutPeriod(String periodId) async {
    await _db.collection('commission_payout_periods').doc(periodId).update({
      'status': 'open',
      'updatedAt': FieldValue.serverTimestamp(),
      'closedAt': null,
    });
  }

  static Future<void> setCommissionRepPaid({
    required String periodId,
    required String repDocId,
    required bool paid,
    required String actorEmail,
  }) async {
    await _db
        .collection('commission_payout_periods')
        .doc(periodId)
        .collection('reps')
        .doc(repDocId)
        .update({
      'paid': paid,
      'paidAt': paid ? FieldValue.serverTimestamp() : null,
      'paidByEmail': paid ? actorEmail : null,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> setAccountSuspended({
    required String accountId,
    required bool suspended,
    String? reason,
    required String actorUid,
    required String actorEmail,
  }) async {
    final update = <String, dynamic>{
      'suspended': suspended,
      'updatedAt': FieldValue.serverTimestamp(),
      'suspendedByUid': suspended ? actorUid : null,
      'suspendedByEmail': suspended ? actorEmail : null,
      'suspendedAt': suspended ? FieldValue.serverTimestamp() : null,
      'suspensionReason': suspended ? reason : null,
    };
    if (suspended) {
      update['subscriptionStatus'] = 'cancelled';
      update['subscriptionCurrentPeriodEnd'] = FieldValue.delete();
      update['subscriptionTrialEnd'] = FieldValue.delete();
    }
    await _db
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .update(update);
  }
}
