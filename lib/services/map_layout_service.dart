import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/map_shape_model.dart';
import 'facility_limits_service.dart';

/// Service for managing facility map layouts
/// ✅ All operations are scoped by facilityId for SaaS multi-tenant isolation
class MapLayoutService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Get all map shapes for a facility
  /// ✅ Scoped by facilityId - only returns shapes for the specified facility
  static Future<List<MapShapeModel>> getMapShapes(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting map shapes for facility: $facilityId');
      }

      // ✅ CRITICAL: Always filter by facilityId for SaaS isolation
      // Get all shapes without ordering (avoids index requirement)
      // We'll sort in memory by zIndex and createdAt
      // Hard cap: 300 map shapes per facility
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('mapShapes')
          .limit(300)
          .get();

      // Sort in memory: first by zIndex, then by createdAt
      final shapes = snapshot.docs
          .map((doc) => MapShapeModel.fromFirestore(doc))
          .toList()
        ..sort((a, b) {
          final zIndexCompare = a.zIndex.compareTo(b.zIndex);
          if (zIndexCompare != 0) return zIndexCompare;
          return a.createdAt.compareTo(b.createdAt);
        });

      if (kDebugMode) {
        print('✅ Retrieved ${shapes.length} map shapes for facility: $facilityId');
      }

      return shapes;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting map shapes: $e');
      }
      rethrow;
    }
  }

  /// Get real-time stream of map shapes for a facility
  /// ✅ Scoped by facilityId
  static Stream<List<MapShapeModel>> getMapShapesStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up map shapes stream for facility: $facilityId');
      }

      // ✅ CRITICAL: Always filter by facilityId
      // Get all shapes without ordering (avoids index requirement)
      // We'll sort in memory by zIndex and createdAt
      // Limit to 2000 shapes per facility (safety limit for large maps)
      return _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('mapShapes')
          .limit(300) // Hard cap: 300 map shapes per facility
          .snapshots()
          .map((snapshot) {
        try {
          // Sort in memory: first by zIndex, then by createdAt
          final shapes = snapshot.docs
              .map((doc) {
                try {
                  return MapShapeModel.fromFirestore(doc);
                } catch (e) {
                  if (kDebugMode) {
                    print('❌ Error parsing shape ${doc.id}: $e');
                  }
                  return null;
                }
              })
              .whereType<MapShapeModel>()
              .toList()
            ..sort((a, b) {
              final zIndexCompare = a.zIndex.compareTo(b.zIndex);
              if (zIndexCompare != 0) return zIndexCompare;
              return a.createdAt.compareTo(b.createdAt);
            });

          if (kDebugMode) {
            print('📡 Stream update: ${shapes.length} shapes for facility: $facilityId');
          }

          return shapes;
        } catch (e) {
          if (kDebugMode) {
            print('❌ Error processing stream snapshot: $e');
          }
          return <MapShapeModel>[];
        }
      }).handleError((error, stackTrace) {
        if (kDebugMode) {
          print('❌ Firestore stream error: $error');
          print('Stack: $stackTrace');
        }
        // Emit empty list on stream error
      }).distinct((prev, next) {
        if (prev.length != next.length) return false;
        for (int i = 0; i < prev.length; i++) {
          final a = prev[i];
          final b = next[i];
          if (a.id != b.id ||
              a.x != b.x ||
              a.y != b.y ||
              a.width != b.width ||
              a.height != b.height ||
              a.rotation != b.rotation ||
              a.zIndex != b.zIndex ||
              a.unitId != b.unitId) {
            return false;
          }
        }
        return true;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up map shapes stream: $e');
      }
      // Return a stream that emits an empty list instead of erroring
      return Stream.value(<MapShapeModel>[]);
    }
  }

  /// Create a new map shape
  /// ✅ Automatically scoped to facilityId
  static Future<String> createMapShape({
    required String facilityId,
    String? unitId,
    String type = 'rect',
    double x = 0.0,
    double y = 0.0,
    double width = 100.0,
    double height = 100.0,
    double rotation = 0.0,
    int zIndex = 0,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      // Check facility map shape limit (hard cap: 300)
      final canAdd = await FacilityLimitsService.canAddMapShape(facilityId);
      if (!canAdd) {
        final currentCount = await FacilityLimitsService.getMapShapeCount(facilityId);
        throw Exception(
          'Map shape limit reached. This facility has reached the maximum of ${FacilityLimitsService.maxMapShapesPerFacility} map shapes. '
          'Current count: $currentCount. Please contact support if you need to increase your limit.'
        );
      }

      if (kDebugMode) {
        print('🔄 Creating map shape for facility: $facilityId');
      }

      // ✅ CRITICAL: Store under facility subcollection for SaaS isolation
      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('mapShapes')
          .doc();

      final shapeData = {
        'facilityId': facilityId, // ✅ Always include for security
        if (unitId != null) 'unitId': unitId,
        'type': type,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'rotation': rotation,
        'zIndex': zIndex,
        if (metadata != null) 'metadata': metadata,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'createdBy': user.uid,
      };

      await ref.set(shapeData);

      if (kDebugMode) {
        print('✅ Map shape created: ${ref.id}');
      }

      return ref.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating map shape: $e');
      }
      rethrow;
    }
  }

  /// Update an existing map shape
  /// ✅ Validates facilityId matches before update
  static Future<void> updateMapShape({
    required String facilityId,
    required String shapeId,
    String? unitId,
    String? type,
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    int? zIndex,
    Map<String, dynamic>? metadata,
    bool clearUnitId = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Updating map shape: $shapeId for facility: $facilityId');
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (unitId != null) updateData['unitId'] = unitId;
      if (clearUnitId) updateData['unitId'] = FieldValue.delete();
      if (type != null) updateData['type'] = type;
      if (x != null) updateData['x'] = x;
      if (y != null) updateData['y'] = y;
      if (width != null) updateData['width'] = width;
      if (height != null) updateData['height'] = height;
      if (rotation != null) updateData['rotation'] = rotation;
      if (zIndex != null) updateData['zIndex'] = zIndex;
      if (metadata != null) updateData['metadata'] = metadata;

      // ✅ CRITICAL: Update only in the correct facility's subcollection
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('mapShapes')
          .doc(shapeId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ Map shape updated: $shapeId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating map shape: $e');
      }
      rethrow;
    }
  }

  /// Delete a map shape
  /// ✅ Validates facilityId matches before delete
  static Future<void> deleteMapShape({
    required String facilityId,
    required String shapeId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Deleting map shape: $shapeId from facility: $facilityId');
      }

      // ✅ CRITICAL: Delete only from the correct facility's subcollection
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('mapShapes')
          .doc(shapeId)
          .delete();

      if (kDebugMode) {
        print('✅ Map shape deleted: $shapeId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting map shape: $e');
      }
      rethrow;
    }
  }

  /// Deletes every map shape for the facility (layout only; does not delete units).
  /// Uses batched writes (max 500 ops per batch). Respects the same 300-shape query cap as [getMapShapes].
  static Future<int> deleteAllMapShapes({required String facilityId}) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Deleting all map shapes for facility: $facilityId');
      }

      final col = _firestore.collection('facilities').doc(facilityId).collection('mapShapes');
      final snapshot = await col.limit(300).get();
      final docs = snapshot.docs;
      if (docs.isEmpty) {
        return 0;
      }

      const chunkSize = 500;
      for (var i = 0; i < docs.length; i += chunkSize) {
        final batch = _firestore.batch();
        final end = (i + chunkSize < docs.length) ? i + chunkSize : docs.length;
        for (var j = i; j < end; j++) {
          batch.delete(docs[j].reference);
        }
        await batch.commit();
      }

      if (kDebugMode) {
        print('✅ Deleted ${docs.length} map shapes');
      }
      return docs.length;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting all map shapes: $e');
      }
      rethrow;
    }
  }

  /// Batch update multiple shapes (for drag operations)
  /// ✅ All shapes must belong to the same facilityId
  static Future<void> batchUpdateShapes({
    required String facilityId,
    required List<MapShapeModel> shapes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Batch updating ${shapes.length} shapes for facility: $facilityId');
      }

      final batch = _firestore.batch();
      final shapesRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('mapShapes');

      for (final shape in shapes) {
        // ✅ Validate facilityId matches
        if (shape.facilityId != facilityId) {
          throw Exception('Shape ${shape.id} does not belong to facility $facilityId');
        }

        final shapeDoc = shapesRef.doc(shape.id);
        batch.update(shapeDoc, {
          'x': shape.x,
          'y': shape.y,
          'width': shape.width,
          'height': shape.height,
          'rotation': shape.rotation,
          'zIndex': shape.zIndex,
          if (shape.unitId != null) 'unitId': shape.unitId,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (kDebugMode) {
        print('✅ Batch updated ${shapes.length} shapes');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error batch updating shapes: $e');
      }
      rethrow;
    }
  }
}
