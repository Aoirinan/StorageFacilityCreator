import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/transfer_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';

/// Service for managing unit transfers
class TransferService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Calculate prorated rent for a unit
  /// Returns the amount owed for the remaining days in the month
  static double calculateProratedRent({
    required double monthlyRate,
    required DateTime transferDate,
    bool isMoveIn = true, // true = moving in (charge), false = moving out (refund)
  }) {
    final now = DateTime.now();
    final year = transferDate.year;
    final month = transferDate.month;
    
    // Get first and last day of the month
    final firstDay = DateTime(year, month, 1);
    final lastDay = DateTime(year, month + 1, 0);
    final daysInMonth = lastDay.day;
    
    // Calculate days
    int days;
    if (isMoveIn) {
      // Moving in: charge from transfer date to end of month
      days = lastDay.difference(transferDate).inDays + 1;
    } else {
      // Moving out: refund from transfer date to end of month
      days = lastDay.difference(transferDate).inDays + 1;
    }
    
    // Calculate prorated amount
    final dailyRate = monthlyRate / daysInMonth;
    return dailyRate * days;
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

