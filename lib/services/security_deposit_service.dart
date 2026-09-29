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

  /// The deposit on the tenant doc read in [txn], or null when none is on
  /// file. Throws when the tenant is gone.
  static Future<SecurityDeposit?> _current(
    Transaction txn,
    DocumentReference<Map<String, dynamic>> tenantRef,
  ) async {
    final snap = await txn.get(tenantRef);
    final data = snap.data();
    if (!snap.exists || data == null) {
      throw SecurityDepositException('This tenant no longer exists.');
    }
    final raw = data['securityDeposit'];
    return raw is Map
        ? SecurityDeposit.fromMap(Map<String, dynamic>.from(raw))
        : null;
  }

  /// Records a deposit the facility holds, or corrects the one on file.
  /// Refused once the deposit is settled: the settlement is the record of
  /// where the money went.
  static Future<SecurityDeposit> record({
    required String facilityId,
    required String tenantId,
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
    await _firestore.runTransaction<void>((txn) async {
      before = await _current(txn, tenantRef);
      if (before != null && !before!.isHeld) {
        throw SecurityDepositException(
            'This security deposit has already been settled.');
      }
      after = SecurityDeposit(
        amount: SecurityDeposit.toCents(amount),
        receivedDate:
            receivedDate == null ? null : SecurityDeposit.noonUtc(receivedDate),
        method: method,
        reference: reference,
        note: note,
        recordedAt: before?.recordedAt ?? now,
        recordedBy: before?.recordedBy ?? user.uid,
        updatedAt: now,
      );
      txn.update(tenantRef, {
        'securityDeposit': after.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    await AuditService.logEvent(
      facilityId: facilityId,
      eventType: before == null
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
  static Future<bool> remove({
    required String facilityId,
    required String tenantId,
  }) async {
    _signedInUser();
    final tenantRef = _tenantRef(facilityId, tenantId);

    SecurityDeposit? before;
    await _firestore.runTransaction<void>((txn) async {
      before = await _current(txn, tenantRef);
      if (before == null) return;
      if (!before!.isHeld) {
        throw SecurityDepositException(
            'A settled security deposit cannot be removed.');
      }
      txn.update(tenantRef, {
        'securityDeposit': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
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
    await _firestore.runTransaction<void>((txn) async {
      final current = await _current(txn, tenantRef);
      if (current == null) {
        throw SecurityDepositException('No security deposit is on file.');
      }
      before = current;
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
      final ledgerEntry = plan.ledgerEntry;
      if (ledgerEntry != null) txn.set(ledgerRef, ledgerEntry);
      txn.update(tenantRef, {
        'securityDeposit': plan.deposit,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

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
