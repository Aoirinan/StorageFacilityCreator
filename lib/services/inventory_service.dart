import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/product_model.dart';

/// Service for managing inventory/products
class InventoryService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a new product
  static Future<ProductModel> createProduct({
    required String facilityId,
    required String name,
    required ProductCategory category,
    required double price,
    String? description,
    String? sku,
    double? cost,
    int stockQuantity = 0,
    int? lowStockThreshold,
    String? unit,
    bool trackInventory = true,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final product = ProductModel(
        id: '',
        facilityId: facilityId,
        name: name,
        description: description,
        sku: sku,
        category: category,
        price: price,
        cost: cost,
        stockQuantity: stockQuantity,
        lowStockThreshold: lowStockThreshold,
        unit: unit,
        trackInventory: trackInventory,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('products')
          .add(product.toFirestore());

      if (kDebugMode) {
        print('✅ [Inventory] Created product: ${docRef.id}');
      }

      return product.copyWith(id: docRef.id);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Inventory] Error creating product: $e');
      }
      rethrow;
    }
  }

  /// Update product
  static Future<void> updateProduct({
    required String facilityId,
    required String productId,
    String? name,
    String? description,
    String? sku,
    ProductCategory? category,
    double? price,
    double? cost,
    int? stockQuantity,
    int? lowStockThreshold,
    String? unit,
    bool? trackInventory,
    bool? isActive,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) updates['name'] = name;
      if (description != null) updates['description'] = description;
      if (sku != null) updates['sku'] = sku;
      if (category != null) updates['category'] = category.name;
      if (price != null) updates['price'] = price;
      if (cost != null) updates['cost'] = cost;
      if (stockQuantity != null) updates['stockQuantity'] = stockQuantity;
      if (lowStockThreshold != null) updates['lowStockThreshold'] = lowStockThreshold;
      if (unit != null) updates['unit'] = unit;
      if (trackInventory != null) updates['trackInventory'] = trackInventory;
      if (isActive != null) updates['isActive'] = isActive;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('products')
          .doc(productId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [Inventory] Updated product: $productId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Inventory] Error updating product: $e');
      }
      rethrow;
    }
  }

  /// Adjust stock quantity
  static Future<void> adjustStock({
    required String facilityId,
    required String productId,
    required int quantityChange, // Positive for increase, negative for decrease
    String? reason, // e.g., "sale", "restock", "adjustment"
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final productDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('products')
          .doc(productId)
          .get();

      if (!productDoc.exists) {
        throw Exception('Product not found');
      }

      final currentStock = (productDoc.data()?['stockQuantity'] ?? 0) as int;
      final newStock = currentStock + quantityChange;

      if (newStock < 0) {
        throw Exception('Stock cannot be negative');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('products')
          .doc(productId)
          .update({
        'stockQuantity': newStock,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Log stock adjustment
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('products')
          .doc(productId)
          .collection('stockAdjustments')
          .add({
        'quantityChange': quantityChange,
        'previousStock': currentStock,
        'newStock': newStock,
        'reason': reason ?? 'adjustment',
        'createdBy': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [Inventory] Adjusted stock: $productId by $quantityChange');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Inventory] Error adjusting stock: $e');
      }
      rethrow;
    }
  }

  static int _compareProductName(ProductModel a, ProductModel b) {
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// Active products only. Sorted by name in memory so we do not require a
  /// Firestore composite index on `isActive` + `name` (see failed-precondition in console).
  static Stream<List<ProductModel>> getProductsForFacilityStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('products')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
      final list =
          snapshot.docs.map((doc) => ProductModel.fromFirestore(doc)).toList();
      list.sort(_compareProductName);
      return list;
    });
  }

  /// Get products for a facility (list)
  static Future<List<ProductModel>> getProductsForFacility(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('products')
          .where('isActive', isEqualTo: true)
          .get();

      final list =
          snapshot.docs.map((doc) => ProductModel.fromFirestore(doc)).toList();
      list.sort(_compareProductName);
      return list;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Inventory] Error getting products: $e');
      }
      rethrow;
    }
  }

  /// Get product by ID
  static Future<ProductModel?> getProduct({
    required String facilityId,
    required String productId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('products')
          .doc(productId)
          .get();

      if (!doc.exists) return null;

      return ProductModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Inventory] Error getting product: $e');
      }
      rethrow;
    }
  }

  /// Get low stock products
  static Future<List<ProductModel>> getLowStockProducts(String facilityId) async {
    try {
      final products = await getProductsForFacility(facilityId);
      return products.where((p) => p.isLowStock).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Inventory] Error getting low stock products: $e');
      }
      rethrow;
    }
  }

  /// Get out of stock products
  static Future<List<ProductModel>> getOutOfStockProducts(String facilityId) async {
    try {
      final products = await getProductsForFacility(facilityId);
      return products.where((p) => p.isOutOfStock).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Inventory] Error getting out of stock products: $e');
      }
      rethrow;
    }
  }
}

