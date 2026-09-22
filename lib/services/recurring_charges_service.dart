import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/tenant_model.dart';
import '../models/ledger_entry_model.dart' show LedgerEntry, LedgerEntryType, LedgerEntryStatus;
import '../services/ledger_service.dart';
import '../services/tenant_service.dart';
import '../services/audit_service.dart';

/// Service for generating recurring charges (monthly rent, insurance, etc.)
class RecurringChargesService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Generate monthly rent charges for all active tenants in a facility
  /// This should be called by a background job (Cloud Function) on the 1st of each month
  static Future<RecurringChargesResult> generateMonthlyRentCharges({
    required String facilityId,
    DateTime? forDate, // Defaults to first day of current month
    bool dryRun = false, // Preview mode - don't actually create charges
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final targetDate = forDate ?? DateTime(DateTime.now().year, DateTime.now().month, 1);

      if (kDebugMode) {
        print('🔄 [RecurringCharges] Generating monthly rent charges for facility: $facilityId');
        print('   Target date: ${targetDate.toIso8601String()}');
      }

      // Get all active tenants for the facility (with safety checks)
      final tenants = await TenantService.getTenantsForFacility(facilityId);
      final activeTenants = tenants.where((t) {
        // Must be active
        if (!t.isActive) return false;
        // Must have unit number
        if (t.unitNumber.isEmpty) return false;
        // Skip if moved out (has moveOutDate)
        // Note: TenantModel doesn't have moveOutDate, but we check isActive which should cover this
        return true;
      }).toList();

      if (kDebugMode) {
        print('   Found ${activeTenants.length} active tenants');
      }

      int successCount = 0;
      int skippedCount = 0;
      int errorCount = 0;
      final errors = <String>[];

      for (final tenant in activeTenants) {
        try {
          // Check if charge already exists for this month
          final existingCharge = await _checkExistingCharge(
            tenantId: tenant.id,
            facilityId: facilityId,
            targetDate: targetDate,
          );

          if (existingCharge) {
            if (kDebugMode) {
              print('   ⏭️  Skipping tenant ${tenant.name} - charge already exists');
            }
            skippedCount++;
            continue;
          }

          // In dry-run mode, skip actual creation
          if (dryRun) {
            if (kDebugMode) {
              print('   🔍 [DRY RUN] Would generate charge for tenant: ${tenant.name}');
            }
            successCount++;
            continue;
          }

          // Generate rent charge
          await _generateRentCharge(
            tenant: tenant,
            facilityId: facilityId,
            targetDate: targetDate,
          );

          successCount++;

          if (kDebugMode) {
            print('   ✅ Generated charge for tenant: ${tenant.name}');
          }
        } catch (e) {
          errorCount++;
          final errorMsg = 'Tenant ${tenant.name} (${tenant.id}): $e';
          errors.add(errorMsg);

          if (kDebugMode) {
            print('   ❌ Error for tenant ${tenant.name}: $e');
          }
        }
      }

      if (kDebugMode) {
        print('✅ [RecurringCharges] Completed: $successCount success, $skippedCount skipped, $errorCount errors');
      }

      return RecurringChargesResult(
        success: true,
        totalTenants: activeTenants.length,
        successCount: successCount,
        skippedCount: skippedCount,
        errorCount: errorCount,
        errors: errors,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [RecurringCharges] Error generating charges: $e');
      }
      return RecurringChargesResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Generate rent charge for a single tenant
  static Future<LedgerEntry> _generateRentCharge({
    required TenantModel tenant,
    required String facilityId,
    required DateTime targetDate,
  }) async {
    if (tenant.monthlyRate <= 0) {
      throw Exception('Tenant has no monthly rate set');
    }

    // Create ledger entry for monthly rent
    final entry = await LedgerService.createLedgerEntry(
      tenantId: tenant.id,
      facilityId: facilityId,
      type: LedgerEntryType.rentCharge,
      amount: tenant.monthlyRate,
      description: 'Monthly Rent - ${_formatMonthYear(targetDate)}',
      entryDate: targetDate,
      dueDate: targetDate, // Due on the 1st
      status: LedgerEntryStatus.posted,
      metadata: {
        'recurringCharge': true,
        'chargeType': 'monthlyRent',
        'month': targetDate.month,
        'year': targetDate.year,
        'generatedAt': DateTime.now().toIso8601String(),
      },
    );

    // Audit log
    await AuditService.logRecurringChargeGenerated(
      facilityId: facilityId,
      tenantId: tenant.id,
      entryId: entry.id,
      amount: tenant.monthlyRate,
      chargeType: 'monthlyRent',
    );

    return entry;
  }

  /// Whether [entries] already contain this month's recurring rent charge.
  ///
  /// Matches the month two ways on purpose: the entry's own date, and the
  /// month and year the generator stamped into metadata. The scheduled job in
  /// functions-automation writes the same four metadata fields with a 1-based
  /// month, so a charge posted server-side is recognised here and the two
  /// paths cannot bill the same month twice between them.
  ///
  /// Voided entries do not count. A month whose charge was voided is a month
  /// with no charge, and the operator must be able to post it again.
  static bool hasPostedRecurringRentCharge(
    List<LedgerEntry> entries,
    DateTime targetDate,
  ) {
    return entries.any((entry) {
      if (entry.type != LedgerEntryType.rentCharge) return false;
      if (entry.status != LedgerEntryStatus.posted) return false;

      final entryDate = entry.entryDate;
      final isSameMonth = entryDate.year == targetDate.year &&
          entryDate.month == targetDate.month;

      if (!isSameMonth) return false;

      // Check metadata to confirm it's a recurring charge
      final metadata = entry.metadata;
      if (metadata == null) return false;

      return metadata['recurringCharge'] == true &&
          metadata['chargeType'] == 'monthlyRent' &&
          metadata['month'] == targetDate.month &&
          metadata['year'] == targetDate.year;
    });
  }

  /// Whether this month's rent is already posted, treating a failed read as
  /// yes.
  ///
  /// Split from the Firestore call so the failure branch can be tested, which
  /// is the branch that matters: it used to return false, which the caller
  /// reads as "no charge yet" and acts on by posting one, so a read failure
  /// raised a second month of rent against every tenant in the facility. That
  /// is the outcome the comment here claimed to be avoiding.
  ///
  /// Failing closed turns a read failure into a skipped tenant: a missing
  /// charge an operator can re-run, rather than a duplicate landing on a real
  /// balance where autopay can collect it.
  static Future<bool> rentChargeAlreadyPosted({
    required DateTime targetDate,
    required Future<List<LedgerEntry>> Function() loadEntries,
  }) async {
    try {
      return hasPostedRecurringRentCharge(await loadEntries(), targetDate);
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [RecurringCharges] Error checking existing charge: $e');
      }
      return true;
    }
  }

  /// Check if a charge already exists for the target month
  static Future<bool> _checkExistingCharge({
    required String tenantId,
    required String facilityId,
    required DateTime targetDate,
  }) {
    return rentChargeAlreadyPosted(
      targetDate: targetDate,
      loadEntries: () => LedgerService.getLedgerEntries(
        tenantId: tenantId,
        facilityId: facilityId,
      ),
    );
  }

  /// Generate insurance charge for a tenant (if applicable)
  static Future<LedgerEntry?> generateInsuranceCharge({
    required String tenantId,
    required String facilityId,
    required double insuranceAmount,
    required DateTime targetDate,
  }) async {
    try {
      if (insuranceAmount <= 0) return null;

      final entry = await LedgerService.createLedgerEntry(
        tenantId: tenantId,
        facilityId: facilityId,
        type: LedgerEntryType.insuranceCharge,
        amount: insuranceAmount,
        description: 'Insurance - ${_formatMonthYear(targetDate)}',
        entryDate: targetDate,
        dueDate: targetDate,
        status: LedgerEntryStatus.posted,
        metadata: {
          'recurringCharge': true,
          'chargeType': 'insurance',
          'month': targetDate.month,
          'year': targetDate.year,
          'generatedAt': DateTime.now().toIso8601String(),
        },
      );

      // Audit log
      await AuditService.logRecurringChargeGenerated(
        facilityId: facilityId,
        tenantId: tenantId,
        entryId: entry.id,
        amount: insuranceAmount,
        chargeType: 'insurance',
      );

      return entry;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [RecurringCharges] Error generating insurance charge: $e');
      }
      rethrow;
    }
  }

  /// Generate recurring charge for a specific tenant (manual trigger)
  static Future<LedgerEntry> generateChargeForTenant({
    required String tenantId,
    required String facilityId,
    required double amount,
    required String description,
    DateTime? targetDate,
    LedgerEntryType type = LedgerEntryType.rentCharge,
  }) async {
    try {
      final date = targetDate ?? DateTime(DateTime.now().year, DateTime.now().month, 1);

      final entry = await LedgerService.createLedgerEntry(
        tenantId: tenantId,
        facilityId: facilityId,
        type: type,
        amount: amount,
        description: description,
        entryDate: date,
        dueDate: date,
        status: LedgerEntryStatus.posted,
        metadata: {
          'recurringCharge': true,
          'chargeType': type.name,
          'month': date.month,
          'year': date.year,
          'generatedAt': DateTime.now().toIso8601String(),
        },
      );

      // Audit log
      await AuditService.logRecurringChargeGenerated(
        facilityId: facilityId,
        tenantId: tenantId,
        entryId: entry.id,
        amount: amount,
        chargeType: type.name,
      );

      return entry;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [RecurringCharges] Error generating charge: $e');
      }
      rethrow;
    }
  }

  static String _formatMonthYear(DateTime date) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    return '${months[date.month - 1]} ${date.year}';
  }
}

class RecurringChargesResult {
  final bool success;
  final int? totalTenants;
  final int? successCount;
  final int? skippedCount;
  final int? errorCount;
  final List<String> errors;
  final String? error;

  RecurringChargesResult({
    required this.success,
    this.totalTenants,
    this.successCount,
    this.skippedCount,
    this.errorCount,
    this.errors = const [],
    this.error,
  });
}

