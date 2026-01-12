import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/payment_model.dart';
import '../models/ledger_entry_model.dart';
import 'ledger_service.dart';
import 'payment_service.dart';

/// Service to migrate existing payments to ledger entries
/// This is a one-time migration script
class LedgerMigrationService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Migrate all payments for a facility to ledger entries
  /// Returns migration report
  static Future<MigrationReport> migrateFacilityPayments({
    required String facilityId,
    bool dryRun = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [Migration] Starting payment migration for facility: $facilityId');
        if (dryRun) {
          print('⚠️ [Migration] DRY RUN MODE - No changes will be made');
        }
      }

      // Get all payments for facility
      final payments = await PaymentService.getPaymentsForFacility(facilityId);

      if (kDebugMode) {
        print('📊 [Migration] Found ${payments.length} payments to migrate');
      }

      final report = MigrationReport(
        facilityId: facilityId,
        totalPayments: payments.length,
        migrated: 0,
        skipped: 0,
        errors: [],
      );

      for (final payment in payments) {
        try {
          // Check if ledger entry already exists for this payment
          final existingEntries = await LedgerService.getLedgerEntries(
            tenantId: payment.tenantId,
            facilityId: facilityId,
          );

          final alreadyMigrated = existingEntries.any(
            (e) => e.referenceId == payment.id,
          );

          if (alreadyMigrated) {
            if (kDebugMode) {
              print('⏭️ [Migration] Payment ${payment.id} already migrated, skipping');
            }
            report.skipped++;
            continue;
          }

          if (!dryRun) {
            // Create ledger entry for payment
            // Payment amount should be negative in ledger
            await LedgerService.createLedgerEntry(
              tenantId: payment.tenantId,
              facilityId: facilityId,
              type: LedgerEntryType.payment,
              amount: -payment.amount, // Negative for payments
              description: 'Payment - ${payment.methodDisplayName}',
              referenceId: payment.id,
              entryDate: payment.paidDate ?? payment.dueDate,
              status: payment.status == PaymentStatus.completed || payment.status == PaymentStatus.paid
                  ? LedgerEntryStatus.posted
                  : LedgerEntryStatus.pending,
              metadata: {
                'originalPaymentId': payment.id,
                'paymentMethod': payment.method.name,
                'migratedAt': FieldValue.serverTimestamp(),
              },
            );

            // If payment is completed/paid, allocate it
            if (payment.status == PaymentStatus.completed || payment.status == PaymentStatus.paid) {
              try {
                await LedgerService.allocatePayment(
                  paymentId: payment.id,
                  tenantId: payment.tenantId,
                  facilityId: facilityId,
                  paymentAmount: payment.amount,
                );
              } catch (e) {
                if (kDebugMode) {
                  print('⚠️ [Migration] Could not allocate payment ${payment.id}: $e');
                }
              }
            }
          }

          report.migrated++;

          if (kDebugMode && report.migrated % 10 == 0) {
            print('✅ [Migration] Migrated ${report.migrated}/${payments.length} payments');
          }
        } catch (e) {
          if (kDebugMode) {
            print('❌ [Migration] Error migrating payment ${payment.id}: $e');
          }
          report.errors.add('Payment ${payment.id}: $e');
        }
      }

      if (kDebugMode) {
        print('✅ [Migration] Migration complete:');
        print('   - Total: ${report.totalPayments}');
        print('   - Migrated: ${report.migrated}');
        print('   - Skipped: ${report.skipped}');
        print('   - Errors: ${report.errors.length}');
      }

      return report;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Migration] Error in migration: $e');
      }
      rethrow;
    }
  }

  /// Migrate all facilities (for super admin use)
  static Future<List<MigrationReport>> migrateAllFacilities({
    bool dryRun = false,
  }) async {
    try {
      final facilitiesSnapshot = await _firestore.collection('facilities').get();
      final reports = <MigrationReport>[];

      for (final facilityDoc in facilitiesSnapshot.docs) {
        try {
          final report = await migrateFacilityPayments(
            facilityId: facilityDoc.id,
            dryRun: dryRun,
          );
          reports.add(report);
        } catch (e) {
          if (kDebugMode) {
            print('❌ [Migration] Error migrating facility ${facilityDoc.id}: $e');
          }
          reports.add(MigrationReport(
            facilityId: facilityDoc.id,
            totalPayments: 0,
            migrated: 0,
            skipped: 0,
            errors: ['Facility migration failed: $e'],
          ));
        }
      }

      return reports;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Migration] Error in bulk migration: $e');
      }
      rethrow;
    }
  }
}

/// Migration report
class MigrationReport {
  final String facilityId;
  final int totalPayments;
  final int migrated;
  final int skipped;
  final List<String> errors;

  MigrationReport({
    required this.facilityId,
    required this.totalPayments,
    required this.migrated,
    required this.skipped,
    required this.errors,
  });

  bool get isSuccess => errors.isEmpty;
  double get successRate => totalPayments > 0 ? migrated / totalPayments : 0.0;
}

