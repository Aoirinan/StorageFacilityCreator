import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/ledger_entry_model.dart';
import 'audit_service.dart';

/// Service for managing tenant financial ledgers
/// Ledger is the single source of truth for all tenant financials
class LedgerService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a new ledger entry
  static Future<LedgerEntry> createLedgerEntry({
    required String tenantId,
    required String facilityId,
    required LedgerEntryType type,
    required double amount,
    String? description,
    String? referenceId,
    DateTime? entryDate,
    DateTime? dueDate,
    LedgerEntryStatus status = LedgerEntryStatus.posted,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [Ledger] Creating ledger entry for tenant: $tenantId');
      }

      final now = DateTime.now();
      final entry = LedgerEntry(
        id: '', // Will be set by Firestore
        tenantId: tenantId,
        facilityId: facilityId,
        type: type,
        amount: amount,
        description: description,
        referenceId: referenceId,
        entryDate: entryDate ?? now,
        dueDate: dueDate,
        status: status,
        metadata: metadata,
        createdAt: now,
        createdBy: user.uid,
      );

      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .doc();

      await ref.set(entry.copyWith(id: ref.id).toFirestore());

      final createdEntry = entry.copyWith(id: ref.id);

      // Audit log
      await AuditService.logLedgerEntryCreated(
        facilityId: facilityId,
        tenantId: tenantId,
        entryId: ref.id,
        type: type.name,
        amount: amount,
      );

      if (kDebugMode) {
        print('✅ [Ledger] Created ledger entry: ${ref.id}');
      }

      return createdEntry;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Ledger] Error creating ledger entry: $e');
      }
      rethrow;
    }
  }

  /// Get ledger entries for a tenant (real-time stream)
  static Stream<List<LedgerEntry>> getLedgerStream({
    required String tenantId,
    required String facilityId,
  }) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 [Ledger] Setting up ledger stream for tenant: $tenantId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .where('tenantId', isEqualTo: tenantId);
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('entryDate', descending: true);
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ [Ledger] Ordered query not available, using unordered: $e');
        }
      }

      return query.snapshots().map((snapshot) {
        final entries = snapshot.docs
            .map((doc) => LedgerEntry.fromFirestore(doc))
            .toList();

        // Sort in memory if we used fallback query
        entries.sort((a, b) {
          final dateCompare = b.entryDate.compareTo(a.entryDate);
          if (dateCompare != 0) return dateCompare;
          return b.createdAt.compareTo(a.createdAt);
        });

        if (kDebugMode) {
          print('📡 [Ledger] Stream update: ${entries.length} entries for tenant: $tenantId');
        }

        return entries;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Ledger] Error setting up ledger stream: $e');
      }
      rethrow;
    }
  }

  /// Get ledger entries for a tenant (one-time)
  static Future<List<LedgerEntry>> getLedgerEntries({
    required String tenantId,
    required String facilityId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [Ledger] Getting ledger entries for tenant: $tenantId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .where('tenantId', isEqualTo: tenantId);
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('entryDate', descending: true);
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ [Ledger] Ordered query not available, using unordered: $e');
        }
      }
      
      // Add limit after orderBy (if present) or directly
      query = query.limit(1000); // Limit to 1000 ledger entries per tenant (safety limit)

      final snapshot = await query.get();

      final entries = snapshot.docs
          .map((doc) => LedgerEntry.fromFirestore(doc))
          .toList();

      // Sort in memory if we used fallback query
      entries.sort((a, b) {
        final dateCompare = b.entryDate.compareTo(a.entryDate);
        if (dateCompare != 0) return dateCompare;
        return b.createdAt.compareTo(a.createdAt);
      });

      if (kDebugMode) {
        print('✅ [Ledger] Found ${entries.length} entries for tenant: $tenantId');
      }

      return entries;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Ledger] Error getting ledger entries: $e');
      }
      rethrow;
    }
  }

  /// Get balances for all tenants in a facility (for overlock/delinquency screens).
  /// Returns map of tenantId -> balance (sum of posted entries).
  static Future<Map<String, double>> getBalancesForFacility(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .where('status', isEqualTo: 'posted')
          .get();
      final map = <String, double>{};
      for (final doc in snapshot.docs) {
        final d = doc.data();
        final tenantId = d['tenantId'] as String?;
        if (tenantId == null) continue;
        final amount = (d['amount'] as num?)?.toDouble() ?? 0.0;
        map[tenantId] = (map[tenantId] ?? 0) + amount;
      }
      return map;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Ledger] Error getBalancesForFacility: $e');
      }
      rethrow;
    }
  }

  /// Calculate current balance for a tenant
  /// Balance = Sum of all posted entries (charges are positive, payments are negative)
  static Future<double> getLedgerBalance({
    required String tenantId,
    required String facilityId,
  }) async {
    try {
      final entries = await getLedgerEntries(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      // Sum only posted entries
      final balance = entries
          .where((e) => e.status == LedgerEntryStatus.posted)
          .fold(0.0, (sum, entry) => sum + entry.amount);

      if (kDebugMode) {
        print('💰 [Ledger] Balance for tenant $tenantId: \$${balance.toStringAsFixed(2)}');
      }

      return balance;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Ledger] Error calculating balance: $e');
      }
      rethrow;
    }
  }

  /// Allocate a payment to oldest unpaid charges
  /// Returns list of allocation records: [{chargeId, amount}]
  static Future<List<Map<String, dynamic>>> allocatePayment({
    required String paymentId,
    required String tenantId,
    required String facilityId,
    required double paymentAmount,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [Ledger] Allocating payment $paymentId (\$${paymentAmount.toStringAsFixed(2)})');
      }

      // Get all unpaid charges (posted, positive amount, no allocation in metadata)
      final entries = await getLedgerEntries(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      final unpaidCharges = entries
          .where((e) =>
              e.status == LedgerEntryStatus.posted &&
              e.isCharge &&
              (e.metadata?['allocatedAmount'] == null ||
                  (e.metadata?['allocatedAmount'] as num).toDouble() < e.amount))
          .toList()
        ..sort((a, b) => a.entryDate.compareTo(b.entryDate)); // Oldest first

      if (unpaidCharges.isEmpty) {
        if (kDebugMode) {
          print('⚠️ [Ledger] No unpaid charges to allocate payment to');
        }
        return [];
      }

      double remainingPayment = paymentAmount.abs(); // Payment amount is negative
      final allocations = <Map<String, dynamic>>[];

      for (final charge in unpaidCharges) {
        if (remainingPayment <= 0) break;

        final currentAllocated = (charge.metadata?['allocatedAmount'] as num?)?.toDouble() ?? 0.0;
        final remainingCharge = charge.amount - currentAllocated;
        final allocationAmount = remainingPayment < remainingCharge
            ? remainingPayment
            : remainingCharge;

        // Update charge metadata with allocation
        final updatedMetadata = Map<String, dynamic>.from(charge.metadata ?? {});
        updatedMetadata['allocatedAmount'] = currentAllocated + allocationAmount;
        updatedMetadata['allocations'] = [
          ...(updatedMetadata['allocations'] as List<dynamic>? ?? []),
          {
            'paymentId': paymentId,
            'amount': allocationAmount,
            'allocatedAt': FieldValue.serverTimestamp(),
            'allocatedBy': user.uid,
          }
        ];

        await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('ledgers')
            .doc(charge.id)
            .update({'metadata': updatedMetadata});

        allocations.add({
          'chargeId': charge.id,
          'amount': allocationAmount,
        });

        remainingPayment -= allocationAmount;

        if (kDebugMode) {
          print('✅ [Ledger] Allocated \$${allocationAmount.toStringAsFixed(2)} to charge ${charge.id}');
        }
      }

      // Audit log
      await AuditService.logPaymentAllocated(
        facilityId: facilityId,
        tenantId: tenantId,
        paymentId: paymentId,
        allocations: allocations,
      );

      if (kDebugMode) {
        print('✅ [Ledger] Payment allocation complete: ${allocations.length} charges');
      }

      return allocations;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Ledger] Error allocating payment: $e');
      }
      rethrow;
    }
  }

  /// Void a ledger entry
  static Future<void> voidLedgerEntry({
    required String entryId,
    required String facilityId,
    String? reason,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [Ledger] Voiding ledger entry: $entryId');
      }

      final entryRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .doc(entryId);

      final entryDoc = await entryRef.get();
      if (!entryDoc.exists) {
        throw Exception('Ledger entry not found');
      }

      final entry = LedgerEntry.fromFirestore(entryDoc);
      if (entry.status == LedgerEntryStatus.voided) {
        throw Exception('Entry already voided');
      }

      final updatedMetadata = Map<String, dynamic>.from(entry.metadata ?? {});
      if (reason != null) {
        updatedMetadata['voidReason'] = reason;
      }

      await entryRef.update({
        'status': LedgerEntryStatus.voided.name,
        'voidedAt': FieldValue.serverTimestamp(),
        'voidedBy': user.uid,
        'metadata': updatedMetadata,
      });

      // Audit log
      await AuditService.logLedgerEntryVoided(
        facilityId: facilityId,
        tenantId: entry.tenantId,
        entryId: entryId,
        reason: reason,
      );

      if (kDebugMode) {
        print('✅ [Ledger] Voided ledger entry: $entryId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Ledger] Error voiding ledger entry: $e');
      }
      rethrow;
    }
  }

  /// Get ledger entries by date range
  static Future<List<LedgerEntry>> getLedgerEntriesByDateRange({
    required String tenantId,
    required String facilityId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .where('tenantId', isEqualTo: tenantId)
          .where('entryDate', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate))
          .where('entryDate', isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('entryDate', descending: true);
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ [Ledger] Ordered query not available, using unordered: $e');
        }
      }
      
      // Add limit after orderBy (if present) or directly
      query = query.limit(1000); // Limit to 1000 ledger entries per date range (safety limit)

      final snapshot = await query.get();

      return snapshot.docs
          .map((doc) => LedgerEntry.fromFirestore(doc))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Ledger] Error getting ledger entries by date range: $e');
      }
      rethrow;
    }
  }
}

