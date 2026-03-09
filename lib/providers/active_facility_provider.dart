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
  ActiveFacilityNotifier() : super(const AsyncValue.loading()) {
    _loadActiveFacility();
  }

  Future<void> _loadActiveFacility() async {
    try {
      final facilityId = await ActiveFacilityService.getActiveFacilityId();
      state = AsyncValue.data(facilityId);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  /// Set the active facility ID
  /// Pass null to select "All Facilities"
  Future<void> setActiveFacilityId(String? facilityId) async {
    state = const AsyncValue.loading();
    try {
      await ActiveFacilityService.setActiveFacilityId(facilityId);
      state = AsyncValue.data(facilityId);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  /// Refresh the active facility from storage
  Future<void> refresh() async {
    await _loadActiveFacility();
  }
}
