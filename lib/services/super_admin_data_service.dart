import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/user_model.dart';

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
      .map((snap) =>
          snap.docs.map((d) => UserModel.fromFirestore(d)).toList());
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
              final accountByOwner = {
                for (final a in accounts) a.ownerUid: a
              };

              return AsyncValue.data(facilities.map((f) {
                final owner = userMap[f.ownerUid];
                final account = accountByOwner[f.ownerUid];
                return SuperAdminFacilityRow(
                  facility: f,
                  ownerEmail: owner?.email ?? f.email ?? 'Unknown',
                  subscriptionStatus:
                      account?.subscriptionStatus.displayName,
                  subscriptionPeriodEnd:
                      account?.subscriptionCurrentPeriodEnd,
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
                totalUnits: facilities.fold(0, (s, f) => s + f.totalUnits),
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
    final doc = await _db
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .get();
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
    await _db
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .update({
      'subscriptionStatus': 'trialing',
      'subscriptionTrialEnd': Timestamp.fromDate(trialEnd),
      'subscriptionCurrentPeriodStart': Timestamp.fromDate(now),
      'subscriptionCurrentPeriodEnd': Timestamp.fromDate(trialEnd),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Revoke an active trial — sets status back to cancelled and clears trial end.
  static Future<void> revokeTrial(String accountId) async {
    await _db
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .update({
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
    await _db
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .update({
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
    await _db
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .update({
      'subscriptionStatus': 'cancelled',
      'rejectedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
