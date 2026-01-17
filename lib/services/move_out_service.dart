import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/invoice_line_item_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart'
    show LedgerEntry, LedgerEntryStatus, LedgerEntryType;
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/gate_access_service.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';

/// Service for managing move-out workflow
class MoveOutService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Calculate move-out charges and refunds
  static Future<MoveOutCalculation> calculateMoveOutCharges({
    required String tenantId,
    required String facilityId,
    required String contractId,
    required DateTime moveOutDate,
    double? cleaningFee,
    double? damageFee,
    double? otherFees,
    bool prorateRent = true,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 [MoveOut] Calculating move-out charges for tenant: $tenantId');
      }

      // Get current ledger balance
      final currentBalance = await LedgerService.getLedgerBalance(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      // Get tenant to find monthly rate
      final tenantModel = await TenantService.getTenantById(facilityId, tenantId);
      if (tenantModel == null) {
        throw Exception('Tenant not found');
      }

      final lineItems = <InvoiceLineItem>[];
      double totalCharges = 0.0;

      // 1. Prorated rent (if move-out is mid-month)
      if (prorateRent && tenantModel.monthlyRate > 0) {
        final daysInMonth = DateTime(moveOutDate.year, moveOutDate.month + 1, 0).day;
        final daysUsed = moveOutDate.day;
        final dailyRate = tenantModel.monthlyRate / daysInMonth;
        final proratedRent = dailyRate * daysUsed;

        if (proratedRent > 0) {
          lineItems.add(InvoiceLineItem(
            id: 'prorated_rent_${DateTime.now().millisecondsSinceEpoch}',
            type: InvoiceLineItemType.proratedRent,
            description: 'Prorated Rent (${daysUsed} days)',
            amount: proratedRent,
            isProrated: true,
            dueDate: moveOutDate,
          ));
          totalCharges += proratedRent;
        }
      }

      // 2. Cleaning fee (if provided)
      if (cleaningFee != null && cleaningFee > 0) {
        lineItems.add(InvoiceLineItem(
          id: 'cleaning_fee_${DateTime.now().millisecondsSinceEpoch}',
          type: InvoiceLineItemType.otherFee,
          description: 'Cleaning Fee',
          amount: cleaningFee,
          isProrated: false,
          dueDate: moveOutDate,
        ));
        totalCharges += cleaningFee;
      }

      // 3. Damage fee (if provided)
      if (damageFee != null && damageFee > 0) {
        lineItems.add(InvoiceLineItem(
          id: 'damage_fee_${DateTime.now().millisecondsSinceEpoch}',
          type: InvoiceLineItemType.otherFee,
          description: 'Damage Fee',
          amount: damageFee,
          isProrated: false,
          dueDate: moveOutDate,
        ));
        totalCharges += damageFee;
      }

      // 4. Other fees (if provided)
      if (otherFees != null && otherFees > 0) {
        lineItems.add(InvoiceLineItem(
          id: 'other_fees_${DateTime.now().millisecondsSinceEpoch}',
          type: InvoiceLineItemType.otherFee,
          description: 'Other Fees',
          amount: otherFees,
          isProrated: false,
          dueDate: moveOutDate,
        ));
        totalCharges += otherFees;
      }

      // Calculate final balance (current balance + new charges)
      final finalBalance = currentBalance + totalCharges;

      // Calculate refund (if balance is negative)
      final refundAmount = finalBalance < 0 ? finalBalance.abs() : 0.0;

      if (kDebugMode) {
        print('💰 [MoveOut] Current Balance: \$${currentBalance.toStringAsFixed(2)}');
        print('💰 [MoveOut] New Charges: \$${totalCharges.toStringAsFixed(2)}');
        print('💰 [MoveOut] Final Balance: \$${finalBalance.toStringAsFixed(2)}');
        print('💰 [MoveOut] Refund Amount: \$${refundAmount.toStringAsFixed(2)}');
      }

      return MoveOutCalculation(
        lineItems: lineItems,
        currentBalance: currentBalance,
        newCharges: totalCharges,
        finalBalance: finalBalance,
        refundAmount: refundAmount,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [MoveOut] Error calculating charges: $e');
      }
      rethrow;
    }
  }

  /// Complete move-out workflow using Cloud Function for transaction safety
  static Future<MoveOutResult> completeMoveOut({
    required String tenantId,
    required String facilityId,
    required String contractId,
    required String unitId,
    required DateTime moveOutDate,
    required MoveOutCalculation calculation,
    String? moveOutNotes,
    bool processRefund = false,
    String? refundMethod, // 'cash', 'check', 'creditCard', 'ach'
    String? refundReferenceId,
    bool useCloudFunction = true, // Use Cloud Function by default for transaction safety
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [MoveOut] Starting move-out process for tenant: $tenantId');
      }

      // Use Cloud Function for transaction-safe move-out processing
      if (useCloudFunction) {
        return await _completeMoveOutViaCloudFunction(
          tenantId: tenantId,
          facilityId: facilityId,
          contractId: contractId,
          unitId: unitId,
          moveOutDate: moveOutDate,
          calculation: calculation,
          moveOutNotes: moveOutNotes,
          processRefund: processRefund,
          refundMethod: refundMethod,
          refundReferenceId: refundReferenceId,
        );
      }

      List<String> ledgerEntryIds = [];

      // Step 1: Create ledger entries for move-out charges
      for (final lineItem in calculation.lineItems) {
        final entry = await LedgerService.createLedgerEntry(
          tenantId: tenantId,
          facilityId: facilityId,
          type: LedgerEntryType.moveOutFee,
          amount: lineItem.amount,
          description: lineItem.description,
          referenceId: contractId,
          entryDate: moveOutDate,
          status: LedgerEntryStatus.posted,
          metadata: {
            'lineItemId': lineItem.id,
            'moveOutDate': moveOutDate.toIso8601String(),
          },
        );

        ledgerEntryIds.add(entry.id);
      }

      // Step 2: Process refund if applicable
      if (processRefund && calculation.refundAmount > 0) {
        // Create refund ledger entry
        final refundEntry = await LedgerService.createLedgerEntry(
          tenantId: tenantId,
          facilityId: facilityId,
          type: LedgerEntryType.refund,
          amount: -calculation.refundAmount, // Negative for refunds
          description: 'Move-out Refund - ${refundMethod ?? 'Cash'}',
          referenceId: refundReferenceId,
          entryDate: DateTime.now(),
          status: LedgerEntryStatus.posted,
          metadata: {
            'moveOutRefund': true,
            'refundMethod': refundMethod,
            'contractId': contractId,
          },
        );

        ledgerEntryIds.add(refundEntry.id);

        // Process refund via Stripe if credit card or ACH
        if (refundMethod == 'creditCard' || refundMethod == 'ach') {
          try {
            // Call Cloud Function to process refund
            final result = await _processStripeRefund(
              facilityId: facilityId,
              tenantId: tenantId,
              amount: calculation.refundAmount,
              refundMethod: refundMethod,
              referenceId: refundReferenceId,
            );
            
            if (kDebugMode) {
              print('💸 [MoveOut] Stripe refund processed: $result');
            }
          } catch (e) {
            if (kDebugMode) {
              print('⚠️ [MoveOut] Error processing Stripe refund: $e');
            }
            // Don't fail move-out if refund fails - it's logged in ledger
          }
        } else {
          // Cash/Check refunds are handled manually
          if (kDebugMode) {
            print('💸 [MoveOut] Refund processed: \$${calculation.refundAmount.toStringAsFixed(2)} via $refundMethod');
          }
        }
      }

      // Step 3: Update contract with move-out status
      // Note: ContractService.updateContract may need to be enhanced to support move-out fields
      // For now, we'll update directly via Firestore
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'moveOutStatus': MoveOutStatus.completed.name,
        'moveOutDate': Timestamp.fromDate(moveOutDate),
        'moveOutCharges': calculation.newCharges,
        'moveOutRefund': calculation.refundAmount,
        if (moveOutNotes != null && moveOutNotes!.isNotEmpty) 'moveOutNotes': moveOutNotes,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Step 4: Update unit status to available
      await UnitService.updateUnit(
        unitId: unitId,
        facilityId: facilityId,
        status: UnitStatus.available,
        moveOutDate: moveOutDate,
      );

      // Step 5: Deactivate gate access
      try {
        // Get all gate access codes for this tenant
        final gateAccessStream = GateAccessService.getGateAccessStream(facilityId);
        await for (final accessList in gateAccessStream) {
          final tenantAccess = accessList.where((a) => a.tenantId == tenantId);
          for (final access in tenantAccess) {
            await GateAccessService.updateGateAccess(
              facilityId: facilityId,
              accessId: access.id,
              isActive: false,
            );
          }
          break; // Only need first batch
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ [MoveOut] Could not deactivate gate access: $e');
        }
        // Don't fail move-out if gate access fails
      }

      // Step 6: Update tenant (clear unit assignment, mark as inactive if needed)
      await TenantService.updateTenant(
        tenantId: tenantId,
        facilityId: facilityId,
        unitNumber: '', // Clear unit assignment
        isActive: false, // Mark tenant as inactive
      );

      // Audit log
      await AuditService.logMoveOutCompleted(
        facilityId: facilityId,
        tenantId: tenantId,
        unitId: unitId,
        contractId: contractId,
        charges: calculation.newCharges,
        refund: calculation.refundAmount,
      );

      if (kDebugMode) {
        print('✅ [MoveOut] Move-out completed successfully');
        print('   - Charges: \$${calculation.newCharges.toStringAsFixed(2)}');
        print('   - Refund: \$${calculation.refundAmount.toStringAsFixed(2)}');
        print('   - Ledger Entries: ${ledgerEntryIds.length}');
      }

      return MoveOutResult(
        success: true,
        ledgerEntryIds: ledgerEntryIds,
        charges: calculation.newCharges,
        refund: calculation.refundAmount,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [MoveOut] Error completing move-out: $e');
      }
      return MoveOutResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Complete move-out via Cloud Function (transaction-safe)
  static Future<MoveOutResult> _completeMoveOutViaCloudFunction({
    required String tenantId,
    required String facilityId,
    required String contractId,
    required String unitId,
    required DateTime moveOutDate,
    required MoveOutCalculation calculation,
    String? moveOutNotes,
    bool processRefund = false,
    String? refundMethod,
    String? refundReferenceId,
  }) async {
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('processMoveOut');

      if (kDebugMode) {
        print('🔄 [MoveOut] Calling processMoveOut Cloud Function...');
      }

      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'contractId': contractId,
        'unitId': unitId,
        'moveOutDate': moveOutDate.toIso8601String(),
        'moveOutCharges': calculation.newCharges,
        'moveOutRefund': calculation.refundAmount,
        'moveOutNotes': moveOutNotes,
        'processRefund': processRefund && calculation.refundAmount > 0,
        'refundMethod': refundMethod,
        'refundReferenceId': refundReferenceId,
      });

      final data = result.data as Map<String, dynamic>;

      if (kDebugMode) {
        print('✅ [MoveOut] Cloud Function completed successfully');
      }

      return MoveOutResult(
        success: data['success'] ?? false,
        charges: calculation.newCharges,
        refund: calculation.refundAmount,
      );
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [MoveOut] Cloud Function error: ${e.code} - ${e.message}');
      }
      return MoveOutResult(
        success: false,
        error: 'Cloud Function Error: ${e.message}',
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [MoveOut] Error calling Cloud Function: $e');
      }
      return MoveOutResult(
        success: false,
        error: 'Failed to process move-out: $e',
      );
    }
  }

  /// Process refund via Stripe Cloud Function
  static Future<String> _processStripeRefund({
    required String facilityId,
    required String tenantId,
    required double amount,
    required String? refundMethod,
    String? referenceId,
  }) async {
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('processRefund');

      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'amount': amount,
        'refundMethod': refundMethod,
        'referenceId': referenceId,
      });

      return result.data['refundId'] as String? ?? 'unknown';
    } catch (e) {
      if (kDebugMode) {
        print('❌ [MoveOut] Error calling refund Cloud Function: $e');
      }
      rethrow;
    }
  }
}

class MoveOutCalculation {
  final List<InvoiceLineItem> lineItems;
  final double currentBalance;
  final double newCharges;
  final double finalBalance;
  final double refundAmount;

  MoveOutCalculation({
    required this.lineItems,
    required this.currentBalance,
    required this.newCharges,
    required this.finalBalance,
    required this.refundAmount,
  });
}

class MoveOutResult {
  final bool success;
  final List<String> ledgerEntryIds;
  final double? charges;
  final double? refund;
  final String? error;

  MoveOutResult({
    required this.success,
    this.ledgerEntryIds = const [],
    this.charges,
    this.refund,
    this.error,
  });
}

