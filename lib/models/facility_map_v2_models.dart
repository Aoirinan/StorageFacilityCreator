import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sfcapp/models/unit_model.dart';

enum FacilityMapVersionStatus { draft, published, archived }

enum FacilityMapElementType { unit, label, building, road, office, custom }

class FacilityMapMeta {
  final String facilityId;
  final String publicSlug;
  final String? activePublishedVersionId;
  final String activeDraftSource;
  final bool enabledForFacility;
  final Map<String, String> statusColorConfig;
  final DateTime? updatedAt;
  final String? updatedBy;

  const FacilityMapMeta({
    required this.facilityId,
    required this.publicSlug,
    this.activePublishedVersionId,
    this.activeDraftSource = 'legacyMapShapes',
    this.enabledForFacility = false,
    this.statusColorConfig = const {
      'available': '#2E7D32',
      'reserved': '#ED6C02',
      'occupied': '#1565C0',
      'maintenance': '#C62828',
      'outOfOrder': '#616161',
      'overlocked': '#B71C1C',
      'lockout': '#B71C1C',
      'auction': '#6A1B9A',
    },
    this.updatedAt,
    this.updatedBy,
  });

  factory FacilityMapMeta.fromMap(Map<String, dynamic> map, String facilityId) {
    final rawColors = (map['statusColorConfig'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    return FacilityMapMeta(
      facilityId: facilityId,
      publicSlug: map['publicSlug'] as String? ?? facilityId,
      activePublishedVersionId: map['activePublishedVersionId'] as String?,
      activeDraftSource: map['activeDraftSource'] as String? ?? 'legacyMapShapes',
      enabledForFacility: map['enabledForFacility'] == true,
      statusColorConfig: rawColors.map((k, v) => MapEntry(k, v.toString())),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      updatedBy: map['updatedBy'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'publicSlug': publicSlug,
      'activePublishedVersionId': activePublishedVersionId,
      'activeDraftSource': activeDraftSource,
      'enabledForFacility': enabledForFacility,
      'statusColorConfig': statusColorConfig,
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : FieldValue.serverTimestamp(),
      'updatedBy': updatedBy,
    };
  }
}

class FacilityMapElement {
  final String id;
  final String facilityId;
  final String? mapVersionId;
  final FacilityMapElementType elementType;
  final String? linkedUnitId;
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final int zIndex;
  final String? label;
  final Map<String, dynamic> style;
  final bool visibleInternal;
  final bool visiblePublic;

  const FacilityMapElement({
    required this.id,
    required this.facilityId,
    this.mapVersionId,
    required this.elementType,
    this.linkedUnitId,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.zIndex = 0,
    this.label,
    this.style = const <String, dynamic>{},
    this.visibleInternal = true,
    this.visiblePublic = true,
  });

  factory FacilityMapElement.fromMap(Map<String, dynamic> map, String id) {
    return FacilityMapElement(
      id: id,
      facilityId: map['facilityId'] as String? ?? '',
      mapVersionId: map['mapVersionId'] as String?,
      elementType: FacilityMapElementType.values.firstWhere(
        (v) => v.name == map['elementType'],
        orElse: () => FacilityMapElementType.custom,
      ),
      linkedUnitId: map['linkedUnitId'] as String?,
      x: (map['x'] as num?)?.toDouble() ?? 0,
      y: (map['y'] as num?)?.toDouble() ?? 0,
      width: (map['width'] as num?)?.toDouble() ?? 100,
      height: (map['height'] as num?)?.toDouble() ?? 80,
      rotation: (map['rotation'] as num?)?.toDouble() ?? 0,
      zIndex: map['zIndex'] as int? ?? 0,
      label: map['label'] as String?,
      style: Map<String, dynamic>.from(map['style'] as Map<String, dynamic>? ?? const <String, dynamic>{}),
      visibleInternal: map['visibleInternal'] != false,
      visiblePublic: map['visiblePublic'] != false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'mapVersionId': mapVersionId,
      'elementType': elementType.name,
      'linkedUnitId': linkedUnitId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'rotation': rotation,
      'zIndex': zIndex,
      'label': label,
      'style': style,
      'visibleInternal': visibleInternal,
      'visiblePublic': visiblePublic,
    };
  }
}

class FacilityMapVersion {
  final String id;
  final String facilityId;
  final FacilityMapVersionStatus status;
  final int versionNumber;
  final String? basedOnVersionId;
  final DateTime? createdAt;
  final String? createdBy;
  final DateTime? publishedAt;
  final String? publishedBy;
  final Map<String, dynamic> mapSettings;
  final List<FacilityMapElement> elements;

  const FacilityMapVersion({
    required this.id,
    required this.facilityId,
    required this.status,
    required this.versionNumber,
    this.basedOnVersionId,
    this.createdAt,
    this.createdBy,
    this.publishedAt,
    this.publishedBy,
    this.mapSettings = const <String, dynamic>{},
    this.elements = const <FacilityMapElement>[],
  });

  factory FacilityMapVersion.fromMap(Map<String, dynamic> map, String id) {
    final rawElements = (map['elements'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList();
    return FacilityMapVersion(
      id: id,
      facilityId: map['facilityId'] as String? ?? '',
      status: FacilityMapVersionStatus.values.firstWhere(
        (v) => v.name == map['status'],
        orElse: () => FacilityMapVersionStatus.draft,
      ),
      versionNumber: (map['versionNumber'] as num?)?.toInt() ?? 1,
      basedOnVersionId: map['basedOnVersionId'] as String?,
      createdAt: (map['createdAt'] as Timestamp?)?.toDate(),
      createdBy: map['createdBy'] as String?,
      publishedAt: (map['publishedAt'] as Timestamp?)?.toDate(),
      publishedBy: map['publishedBy'] as String?,
      mapSettings: Map<String, dynamic>.from(map['mapSettings'] as Map<String, dynamic>? ?? const <String, dynamic>{}),
      elements: rawElements
          .asMap()
          .entries
          .map((e) => FacilityMapElement.fromMap(e.value, e.value['id'] as String? ?? 'el-${e.key}'))
          .toList(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'status': status.name,
      'versionNumber': versionNumber,
      'basedOnVersionId': basedOnVersionId,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt!) : FieldValue.serverTimestamp(),
      'createdBy': createdBy,
      'publishedAt': publishedAt != null ? Timestamp.fromDate(publishedAt!) : null,
      'publishedBy': publishedBy,
      'mapSettings': mapSettings,
      'elements': elements
          .map((e) => {
                'id': e.id,
                ...e.toMap(),
              })
          .toList(),
    };
  }
}

class PublicFacilityMapSnapshot {
  final String facilityId;
  final String facilitySlug;
  final String publishedVersionId;
  final DateTime publishedAt;
  final Map<String, dynamic> publicSettings;
  final List<FacilityMapElement> elements;
  final List<Map<String, dynamic>> units;
  final String rentalRouteTemplate;
  final String moveInRouteTemplate;

  const PublicFacilityMapSnapshot({
    required this.facilityId,
    required this.facilitySlug,
    required this.publishedVersionId,
    required this.publishedAt,
    this.publicSettings = const <String, dynamic>{},
    this.elements = const <FacilityMapElement>[],
    this.units = const <Map<String, dynamic>>[],
    required this.rentalRouteTemplate,
    required this.moveInRouteTemplate,
  });

  factory PublicFacilityMapSnapshot.fromMap(Map<String, dynamic> map) {
    final rawElements = (map['elements'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList();
    final rawUnits = (map['units'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList();
    return PublicFacilityMapSnapshot(
      facilityId: map['facilityId'] as String? ?? '',
      facilitySlug: map['facilitySlug'] as String? ?? '',
      publishedVersionId: map['publishedVersionId'] as String? ?? '',
      publishedAt: (map['publishedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      publicSettings: Map<String, dynamic>.from(map['publicSettings'] as Map<String, dynamic>? ?? const <String, dynamic>{}),
      elements: rawElements
          .asMap()
          .entries
          .map((e) => FacilityMapElement.fromMap(e.value, e.value['id'] as String? ?? 'public-el-${e.key}'))
          .toList(),
      units: rawUnits,
      rentalRouteTemplate: map['rentalRouteTemplate'] as String? ?? '/rental',
      moveInRouteTemplate: map['moveInRouteTemplate'] as String? ?? '/public-move-in',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'facilitySlug': facilitySlug,
      'publishedVersionId': publishedVersionId,
      'publishedAt': Timestamp.fromDate(publishedAt),
      'publicSettings': publicSettings,
      'elements': elements
          .map((e) => {
                'id': e.id,
                ...e.toMap(),
              })
          .toList(),
      'units': units,
      'rentalRouteTemplate': rentalRouteTemplate,
      'moveInRouteTemplate': moveInRouteTemplate,
    };
  }
}

String statusToPublicStatus(UnitStatus status) {
  switch (status) {
    case UnitStatus.available:
      return 'available';
    case UnitStatus.reserved:
      return 'reserved';
    case UnitStatus.occupied:
      return 'rented';
    case UnitStatus.maintenance:
    case UnitStatus.outOfOrder:
    case UnitStatus.overlocked:
    case UnitStatus.lockout:
    case UnitStatus.auction:
      return 'unavailable';
  }
}
