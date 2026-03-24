import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/facility_map_v2_models.dart';
import 'package:sfcapp/models/facility_public_settings_model.dart';
import 'package:sfcapp/models/map_shape_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_public_service.dart';
import 'package:sfcapp/services/map_layout_service.dart';
import 'package:sfcapp/services/unit_service.dart';

class FacilityMapV2Service {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static DocumentReference<Map<String, dynamic>> _metaRef(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('mapEngine')
        .doc('meta');
  }

  static CollectionReference<Map<String, dynamic>> _versionsRef(
      String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('mapEngine')
        .doc('versions')
        .collection('items');
  }

  static Future<FacilityMapMeta> getOrCreateMeta(String facilityId) async {
    final current = _auth.currentUser;
    if (current == null) {
      throw Exception('Not signed in');
    }

    final ref = _metaRef(facilityId);
    final snap = await ref.get();
    if (snap.exists && snap.data() != null) {
      return FacilityMapMeta.fromMap(snap.data()!, facilityId);
    }

    final slug = _slugify(facilityId);
    final meta = FacilityMapMeta(
      facilityId: facilityId,
      publicSlug: slug,
      updatedAt: DateTime.now(),
      updatedBy: current.uid,
    );
    await ref.set(meta.toMap(), SetOptions(merge: true));
    return meta;
  }

  static Future<FacilityMapMeta?> getMeta(String facilityId) async {
    final current = _auth.currentUser;
    if (current == null) {
      throw Exception('Not signed in');
    }
    final snap = await _metaRef(facilityId).get();
    if (!snap.exists || snap.data() == null) {
      return null;
    }
    return FacilityMapMeta.fromMap(snap.data()!, facilityId);
  }

  static Stream<FacilityMapMeta> metaStream(String facilityId) {
    return _metaRef(facilityId).snapshots().asyncMap((snap) async {
      if (!snap.exists || snap.data() == null) {
        return getOrCreateMeta(facilityId);
      }
      return FacilityMapMeta.fromMap(snap.data()!, facilityId);
    });
  }

  static Stream<List<FacilityMapVersion>> versionsStream(String facilityId) {
    return _versionsRef(facilityId)
        .orderBy('versionNumber', descending: true)
        .snapshots()
        .map((snap) {
      return snap.docs
          .map((doc) => FacilityMapVersion.fromMap(doc.data(), doc.id))
          .toList();
    });
  }

  static Future<void> setFacilityV2Enabled({
    required String facilityId,
    required bool enabled,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }
    await _metaRef(facilityId).set({
      'facilityId': facilityId,
      'enabledForFacility': enabled,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': user.uid,
    }, SetOptions(merge: true));
  }

  static Future<String> publishCurrentDraft({
    required String facilityId,
    Map<String, dynamic>? mapSettings,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }

    final meta = await getOrCreateMeta(facilityId);
    final facilitySnap =
        await _firestore.collection('facilities').doc(facilityId).get();
    final facilityData = facilitySnap.data() ?? const <String, dynamic>{};
    final draftShapes = await MapLayoutService.getMapShapes(facilityId);
    final units = await UnitService.getUnitsForFacility(facilityId);
    final existingVersions = await _versionsRef(facilityId)
        .orderBy('versionNumber', descending: true)
        .limit(1)
        .get();
    final nextVersion = existingVersions.docs.isEmpty
        ? 1
        : (existingVersions.docs.first.data()['versionNumber'] as num? ?? 0)
                .toInt() +
            1;

    final versionDoc = _versionsRef(facilityId).doc();
    final now = DateTime.now();
    final elements = draftShapes.map(_shapeToV2Element).toList();

    final version = FacilityMapVersion(
      id: versionDoc.id,
      facilityId: facilityId,
      status: FacilityMapVersionStatus.published,
      versionNumber: nextVersion,
      basedOnVersionId: meta.activePublishedVersionId,
      createdAt: now,
      createdBy: user.uid,
      publishedAt: now,
      publishedBy: user.uid,
      mapSettings: mapSettings ?? const <String, dynamic>{'gridSize': 20},
      elements: elements,
    );

    final batch = _firestore.batch();
    batch.set(versionDoc, version.toMap(), SetOptions(merge: true));

    if (meta.activePublishedVersionId != null &&
        meta.activePublishedVersionId!.isNotEmpty) {
      final oldRef =
          _versionsRef(facilityId).doc(meta.activePublishedVersionId);
      batch.set(
          oldRef,
          {
            'status': FacilityMapVersionStatus.archived.name,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true));
    }

    batch.set(
        _metaRef(facilityId),
        {
          'facilityId': facilityId,
          'activePublishedVersionId': versionDoc.id,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': user.uid,
          'publicSlug': meta.publicSlug,
        },
        SetOptions(merge: true));

    final publicSettings =
        await FacilityPublicService.getPublicSettings(facilityId);
    final snapshot = _buildPublicSnapshot(
      facilityId: facilityId,
      slug: meta.publicSlug,
      facilityName: facilityData['name']?.toString(),
      facilityDescription: facilityData['description']?.toString(),
      facilityPhone: facilityData['phone']?.toString(),
      facilityLogoUrl: facilityData['logoUrl']?.toString(),
      publishedVersionId: versionDoc.id,
      elements: elements,
      units: units,
      publicSettingsModel: publicSettings,
      mapSettings: version.mapSettings,
    );
    final publicRef =
        _firestore.collection('publicFacilityMaps').doc(meta.publicSlug);
    batch.set(publicRef, snapshot.toMap(), SetOptions(merge: true));

    await batch.commit();
    return versionDoc.id;
  }

  static Future<void> rollbackToVersion({
    required String facilityId,
    required String versionId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }
    final versionSnap = await _versionsRef(facilityId).doc(versionId).get();
    if (!versionSnap.exists || versionSnap.data() == null) {
      throw Exception('Version not found');
    }

    final version =
        FacilityMapVersion.fromMap(versionSnap.data()!, versionSnap.id);
    final shapesRef = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('mapShapes');
    final existingShapes = await shapesRef.get();
    final deleteBatch = _firestore.batch();
    for (final doc in existingShapes.docs) {
      deleteBatch.delete(doc.reference);
    }
    await deleteBatch.commit();

    final createBatch = _firestore.batch();
    for (final element in version.elements
        .where((e) => e.elementType == FacilityMapElementType.unit)) {
      final docRef = shapesRef.doc(element.id);
      createBatch.set(docRef, {
        'facilityId': facilityId,
        if (element.linkedUnitId != null) 'unitId': element.linkedUnitId,
        'type': 'rect',
        'x': element.x,
        'y': element.y,
        'width': element.width,
        'height': element.height,
        'rotation': element.rotation,
        'zIndex': element.zIndex,
        'metadata': {'label': element.label},
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'createdBy': user.uid,
      });
    }
    await createBatch.commit();

    await _metaRef(facilityId).set({
      'activePublishedVersionId': versionId,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': user.uid,
    }, SetOptions(merge: true));
  }

  static Future<String> setPublicSlug({
    required String facilityId,
    required String slug,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }
    final normalized = _slugify(slug);
    await _metaRef(facilityId).set({
      'facilityId': facilityId,
      'publicSlug': normalized,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': user.uid,
    }, SetOptions(merge: true));
    return normalized;
  }

  static String buildPublicMapUrl(String slug,
      {String baseUrl = 'https://storage-facility-creator.web.app'}) {
    return '$baseUrl/#/public/$slug/map';
  }

  static Future<PublicFacilityMapSnapshot?> getPublicSnapshotBySlug(
      String slug) async {
    final doc =
        await _firestore.collection('publicFacilityMaps').doc(slug).get();
    if (!doc.exists || doc.data() == null) {
      return null;
    }
    return PublicFacilityMapSnapshot.fromMap(doc.data()!);
  }

  static Future<String?> getPublicSlugForFacility(String facilityId) async {
    final query = await _firestore
        .collection('publicFacilityMaps')
        .where('facilityId', isEqualTo: facilityId)
        .limit(1)
        .get();
    if (query.docs.isEmpty) {
      return null;
    }
    return query.docs.first.id;
  }

  static Future<void> migrateLegacyMapToInitialVersion(
      String facilityId) async {
    final versions = await _versionsRef(facilityId).limit(1).get();
    if (versions.docs.isNotEmpty) {
      return;
    }
    await publishCurrentDraft(
        facilityId: facilityId,
        mapSettings: const <String, dynamic>{'migratedFromLegacy': true});
  }

  static PublicFacilityMapSnapshot _buildPublicSnapshot({
    required String facilityId,
    required String slug,
    required String? facilityName,
    required String? facilityDescription,
    required String? facilityPhone,
    required String? facilityLogoUrl,
    required String publishedVersionId,
    required List<FacilityMapElement> elements,
    required List<UnitModel> units,
    required FacilityPublicSettings? publicSettingsModel,
    required Map<String, dynamic> mapSettings,
  }) {
    final showPublicPricing = publicSettingsModel?.publicPricingEnabled ?? true;
    final allowReservation = publicSettingsModel?.publicRentalsEnabled ?? false;
    final showUnitNumbers =
        publicSettingsModel?.publicUnitNumbersEnabled ?? true;
    final allowAutoAssign = publicSettingsModel?.allowAutoAssign ?? true;
    final allowUnitSelection = publicSettingsModel?.allowUnitSelection ?? true;
    final showAvailabilityCount =
        publicSettingsModel?.showAvailabilityCount ?? true;
    final hideUnavailableTypes =
        publicSettingsModel?.hideUnavailableTypes ?? true;
    final enabledPublicUnitTypes =
        (publicSettingsModel?.enabledPublicUnitTypes ?? const <String>[])
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

    final visibleElements = elements.where((e) => e.visiblePublic).toList();
    final safeUnits = units.map((unit) {
      final dims = unit.dimensions ?? const <String, dynamic>{};
      final width = (dims['width'] as num?)?.toDouble();
      final depth = (dims['depth'] as num?)?.toDouble();
      String? size;
      if (width != null && depth != null) {
        size = '${width.toStringAsFixed(0)}x${depth.toStringAsFixed(0)}';
      }

      final unitType = unit.unitType;
      final categorySlug = _slugify(unitType);
      final isPubliclyEnabledType = enabledPublicUnitTypes.isEmpty ||
          enabledPublicUnitTypes.contains(unitType);

      return <String, dynamic>{
        'unitId': unit.id,
        'unitNumber': showUnitNumbers ? unit.unitNumber : null,
        'unitLabel': showUnitNumbers ? unit.unitNumber : null,
        'displayName':
            showUnitNumbers ? 'Unit ${unit.unitNumber}' : 'Available Unit',
        'status': statusToPublicStatus(unit.status),
        'internalStatus': unit.status.name,
        'unitType': unitType,
        'categorySlug': categorySlug,
        'size': size,
        'description': unit.description,
        'monthlyRate': showPublicPricing ? unit.monthlyRate : null,
        'isRentable': (unit.status == UnitStatus.available ||
                unit.status == UnitStatus.reserved) &&
            isPubliclyEnabledType,
      };
    }).toList();

    return PublicFacilityMapSnapshot(
      facilityId: facilityId,
      facilitySlug: slug,
      publishedVersionId: publishedVersionId,
      publishedAt: DateTime.now(),
      publicSettings: <String, dynamic>{
        'facilityName': facilityName,
        'facilityDescription': facilityDescription,
        'facilityPhone': facilityPhone,
        'facilityLogoUrl': facilityLogoUrl,
        'showPublicPricing': showPublicPricing,
        'allowReservation': allowReservation,
        'publicRentalsEnabled': allowReservation,
        'publicUnitNumbersEnabled': showUnitNumbers,
        'allowAutoAssign': allowAutoAssign,
        'allowUnitSelection': allowUnitSelection,
        'showAvailabilityCount': showAvailabilityCount,
        'hideUnavailableTypes': hideUnavailableTypes,
        'enabledPublicUnitTypes': enabledPublicUnitTypes,
        'mapSettings': mapSettings,
      },
      elements: visibleElements,
      units: safeUnits,
      rentalRouteTemplate: '/f/$slug/rent?unitId={unitId}',
      moveInRouteTemplate: '/public-move-in?token={token}',
    );
  }

  static FacilityMapElement _shapeToV2Element(MapShapeModel shape) {
    return FacilityMapElement(
      id: shape.id,
      facilityId: shape.facilityId,
      elementType: shape.unitId != null
          ? FacilityMapElementType.unit
          : FacilityMapElementType.custom,
      linkedUnitId: shape.unitId,
      x: shape.x,
      y: shape.y,
      width: shape.width,
      height: shape.height,
      rotation: shape.rotation,
      zIndex: shape.zIndex,
      label: shape.metadata?['label']?.toString(),
      style: <String, dynamic>{
        'legacyType': shape.type,
      },
      visibleInternal: true,
      visiblePublic: shape.unitId != null,
    );
  }

  static String _slugify(String raw) {
    final lowered = raw.toLowerCase().trim();
    final cleaned = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final normalized = cleaned
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return normalized.isEmpty ? 'facility-map' : normalized;
  }
}
