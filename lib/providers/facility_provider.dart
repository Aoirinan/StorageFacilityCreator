import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../services/facility_service.dart';
import '../models/facility_model.dart';

// Provider for ACTIVE facilities only (real-time stream)
final facilitiesActiveProvider = StreamProvider.family<List<FacilityModel>, String>((ref, ownerUid) {
  return FacilityService.getUserActiveFacilitiesStream();
});

// Provider for ARCHIVED facilities only (real-time stream)
final facilitiesArchivedProvider = StreamProvider.family<List<FacilityModel>, String>((ref, ownerUid) {
  return FacilityService.getUserArchivedFacilitiesStream();
});

// Legacy providers for backward compatibility
final userFacilitiesProvider = facilitiesActiveProvider;
final userFacilitiesWithArchivedProvider = facilitiesArchivedProvider;

// Provider for a specific facility
final facilityProvider = FutureProvider.family<FacilityModel?, String>((ref, facilityId) async {
  return await FacilityService.getFacility(facilityId);
});

// Provider for facility operations
final facilityOperationsProvider = StateNotifierProvider<FacilityOperationsNotifier, AsyncValue<void>>((ref) {
  return FacilityOperationsNotifier();
});

class FacilityOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  FacilityOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createFacility({
    required String name,
    String? logoUrl,
    String? address,
    String? phone,
    String? email,
  }) async {
    state = const AsyncValue.loading();
    try {
      await FacilityService.createFacility(
        name: name,
        logoUrl: logoUrl,
        address: address,
        phone: phone,
        email: email,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      // Swallowed, a caller that awaited this could not tell it failed.
      rethrow;
    }
  }

  Future<void> updateFacility({
    required String facilityId,
    String? name,
    String? logoUrl,
    String? address,
    String? phone,
    String? email,
  }) async {
    state = const AsyncValue.loading();
    try {
      await FacilityService.updateFacility(
        facilityId: facilityId,
        name: name,
        logoUrl: logoUrl,
        address: address,
        phone: phone,
        email: email,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  Future<void> softDeleteFacility(String facilityId) async {
    state = const AsyncValue.loading();
    try {
      await FacilityService.softDeleteFacility(facilityId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      // Swallowed, Facilities said "archived successfully" when it was not.
      rethrow;
    }
  }

  Future<void> hardDeleteFacility(String facilityId) async {
    state = const AsyncValue.loading();
    try {
      await FacilityService.hardDeleteFacility(facilityId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      // Swallowed, the screen said "deleted permanently" even when the
      // server refused (no email code, not the owner) or failed.
      rethrow;
    }
  }

  Future<void> restoreFacility(String facilityId) async {
    state = const AsyncValue.loading();
    try {
      await FacilityService.restoreFacility(facilityId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      // Swallowed, Facilities said "restored successfully" when it was not.
      rethrow;
    }
  }
}
