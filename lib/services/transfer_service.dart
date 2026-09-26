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

      // Update status to in progress
      await transferDoc.reference.update({
        'status': TransferStatus.inProgress.name,
      });

      // Create ledger entries
      final ledgerEntryIds = <String>[];

      // Refund from old unit (if positive)
      if (transfer.fromUnitProratedRent > 0) {
        final refundEntry = await LedgerService.createLedgerEntry(
          tenantId: transfer.tenantId,
          facilityId: facilityId,
          type: LedgerEntryType.credit,
          amount: transfer.fromUnitProratedRent,
          description: 'Transfer refund: ${transfer.fromUnitNumber} (prorated)',
          entryDate: transfer.transferDate,
          dueDate: transfer.transferDate,
          status: LedgerEntryStatus.posted,
          metadata: {
            'transferId': transferId,
            'unitId': transfer.fromUnitId,
            'unitNumber': transfer.fromUnitNumber,
            'type': 'transfer_refund',
          },
        );
        ledgerEntryIds.add(refundEntry.id);
      }

      // Charge for new unit
      if (transfer.toUnitProratedRent > 0) {
        final chargeEntry = await LedgerService.createLedgerEntry(
          tenantId: transfer.tenantId,
          facilityId: facilityId,
          type: LedgerEntryType.rentCharge,
          amount: transfer.toUnitProratedRent,
          description: 'Transfer charge: ${transfer.toUnitNumber} (prorated)',
          entryDate: transfer.transferDate,
          dueDate: transfer.transferDate,
          status: LedgerEntryStatus.posted,
          metadata: {
            'transferId': transferId,
            'unitId': transfer.toUnitId,
            'unitNumber': transfer.toUnitNumber,
            'type': 'transfer_charge',
          },
        );
        ledgerEntryIds.add(chargeEntry.id);
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
        await TenantService.updateTenant(
          facilityId: facilityId,
          tenantId: transfer.tenantId,
          unitNumber: transfer.toUnitNumber,
          unitId: transfer.toUnitId,
          monthlyRate: transfer.toUnitRate,
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

