import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/sale_model.dart';
import '../models/product_model.dart';
import '../models/ledger_entry_model.dart';
import '../services/inventory_service.dart';
import '../services/ledger_service.dart';
import '../services/deposit_service.dart';
import '../services/audit_service.dart';

/// Service for managing sales (POS)
class SaleService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Generate next sale number for a facility
  /// Format: SALE-YYYY-XXX (e.g., SALE-2025-001)
  static Future<String> _generateSaleNumber(String facilityId) async {
    try {
      final year = DateTime.now().year;
      final prefix = 'SALE-$year-';

      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('sales')
          .where('saleNumber', isGreaterThanOrEqualTo: prefix)
          .where('saleNumber', isLessThan: 'SALE-${year + 1}-')
          .orderBy('saleNumber', descending: true)
          .limit(1)
          .get();

      int nextNumber = 1;
      if (snapshot.docs.isNotEmpty) {
        final lastNumber = snapshot.docs.first.data()['saleNumber'] as String;
        final lastNumStr = lastNumber.split('-').last;
        nextNumber = (int.tryParse(lastNumStr) ?? 0) + 1;
      }

      return '$prefix${nextNumber.toString().padLeft(3, '0')}';
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Sale] Error generating sale number: $e');
      }
      return 'SALE-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// Create a sale
  static Future<SaleModel> createSale({
    required String facilityId,
    String? tenantId,
    required List<SaleLineItem> lineItems,
    required PaymentMethod paymentMethod,
    double? tax,
    String? notes,
    bool updateInventory = true,
    bool createLedgerEntry = true, // If sold to tenant, create ledger entry
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (lineItems.isEmpty) {
        throw Exception('Sale must have at least one line item');
      }

      // Calculate totals
      final subtotal = lineItems.fold(0.0, (sum, item) => sum + item.total);
      final total = subtotal + (tax ?? 0.0);

      // Check inventory availability
      if (updateInventory) {
        for (final item in lineItems) {
          final product = await InventoryService.getProduct(
            facilityId: facilityId,
            productId: item.productId,
          );
          if (product == null) {
            throw Exception('Product ${item.productName} not found');
          }
          if (product.trackInventory && product.stockQuantity < item.quantity) {
            throw Exception('Insufficient stock for ${item.productName}. Available: ${product.stockQuantity}, Requested: ${item.quantity}');
          }
        }
      }

      final saleNumber = await _generateSaleNumber(facilityId);

      final sale = SaleModel(
        id: '',
        facilityId: facilityId,
        tenantId: tenantId,
        saleNumber: saleNumber,
        status: SaleStatus.completed,
        paymentMethod: paymentMethod,
        lineItems: lineItems,
        subtotal: subtotal,
        tax: tax,
        total: total,
        saleDate: DateTime.now(),
        notes: notes,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('sales')
          .add(sale.toFirestore());

      String? ledgerEntryId;

      // Update inventory
      if (updateInventory) {
        for (final item in lineItems) {
          await InventoryService.adjustStock(
            facilityId: facilityId,
            productId: item.productId,
            quantityChange: -item.quantity, // Negative for sale
            reason: 'sale',
          );
        }
      }

      // Create ledger entry if sold to tenant
      if (createLedgerEntry && tenantId != null && tenantId.isNotEmpty) {
        final ledgerEntry = await LedgerService.createLedgerEntry(
          tenantId: tenantId,
          facilityId: facilityId,
          type: LedgerEntryType.otherCharge,
          amount: total,
          description: 'Sale: $saleNumber',
          entryDate: DateTime.now(),
          dueDate: DateTime.now(),
          status: LedgerEntryStatus.posted,
          metadata: {
            'saleId': docRef.id,
            'saleNumber': saleNumber,
            'lineItems': lineItems.map((item) => item.toMap()).toList(),
          },
        );
        ledgerEntryId = ledgerEntry.id;

        // Update sale with ledger entry ID
        await docRef.update({'ledgerEntryId': ledgerEntryId});
      }

      // Link to deposit if cash/check payment
      if (paymentMethod == PaymentMethod.cash || paymentMethod == PaymentMethod.check) {
        // Note: Deposit linking would happen when deposit is created
        // This is handled in deposit creation screen
      }

      if (kDebugMode) {
        print('✅ [Sale] Created sale: $saleNumber');
      }

      return sale.copyWith(id: docRef.id, ledgerEntryId: ledgerEntryId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Sale] Error creating sale: $e');
      }
      rethrow;
    }
  }

  /// Get sales for a facility
  static Stream<List<SaleModel>> getSalesForFacilityStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('sales')
        .where('isActive', isEqualTo: true)
        .orderBy('saleDate', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => SaleModel.fromFirestore(doc))
            .toList());
  }

  /// Get sale by ID
  static Future<SaleModel?> getSale({
    required String facilityId,
    required String saleId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('sales')
          .doc(saleId)
          .get();

      if (!doc.exists) return null;

      return SaleModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Sale] Error getting sale: $e');
      }
      rethrow;
    }
  }
}

