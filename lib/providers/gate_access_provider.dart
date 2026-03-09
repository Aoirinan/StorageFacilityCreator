import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';

import '../models/gate_access_model.dart';
import '../services/gate_access_service.dart';

final gateAccessProvider =
    StreamProvider.family<List<GateAccessModel>, String>((ref, facilityId) {
  return GateAccessService.getGateAccessStream(facilityId);
});

final gateAccessOperationsProvider =
    StateNotifierProvider<GateAccessOperationsNotifier, AsyncValue<void>>((ref) {
  return GateAccessOperationsNotifier();
});

class GateAccessOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  GateAccessOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createGateAccess({
    required String facilityId,
    required String accessCode,
    String? tenantId,
    String? tenantName,
    bool isActive = true,
    DateTime? validFrom,
    DateTime? validUntil,
    List<String> allowedDays = const [],
    String? allowedStartTime,
    String? allowedEndTime,
    String? notes,
  }) async {
    state = const AsyncValue.loading();
    try {
      await GateAccessService.createGateAccess(
        facilityId: facilityId,
        accessCode: accessCode,
        tenantId: tenantId,
        tenantName: tenantName,
        isActive: isActive,
        validFrom: validFrom,
        validUntil: validUntil,
        allowedDays: allowedDays,
        allowedStartTime: allowedStartTime,
        allowedEndTime: allowedEndTime,
        notes: notes,
      );
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> updateGateAccess({
    required String facilityId,
    required String accessId,
    String? tenantId,
    String? tenantName,
    String? accessCode,
    bool? isActive,
    DateTime? validFrom,
    DateTime? validUntil,
    List<String>? allowedDays,
    String? allowedStartTime,
    String? allowedEndTime,
    String? notes,
  }) async {
    state = const AsyncValue.loading();
    try {
      await GateAccessService.updateGateAccess(
        facilityId: facilityId,
        accessId: accessId,
        tenantId: tenantId,
        tenantName: tenantName,
        accessCode: accessCode,
        isActive: isActive,
        validFrom: validFrom,
        validUntil: validUntil,
        allowedDays: allowedDays,
        allowedStartTime: allowedStartTime,
        allowedEndTime: allowedEndTime,
        notes: notes,
      );
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> deleteGateAccess({
    required String facilityId,
    required String accessId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await GateAccessService.deleteGateAccess(
        facilityId: facilityId,
        accessId: accessId,
      );
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}

