import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/facility_map_v2_models.dart';
import 'package:sfcapp/models/facility_public_settings_model.dart';
import 'package:sfcapp/models/map_shape_model.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_public_service.dart';
import 'package:sfcapp/services/map_layout_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/firestore_field_read.dart';

/// The website URL name asked for is another facility's storefront.
class PublicSlugTakenException implements UserFacingException {
  PublicSlugTakenException(this.slug);

  final String slug;

  @override
  String get message => 'The website URL name "$slug" is already used by '
      'another facility. Choose a different one.';

  @override
  String toString() => message;
}

class FacilityMapV2Service {
  // Getters, not final fields, so tests can run a publish against a fake
  // Firestore and a signed-in fake user.
  static FirebaseFirestore get _firestore =>
      _firestoreForTesting ?? FirebaseFirestore.instance;
  static FirebaseFirestore? _firestoreForTesting;
  static FirebaseAuth get _auth => _authForTesting ?? FirebaseAuth.instance;
  static FirebaseAuth? _authForTesting;

  @visibleForTesting
  static set firestoreForTesting(FirebaseFirestore? firestore) =>
      _firestoreForTesting = firestore;

  @visibleForTesting
  static set authForTesting(FirebaseAuth? auth) => _authForTesting = auth;

  // Where the map meta, the public map docs, batches and the signed-in user
  // come from: Firestore and Auth, unless a test points them at fakes so the
  // slug methods' own reads and writes run.
  static CollectionReference<Map<String, dynamic>> Function(String path)
      _collection = _firestoreCollection;
  static WriteBatch Function() _batch = _firestoreBatch;
  static User? Function() _currentUser = _authCurrentUser;

  static CollectionReference<Map<String, dynamic>> _firestoreCollection(
          String path) =>
      _firestore.collection(path);
  static WriteBatch _firestoreBatch() => _firestore.batch();
  static User? _authCurrentUser() => _auth.currentUser;

  /// Serves [collection], [batch] and [currentUser] instead of Firestore and
  /// Auth; null restores them.
  @visibleForTesting
  static void overrideForTesting({
    CollectionReference<Map<String, dynamic>> Function(String path)?
        collection,
    WriteBatch Function()? batch,
    User? Function()? currentUser,
  }) {
    _collection = collection ?? _firestoreCollection;
    _batch = batch ?? _firestoreBatch;
    _currentUser = currentUser ?? _authCurrentUser;
  }

  static const String _publicMapsCollection = 'publicFacilityMaps';

  static DocumentReference<Map<String, dynamic>> _metaRef(String facilityId) {
    return _collection('facilities')
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

  static Future<String> publishCurrentDraft({
    required String facilityId,
    Map<String, dynamic>? mapSettings,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }

    // Throws rather than publish a snapshot built from default settings: that
    // switched the public site off, cleared its custom domain and page text,
    // and opened every unit type, until the next publish. Read first, so a
    // failure writes nothing (getOrCreateMeta can create the meta doc).
    final publicSettings =
        await FacilityPublicService.getPublicSettingsOrThrow(facilityId);
    // Throws too. On a failed read this saw no tenants, so a unit taken only
    // through an active tenant's unit number was published as rentable.
    final claimedUnits = await readTenantClaimedUnitNumbersOrThrow(facilityId);

    final meta = await getOrCreateMeta(facilityId);
    final facilitySnap =
        await _firestore.collection('facilities').doc(facilityId).get();
    final facilityData = facilitySnap.data() ?? const <String, dynamic>{};
    final draftShapes = await MapLayoutService.getMapShapes(facilityId);
    final units = await _fetchActiveUnitsOrdered(facilityId);
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

    final inventory = publicUnitInventory(
      facilityId: facilityId,
      units: units,
      publicSettings: publicSettings,
      tenantClaimedUnitNumbers: claimedUnits,
    );
    final snapshot = _buildPublicSnapshot(
      facilityId: facilityId,
      slug: meta.publicSlug,
      facilityName: facilityData['name']?.toString(),
      facilityDescription: facilityData['description']?.toString(),
      facilityPhone: facilityData['phone']?.toString(),
      facilityLogoUrl: facilityData['logoUrl']?.toString(),
      publishedVersionId: versionDoc.id,
      elements: elements,
      publicUnits: inventory.units,
      publicSettingsModel: publicSettings,
      mapSettings: version.mapSettings,
    );
    final publicRef =
        _firestore.collection(_publicMapsCollection).doc(meta.publicSlug);
    batch.set(
      publicRef,
      publishedMapFields(
        snapshot,
        unitsTotal: inventory.unitsTotal,
        unitsOmitted: inventory.unitsOmitted,
      ),
      SetOptions(merge: true),
    );

    await batch.commit();
    return versionDoc.id;
  }

  /// What a publish merges into the current slug's public map doc: the
  /// snapshot and the unit counts, with any pointer fields deleted. A slug
  /// the facility moved away from and later returned to is a pointer
  /// ([setPublicSlug]), and a merge alone would have left it forwarding.
  @visibleForTesting
  static Map<String, dynamic> publishedMapFields(
    PublicFacilityMapSnapshot snapshot, {
    required int unitsTotal,
    required int unitsOmitted,
  }) {
    return {
      ...snapshot.toMap(),
      'unitsTotal': unitsTotal,
      'unitsOmitted': unitsOmitted,
      'movedToSlug': FieldValue.delete(),
      'movedAt': FieldValue.delete(),
    };
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

  /// Points the facility's public map at [slug] (normalized, and returned).
  ///
  /// This used to change only mapEngine/meta.publicSlug. The old slug's
  /// public map doc stayed, full units and all, and nothing synced it again,
  /// so old links served a frozen unit list for good. Now, when the slug
  /// changes and the old doc is this facility's, the old doc becomes a
  /// pointer ({facilityId, movedToSlug, movedAt}, no units or settings) that
  /// readers follow ([resolvePublicMap]), and the map it held is carried to
  /// the new slug in the same batch, so old links land on it straight away
  /// rather than once the publish that follows succeeds. The pointer keeps
  /// the old slug reserved to this facility (the update rule pins facilityId).
  ///
  /// The facility's other pointers, from earlier changes, are repointed at
  /// the new slug in the same batch. Readers follow one hop only, so after
  /// A to B to C a pointer left at A naming B, itself a pointer now, would
  /// have served nothing.
  ///
  /// A slug another facility's doc holds is refused before anything is
  /// written ([PublicSlugTakenException]). It used to be taken into the meta
  /// and only the publish after it failed, on the rules.
  static Future<String> setPublicSlug({
    required String facilityId,
    required String slug,
  }) async {
    final user = _currentUser();
    if (user == null) {
      throw Exception('Not signed in');
    }
    final normalized =
        await ensurePublicSlugAvailable(facilityId: facilityId, slug: slug);
    final maps = _collection(_publicMapsCollection);
    final metaRef = _metaRef(facilityId);
    final newRef = maps.doc(normalized);

    final storedSlug = (await metaRef.get()).data()?['publicSlug'];
    final oldSlug = storedSlug is String ? storedSlug.trim() : '';
    DocumentReference<Map<String, dynamic>>? oldRef;
    Map<String, dynamic>? oldMap;
    final repoint = <DocumentReference<Map<String, dynamic>>>[];
    if (oldSlug.isNotEmpty && oldSlug != normalized) {
      final ref = maps.doc(oldSlug);
      final data = (await ref.get()).data();
      if (data != null && data['facilityId'] == facilityId) {
        oldRef = ref;
        oldMap = data;
      }
      final mine =
          await maps.where('facilityId', isEqualTo: facilityId).get();
      for (final doc in mine.docs) {
        final movedTo = movedToSlugOf(doc.data());
        if (movedTo == null || movedTo == normalized) continue;
        if (doc.id == oldSlug || doc.id == normalized) continue;
        repoint.add(doc.reference);
      }
    }

    final batch = _batch();
    batch.set(
        metaRef,
        {
          'facilityId': facilityId,
          'publicSlug': normalized,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': user.uid,
        },
        SetOptions(merge: true));
    // A pointer already (the meta named one) has no map to carry over.
    if (oldMap != null && movedToSlugOf(oldMap) == null) {
      batch.set(newRef, {
        ...oldMap,
        'facilitySlug': normalized,
        'rentalRouteTemplate': '/f/$normalized/rent?unitId={unitId}',
      });
    }
    for (final ref in [if (oldRef != null) oldRef, ...repoint]) {
      batch.set(ref, <String, dynamic>{
        'facilityId': facilityId,
        'movedToSlug': normalized,
        'movedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    return normalized;
  }

  /// [slug], normalized as [setPublicSlug] stores it, when no public map doc
  /// holds it or this facility's does (its live map or one of its pointers).
  /// Throws [PublicSlugTakenException] when another facility's does.
  ///
  /// The settings screens call this before saving publicRentalSlug. They
  /// saved it first, and [setPublicSlug] refused a taken slug only after:
  /// the settings kept it, and rent links built from them opened the other
  /// facility's storefront.
  static Future<String> ensurePublicSlugAvailable({
    required String facilityId,
    required String slug,
  }) async {
    final normalized = _slugify(slug);
    final snap =
        await _collection(_publicMapsCollection).doc(normalized).get();
    if (snap.exists && snap.data()?['facilityId'] != facilityId) {
      throw PublicSlugTakenException(normalized);
    }
    return normalized;
  }

  static String buildPublicMapUrl(String slug,
      {String baseUrl = 'https://app.storagefacilitycreator.com'}) {
    return '$baseUrl/#/public/$slug/map';
  }

  /// The slug a public map doc forwards to, or null when [data] is a
  /// published map. Same as movedToSlugOf in
  /// functions-shared/src/hosting/publicFacilityMapSlug.ts.
  static String? movedToSlugOf(Map<String, dynamic>? data) {
    final raw = data?['movedToSlug'];
    if (raw is! String) return null;
    final slug = raw.trim();
    return slug.isEmpty ? null : slug;
  }

  /// Whether publicFacilityMaps/{slug} has the website switched on, which is
  /// half of what renderPublicWebsite checks before serving /w/{slug} (the
  /// other half is the website add-on). False when nothing is published
  /// there, or [slug] is an old slug's pointer; throws when the doc cannot be
  /// read. Reads the one field rather than the whole snapshot, so an odd
  /// value elsewhere cannot fail it.
  static Future<bool> publishedWebsiteEnabled(String slug) async {
    final doc = await _collection(_publicMapsCollection).doc(slug).get();
    final settings = doc.data()?['publicSettings'];
    return settings is Map && settings['enabled'] == true;
  }

  static Future<PublicFacilityMapSnapshot?> getPublicSnapshotBySlug(
      String slug) async {
    return (await resolvePublicMap(slug))?.snapshot;
  }

  /// The published map served at [slug], and the slug it lives at: [slug]
  /// itself, or where the pointer left at an old slug says it moved. The
  /// pointer is followed one hop, and only to a doc of the same facility
  /// that is not a pointer itself, as readPublicFacilityMap does for the
  /// server-rendered site.
  static Future<({String slug, PublicFacilityMapSnapshot snapshot})?>
      resolvePublicMap(String slug) async {
    final maps = _collection(_publicMapsCollection);
    final data = (await maps.doc(slug).get()).data();
    if (data == null) return null;
    final movedTo = movedToSlugOf(data);
    if (movedTo == null) {
      return (slug: slug, snapshot: PublicFacilityMapSnapshot.fromMap(data));
    }

    final facilityId = data['facilityId'];
    if (facilityId is! String || facilityId.isEmpty || movedTo == slug) {
      return null;
    }
    final target = (await maps.doc(movedTo).get()).data();
    if (target == null ||
        target['facilityId'] != facilityId ||
        movedToSlugOf(target) != null) {
      return null;
    }
    return (slug: movedTo, snapshot: PublicFacilityMapSnapshot.fromMap(target));
  }

  /// The facility's current public map slug.
  ///
  /// This asked publicFacilityMaps for any doc of the facility, limit 1,
  /// which is the first by id: an old slug's doc as often as the live one
  /// (Keepsake got 'eXnWPuwuqzBVFcZWv1ZL', frozen, over
  /// 'keepsakeonlinerentals'), and the settings screens then saved it back
  /// as the slug. The facility's own record of it, mapEngine/meta, comes
  /// first, unless another facility's doc holds that slug (a meta could take
  /// one before [setPublicSlug] refused them). Only owners and managers can
  /// read the meta; staff and the public pages, and a facility with no meta
  /// yet, get the query, which never answers with a pointer and prefers the
  /// doc written most recently.
  static Future<String?> getPublicSlugForFacility(String facilityId) async {
    final maps = _collection(_publicMapsCollection);
    try {
      final stored = (await _metaRef(facilityId).get()).data()?['publicSlug'];
      if (stored is String && stored.trim().isNotEmpty) {
        final slug = stored.trim();
        final owner = (await maps.doc(slug).get()).data()?['facilityId'];
        if (owner == null || owner == facilityId) return slug;
      }
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
    }

    final query = await maps
        .where('facilityId', isEqualTo: facilityId)
        .get();
    String? best;
    var bestWrittenAt = -1;
    for (final doc in query.docs) {
      final data = doc.data();
      if (movedToSlugOf(data) != null) continue;
      final writtenAt = _lastWrittenMillis(data);
      if (writtenAt > bestWrittenAt) {
        best = doc.id;
        bestWrittenAt = writtenAt;
      }
    }
    return best;
  }

  /// The later of a public map doc's publish and inventory sync, in ms since
  /// the epoch; 0 when it has neither. An old slug's doc stopped at both.
  static int _lastWrittenMillis(Map<String, dynamic> data) {
    var latest = 0;
    for (final field in const ['publishedAt', 'inventorySyncedAt']) {
      final value = data[field];
      if (value is Timestamp && value.millisecondsSinceEpoch > latest) {
        latest = value.millisecondsSinceEpoch;
      }
    }
    return latest;
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

  /// [migrateLegacyMapToInitialVersion], with a failure handed to [onError]
  /// instead of escaping. The map builder starts it unawaited, so a failure
  /// (a failed unit read now fails the publish rather than publishing no
  /// units) was an uncaught async error the owner never saw.
  ///
  /// Only a user who can publish the map ([canPublish], by default
  /// [currentUserCanPublishMap]) is told: for anyone else the migration
  /// always fails on the rules, and staff opening a map with no version yet
  /// got a red permission-denied snackbar every time.
  static Future<void> migrateLegacyMapReportingFailure(
    String facilityId,
    void Function(Object error) onError, {
    @visibleForTesting Future<void> Function(String facilityId)? migrate,
    @visibleForTesting Future<bool> Function(String facilityId)? canPublish,
  }) async {
    try {
      await (migrate ?? migrateLegacyMapToInitialVersion)(facilityId);
    } catch (e) {
      var tell = false;
      try {
        tell = await (canPublish ?? currentUserCanPublishMap)(facilityId);
      } catch (roleError) {
        debugPrint('⚠️ [FacilityMapV2] Could not check who may publish: '
            '$roleError');
      }
      if (tell) {
        onError(e);
      } else {
        debugPrint('⚠️ [FacilityMapV2] Legacy map migration failed for a '
            'user who cannot publish: $e');
      }
    }
  }

  /// Permission an owner or manager holds and staff do not; the map is
  /// published only by owners and managers (mapEngine and publicFacilityMaps
  /// rules, isFacilityOwnerOrManager).
  static const PermissionType publishMapPermission =
      PermissionType.editFacility;

  /// Whether the signed-in user may publish [facilityId]'s map.
  static Future<bool> currentUserCanPublishMap(String facilityId) async {
    final check = await PermissionService.hasPermission(
      permission: publishMapPermission,
      facilityId: facilityId,
    );
    return check.hasPermission;
  }

  /// Every non-archived unit, sorted by number, for the public map.
  ///
  /// It used its own read, `orderBy('unitNumber').limit(400)` with archived
  /// units dropped after the cap, so archived units used up the cap and units
  /// past it or with no unitNumber were never published. It also returned []
  /// on a failed read, and the publish or inventory refresh then wrote an
  /// empty unit list over the live one. A failure now throws: publish reports
  /// it, and the refresh logs it and writes nothing. Which units the public
  /// can rent is still decided per unit, by `publicListingEnabled` and
  /// `internalUse` ([buildPublicUnitInventoryMaps]).
  static Future<List<UnitModel>> _fetchActiveUnitsOrdered(
      String facilityId) async {
    try {
      return await UnitService.readFacilityUnits(facilityId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error fetching units for public map: $e');
      }
      rethrow;
    }
  }

  @visibleForTesting
  static Future<List<UnitModel>> fetchActiveUnitsForTesting(
          String facilityId) =>
      _fetchActiveUnitsOrdered(facilityId);

  /// The unit numbers active tenants hold (trimmed, lower-cased), which
  /// mark a unit taken even when its own doc was never set to occupied.
  /// Throws when they cannot all be read, so a publish cannot mistake a
  /// failed or partial read for a facility with fewer tenants.
  ///
  /// The claims syncPublicFacilityMapInventoryForFacility makes on the
  /// server, so the two writers of publicFacilityMaps/{slug}.units agree:
  /// only tenants whose `isActive` is exactly true, and a unit number read
  /// from the raw doc. This parsed every tenant into a TenantModel, which
  /// throws on a unit number stored as a number (the server reads 101 as
  /// '101') and on any odd field unrelated to the claim, and read every
  /// tenant under a cap that was reported but still published a partial
  /// list of claims.
  static Future<Set<String>> readTenantClaimedUnitNumbersOrThrow(
      String facilityId) async {
    const cap = FacilitySubcollections.readLimit;
    final snapshot =
        await FacilitySubcollections.activeTenants(facilityId).limit(cap).get();
    if (snapshot.docs.length >= cap) {
      throw StateError('Facility $facilityId has at least $cap active tenants; '
          'the public map cannot be published from a partial list of them.');
    }
    return {
      for (final doc in snapshot.docs)
        if (tenantClaimedUnitNumber(doc.data()) case final n?) n,
    };
  }

  /// The unit number a tenant doc claims, as the server's
  /// `String(td.unitNumber || '').trim().toLowerCase()` reads it, or null
  /// when it claims none.
  @visibleForTesting
  static String? tenantClaimedUnitNumber(Map<String, dynamic> tenant) {
    final raw = tenant['unitNumber'];
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is num && raw != 0 && !raw.isNaN) {
      // JavaScript's String() writes 101.0 as '101', as it does 101.
      text = raw is double &&
              raw.isFinite &&
              raw == raw.roundToDouble() &&
              raw.abs() < 1e21
          ? raw.toStringAsFixed(0)
          : raw.toString();
    } else if (raw == true) {
      text = 'true';
    } else {
      text = '';
    }
    final n = text.trim().toLowerCase();
    return n.isEmpty ? null : n;
  }

  /// Builds the anonymous-safe `units` payload for [publicFacilityMaps] documents.
  static List<Map<String, dynamic>> buildPublicUnitInventoryMaps({
    required List<UnitModel> units,
    required FacilityPublicSettings? publicSettings,
    Set<String> tenantClaimedUnitNumbers = const <String>{},
  }) {
    final showPublicPricing = publicSettings?.publicPricingEnabled ?? true;
    final showUnitNumbers = publicSettings?.publicUnitNumbersEnabled ?? true;
    final enabledPublicUnitTypes =
        (publicSettings?.enabledPublicUnitTypes ?? const <String>[])
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

    return units.map((unit) {
      final dims = unit.dimensions ?? const <String, dynamic>{};
      // Was `as num?`, which threw on a width typed in as '10' and failed the
      // publish for every unit; the sync reads these with Number().
      final width = numberFromField(dims['width']);
      final depth = numberFromField(dims['depth']);
      String? size;
      if (width != null && depth != null) {
        size = '${width.toStringAsFixed(0)}x${depth.toStringAsFixed(0)}';
      }

      final unitType = unit.unitType;
      final categorySlug = _slugify(unitType);
      final isPubliclyEnabledType = enabledPublicUnitTypes.isEmpty ||
          enabledPublicUnitTypes.contains(unitType);

      final unitNumNorm = unit.unitNumber.trim().toLowerCase();
      final hasTenantLink =
          unit.tenantId != null && unit.tenantId!.trim().isNotEmpty;
      final claimedByActiveTenant =
          tenantClaimedUnitNumbers.contains(unitNumNorm);
      // The online rental holds (createPublicReservationHold,
      // createTenantPortalAdditionalUnitHold) and createPublicMoveInCheckout
      // accept a unit whose stored status lower-cases to 'available' or
      // 'reserved'. This used unit.status, which reads a unit with no status
      // as available, so the list offered units the hold then refused (and
      // misread 'Occupied' as available). Keep in step with
      // syncPublicFacilityMapInventoryForFacility.
      final storedStatus = unit.storedStatus ?? unit.status.name;
      final st = storedStatus.toLowerCase();
      final statusAllowsRental = st == 'available' || st == 'reserved';
      // The online rental callables rent only what isUnitOfferedOnline
      // (functions-shared) allows: listed and not internal use. This looked at
      // the listing switch alone, so an office or residence left listed was
      // advertised as rentable and then refused at the hold. Archived units
      // never get here (UnitService.readFacilityUnits drops them). Keep in step
      // with syncPublicFacilityMapInventoryForFacility.
      final offeredOnline = unit.publicListingEnabled && !unit.internalUse;
      final isRentable = statusAllowsRental &&
          !hasTenantLink &&
          !claimedByActiveTenant &&
          isPubliclyEnabledType &&
          offeredOnline;

      final publicStatus = !offeredOnline
          ? 'unavailable'
          : (hasTenantLink || claimedByActiveTenant)
              ? 'rented'
              : statusToPublicStatus(st);

      return <String, dynamic>{
        'unitId': unit.id,
        'unitNumber': showUnitNumbers ? unit.unitNumber : null,
        'unitLabel': showUnitNumbers ? unit.unitNumber : null,
        'displayName':
            showUnitNumbers ? 'Unit ${unit.unitNumber}' : 'Available Unit',
        'status': publicStatus,
        'internalStatus': storedStatus.isEmpty ? null : storedStatus,
        'unitType': unitType,
        'categorySlug': categorySlug,
        'size': size,
        'description': unit.description,
        'monthlyRate': showPublicPricing ? unit.monthlyRate : null,
        'isRentable': isRentable,
        'publicListingEnabled': unit.publicListingEnabled,
      };
    }).toList();
  }

  /// Byte budget for the published unit list, the server's
  /// MAX_PUBLISHED_UNITS_BYTES (publicFacilityMapInventorySync.ts). The list
  /// lives in one document, capped at 1 MiB with other fields beside it, and
  /// a write that overshoots fails outright.
  static const int maxPublishedUnitsBytes = 700000;

  /// Trims a sorted unit list from the end until it fits in one document
  /// ([maxBytes] of JSON), and says how many went. A port of the server's
  /// fitUnitsToDocument: the app's publish and refresh had no guard, so a
  /// facility too big for one document (one imported on the server, say)
  /// could not publish at all, and the refresh failed and left the map as
  /// it was.
  static ({List<Map<String, dynamic>> published, int omitted})
      fitUnitsToDocument(
    List<Map<String, dynamic>> units, {
    int maxBytes = maxPublishedUnitsBytes,
  }) {
    int bytes(List<Map<String, dynamic>> list) =>
        utf8.encode(jsonEncode(list)).length;
    if (bytes(units) <= maxBytes) return (published: units, omitted: 0);

    var published = units;
    // A tenth at a time converges in a few steps and, since the floor of
    // 0.9 * n is below n for any n > 1, cannot stall.
    while (published.length > 1 && bytes(published) > maxBytes) {
      published = published.sublist(0, (published.length * 0.9).floor());
    }
    return (published: published, omitted: units.length - published.length);
  }

  /// The unit fields of a [publicFacilityMaps] document, as the server's
  /// inventory sync writes them: the list ([buildPublicUnitInventoryMaps])
  /// trimmed to fit ([fitUnitsToDocument]), how many units there were, and
  /// how many were left out. Both the publish and the refresh write these,
  /// so neither leaves the other's counts behind.
  static ({List<Map<String, dynamic>> units, int unitsTotal, int unitsOmitted})
      publicUnitInventory({
    required String facilityId,
    required List<UnitModel> units,
    required FacilityPublicSettings? publicSettings,
    Set<String> tenantClaimedUnitNumbers = const <String>{},
    int maxBytes = maxPublishedUnitsBytes,
  }) {
    final all = buildPublicUnitInventoryMaps(
      units: units,
      publicSettings: publicSettings,
      tenantClaimedUnitNumbers: tenantClaimedUnitNumbers,
    );
    final fitted = fitUnitsToDocument(all, maxBytes: maxBytes);
    if (fitted.omitted > 0) {
      final message = 'Public map for facility $facilityId: ${all.length} '
          'units do not fit in one document; published the first '
          '${fitted.published.length}, left out ${fitted.omitted}.';
      debugPrint('⚠️ [FacilityMapV2] $message');
      // Reaches Sentry through main.dart's FlutterError.onError.
      FlutterError.reportError(FlutterErrorDetails(
        exception: StateError(message),
        stack: StackTrace.current,
        library: 'facility_map_v2_service',
      ));
    }
    return (
      units: fitted.published,
      unitsTotal: all.length,
      unitsOmitted: fitted.omitted,
    );
  }

  /// Updates [publicFacilityMaps] inventory from live units (no full republish).
  static Future<void> refreshPublicMapInventoryFromLiveUnits(
      String facilityId) async {
    try {
      final meta = await getMeta(facilityId);
      if (meta == null || meta.publicSlug.trim().isEmpty) {
        return;
      }

      final publicRef =
          _collection(_publicMapsCollection).doc(meta.publicSlug);
      final publicSnap = await publicRef.get();
      // Only this facility's published map: a pointer left at an old slug
      // carries no units, by design.
      final publicData = publicSnap.data();
      if (publicData == null ||
          publicData['facilityId'] != facilityId ||
          movedToSlugOf(publicData) != null) {
        return;
      }

      // Throws, and the catch below skips the refresh, rather than list the
      // unit types and unit numbers the owner hid (default settings show all).
      final publicSettings =
          await FacilityPublicService.getPublicSettingsOrThrow(facilityId);
      final units = await _fetchActiveUnitsOrdered(facilityId);
      // Throws and skips the refresh too, rather than list a unit taken only
      // through an active tenant's unit number as rentable.
      final claimedUnits =
          await readTenantClaimedUnitNumbersOrThrow(facilityId);
      final inventory = publicUnitInventory(
        facilityId: facilityId,
        units: units,
        publicSettings: publicSettings,
        tenantClaimedUnitNumbers: claimedUnits,
      );

      await publicRef.update({
        'units': inventory.units,
        'unitsTotal': inventory.unitsTotal,
        'unitsOmitted': inventory.unitsOmitted,
        'inventorySyncedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [FacilityMapV2] refreshPublicMapInventory failed: $e');
      }
    }
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
    required List<Map<String, dynamic>> publicUnits,
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
    final chargeNextMonthAfterMidMonthMoveIn =
        publicSettingsModel?.chargeNextMonthAfterMidMonthMoveIn ?? false;
    final chargeInsuranceAtMoveIn =
        publicSettingsModel?.chargeInsuranceAtMoveIn ?? false;
    final publicInsuranceAmount = publicSettingsModel?.publicInsuranceAmount;
    final chargeSecurityDepositAtMoveIn =
        publicSettingsModel?.chargeSecurityDepositAtMoveIn ?? false;
    final publicSecurityDepositAmount =
        publicSettingsModel?.publicSecurityDepositAmount;
    final enabledPublicUnitTypes =
        (publicSettingsModel?.enabledPublicUnitTypes ?? const <String>[])
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

    final visibleElements = elements.where((e) => e.visiblePublic).toList();

    final publicDescription =
        publicSettingsModel?.marketingContent?.trim().isNotEmpty == true
            ? publicSettingsModel!.marketingContent!.trim()
            : (publicSettingsModel?.pageDescription?.trim().isNotEmpty == true
                ? publicSettingsModel!.pageDescription!.trim()
                : facilityDescription);
    final publicLogoUrl =
        publicSettingsModel?.publicLogoUrl?.trim().isNotEmpty == true
            ? publicSettingsModel!.publicLogoUrl!.trim()
            : facilityLogoUrl;
    final unitTypeImageUrls =
        publicSettingsModel?.unitTypeImageUrls ?? const <String, String>{};
    final websiteConfigRaw = publicSettingsModel?.widgets?['websiteConfig'];
    final websiteConfig = websiteConfigRaw is Map
        ? websiteConfigRaw.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};

    return PublicFacilityMapSnapshot(
      facilityId: facilityId,
      facilitySlug: slug,
      publishedVersionId: publishedVersionId,
      publishedAt: DateTime.now(),
      publicSettings: <String, dynamic>{
        'enabled': publicSettingsModel?.enabled ?? false,
        'facilityName': facilityName,
        'facilityDescription': publicDescription,
        'facilityPhone': facilityPhone,
        'facilityLogoUrl': publicLogoUrl,
        'customDomain': publicSettingsModel?.customDomain,
        'pageTitle': publicSettingsModel?.pageTitle,
        'pageDescription': publicSettingsModel?.pageDescription,
        'marketingContent': publicSettingsModel?.marketingContent,
        'unitTypeImageUrls': unitTypeImageUrls,
        'showPublicPricing': showPublicPricing,
        'allowReservation': allowReservation,
        'publicRentalsEnabled': allowReservation,
        'publicUnitNumbersEnabled': showUnitNumbers,
        'allowAutoAssign': allowAutoAssign,
        'allowUnitSelection': allowUnitSelection,
        'showAvailabilityCount': showAvailabilityCount,
        'hideUnavailableTypes': hideUnavailableTypes,
        'enabledPublicUnitTypes': enabledPublicUnitTypes,
        'chargeNextMonthAfterMidMonthMoveIn':
            chargeNextMonthAfterMidMonthMoveIn,
        'chargeInsuranceAtMoveIn': chargeInsuranceAtMoveIn,
        'publicInsuranceAmount': publicInsuranceAmount,
        'chargeSecurityDepositAtMoveIn': chargeSecurityDepositAtMoveIn,
        'publicSecurityDepositAmount': publicSecurityDepositAmount,
        'mapSettings': mapSettings,
        'customStyles': publicSettingsModel?.customStyles ??
            const <String, dynamic>{},
        'featuredImages': publicSettingsModel?.featuredImages ??
            const <String>[],
        'websiteConfig': websiteConfig,
      },
      elements: visibleElements,
      units: publicUnits,
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
