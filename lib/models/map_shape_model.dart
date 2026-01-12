import 'package:cloud_firestore/cloud_firestore.dart';

/// Model representing a shape on the facility map layout
/// Each shape can be assigned to a unit or exist independently
/// All shapes are scoped to a specific facility (multi-tenant SaaS)
class MapShapeModel {
  final String id;
  final String facilityId; // ✅ REQUIRED: SaaS tenant isolation
  final String? unitId; // Nullable: shape can exist before unit assignment
  final String type; // e.g., "rect", "circle", etc.
  final double x; // Position on canvas
  final double y; // Position on canvas
  final double width;
  final double height;
  final double rotation; // Optional rotation in degrees
  final int zIndex; // Draw order (higher = on top)
  final Map<String, dynamic>? metadata; // Optional custom fields
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;

  const MapShapeModel({
    required this.id,
    required this.facilityId,
    this.unitId,
    this.type = 'rect',
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotation = 0.0,
    this.zIndex = 0,
    this.metadata,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
  });

  /// Create from Firestore document
  factory MapShapeModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MapShapeModel(
      id: doc.id,
      facilityId: data['facilityId'] as String? ?? '',
      unitId: data['unitId'] as String?,
      type: data['type'] as String? ?? 'rect',
      x: (data['x'] as num?)?.toDouble() ?? 0.0,
      y: (data['y'] as num?)?.toDouble() ?? 0.0,
      width: (data['width'] as num?)?.toDouble() ?? 100.0,
      height: (data['height'] as num?)?.toDouble() ?? 100.0,
      rotation: (data['rotation'] as num?)?.toDouble() ?? 0.0,
      zIndex: data['zIndex'] as int? ?? 0,
      metadata: data['metadata'] as Map<String, dynamic>?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] as String? ?? '',
    );
  }

  /// Convert to Firestore map
  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId, // ✅ Always include for SaaS scoping
      if (unitId != null) 'unitId': unitId,
      'type': type,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'rotation': rotation,
      'zIndex': zIndex,
      if (metadata != null) 'metadata': metadata,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'createdBy': createdBy,
    };
  }

  /// Create a copy with updated fields
  MapShapeModel copyWith({
    String? id,
    String? facilityId,
    String? unitId,
    String? type,
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    int? zIndex,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    bool clearUnitId = false,
  }) {
    return MapShapeModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      unitId: clearUnitId ? null : (unitId ?? this.unitId),
      type: type ?? this.type,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      zIndex: zIndex ?? this.zIndex,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}
