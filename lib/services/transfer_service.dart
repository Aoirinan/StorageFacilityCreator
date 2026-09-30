import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/transfer_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/prorate_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/unit_number.dart';

/// A transfer that cannot go ahead as it stands: the unit to move out of is
/// not (or no longer) the tenant's, or the unit to move into is taken.
class TransferRefusedException implements UserFacingException {
  const TransferRefusedException(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

/// One ledger entry a completed transfer posts. [amount] is signed the way
/// the ledger stores it: negative for the credit, positive for the charge.
typedef TransferLedgerLine = ({
  LedgerEntryType type,
  double amount,
  String description,
  Map<String, dynamic> metadata,
});

/// Service for managing unit transfers
class TransferService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Calculate prorated rent for a unit
  /// Returns the amount owed for the remaining days in the month
  ///
  /// [isMoveIn] does not change the magnitude — leaving the old unit and
  /// taking the new one both cover transfer day through month end. The
  /// direction is applied by the caller, which subtracts the old unit's share
  /// from the new one's. The flag is kept so call sites still read clearly.
  ///
  /// This used to be a second copy of the proration arithmetic and had drifted
  /// from [ProrateService]: it measured from the raw timestamp (so the time of
  /// day a transfer was recorded moved the money), it lost a day across the
  /// spring daylight-saving change, and it returned an unrounded float straight
  /// into the ledger. Delegating keeps one implementation under test.
  static double calculateProratedRent({
    required double monthlyRate,
    required DateTime transferDate,
    bool isMoveIn = true,
  }) {
    return ProrateService.calculateProratedRent(
      monthlyRate: monthlyRate,
      moveInDate: transferDate,
    );
  }

  /// The unit [tenant] transfers out of, from the facility's [units], and
  /// the units they could pick from ([choices], the ones they occupy).
  /// [unit] is null when they occupy several and none, or more than one,
  /// has their unit number: the operator picks. Throws
  /// [TransferRefusedException] when they occupy none.
  ///
  /// The screen used to take the occupied unit numbered like the tenant,
  /// else any unit with that number, else the facility's first unit, which
  /// could be another tenant's.
  static ({UnitModel? unit, List<UnitModel> choices}) transferFromUnit(
    TenantModel tenant,
    Iterable<UnitModel> units,
  ) {
    final held = [
      for (final u in units)
        if (u.tenantId == tenant.id && u.status != UnitStatus.available) u
    ];
    if (held.isEmpty) {
      final name = tenant.name.trim().isEmpty ? 'This tenant' : tenant.name.trim();
      throw TransferRefusedException(
          '$name has no unit assigned, so there is nothing to transfer from. '
          'Assign their unit first (Units > unit > Assign Tenant).');
    }
    if (held.length == 1) return (unit: held.single, choices: held);
    // Their primary unit by id first: with unit numbers repeated across
    // areas, their number can name two of the units they hold.
    final primary = tenant.unitId?.trim() ?? '';
    for (final u in held) {
      if (primary.isNotEmpty && u.id == primary) {
        return (unit: u, choices: held);
      }
    }
    final named = [
      for (final u in held)
        if (sameUnitNumber(u.unitNumber, tenant.unitNumber)) u
    ];
    return (unit: named.length == 1 ? named.single : null, choices: held);
  }

  /// Why [transfer] cannot be completed now, or null. Checked before
  /// anything is written: completing used to free the from-unit whoever
  /// held it by then, and give the tenant the to-unit whoever had taken it.
  static TransferRefusedException? completionRefusal({
    required TransferModel transfer,
    required UnitModel? fromUnit,
    required UnitModel? toUnit,
  }) {
    if (fromUnit == null || fromUnit.tenantId != transfer.tenantId) {
      return TransferRefusedException(
          'Unit ${transfer.fromUnitNumber} is no longer assigned to this '
          'tenant, so it was not freed. Nothing was changed. Cancel this '
          'transfer and start a new one.');
    }
    if (toUnit == null || toUnit.status != UnitStatus.available) {
      return TransferRefusedException(
          'Unit ${transfer.toUnitNumber} is no longer available. Nothing was '
          'changed. Cancel this transfer and pick another unit.');
    }
    return null;
  }

  /// The tenant's rent and unit number once [transfer] completes
  /// ([unitNumber] null: left as it is). With no [otherUnits], the to-unit's
  /// rate and number, as before. With others, the from-unit's rate comes off
  /// their rent and the to-unit's goes on (never below zero), and their
  /// unit number moves to the new unit only if it named the unit they left:
  /// setting both to the new unit billed a tenant with units A and B who
  /// moved B to C for C alone, and labelled them C. [unitId] is the unit
  /// [unitNumber] names (the to-unit), null with it: updateTenant links it
  /// by id and makes it their primary unit (`unitId`, `unitArea`).
  ///
  /// Whether the label named the unit they left is decided by id when the
  /// tenant has a primary unit ([currentUnitId], their `unitId`): the
  /// transfer's from-number is a copy taken when it was created, and with
  /// numbers repeated across areas "12" can be a unit they keep. By number
  /// only for a tenant with no `unitId`.
  static ({double monthlyRate, String? unitNumber, String? unitId})
      tenantAfterTransfer({
    required TransferModel transfer,
    required double currentRate,
    required String currentUnitNumber,
    String? currentUnitId,
    required List<UnitModel> otherUnits,
  }) {
    if (otherUnits.isEmpty) {
      return (
        monthlyRate: transfer.toUnitRate,
        unitNumber: transfer.toUnitNumber,
        unitId: transfer.toUnitId,
      );
    }
    final rate = currentRate - transfer.fromUnitRate + transfer.toUnitRate;
    final label = currentUnitNumber.trim();
    final primary = currentUnitId?.trim() ?? '';
    final bool movesLabel;
    if (label.isEmpty) {
      movesLabel = true;
    } else if (primary.isNotEmpty) {
      movesLabel = primary == transfer.fromUnitId;
    } else {
      // A label that names one of the units they keep stays.
      final namesKept = otherUnits.any((u) => u.unitNumber.trim() == label);
      movesLabel = !namesKept && sameUnitNumber(label, transfer.fromUnitNumber);
    }
    return (
      monthlyRate: rate <= 0 ? 0 : (rate * 100).round() / 100,
      unitNumber: movesLabel ? transfer.toUnitNumber : null,
      unitId: movesLabel ? transfer.toUnitId : null,
    );
  }

  /// Create a transfer request
  static Future<TransferModel> createTransfer({
    required String facilityId,
    required String tenantId,
    required String fromUnitId,
    required String toUnitId,
    required DateTime transferDate,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Get units
      final fromUnit = await UnitService.getUnit(facilityId, fromUnitId);
      final toUnit = await UnitService.getUnit(facilityId, toUnitId);
      
      if (fromUnit == null || toUnit == null) {
        throw Exception('Unit not found');
      }

      // Verify from unit is occupied by this tenant
      if (fromUnit.tenantId != tenantId) {
        throw Exception('From unit is not occupied by this tenant');
      }

      // Verify to unit is available
      if (toUnit.status != UnitStatus.available) {
        throw Exception('To unit is not available');
      }

      // Calculate prorated amounts
      final fromProrated = calculateProratedRent(
        monthlyRate: fromUnit.monthlyRate,
        transferDate: transferDate,
        isMoveIn: false, // Moving out = refund
      );
      
      final toProrated = calculateProratedRent(
        monthlyRate: toUnit.monthlyRate,
        transferDate: transferDate,
        isMoveIn: true, // Moving in = charge
      );

      final netAmount = toProrated - fromProrated;

      final transfer = TransferModel(
        id: '',
        facilityId: facilityId,
        tenantId: tenantId,
        fromUnitId: fromUnitId,
        toUnitId: toUnitId,
        fromUnitNumber: fromUnit.unitNumber,
        toUnitNumber: toUnit.unitNumber,
        status: TransferStatus.pending,
        transferDate: transferDate,
        fromUnitProratedRent: fromProrated,
        toUnitProratedRent: toProrated,
        fromUnitRate: fromUnit.monthlyRate,
        toUnitRate: toUnit.monthlyRate,
        netAmount: netAmount,
        notes: notes,
        ledgerEntryIds: [],
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('transfers')
          .add(transfer.toFirestore());

      if (kDebugMode) {
        print('✅ [Transfer] Created transfer: ${docRef.id}');
      }

      return transfer.copyWith(id: docRef.id);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Transfer] Error creating transfer: $e');
      }
      rethrow;
    }
  }

  /// The ledger entries completing [transfer] posts: a credit for the
  /// from-unit's rent from transfer day to month end, then a charge for the
  /// to-unit's. Either is left out when its amount is zero.
  ///
  /// A tenant's balance is the signed sum of their posted amounts
  /// (LedgerService.getLedgerBalance, sumPostedLedgerEntries): charges are
  /// stored positive, payments and credits negative. The transfer credit
  /// used to be written positive, so leaving a unit with $30 of rent to
  /// give back put the tenant $30 further into debt instead of $30 ahead,
  /// and the two entries summed to fromUnit + toUnit rather than
  /// [TransferModel.netAmount]. Every balance reader (statements, the
  /// tenant's balance, the delinquency list, payment history) adds the
  /// signed amounts, so the credit has to be stored negative.
  static List<TransferLedgerLine> ledgerLines(TransferModel transfer) {
    final lines = <TransferLedgerLine>[];
    if (transfer.fromUnitProratedRent > 0) {
      lines.add((
        type: LedgerEntryType.credit,
        amount: -transfer.fromUnitProratedRent,
        description: 'Transfer refund: ${transfer.fromUnitNumber} (prorated)',
        metadata: {
          'transferId': transfer.id,
          'unitId': transfer.fromUnitId,
          'unitNumber': transfer.fromUnitNumber,
          'type': 'transfer_refund',
        },
      ));
    }
    if (transfer.toUnitProratedRent > 0) {
      lines.add((
        type: LedgerEntryType.rentCharge,
        amount: transfer.toUnitProratedRent,
        description: 'Transfer charge: ${transfer.toUnitNumber} (prorated)',
        metadata: {
          'transferId': transfer.id,
          'unitId': transfer.toUnitId,
          'unitNumber': transfer.toUnitNumber,
          'type': 'transfer_charge',
        },
      ));
    }
    return lines;
  }

  /// Complete a transfer
  static Future<void> completeTransfer({
    required String facilityId,
    required String transferId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Get transfer
      final transferDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('transfers')
          .doc(transferId)
          .get();

      if (!transferDoc.exists) {
        throw Exception('Transfer not found');
      }

      final transfer = TransferModel.fromFirestore(transferDoc);

      if (transfer.status != TransferStatus.pending) {
        throw Exception('Transfer is not in pending status');
      }

      // The units as they are now, not as they were when it was worked out.
      final refusal = completionRefusal(
        transfer: transfer,
        fromUnit: await UnitService.getUnit(facilityId, transfer.fromUnitId),
        toUnit: await UnitService.getUnit(facilityId, transfer.toUnitId),
      );
      if (refusal != null) throw refusal;
      // The other units they rent, read before either unit changes.
      final otherUnits = [
        for (final u in await TenantService.recordsFor(facilityId)
            .linkedUnits(transfer.tenantId))
          if (u.id != transfer.fromUnitId &&
              u.id != transfer.toUnitId &&
              u.status != UnitStatus.available)
            u
      ];

      // Update status to in progress
      await transferDoc.reference.update({
        'status': TransferStatus.inProgress.name,
      });

      // Create ledger entries
      final ledgerEntryIds = <String>[];
      for (final line in ledgerLines(transfer)) {
        final entry = await LedgerService.createLedgerEntry(
          tenantId: transfer.tenantId,
          facilityId: facilityId,
          type: line.type,
          amount: line.amount,
          description: line.description,
          entryDate: transfer.transferDate,
          dueDate: transfer.transferDate,
          status: LedgerEntryStatus.posted,
          metadata: line.metadata,
        );
        ledgerEntryIds.add(entry.id);
      }

      // Update units
      // Free up old unit
      await UnitService.updateUnit(
        facilityId: facilityId,
        unitId: transfer.fromUnitId,
        status: UnitStatus.available,
        tenantId: null,
      );

      // Assign new unit to tenant
      await UnitService.updateUnit(
        facilityId: facilityId,
        unitId: transfer.toUnitId,
        status: UnitStatus.occupied,
        tenantId: transfer.tenantId,
      );

      // Update tenant's unit number
      final tenant = await TenantService.getTenantById(facilityId, transfer.tenantId);
      
      if (tenant != null) {
        final after = tenantAfterTransfer(
          transfer: transfer,
          currentRate: tenant.monthlyRate,
          currentUnitNumber: tenant.unitNumber,
          currentUnitId: tenant.unitId,
          otherUnits: otherUnits,
        );
        await TenantService.updateTenant(
          facilityId: facilityId,
          tenantId: transfer.tenantId,
          unitNumber: after.unitNumber,
          unitId: after.unitId,
          monthlyRate: after.monthlyRate,
        );
      }

      // Mark transfer as completed
      await transferDoc.reference.update({
        'status': TransferStatus.completed.name,
        'completedAt': FieldValue.serverTimestamp(),
        'ledgerEntryIds': ledgerEntryIds,
      });

      // Audit log
      await AuditService.logTransferCompleted(
        facilityId: facilityId,
        tenantId: transfer.tenantId,
        transferId: transferId,
        fromUnitNumber: transfer.fromUnitNumber,
        toUnitNumber: transfer.toUnitNumber,
        netAmount: transfer.netAmount,
      );

      if (kDebugMode) {
        print('✅ [Transfer] Completed transfer: $transferId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Transfer] Error completing transfer: $e');
      }
      rethrow;
    }
  }

  /// Cancel a transfer
  static Future<void> cancelTransfer({
    required String facilityId,
    required String transferId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('transfers')
          .doc(transferId)
          .update({
        'status': TransferStatus.cancelled.name,
      });

      if (kDebugMode) {
        print('✅ [Transfer] Cancelled transfer: $transferId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Transfer] Error cancelling transfer: $e');
      }
      rethrow;
    }
  }

  /// Get transfers for a facility
  static Stream<List<TransferModel>> getTransfersForFacilityStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('transfers')
        .where('isActive', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => TransferModel.fromFirestore(doc))
            .toList());
  }

  /// Get transfer by ID
  static Future<TransferModel?> getTransfer({
    required String facilityId,
    required String transferId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('transfers')
          .doc(transferId)
          .get();

      if (!doc.exists) return null;

      return TransferModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Transfer] Error getting transfer: $e');
      }
      rethrow;
    }
  }
}

