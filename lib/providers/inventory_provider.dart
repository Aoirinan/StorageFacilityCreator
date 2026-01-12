import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/product_model.dart';
import '../services/inventory_service.dart';

/// Provider for products stream for a facility
final productsForFacilityProvider = StreamProvider.family<List<ProductModel>, String>(
  (ref, facilityId) {
    return InventoryService.getProductsForFacilityStream(facilityId);
  },
);

/// Provider for a single product
final productProvider = FutureProvider.family<ProductModel?, ({String facilityId, String productId})>(
  (ref, params) async {
    return await InventoryService.getProduct(
      facilityId: params.facilityId,
      productId: params.productId,
    );
  },
);

