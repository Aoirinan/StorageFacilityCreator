import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/tenant_model.dart';
import '../models/unit_model.dart';
import '../models/contract_model.dart';
import '../models/ledger_entry_model.dart' show LedgerEntry, LedgerEntryType, LedgerEntryStatus;
import '../models/invoice_line_item_model.dart';
import '../services/ledger_service.dart';
import '../services/tenant_service.dart';
import '../services/unit_service.dart';
import '../services/contract_service.dart';
import '../services/gate_access_service.dart';
import '../services/prorate_service.dart';
import '../services/audit_service.dart';
import '../services/coupon_service.dart';
import '../models/coupon_model.dart';

/// Move-in data structure
class MoveInData {
  final TenantModel? existingTenant;
  final UnitModel unit;
  final ContractModel contract;
  final List<InvoiceLineItem> lineItems;
  final double totalAmount;
  final DateTime moveInDate;
  final bool requiresSignature;
  final bool requiresPayment;

  const MoveInData({
    this.existingTenant,
    required this.unit,
    required this.contract,
    required this.lineItems,
    required this.totalAmount,
    required this.moveInDate,
    this.requiresSignature = true,
    this.requiresPayment = true,
  });
}

/// Statuses in which a tenant is in the unit.
const _tenantInUnitStatuses = {
  UnitStatus.occupied,
  UnitStatus.overlocked,
  UnitStatus.lockout,
  UnitStatus.auction,
};

/// A move-in refused because the unit already has a tenant in it.
///
/// Thrown typed so the wizard can tell a move-in of this same tenant
/// ([sameTenant]) from a unit someone else rents, and so its message does not
/// reach the screen as "Exception: ...".
class MoveInUnitConflict implements Exception {
  const MoveInUnitConflict({
    required this.unitNumber,
    required this.holderName,
    required this.sameTenant,
  });

  final String unitNumber;

  /// The name the unit shows for its tenant; may be empty.
  final String holderName;

  /// The unit shows the tenant being moved in.
  final bool sameTenant;

  String get message {
    if (sameTenant) {
      final who = holderName.isEmpty ? 'this tenant' : holderName;
      return 'This move-in was partly completed: Unit $unitNumber already '
          "shows $who in it. Open $who's ledger to review before trying "
          'again.';
    }
    return 'Unit $unitNumber is already occupied'
        '${holderName.isEmpty ? '' : ' by $holderName'}.';
  }

  @override
  String toString() => message;
}

/// Why a move-in of [tenantId] into [unit] (as just read from Firestore) must
/// not run, or null when it may.
///
/// A move-in submitted twice, or retried after it had in fact finished, wrote
/// a second contract, second charges, a second payment allocation and a
/// second gate code: nothing checked the unit before writing. The unit is not
/// the last thing a move-in writes: step 1 (the tenant's unit) already marks
/// it occupied by the tenant, before the contract, charges and payment. So
/// the same tenant in the unit means a move-in at least partly done, maybe
/// one that failed partway, and running it again could charge them twice.
/// [unit] null (it could not be read) lets the move-in run as before.
MoveInUnitConflict? moveInUnitConflict({
  required UnitModel? unit,
  required String tenantId,
}) {
  if (unit == null) return null;
  final holder = unit.tenantId ?? '';
  if (holder.isEmpty || !_tenantInUnitStatuses.contains(unit.status)) {
    return null;
  }
  return MoveInUnitConflict(
    unitNumber: unit.unitNumber,
    holderName: unit.tenantName ?? '',
    sameTenant: holder == tenantId,
  );
}

/// Service for managing move-in workflow
class MoveInService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  // A getter, not a final field, so a test can sign a fake user in and run
  // the real move-in (see authForTesting).
  static FirebaseAuth get _auth => _authForTesting ?? FirebaseAuth.instance;
  static FirebaseAuth? _authForTesting;

  @visibleForTesting
  static set authForTesting(FirebaseAuth? auth) => _authForTesting = auth;

  /// Calculate move-in charges
  /// Returns list of invoice line items with prorated amounts
  static Future<List<InvoiceLineItem>> calculateMoveInCharges({
    required String facilityId,
    required String unitId,
    required double monthlyRent,
    required DateTime moveInDate,
    double? insuranceAmount,
    double? adminFee,
    double? moveInFee,
    double? securityDeposit,
    String? couponCode, // For future use
    bool prorateRent = true,
  }) async {
    try {
      final lineItems = <InvoiceLineItem>[];

      // 1. Prorated Rent (if move-in is mid-month)
      if (prorateRent) {
        final proratedRent = ProrateService.calculateProratedRent(
          monthlyRate: monthlyRent,
          moveInDate: moveInDate,
        );
        
        if (proratedRent > 0) {
          lineItems.add(InvoiceLineItem(
            id: 'prorated_rent_${DateTime.now().millisecondsSinceEpoch}',
            type: InvoiceLineItemType.proratedRent,
            description: 'Prorated Rent (${ProrateService.calculateDaysRemainingInMonth(moveInDate)} days)',
            amount: proratedRent,
            isProrated: true,
            dueDate: ProrateService.getFirstDayOfNextMonth(moveInDate),
          ));
        }
      } else {
        // Full month rent
        lineItems.add(InvoiceLineItem(
          id: 'rent_${DateTime.now().millisecondsSinceEpoch}',
          type: InvoiceLineItemType.rent,
          description: 'Monthly Rent',
          amount: monthlyRent,
          isProrated: false,
          dueDate: ProrateService.getFirstDayOfNextMonth(moveInDate),
        ));
      }

      // 2. Insurance (if provided)
      if (insuranceAmount != null && insuranceAmount > 0) {
        lineItems.add(InvoiceLineItem(
          id: 'insurance_${DateTime.now().millisecondsSinceEpoch}',
          type: InvoiceLineItemType.insurance,
          description: 'Insurance',
          amount: insuranceAmount,
          isProrated: false,
        ));
      }

      // 3. Admin Fee (if provided)
      if (adminFee != null && adminFee > 0) {
        lineItems.add(InvoiceLineItem(
          id: 'admin_fee_${DateTime.now().millisecondsSinceEpoch}',
          type: InvoiceLineItemType.adminFee,
          description: 'Admin Fee',
          amount: adminFee,
          isProrated: false,
        ));
      }

      // 4. Move-in Fee (if provided)
      if (moveInFee != null && moveInFee > 0) {
        lineItems.add(InvoiceLineItem(
          id: 'move_in_fee_${DateTime.now().millisecondsSinceEpoch}',
          type: InvoiceLineItemType.moveInFee,
          description: 'Move-In Fee',
          amount: moveInFee,
          isProrated: false,
        ));
      }

      // 5. Security Deposit (if provided)
      if (securityDeposit != null && securityDeposit > 0) {
        lineItems.add(InvoiceLineItem(
          id: 'security_deposit_${DateTime.now().millisecondsSinceEpoch}',
          type: InvoiceLineItemType.securityDeposit,
          description: 'Security Deposit',
          amount: securityDeposit,
          isProrated: false,
        ));
      }

      // Apply coupon/discount if provided
      if (couponCode != null && couponCode.isNotEmpty) {
        try {
          final coupon = await CouponService.getCouponByCode(
            facilityId: facilityId,
            code: couponCode,
          );

          if (coupon != null && coupon.isValid) {
            // Calculate discount based on applicable items
            double discountableAmount = 0.0;

            for (final item in lineItems) {
              bool applies = false;
              if (item.type == InvoiceLineItemType.rent || item.type == InvoiceLineItemType.proratedRent) {
                applies = coupon.appliesToRent;
              } else if (item.type == InvoiceLineItemType.adminFee || 
                         item.type == InvoiceLineItemType.moveInFee) {
                applies = coupon.appliesToFees;
              } else if (item.type == InvoiceLineItemType.insurance) {
                applies = coupon.appliesToInsurance;
              }

              if (applies) {
                discountableAmount += item.amount;
              }
            }

            // Check minimum purchase amount
            if (coupon.minPurchaseAmount == null || 
                discountableAmount >= coupon.minPurchaseAmount!) {
              double discount = 0.0;

              if (coupon.type == CouponType.freeMonth) {
                // Free month: find the rent item and make it free
                final rentItem = lineItems.firstWhere(
                  (item) => item.type == InvoiceLineItemType.rent || 
                           item.type == InvoiceLineItemType.proratedRent,
                  orElse: () => lineItems.first,
                );
                discount = rentItem.amount;
              } else {
                discount = coupon.calculateDiscount(discountableAmount);
              }

              if (discount > 0) {
                // Add discount line item
                lineItems.add(InvoiceLineItem(
                  id: 'discount_${DateTime.now().millisecondsSinceEpoch}',
                  type: InvoiceLineItemType.discount,
                  description: 'Discount: ${coupon.name} (${coupon.code})',
                  amount: -discount, // Negative amount for discount
                  isProrated: false,
                  metadata: {
                    'couponId': coupon.id,
                    'couponCode': coupon.code,
                  },
                ));

                if (kDebugMode) {
                  print('✅ [MoveIn] Applied coupon ${coupon.code}: \$${discount.toStringAsFixed(2)} discount');
                }

                // Increment coupon usage (will be called when move-in completes)
                // Store coupon ID in metadata for later use
              }
            } else {
              if (kDebugMode) {
                print('⚠️ [MoveIn] Coupon ${coupon.code} requires minimum purchase of \$${coupon.minPurchaseAmount}');
              }
            }
          } else {
            if (kDebugMode) {
              print('⚠️ [MoveIn] Coupon $couponCode not found or invalid');
            }
          }
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ [MoveIn] Error applying coupon: $e');
          }
          // Don't fail the whole operation if coupon fails
        }
      }

      if (kDebugMode) {
        print('💰 [MoveIn] Calculated ${lineItems.length} line items');
        final total = lineItems.fold(0.0, (sum, item) => sum + item.amount);
        print('💰 [MoveIn] Total: \$${total.toStringAsFixed(2)}');
      }

      return lineItems;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [MoveIn] Error calculating charges: $e');
      }
      rethrow;
    }
  }

  /// Complete move-in workflow
  /// Creates tenant, contract, ledger entries, activates unit, creates gate access
  static Future<MoveInResult> completeMoveIn({
    required MoveInData moveInData,
    String? paymentMethod, // 'cash', 'check', 'creditCard', 'ach'
    String? paymentReferenceId, // Stripe payment intent ID, etc.
    bool skipPayment = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [MoveIn] Starting move-in process for unit: ${moveInData.unit.unitNumber}');
      }

      final facilityId = moveInData.unit.facilityId;
      String? rentNotice;
      TenantModel tenant;
      ContractModel contract;
      List<String> ledgerEntryIds = [];

      // Read the unit fresh, before any write: the wizard's copy is from
      // when the unit was picked.
      final conflict = moveInUnitConflict(
        unit: await UnitService.getUnit(facilityId, moveInData.unit.id),
        tenantId: moveInData.existingTenant?.id ?? '',
      );
      if (conflict != null) throw conflict;

      // Step 1: Create or update tenant
      if (moveInData.existingTenant != null) {
        tenant = moveInData.existingTenant!;
        // Calculate monthly rate from line items
        final monthlyRate = moveInData.lineItems
            .where((item) => item.type == InvoiceLineItemType.rent || item.type == InvoiceLineItemType.proratedRent)
            .fold(0.0, (sum, item) => sum + item.amount);
        
        // Update tenant with move-in info
        // Note: Insurance status should be set via the wizard UI, not here
        // Never frees a unit the tenant already rents (a second unit).
        // A unit added to ones they hold adds its rate; the wizard shows it.
        rentNotice = await TenantService.recordMoveInUnit(
          tenantId: tenant.id,
          facilityId: facilityId,
          unitNumber: moveInData.unit.unitNumber,
          // The unit picked in the wizard, by id: by number alone, two
          // units with one number were a guess.
          unitId: moveInData.unit.id,
          monthlyRate: monthlyRate > 0 ? monthlyRate : null,
        );
      } else {
        // Create new tenant (this would need tenant data from wizard)
        throw Exception('Tenant creation from move-in wizard not yet implemented');
      }

      // Step 2: Create contract
      contract = moveInData.contract;
      if (contract.id.isEmpty) {
        // Create contract
        final contractId = await ContractService.createContract(
          facilityId: facilityId,
          tenantId: tenant.id,
          title: contract.title,
          description: contract.description,
          type: contract.type,
          templateId: contract.templateId,
        );
        // Fetch the created contract
        final createdContract = await ContractService.getContract(facilityId, contractId);
        if (createdContract == null) {
          throw Exception('Failed to retrieve created contract');
        }
        contract = createdContract;
      }

      // Step 3: Create ledger entries for all line items
      for (final lineItem in moveInData.lineItems) {
        // Determine ledger entry type
        LedgerEntryType ledgerType;
        switch (lineItem.type) {
          case InvoiceLineItemType.rent:
          case InvoiceLineItemType.proratedRent:
            ledgerType = LedgerEntryType.rentCharge;
            break;
          case InvoiceLineItemType.insurance:
            ledgerType = LedgerEntryType.insuranceCharge;
            break;
          case InvoiceLineItemType.adminFee:
            ledgerType = LedgerEntryType.adminFee;
            break;
          case InvoiceLineItemType.moveInFee:
            ledgerType = LedgerEntryType.moveInFee;
            break;
          case InvoiceLineItemType.securityDeposit:
            ledgerType = LedgerEntryType.otherCharge; // Security deposit handled separately
            break;
          default:
            ledgerType = LedgerEntryType.otherCharge;
        }

        final entry = await LedgerService.createLedgerEntry(
          tenantId: tenant.id,
          facilityId: facilityId,
          type: ledgerType,
          amount: lineItem.amount,
          description: lineItem.description,
          referenceId: contract.id,
          entryDate: moveInData.moveInDate,
          dueDate: lineItem.dueDate,
          status: LedgerEntryStatus.posted,
          metadata: {
            'lineItemId': lineItem.id,
            'lineItemType': lineItem.type.name,
            'isProrated': lineItem.isProrated,
            'moveInDate': moveInData.moveInDate.toIso8601String(),
          },
        );

        ledgerEntryIds.add(entry.id);
      }

      // Step 4: Process payment if provided
      if (!skipPayment && paymentMethod != null && moveInData.totalAmount > 0) {
        // Create payment ledger entry
        final paymentEntry = await LedgerService.createLedgerEntry(
          tenantId: tenant.id,
          facilityId: facilityId,
          type: LedgerEntryType.payment,
          amount: -moveInData.totalAmount, // Negative for payments
          description: 'Move-in Payment - ${paymentMethod}',
          referenceId: paymentReferenceId,
          entryDate: DateTime.now(),
          status: LedgerEntryStatus.posted,
          metadata: {
            'paymentMethod': paymentMethod,
            'moveInPayment': true,
            'contractId': contract.id,
          },
        );

        // Allocate payment to charges
        await LedgerService.allocatePayment(
          paymentId: paymentReferenceId ?? paymentEntry.id,
          tenantId: tenant.id,
          facilityId: facilityId,
          paymentAmount: moveInData.totalAmount,
        );

        ledgerEntryIds.add(paymentEntry.id);
      }

      // Step 5: Update unit status to occupied
      await UnitService.updateUnit(
        unitId: moveInData.unit.id,
        facilityId: facilityId,
        status: UnitStatus.occupied,
        tenantId: tenant.id,
        tenantName: tenant.name,
        moveInDate: moveInData.moveInDate,
      );

      // Step 6: Create gate access code
      try {
        final accessCode = await GateAccessService.generateUniqueAccessCode(
          facilityId: facilityId,
        );
        await GateAccessService.createGateAccess(
          facilityId: facilityId,
          accessCode: accessCode,
          tenantId: tenant.id,
          tenantName: tenant.name,
          isActive: true,
        );
        if (kDebugMode) {
          print('✅ [MoveIn] Gate access code created: $accessCode');
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ [MoveIn] Could not create gate access: $e');
        }
        // Don't fail move-in if gate access fails
      }

      // Step 7: Increment coupon usage if coupon was applied
      // Note: Coupon incrementing should be handled by the calling code
      // This is a placeholder for future coupon integration

      // Audit log
      await AuditService.logMoveInCompleted(
        facilityId: facilityId,
        tenantId: tenant.id,
        unitId: moveInData.unit.id,
        contractId: contract.id,
        totalAmount: moveInData.totalAmount,
      );

      if (kDebugMode) {
        print('✅ [MoveIn] Move-in completed successfully');
        print('   - Tenant: ${tenant.id}');
        print('   - Contract: ${contract.id}');
        print('   - Ledger Entries: ${ledgerEntryIds.length}');
      }

      return MoveInResult(
        success: true,
        tenantId: tenant.id,
        contractId: contract.id,
        ledgerEntryIds: ledgerEntryIds,
        notice: rentNotice,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [MoveIn] Error completing move-in: $e');
      }
      return MoveInResult(
        success: false,
        error: e.toString(),
        conflict: e is MoveInUnitConflict ? e : null,
      );
    }
  }

}

class MoveInResult {
  final bool success;
  final String? tenantId;
  final String? contractId;
  final List<String> ledgerEntryIds;
  final String? error;

  /// For the owner after a finished move-in, e.g. the tenant's new monthly
  /// rent when the unit was added to others they rent.
  final String? notice;

  /// Set when the unit already had a tenant, so the wizard can point the
  /// owner at the ledger instead of inviting a retry.
  final MoveInUnitConflict? conflict;

  MoveInResult({
    required this.success,
    this.tenantId,
    this.contractId,
    this.ledgerEntryIds = const [],
    this.error,
    this.notice,
    this.conflict,
  });
}

