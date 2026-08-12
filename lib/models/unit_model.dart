import 'package:cloud_firestore/cloud_firestore.dart';
import 'overlock_model.dart';

enum UnitStatus {
  available,
  occupied,
  reserved,
  maintenance,
  outOfOrder,
  overlocked, // Unit is locked due to delinquency
  lockout, // Unit is locked out (same as overlocked, kept for clarity)
  auction, // Unit is in auction process
}

enum UnitType {
  standard,
  climateControlled,
  vehicle,
  document,
  wine,
  outdoor,
}

class UnitModel {
  final String id;
  final String facilityId;
  final String unitNumber;
  final String unitType;
  final UnitStatus status;
  final String? tenantId;
  final String? tenantName;
  final double monthlyRate;
  final double? securityDeposit;
  final String? description;
  final Map<String, dynamic>? dimensions; // width, height, depth
  final List<String>? features; // climate control, security, etc.
  final String? notes;
  final DateTime? lastMaintenance;
  final DateTime? nextMaintenance;
  final DateTime? moveInDate;
  final DateTime? moveOutDate;
  final DateTime? moveOutNoticeDate; // Date tenant gave notice to vacate
  final DateTime? reservationExpiry;
  final String? reservedBy;
  final Map<String, dynamic>? customFields;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;
  final String? updatedBy;
  final double? mapX;
  final double? mapY;
  final double? mapWidth;
  final double? mapHeight;
  /// Manager overlock state (auditable). If absent, treat as not overlocked.
  final OverlockInfo? overlock;
  /// Whether this unit can appear as rentable on the facility's public website.
  /// Defaults to true; set false for staff-only spaces (manager residence,
  /// office, personal-use units) that are `available` internally but must
  /// never be publicly rentable.
  final bool publicListingEnabled;

  const UnitModel({
    required this.id,
    required this.facilityId,
    required this.unitNumber,
    required this.unitType,
    required this.status,
    this.tenantId,
    this.tenantName,
    required this.monthlyRate,
    this.securityDeposit,
    this.description,
    this.dimensions,
    this.features,
    this.notes,
    this.lastMaintenance,
    this.nextMaintenance,
    this.moveInDate,
    this.moveOutDate,
    this.moveOutNoticeDate,
    this.reservationExpiry,
    this.reservedBy,
    this.customFields,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
    this.updatedBy,
    this.mapX,
    this.mapY,
    this.mapWidth,
    this.mapHeight,
    this.overlock,
    this.publicListingEnabled = true,
  });

  factory UnitModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final layout = data['mapLayout'] as Map<String, dynamic>?;
    return UnitModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      unitNumber: data['unitNumber'] ?? '',
      unitType: data['unitType'] ?? 'standard',
      status: UnitStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => UnitStatus.available,
      ),
      tenantId: data['tenantId'],
      tenantName: data['tenantName'],
      monthlyRate: (data['monthlyRate'] ?? 0.0).toDouble(),
      securityDeposit: data['securityDeposit']?.toDouble(),
      description: data['description'],
      dimensions: data['dimensions'] != null 
          ? Map<String, dynamic>.from(data['dimensions'])
          : null,
      features: data['features'] != null 
          ? List<String>.from(data['features'])
          : null,
      notes: data['notes'],
      lastMaintenance: data['lastMaintenance']?.toDate(),
      nextMaintenance: data['nextMaintenance']?.toDate(),
      moveInDate: data['moveInDate']?.toDate(),
      moveOutDate: data['moveOutDate']?.toDate(),
      moveOutNoticeDate: data['moveOutNoticeDate']?.toDate(),
      reservationExpiry: data['reservationExpiry']?.toDate(),
      reservedBy: data['reservedBy'],
      customFields: data['customFields'] != null 
          ? Map<String, dynamic>.from(data['customFields'])
          : null,
      createdAt: data['createdAt']?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt']?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] ?? '',
      updatedBy: data['updatedBy'],
      mapX: (layout?['x'] as num?)?.toDouble(),
      mapY: (layout?['y'] as num?)?.toDouble(),
      mapWidth: (layout?['width'] as num?)?.toDouble(),
      mapHeight: (layout?['height'] as num?)?.toDouble(),
      overlock: data['overlock'] != null
          ? OverlockInfo.fromMap(Map<String, dynamic>.from(data['overlock'] as Map))
          : null,
      publicListingEnabled: data['publicListingEnabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    final map = {
      'facilityId': facilityId,
      'unitNumber': unitNumber,
      'unitType': unitType,
      'status': status.name,
      'tenantId': tenantId,
      'tenantName': tenantName,
      'monthlyRate': monthlyRate,
      'securityDeposit': securityDeposit,
      'description': description,
      'dimensions': dimensions,
      'features': features,
      'notes': notes,
      'lastMaintenance': lastMaintenance,
      'nextMaintenance': nextMaintenance,
      'moveInDate': moveInDate,
      'moveOutDate': moveOutDate,
      'moveOutNoticeDate': moveOutNoticeDate,
      'reservationExpiry': reservationExpiry,
      'reservedBy': reservedBy,
      'customFields': customFields,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'createdBy': createdBy,
      'updatedBy': updatedBy,
      'publicListingEnabled': publicListingEnabled,
    };
    if (mapX != null || mapY != null || mapWidth != null || mapHeight != null) {
      map['mapLayout'] = {
        if (mapX != null) 'x': mapX,
        if (mapY != null) 'y': mapY,
        if (mapWidth != null) 'width': mapWidth,
        if (mapHeight != null) 'height': mapHeight,
      };
    }
    return map;
  }

  UnitModel copyWith({
    String? id,
    String? facilityId,
    String? unitNumber,
    String? unitType,
    UnitStatus? status,
    String? tenantId,
    String? tenantName,
    double? monthlyRate,
    double? securityDeposit,
    String? description,
    Map<String, dynamic>? dimensions,
    List<String>? features,
    String? notes,
    DateTime? lastMaintenance,
    DateTime? nextMaintenance,
    DateTime? moveInDate,
    DateTime? moveOutDate,
    DateTime? moveOutNoticeDate,
    DateTime? reservationExpiry,
    String? reservedBy,
    Map<String, dynamic>? customFields,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    String? updatedBy,
    double? mapX,
    double? mapY,
    double? mapWidth,
    double? mapHeight,
    OverlockInfo? overlock,
    bool? publicListingEnabled,
  }) {
    return UnitModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      unitNumber: unitNumber ?? this.unitNumber,
      unitType: unitType ?? this.unitType,
      status: status ?? this.status,
      tenantId: tenantId ?? this.tenantId,
      tenantName: tenantName ?? this.tenantName,
      monthlyRate: monthlyRate ?? this.monthlyRate,
      securityDeposit: securityDeposit ?? this.securityDeposit,
      description: description ?? this.description,
      dimensions: dimensions ?? this.dimensions,
      features: features ?? this.features,
      notes: notes ?? this.notes,
      lastMaintenance: lastMaintenance ?? this.lastMaintenance,
      nextMaintenance: nextMaintenance ?? this.nextMaintenance,
      moveInDate: moveInDate ?? this.moveInDate,
      moveOutDate: moveOutDate ?? this.moveOutDate,
      moveOutNoticeDate: moveOutNoticeDate ?? this.moveOutNoticeDate,
      reservationExpiry: reservationExpiry ?? this.reservationExpiry,
      reservedBy: reservedBy ?? this.reservedBy,
      customFields: customFields ?? this.customFields,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      updatedBy: updatedBy ?? this.updatedBy,
      mapX: mapX ?? this.mapX,
      mapY: mapY ?? this.mapY,
      mapWidth: mapWidth ?? this.mapWidth,
      mapHeight: mapHeight ?? this.mapHeight,
      overlock: overlock ?? this.overlock,
      publicListingEnabled: publicListingEnabled ?? this.publicListingEnabled,
    );
  }

  // Helper methods
  bool get isAvailable => status == UnitStatus.available;
  bool get isOccupied => status == UnitStatus.occupied;
  bool get isReserved => status == UnitStatus.reserved;
  bool get isMaintenance => status == UnitStatus.maintenance;
  bool get isOutOfOrder => status == UnitStatus.outOfOrder;
  /// True if unit has overlock flag set (manager overlock). Prefers overlock.isOverlocked when present; otherwise status.
  bool get isOverlocked {
    if (overlock != null) return overlock!.isOverlocked;
    return status == UnitStatus.overlocked || status == UnitStatus.lockout;
  }

  String get statusDisplayName {
    switch (status) {
      case UnitStatus.available:
        return 'Available';
      case UnitStatus.occupied:
        return 'Occupied';
      case UnitStatus.reserved:
        return 'Reserved';
      case UnitStatus.maintenance:
        return 'Maintenance';
      case UnitStatus.outOfOrder:
        return 'Out of Order';
      case UnitStatus.overlocked:
        return 'Overlocked';
      case UnitStatus.lockout:
        return 'Lockout';
      case UnitStatus.auction:
        return 'Auction';
    }
  }

  String get unitTypeDisplayName {
    switch (unitType) {
      case 'standard':
        return 'Standard';
      case 'climateControlled':
        return 'Climate Controlled';
      case 'vehicle':
        return 'Vehicle Storage';
      case 'document':
        return 'Document Storage';
      case 'wine':
        return 'Wine Storage';
      case 'outdoor':
        return 'Outdoor Storage';
      default:
        return 'Standard';
    }
  }

  String get displayName => '$unitNumber - $unitTypeDisplayName';
  String get fullDisplayName => '$unitNumber - $unitTypeDisplayName (${statusDisplayName})';

  String get formattedPrice => '\$${monthlyRate.toStringAsFixed(2)}/month';

  String get dimensionsDisplay {
    if (dimensions == null) return 'Not specified';
    final width = dimensions!['width']?.toString() ?? 'N/A';
    final height = dimensions!['height']?.toString() ?? 'N/A';
    final depth = dimensions!['depth']?.toString() ?? 'N/A';
    return '${width}" × ${height}" × ${depth}"';
  }

  String get mapStatusLabel {
    switch (status) {
      case UnitStatus.available:
        return 'Available';
      case UnitStatus.occupied:
        return 'Occupied';
      case UnitStatus.reserved:
        return 'Reserved';
      case UnitStatus.maintenance:
        return 'Maintenance';
      case UnitStatus.outOfOrder:
        return 'Out of Order';
      case UnitStatus.overlocked:
        return 'Overlocked';
      case UnitStatus.lockout:
        return 'Lockout';
      case UnitStatus.auction:
        return 'Auction';
    }
  }

  @override
  String toString() {
    return 'UnitModel(id: $id, unitNumber: $unitNumber, status: $status, tenantId: $tenantId)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UnitModel && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

// Extension for enum display names
extension UnitStatusExtension on UnitStatus {
  String get displayName {
    switch (this) {
      case UnitStatus.available:
        return 'Available';
      case UnitStatus.occupied:
        return 'Occupied';
      case UnitStatus.reserved:
        return 'Reserved';
      case UnitStatus.maintenance:
        return 'Maintenance';
      case UnitStatus.outOfOrder:
        return 'Out of Order';
      case UnitStatus.overlocked:
        return 'Overlocked';
      case UnitStatus.lockout:
        return 'Lockout';
      case UnitStatus.auction:
        return 'Auction';
    }
  }
}

extension UnitTypeExtension on UnitType {
  String get displayName {
    switch (this) {
      case UnitType.standard:
        return 'Standard';
      case UnitType.climateControlled:
        return 'Climate Controlled';
      case UnitType.vehicle:
        return 'Vehicle Storage';
      case UnitType.document:
        return 'Document Storage';
      case UnitType.wine:
        return 'Wine Storage';
      case UnitType.outdoor:
        return 'Outdoor Storage';
    }
  }
}
