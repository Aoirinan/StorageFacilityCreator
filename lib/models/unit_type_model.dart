import 'package:cloud_firestore/cloud_firestore.dart';

class UnitTypeModel {
  final String id;
  final String facilityId;
  final String name;
  final String description;
  final double basePrice;
  final String? sizeCategory; // small, medium, large, extraLarge
  final Map<String, dynamic>? dimensions; // width, height, depth
  final List<String>? features; // climate control, security, etc.
  final String? iconName; // For UI display
  final String? colorCode; // Hex color for UI
  final bool isActive;
  final int sortOrder;
  final Map<String, dynamic>? customFields;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;
  final String? updatedBy;

  const UnitTypeModel({
    required this.id,
    required this.facilityId,
    required this.name,
    required this.description,
    required this.basePrice,
    this.sizeCategory,
    this.dimensions,
    this.features,
    this.iconName,
    this.colorCode,
    this.isActive = true,
    this.sortOrder = 0,
    this.customFields,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
    this.updatedBy,
  });

  factory UnitTypeModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return UnitTypeModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      basePrice: (data['basePrice'] ?? 0.0).toDouble(),
      sizeCategory: data['sizeCategory'],
      dimensions: data['dimensions'] != null 
          ? Map<String, dynamic>.from(data['dimensions'])
          : null,
      features: data['features'] != null 
          ? List<String>.from(data['features'])
          : null,
      iconName: data['iconName'],
      colorCode: data['colorCode'],
      isActive: data['isActive'] ?? true,
      sortOrder: data['sortOrder'] ?? 0,
      customFields: data['customFields'] != null 
          ? Map<String, dynamic>.from(data['customFields'])
          : null,
      createdAt: data['createdAt']?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt']?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] ?? '',
      updatedBy: data['updatedBy'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'name': name,
      'description': description,
      'basePrice': basePrice,
      'sizeCategory': sizeCategory,
      'dimensions': dimensions,
      'features': features,
      'iconName': iconName,
      'colorCode': colorCode,
      'isActive': isActive,
      'sortOrder': sortOrder,
      'customFields': customFields,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'createdBy': createdBy,
      'updatedBy': updatedBy,
    };
  }

  UnitTypeModel copyWith({
    String? id,
    String? facilityId,
    String? name,
    String? description,
    double? basePrice,
    String? sizeCategory,
    Map<String, dynamic>? dimensions,
    List<String>? features,
    String? iconName,
    String? colorCode,
    bool? isActive,
    int? sortOrder,
    Map<String, dynamic>? customFields,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    String? updatedBy,
  }) {
    return UnitTypeModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      name: name ?? this.name,
      description: description ?? this.description,
      basePrice: basePrice ?? this.basePrice,
      sizeCategory: sizeCategory ?? this.sizeCategory,
      dimensions: dimensions ?? this.dimensions,
      features: features ?? this.features,
      iconName: iconName ?? this.iconName,
      colorCode: colorCode ?? this.colorCode,
      isActive: isActive ?? this.isActive,
      sortOrder: sortOrder ?? this.sortOrder,
      customFields: customFields ?? this.customFields,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }

  // Helper methods
  String get displayName => name;
  String get formattedPrice => '\$${basePrice.toStringAsFixed(2)}/month';
  
  String get sizeDisplayName {
    switch (sizeCategory) {
      case 'small':
        return 'Small';
      case 'medium':
        return 'Medium';
      case 'large':
        return 'Large';
      case 'extraLarge':
        return 'Extra Large';
      default:
        return 'Standard';
    }
  }

  String get dimensionsDisplay {
    if (dimensions == null) return 'Not specified';
    final width = dimensions!['width']?.toString() ?? 'N/A';
    final height = dimensions!['height']?.toString() ?? 'N/A';
    final depth = dimensions!['depth']?.toString() ?? 'N/A';
    return '${width}" × ${height}" × ${depth}"';
  }

  @override
  String toString() {
    return 'UnitTypeModel(id: $id, name: $name, basePrice: $basePrice)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UnitTypeModel && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
