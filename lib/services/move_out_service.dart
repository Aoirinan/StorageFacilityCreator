import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/invoice_line_item_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart'
    show LedgerEntry, LedgerEntryStatus, LedgerEntryType;
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';

/// The unit a move-out vacates when the link names none: the one unit the
/// tenant holds, or among several the one their record names. Null when
/// that leaves it open, for the owner to choose; never another tenant's
/// unit. The screen fell back to the facility's first unit when the
/// tenant's unit number matched none.
UnitModel? unitToVacate({
  required List<UnitModel> units,
  required TenantModel tenant,
}) {
  final held = units.where((u) => u.tenantId == tenant.id).toList();
  if (held.length == 1) return held.single;
  final number = tenant.unitNumber.trim();
  // Their own units, or with none linked by id (an older record) a unit by
  // number that no other tenant holds.
  final candidates = held.isNotEmpty
      ? held
      : units.where((u) => (u.tenantId ?? '').trim().isEmpty).toList();
  final byNumber =
      candidates.where((u) => number.isNotEmpty && u.unitNumber.trim() == number);
  return byNumber.length == 1 ? byNumber.single : null;
}

/// Service for managing move-out workflow
class MoveOutService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Whether the scheduled rent job has already posted this tenant's rent for
  /// the month containing [month].
  ///
  /// The job tags its entries `metadata.chargeType == 'monthlyRent'` with the
  /// month and year, so this is an exact lookup rather than a guess from the
  /// description. Returns false on error: charging prorated rent for the days
  /// used is the safer wrong answer than issuing a credit for a month that was
  /// never billed.
  static Future<bool> _monthlyRentAlreadyCharged({
    required String facilityId,
    required String tenantId,
    required DateTime month,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .where('tenantId', isEqualTo: tenantId)
          .where('status', isEqualTo: 'posted')
          .where('metadata.chargeType', isEqualTo: 'monthlyRent')
          .where('metadata.year', isEqualTo: month.year)
          .where('metadata.month', isEqualTo: month.month)
          .limit(1)
          .get();
      return snapshot.docs.isNotEmpty;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [MoveOut] Could not check for an existing rent charge: $e');
      }
      return false;
    }
  }

  /// The rent line for a move-out, in dollars.
  ///
  /// Rent is billed in advance, so which way the money moves depends on
  /// whether this month was already posted:
  ///
  /// * [alreadyCharged] true — the tenant has paid for the whole month and is
  ///   owed the unused days back, so [amount] is the credit due.
  /// * false — the month was never billed, so [amount] is the charge for the
  ///   days actually used.
  ///
  /// The caller applies the sign. Extracted from [calculateMoveOutCharges] so
  /// the arithmetic can be tested without Firestore; the surrounding method
  /// reads a tenant, a balance and a ledger before it gets here.
  ///
  /// Day counts come from [moveOutDate].day rather than a date subtraction, so
  /// there is no daylight-saving truncation to worry about.
  static ({double amount, int days, int unusedDays}) moveOutRentAmount({
    required double monthlyRate,
    required DateTime moveOutDate,
    required bool alreadyCharged,
  }) {
    final daysInMonth =
        DateTime(moveOutDate.year, moveOutDate.month + 1, 0).day;
    final daysUsed = moveOutDate.day.clamp(0, daysInMonth);
    final daysUnused = daysInMonth - daysUsed;
    final dailyRate = monthlyRate / daysInMonth;
    final billableDays = alreadyCharged ? daysUnused : daysUsed;
    final amount =
        double.parse((dailyRate * billableDays).toStringAsFixed(2));
    return (amount: amount, days: daysUsed, unusedDays: daysUnused);
  }

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

      // 1. Rent for the month of move-out.
      //
      // Rent is billed in advance: the scheduled job posts the whole month on
      // the 1st, and `currentBalance` above already contains it. Adding
      // prorated rent for the days used therefore charged the month twice — a
      // tenant on $150 leaving on the 10th of a 30-day month was billed $150
      // plus $50, or $200 for ten days.
      //
      // When the month has already been charged, the tenant is owed the unused
      // days back, so post a credit. Only when it has not been charged does
      // prorated rent make sense as a charge.
      if (prorateRent && tenantModel.monthlyRate > 0) {
        final alreadyCharged = await _monthlyRentAlreadyCharged(
          facilityId: facilityId,
          tenantId: tenantId,
          month: moveOutDate,
        );
        final rent = moveOutRentAmount(
          monthlyRate: tenantModel.monthlyRate,
          moveOutDate: moveOutDate,
          alreadyCharged: alreadyCharged,
        );
        final daysUsed = rent.days;
        final daysUnused = rent.unusedDays;

        if (alreadyCharged) {
          final refundForUnusedDays = rent.amount;
          if (refundForUnusedDays > 0) {
            lineItems.add(InvoiceLineItem(
              id: 'prorated_rent_credit_${DateTime.now().millisecondsSinceEpoch}',
              type: InvoiceLineItemType.proratedRent,
              description: 'Prorated Rent Credit ($daysUnused unused days)',
              amount: -refundForUnusedDays,
              isProrated: true,
              dueDate: moveOutDate,
            ));
            totalCharges -= refundForUnusedDays;
          }
        } else {
          final proratedRent =
              rent.amount;
          if (proratedRent > 0) {
            lineItems.add(InvoiceLineItem(
              id: 'prorated_rent_${DateTime.now().millisecondsSinceEpoch}',
              type: InvoiceLineItemType.proratedRent,
              description: 'Prorated Rent ($daysUsed days)',
              amount: proratedRent,
              isProrated: true,
              dueDate: moveOutDate,
            ));
            totalCharges += proratedRent;
          }
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
          // Positive. A refund hands money back to the tenant, which removes a
          // credit they were holding, so what they owe goes back up. Written
          // negative, a $50 refund against a -$50 balance produced -$100: the
          // system believed the facility still owed the money it had just paid
          // out. The Stripe webhook already writes refunds positive.
          amount: calculation.refundAmount,
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

      // From here the charges and refund above are posted, so a failed step
      // is a warning on a completed move-out, never "Error completing
      // move-out": a retry would post them again.
      final warnings = <String>[];

      // Step 3: Update contract with move-out status
      // Note: ContractService.updateContract may need to be enhanced to support move-out fields
      // For now, we'll update directly via Firestore
      try {
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
          if (moveOutNotes != null && moveOutNotes.isNotEmpty) 'moveOutNotes': moveOutNotes,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        warnings.add("The contract wasn't marked as moved out ($e).");
      }

      // Step 4: Update unit status to available
      try {
        await UnitService.updateUnit(
          unitId: unitId,
          facilityId: facilityId,
          status: UnitStatus.available,
          moveOutDate: moveOutDate,
        );
      } catch (e) {
        warnings.add("The unit wasn't set to available ($e).");
      }

      // Steps 5 and 6: the tenant's own record and gate codes. A tenant who
      // still rents another unit stays active with their gate codes on.
      final tenantWarning = await settleTenantAfterMoveOut(
        facilityId: facilityId,
        tenantId: tenantId,
        unitId: unitId,
      );
      if (tenantWarning != null) warnings.add(tenantWarning);

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
        warning: warnings.isEmpty ? null : warnings.join(' '),
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

  /// Steps 5 and 6 of [completeMoveOut]: [TenantService.recordMoveOut],
  /// which switches the tenant (and their gate codes) off only when they
  /// hold no other unit. Returns what the owner is shown with the finished
  /// move-out: the tenant's new rent or a request to check it, or a warning
  /// instead of throwing, since it runs after fees and refunds are posted.
  /// The old step set every tenant inactive and turned every gate code off,
  /// even for one still renting another unit, and its failure read as
  /// "Error completing move-out". [records], [effects] and [actingUid] are
  /// for tests.
  @visibleForTesting
  static Future<String?> settleTenantAfterMoveOut({
    required String facilityId,
    required String tenantId,
    required String unitId,
    TenantRecordsStore? records,
    TenantUpdateEffects? effects,
    String? actingUid,
  }) async {
    try {
      return await TenantService.recordMoveOut(
        facilityId: facilityId,
        tenantId: tenantId,
        movedOutUnitId: unitId,
        records: records,
        effects: effects,
        actingUid: actingUid,
      );
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [MoveOut] Tenant record not updated after move-out: $e');
      }
      return 'The move-out, charges and refund are recorded, but the '
          "tenant's own record was not updated ($e). Open the tenant to "
          'check whether they should still be active and have gate access.';
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

      final data = Map<String, dynamic>.from(result.data as Map);

      if (kDebugMode) {
        print('✅ [MoveOut] Cloud Function completed successfully');
      }

      return moveOutResultFromServer(data, calculation);
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

  /// What processMoveOut answered, for the screen. A move-out that had
  /// already been completed (a retry after a dropped connection) charged
  /// and freed nothing this time: its charges are not shown as posted
  /// again, and the owner is told. The tenant's new rent, or a request to
  /// check it, comes with the result.
  @visibleForTesting
  static MoveOutResult moveOutResultFromServer(
    Map<String, dynamic> data,
    MoveOutCalculation calculation,
  ) {
    final repeat = data['alreadyCompleted'] == true;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    return MoveOutResult(
      success: data['success'] == true,
      charges: repeat ? null : calculation.newCharges,
      refund: repeat ? null : calculation.refundAmount,
      notice: text(data['rentNotice']),
      warning: repeat ? text(data['message']) : text(data['rentWarning']),
    );
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

  /// The move-out went through but a later step needs a look.
  final String? warning;

  /// For the owner with the finished move-out: the tenant's new rent.
  final String? notice;

  MoveOutResult({
    required this.success,
    this.ledgerEntryIds = const [],
    this.charges,
    this.refund,
    this.error,
    this.warning,
    this.notice,
  });
}

