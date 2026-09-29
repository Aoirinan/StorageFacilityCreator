import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/security_deposit_model.dart';
import 'package:sfcapp/services/audit_service.dart';

/// A refusal the owner can read as it is (shown in a snackbar).
class SecurityDepositException implements Exception {
  SecurityDepositException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The writes that settle a held deposit: the tenant's new `securityDeposit`
/// map and, when part of it goes against the balance, the one ledger row.
class DepositSettlementPlan {
  const DepositSettlementPlan({
    required this.deposit,
    required this.ledgerEntry,
    required this.appliedAmount,
    required this.refundedAmount,
  });

  /// The settled deposit, as written to the tenant doc.
  final Map<String, dynamic> deposit;

  /// The 'Security deposit applied' credit, as written to ledgers; null when
  /// nothing was applied. There is never a row for the refunded part: that
  /// money was never on the ledger.
  final Map<String, dynamic>? ledgerEntry;
  final double appliedAmount;
  final double refundedAmount;
}

int _cents(double value) => (value * 100).round();

/// How [deposit] settles when [appliedAmount] goes against the balance and
/// [refundedAmount] goes back to the tenant. Pure, so the arithmetic and the
/// row shapes can be tested without Firestore.
///
/// Refused when the deposit is not held (a second press after it settled),
/// when either amount is negative, or when the two do not add up to the
/// deposit to the cent.
DepositSettlementPlan planDepositSettlement({
  required SecurityDeposit deposit,
  required double appliedAmount,
  required double refundedAmount,
  PaymentMethod? refundMethod,
  String? refundReference,
  required String tenantId,
  required String facilityId,
  required String uid,
  required DateTime now,
  required String ledgerEntryId,
}) {
  if (!deposit.isHeld) {
    throw SecurityDepositException(
        'This security deposit has already been settled.');
  }
  if (appliedAmount < 0 || refundedAmount < 0) {
    throw SecurityDepositException('Amounts cannot be negative.');
  }
  final applied = SecurityDeposit.toCents(appliedAmount);
  final refunded = SecurityDeposit.toCents(refundedAmount);
  if (_cents(applied) + _cents(refunded) != _cents(deposit.amount)) {
    throw SecurityDepositException(
        'Applied and refunded amounts must add up to the deposit '
        '(\$${deposit.amount.toStringAsFixed(2)}).');
  }

  Map<String, dynamic>? ledgerEntry;
  if (applied > 0) {
    // A credit, so it lowers what the tenant owes. Not a 'payment': no
    // money changed hands today, so Payments and the bank-deposit
    // reconciliation must not see new cash. Never a 'refund' row: those
    // are stored positive (they raise what is owed) and processMoveOut
    // and the statement disagree on their sign.
    ledgerEntry = LedgerEntry(
      id: ledgerEntryId,
      tenantId: tenantId,
      facilityId: facilityId,
      type: LedgerEntryType.credit,
      amount: -applied,
      description: 'Security deposit applied',
      entryDate: now,
      status: LedgerEntryStatus.posted,
      metadata: {
        'securityDepositApplied': true,
        'depositAmount': deposit.amount,
        if (deposit.receivedDate != null)
          'depositReceivedDate': Timestamp.fromDate(deposit.receivedDate!),
        'depositMethod': deposit.method.name,
        if (deposit.reference != null) 'depositReference': deposit.reference,
      },
      createdAt: now,
      createdBy: uid,
    ).toFirestore();
  }

  final settled = deposit.copyWith(
    status: SecurityDepositStatus.settled,
    updatedAt: now,
    settledAt: now,
    settledBy: uid,
    appliedAmount: applied,
    refundedAmount: refunded,
    refundMethod: refunded > 0 ? refundMethod : null,
    refundReference: refunded > 0 ? refundReference : null,
    appliedLedgerEntryId: applied > 0 ? ledgerEntryId : null,
  );

  return DepositSettlementPlan(
    deposit: settled.toMap(),
    ledgerEntry: ledgerEntry,
    appliedAmount: applied,
    refundedAmount: refunded,
  );
}

/// Records, corrects, removes and settles the security deposit a facility
/// holds for a tenant (tenants/{id}.securityDeposit).
///
/// Every write is a field update on the tenant, which owners and managers
/// may make, plus at settlement one ledger create of a type staff may write.
/// No callable: nothing here is new cash received today, so no payment doc
/// is made.
class SecurityDepositService {
  // Getters, not final fields, so tests can run the real code against a
  // fake Firestore and a signed-in fake user.
  static FirebaseFirestore get _firestore =>
      _firestoreForTesting ?? FirebaseFirestore.instance;
  static FirebaseFirestore? _firestoreForTesting;
  static FirebaseAuth get _auth => _authForTesting ?? FirebaseAuth.instance;
  static FirebaseAuth? _authForTesting;

  @visibleForTesting
  static set firestoreForTesting(FirebaseFirestore? firestore) =>
      _firestoreForTesting = firestore;

  @visibleForTesting
  static set authForTesting(FirebaseAuth? auth) => _authForTesting = auth;

  static DocumentReference<Map<String, dynamic>> _facility(String facilityId) =>
      _firestore.collection('facilities').doc(facilityId);

  static DocumentReference<Map<String, dynamic>> _tenantRef(
          String facilityId, String tenantId) =>
      _facility(facilityId).collection('tenants').doc(tenantId);

  static User _signedInUser() {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');
    return user;
  }

  /// The tenant doc read in [txn], or null when the tenant is gone.
  static Future<Map<String, dynamic>?> _tenantData(
    Transaction txn,
    DocumentReference<Map<String, dynamic>> tenantRef,
  ) async {
    final snap = await txn.get(tenantRef);
    final data = snap.data();
    return snap.exists ? data : null;
  }

  /// The deposit in a tenant doc's [data], or null when none is on file.
  static SecurityDeposit? _depositIn(Map<String, dynamic> data) {
    final raw = data['securityDeposit'];
    return raw is Map
        ? SecurityDeposit.fromMap(Map<String, dynamic>.from(raw))
        : null;
  }

  /// Whether [stored] is still the deposit the dialog opened with
  /// ([expected]): both none, or the same deposit in the same state. Any
  /// save, correction, settlement or removal since changes the status or a
  /// timestamp, so the whole map is compared.
  static bool _unchanged(SecurityDeposit? stored, SecurityDeposit? expected) {
    if (stored == null || expected == null) return stored == expected;
    return mapEquals(stored.toMap(), expected.toMap());
  }

  /// The tenant doc's `securityDepositHistory` as stored, oldest first, or
  /// empty when missing. Kept as written rather than run through the model,
  /// so an entry another build wrote loses nothing on the way back.
  static List<Map<String, dynamic>> _storedHistory(Object? raw) => [
        if (raw is List)
          for (final entry in raw)
            if (entry is Map) Map<String, dynamic>.from(entry),
      ];

  static const _tenantGone = 'This tenant no longer exists.';

  /// Why a save or Remove from a dialog that went stale is refused.
  @visibleForTesting
  static const changedSinceOpened =
      'This deposit changed since you opened it. Close and reopen the '
      'tenant page.';

  // Each transaction below returns why it wrote nothing (null when it
  // wrote) instead of throwing, and the refusal is thrown once the
  // transaction is back. On web a Dart error thrown inside a transaction
  // handler comes back as an opaque JS error, so the owner would read a
  // generic failure instead of why (see PaymentService.markPaymentAsPaid).

  /// Records a deposit the facility holds, corrects the held one on file,
  /// or starts a new one over a settled one. A settled deposit is not a
  /// dead end: a tenant who moves out and comes back, or who pays a fresh
  /// deposit, gets a new held deposit, and the settled one is kept on the
  /// tenant's `securityDepositHistory` (its applied part stays on the
  /// ledger either way).
  ///
  /// [expected] is the deposit the dialog opened with (null when none was
  /// on file). The save is refused when the stored one is no longer it: a
  /// dialog left open on a held deposit that was then settled elsewhere
  /// would otherwise file the settled one and write a new held deposit,
  /// which could be settled again for a second credit.
  static Future<SecurityDeposit> record({
    required String facilityId,
    required String tenantId,
    required SecurityDeposit? expected,
    required double amount,
    DateTime? receivedDate,
    required PaymentMethod method,
    String? reference,
    String? note,
  }) async {
    final user = _signedInUser();
    if (amount <= 0) {
      throw SecurityDepositException('Enter a deposit amount above \$0.');
    }
    final now = DateTime.now();
    final tenantRef = _tenantRef(facilityId, tenantId);

    SecurityDeposit? before;
    late SecurityDeposit after;
    final refusal = await _firestore.runTransaction<String?>((txn) async {
      final data = await _tenantData(txn, tenantRef);
      if (data == null) return _tenantGone;
      before = _depositIn(data);
      if (!_unchanged(before, expected)) return changedSinceOpened;
      // Only a held deposit is being corrected; a settled one is done with,
      // so the new deposit gets its own recorded-at and recorded-by.
      final held = before?.isHeld == true ? before : null;
      after = SecurityDeposit(
        amount: SecurityDeposit.toCents(amount),
        receivedDate:
            receivedDate == null ? null : SecurityDeposit.noonUtc(receivedDate),
        method: method,
        reference: reference,
        note: note,
        recordedAt: held?.recordedAt ?? now,
        recordedBy: held?.recordedBy ?? user.uid,
        updatedAt: now,
      );
      txn.update(tenantRef, {
        'securityDeposit': after.toMap(),
        // The settled deposit goes to the end of the history list. The
        // list is read and written back in this transaction, so two saves
        // at once cannot lose an entry.
        if (before != null && held == null)
          'securityDepositHistory': [
            ..._storedHistory(data['securityDepositHistory']),
            before!.toMap(),
          ],
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return null;
    });
    if (refusal != null) throw SecurityDepositException(refusal);

    await AuditService.logEvent(
      facilityId: facilityId,
      // A new deposit, whether nothing or a settled one was on file; the
      // settled one is still the event's before map.
      eventType: before?.isHeld != true
          ? 'tenant.securityDeposit.recorded'
          : 'tenant.securityDeposit.updated',
      targetType: 'tenant',
      targetId: tenantId,
      tenantId: tenantId,
      before: before?.toMap(),
      after: after.toMap(),
    );
    if (kDebugMode) {
      print('✅ [SecurityDeposit] Recorded for tenant $tenantId: '
          '\$${after.amount.toStringAsFixed(2)}');
    }
    return after;
  }

  /// Takes a mistaken deposit off the tenant. Only while held: a settled
  /// deposit is history (its applied part is on the ledger) and stays.
  /// Returns false when there was nothing on file.
  ///
  /// [expected] is the deposit the dialog opened with; the removal is
  /// refused when the stored one is no longer it (settled, corrected or
  /// replaced since), as in [record].
  static Future<bool> remove({
    required String facilityId,
    required String tenantId,
    required SecurityDeposit? expected,
  }) async {
    _signedInUser();
    final tenantRef = _tenantRef(facilityId, tenantId);

    SecurityDeposit? before;
    final refusal = await _firestore.runTransaction<String?>((txn) async {
      final data = await _tenantData(txn, tenantRef);
      if (data == null) return _tenantGone;
      before = _depositIn(data);
      if (!_unchanged(before, expected)) return changedSinceOpened;
      if (before == null) return null;
      if (!before!.isHeld) {
        return 'A settled security deposit cannot be removed.';
      }
      txn.update(tenantRef, {
        'securityDeposit': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return null;
    });
    if (refusal != null) throw SecurityDepositException(refusal);
    if (before == null) return false;

    await AuditService.logEvent(
      facilityId: facilityId,
      eventType: 'tenant.securityDeposit.removed',
      targetType: 'tenant',
      targetId: tenantId,
      tenantId: tenantId,
      before: before!.toMap(),
    );
    return true;
  }

  /// Settles the held deposit: [appliedAmount] is posted as one ledger
  /// credit against the balance, [refundedAmount] is recorded on the tenant
  /// as handed back. One transaction, so a double press finds the deposit
  /// settled and is refused rather than posting a second credit.
  static Future<SecurityDeposit> settle({
    required String facilityId,
    required String tenantId,
    required double appliedAmount,
    required double refundedAmount,
    PaymentMethod? refundMethod,
    String? refundReference,
  }) async {
    final user = _signedInUser();
    final now = DateTime.now();
    final tenantRef = _tenantRef(facilityId, tenantId);
    // The row's id is fixed before the transaction so the tenant can point
    // at it (appliedLedgerEntryId) in the same commit.
    final ledgerRef = _facility(facilityId).collection('ledgers').doc();

    late SecurityDeposit before;
    late DepositSettlementPlan plan;
    final refusal = await _firestore.runTransaction<String?>((txn) async {
      final data = await _tenantData(txn, tenantRef);
      if (data == null) return _tenantGone;
      final current = _depositIn(data);
      if (current == null) return 'No security deposit is on file.';
      before = current;
      try {
        plan = planDepositSettlement(
          deposit: current,
          appliedAmount: appliedAmount,
          refundedAmount: refundedAmount,
          refundMethod: refundMethod,
          refundReference: refundReference,
          tenantId: tenantId,
          facilityId: facilityId,
          uid: user.uid,
          now: now,
          ledgerEntryId: ledgerRef.id,
        );
      } on SecurityDepositException catch (e) {
        return e.message;
      }
      final ledgerEntry = plan.ledgerEntry;
      if (ledgerEntry != null) txn.set(ledgerRef, ledgerEntry);
      txn.update(tenantRef, {
        'securityDeposit': plan.deposit,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return null;
    });
    if (refusal != null) throw SecurityDepositException(refusal);

    final after = SecurityDeposit.fromMap(plan.deposit);
    await AuditService.logEvent(
      facilityId: facilityId,
      eventType: 'tenant.securityDeposit.settled',
      targetType: 'tenant',
      targetId: tenantId,
      tenantId: tenantId,
      before: before.toMap(),
      after: plan.deposit,
      metadata: {
        'appliedAmount': plan.appliedAmount,
        'refundedAmount': plan.refundedAmount,
        if (plan.ledgerEntry != null) 'appliedLedgerEntryId': ledgerRef.id,
      },
    );
    if (kDebugMode) {
      print('✅ [SecurityDeposit] Settled for tenant $tenantId: '
          '\$${plan.appliedAmount.toStringAsFixed(2)} applied, '
          '\$${plan.refundedAmount.toStringAsFixed(2)} refunded');
    }
    return after;
  }
}
