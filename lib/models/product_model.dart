import 'package:cloud_firestore/cloud_firestore.dart';

enum ProductCategory {
  locks,
  boxes,
  packingSupplies,
  movingSupplies,
  other,
}

class ProductModel {
  final String id;
  final String facilityId;
  final String name;
  final String? description;
  final String? sku; // Stock Keeping Unit
  final ProductCategory category;
  final double price;
  final double? cost; // Cost per unit (for profit tracking)
  final int stockQuantity; // Current stock level
  final int? lowStockThreshold; // Alert when stock falls below this
  final String? unit; // e.g., "each", "box", "pack"
  final String? imageUrl;
  final bool isActive;
  final bool trackInventory; // Whether to track stock levels
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;

  const ProductModel({
    required this.id,
    required this.facilityId,
    required this.name,
    this.description,
    this.sku,
    required this.category,
    required this.price,
    this.cost,
    this.stockQuantity = 0,
    this.lowStockThreshold,
    this.unit,
    this.imageUrl,
    this.isActive = true,
    this.trackInventory = true,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
  });

  factory ProductModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('ProductModel data is null');
    }

    return ProductModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      name: data['name'] ?? '',
      description: data['description'],
      sku: data['sku'],
      category: ProductCategory.values.firstWhere(
        (e) => e.name == data['category'],
        orElse: () => ProductCategory.other,
      ),
      price: (data['price'] ?? 0.0).toDouble(),
      cost: data['cost'] != null ? (data['cost'] as num).toDouble() : null,
      stockQuantity: data['stockQuantity'] ?? 0,
      lowStockThreshold: data['lowStockThreshold'],
      unit: data['unit'] ?? 'each',
      imageUrl: data['imageUrl'],
      isActive: data['isActive'] ?? true,
      trackInventory: data['trackInventory'] ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
      createdBy: data['createdBy'] ?? '',
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'name': name,
      if (description != null && description!.isNotEmpty) 'description': description,
      if (sku != null && sku!.isNotEmpty) 'sku': sku,
      'category': category.name,
      'price': price,
      if (cost != null) 'cost': cost,
      'stockQuantity': stockQuantity,
      if (lowStockThreshold != null) 'lowStockThreshold': lowStockThreshold,
      'unit': unit ?? 'each',
      if (imageUrl != null && imageUrl!.isNotEmpty) 'imageUrl': imageUrl,
      'isActive': isActive,
      'trackInventory': trackInventory,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'createdBy': createdBy,
    };
  }

  ProductModel copyWith({
    String? id,
    String? facilityId,
    String? name,
    String? description,
    String? sku,
    ProductCategory? category,
    double? price,
    double? cost,
    int? stockQuantity,
    int? lowStockThreshold,
    String? unit,
    String? imageUrl,
    bool? isActive,
    bool? trackInventory,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
  }) {
    return ProductModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      name: name ?? this.name,
      description: description ?? this.description,
      sku: sku ?? this.sku,
      category: category ?? this.category,
      price: price ?? this.price,
      cost: cost ?? this.cost,
      stockQuantity: stockQuantity ?? this.stockQuantity,
      lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
      unit: unit ?? this.unit,
      imageUrl: imageUrl ?? this.imageUrl,
      isActive: isActive ?? this.isActive,
      trackInventory: trackInventory ?? this.trackInventory,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }

  String get categoryDisplayName {
    switch (category) {
      case ProductCategory.locks:
        return 'Locks';
      case ProductCategory.boxes:
        return 'Boxes';
      case ProductCategory.packingSupplies:
        return 'Packing Supplies';
      case ProductCategory.movingSupplies:
        return 'Moving Supplies';
      case ProductCategory.other:
        return 'Other';
    }
  }

  String get formattedPrice => '\$${price.toStringAsFixed(2)}';
  bool get isLowStock => trackInventory && 
      lowStockThreshold != null && 
      stockQuantity <= lowStockThreshold!;
  bool get isOutOfStock => trackInventory && stockQuantity <= 0;
  double? get profitMargin => cost != null ? price - cost! : null;
  String? get formattedProfitMargin => profitMargin != null 
      ? '\$${profitMargin!.toStringAsFixed(2)}' 
      : null;
}

