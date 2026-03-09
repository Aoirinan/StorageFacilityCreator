import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/overlock_model.dart';
import '../models/unit_model.dart';

/// Service for manager overlock actions. All mutations go through Cloud Functions.
class OverlockService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Set overlock status for a single unit (manager/admin only).
  static Future<SetUnitOverlockResult> setUnitOverlockStatus({
    required String facilityId,
    required String unitId,
    required bool isOverlocked,
    String? note,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('setUnitOverlockStatus');
    final result = await callable.call({
      'facilityId': facilityId,
      'unitId': unitId,
      'isOverlocked': isOverlocked,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    final data = result.data as Map<String, dynamic>? ?? {};
    return SetUnitOverlockResult(
      ok: data['ok'] == true,
      updated: data['updated'] == true,
      alreadyInState: data['alreadyInState'] == true,
      message: data['message'] as String?,
    );
  }

  /// Bulk set overlock status for multiple units.
  static Future<BulkOverlockResult> setUnitsOverlockStatusBulk({
    required String facilityId,
    required List<String> unitIds,
    required bool isOverlocked,
    String? note,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('setUnitsOverlockStatusBulk');
    final result = await callable.call({
      'facilityId': facilityId,
      'unitIds': unitIds,
      'isOverlocked': isOverlocked,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    final data = result.data as Map<String, dynamic>? ?? {};
    final errorsList = data['errors'] as List<dynamic>?;
    final errors = errorsList
        ?.map((e) => BulkOverlockError(
              unitId: (e as Map)['unitId'] as String? ?? '',
              message: (e as Map)['message'] as String? ?? '',
            ))
        .toList();
    return BulkOverlockResult(
      ok: data['ok'] == true,
      totalRequested: (data['totalRequested'] as num?)?.toInt() ?? 0,
      totalUpdated: (data['totalUpdated'] as num?)?.toInt() ?? 0,
      alreadyInStateCount: (data['alreadyInStateCount'] as num?)?.toInt() ?? 0,
      errors: errors ?? [],
    );
  }

  /// Overlock all units whose tenants have balance > 0 (delinquent).
  static Future<OverlockAllDelinquentResult> overlockAllDelinquent({
    required String facilityId,
    String? note,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('overlockAllDelinquent');
    final result = await callable.call({
      'facilityId': facilityId,
      if (note != null && note.isNotEmpty) 'note': note ?? 'Bulk overlock: all delinquent',
    });
    final data = result.data as Map<String, dynamic>? ?? {};
    return OverlockAllDelinquentResult(
      ok: data['ok'] == true,
      totalUpdated: (data['totalUpdated'] as num?)?.toInt() ?? 0,
      unitIdsProcessed: (data['unitIdsProcessed'] as num?)?.toInt() ?? 0,
      message: data['message'] as String?,
    );
  }

  /// Clear overlock for all units in facility that are currently overlocked. Requires confirmToken 'CLEAR'.
  static Future<ClearOverlockResult> clearOverlockByFilter({
    required String facilityId,
    required String confirmToken,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('clearOverlockByFilter');
    final result = await callable.call({
      'facilityId': facilityId,
      'confirmToken': confirmToken,
    });
    final data = result.data as Map<String, dynamic>? ?? {};
    return ClearOverlockResult(
      ok: data['ok'] == true,
      totalUpdated: (data['totalUpdated'] as num?)?.toInt() ?? 0,
      unitIdsProcessed: (data['unitIdsProcessed'] as num?)?.toInt() ?? 0,
      message: data['message'] as String?,
    );
  }

  /// Stream overlock events for a unit (for detail drawer history).
  static Stream<List<OverlockEventModel>> overlockEventsStream(String facilityId, String unitId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('units')
        .doc(unitId)
        .collection('overlockEvents')
        .orderBy('at', descending: true)
        .limit(20)
        .snapshots()
        .map((snap) => snap.docs.map((d) => OverlockEventModel.fromFirestore(d)).toList());
  }
}

class SetUnitOverlockResult {
  final bool ok;
  final bool updated;
  final bool alreadyInState;
  final String? message;
  SetUnitOverlockResult({required this.ok, this.updated = false, this.alreadyInState = false, this.message});
}

class BulkOverlockResult {
  final bool ok;
  final int totalRequested;
  final int totalUpdated;
  final int alreadyInStateCount;
  final List<BulkOverlockError> errors;
  BulkOverlockResult({
    required this.ok,
    required this.totalRequested,
    required this.totalUpdated,
    required this.alreadyInStateCount,
    required this.errors,
  });
}

class BulkOverlockError {
  final String unitId;
  final String message;
  BulkOverlockError({required this.unitId, required this.message});
}

class OverlockAllDelinquentResult {
  final bool ok;
  final int totalUpdated;
  final int unitIdsProcessed;
  final String? message;
  OverlockAllDelinquentResult({
    required this.ok,
    required this.totalUpdated,
    required this.unitIdsProcessed,
    this.message,
  });
}

class ClearOverlockResult {
  final bool ok;
  final int totalUpdated;
  final int unitIdsProcessed;
  final String? message;
  ClearOverlockResult({
    required this.ok,
    required this.totalUpdated,
    required this.unitIdsProcessed,
    this.message,
  });
}
