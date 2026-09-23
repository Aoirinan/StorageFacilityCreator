import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../services/active_facility_service.dart';

/// Provider for the active facility ID
/// null means "All Facilities" is selected
final activeFacilityIdProvider = StateNotifierProvider<ActiveFacilityNotifier, AsyncValue<String?>>((ref) {
  return ActiveFacilityNotifier();
});

class ActiveFacilityNotifier extends StateNotifier<AsyncValue<String?>> {
  /// [load] and [save] default to [ActiveFacilityService]; tests pass fakes.
  ActiveFacilityNotifier({
    Future<String?> Function()? load,
    Future<void> Function(String? facilityId)? save,
  })  : _load = load ?? ActiveFacilityService.getActiveFacilityId,
        _save = save ?? ActiveFacilityService.setActiveFacilityId,
        super(const AsyncValue.loading()) {
    _loadActiveFacility();
  }

  final Future<String?> Function() _load;
  final Future<void> Function(String? facilityId) _save;

  Future<void> _loadActiveFacility() async {
    try {
      final facilityId = await _load();
      state = AsyncValue.data(facilityId);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  /// Set the active facility ID
  /// Pass null to select "All Facilities"
  Future<void> setActiveFacilityId(String? facilityId) async {
    // Publish the choice before the remote write. Going through loading first
    // held every facility switch on a users-doc round trip, and anything
    // watching read the loading state as "All Facilities" meanwhile (the
    // dashboard ran a full all-facilities load it then threw away).
    if (!(state is AsyncData<String?> && state.value == facilityId)) {
      state = AsyncValue.data(facilityId);
    }
    try {
      await _save(facilityId);
    } catch (e) {
      // The service updates its cache and local storage before the users
      // doc, so the choice holds on this device; only the copy that follows
      // the user to other devices failed.
      if (kDebugMode) {
        print('⚠️ [ActiveFacility] Could not save active facility remotely: $e');
      }
    }
  }

  /// Refresh the active facility from storage
  Future<void> refresh() async {
    await _loadActiveFacility();
  }
}
