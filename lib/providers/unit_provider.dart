import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/unit_model.dart';
import '../services/unit_service.dart';
import '../services/ledger_service.dart';

// Unit layout provider
final unitLayoutProvider = StateNotifierProvider<UnitLayoutNotifier, UnitLayoutState>((ref) {
  return UnitLayoutNotifier();
});

// Facility units provider (real-time stream)
final facilityUnitsProvider = StreamProvider.family<List<UnitModel>, String>((ref, facilityId) {
  return UnitService.getUnitsForFacilityStream(facilityId);
});

// Unit layout state
class UnitLayoutState {
  final String viewMode;
  final String sortBy;
  final bool sortAscending;
  final String? filterStatus;
  final String? filterType;
  final double zoomLevel;

  const UnitLayoutState({
    this.viewMode = 'grid',
    this.sortBy = 'unitNumber',
    this.sortAscending = true,
    this.filterStatus,
    this.filterType,
    this.zoomLevel = 1.0,
  });

  UnitLayoutState copyWith({
    String? viewMode,
    String? sortBy,
    bool? sortAscending,
    String? filterStatus,
    String? filterType,
    double? zoomLevel,
    bool clearFilterStatus = false,
    bool clearFilterType = false,
  }) {
    return UnitLayoutState(
      viewMode: viewMode ?? this.viewMode,
      sortBy: sortBy ?? this.sortBy,
      sortAscending: sortAscending ?? this.sortAscending,
      filterStatus: clearFilterStatus ? null : (filterStatus ?? this.filterStatus),
      filterType: clearFilterType ? null : (filterType ?? this.filterType),
      zoomLevel: zoomLevel ?? this.zoomLevel,
    );
  }
}

// Unit layout notifier
class UnitLayoutNotifier extends StateNotifier<UnitLayoutState> {
  UnitLayoutNotifier() : super(const UnitLayoutState());

  void setViewMode(String mode) {
    state = state.copyWith(viewMode: mode);
  }

  void setSortBy(String sortBy) {
    state = state.copyWith(sortBy: sortBy);
  }

  void setSortAscending(bool ascending) {
    state = state.copyWith(sortAscending: ascending);
  }

  void setFilterStatus(String? status) {
    state = state.copyWith(
      filterStatus: status,
      clearFilterStatus: status == null,
    );
  }

  void setFilterType(String? type) {
    state = state.copyWith(
      filterType: type,
      clearFilterType: type == null,
    );
  }

  void clearAllFilters() {
    state = state.copyWith(
      clearFilterStatus: true,
      clearFilterType: true,
    );
  }

  void updateLayout(String layout) {
    // Update layout logic here
  }

  void updateSorting(String sortBy, bool ascending) {
    state = state.copyWith(sortBy: sortBy, sortAscending: ascending);
  }

  void setZoomLevel(double value) {
    final clamped = value.clamp(0.5, 2.5);
    state = state.copyWith(zoomLevel: clamped);
  }
}

// Units for Facility Provider
final unitsForFacilityProvider = FutureProvider.family<List<UnitModel>, String>((ref, facilityId) async {
  return await UnitService.getUnitsForFacility(facilityId);
});

// Unit Provider
final unitProvider = FutureProvider.family<UnitModel?, Map<String, String>>((ref, params) async {
  return await UnitService.getUnit(params['facilityId']!, params['unitId']!);
});

// Available Units Provider
final availableUnitsProvider = FutureProvider.family<List<UnitModel>, String>((ref, facilityId) async {
  return await UnitService.getAvailableUnits(facilityId);
});

/// Facility tenant balances (tenantId -> balance) for overlock/delinquency UI.
final facilityBalancesProvider = FutureProvider.family<Map<String, double>, String>((ref, facilityId) async {
  if (facilityId.isEmpty) return {};
  return LedgerService.getBalancesForFacility(facilityId);
});

// Unit Search and Filter Providers
final unitSearchQueryProvider = StateProvider<String>((ref) => '');
final unitStatusFilterProvider = StateProvider<String?>((ref) => null);
final unitTypeFilterProvider = StateProvider<String?>((ref) => null);
final unitMinPriceProvider = StateProvider<double?>((ref) => null);
final unitMaxPriceProvider = StateProvider<double?>((ref) => null);

// Unit Operations Provider
class UnitOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  UnitOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createUnit({
    required String facilityId,
    required String unitNumber,
    required String unitType,
    required double monthlyRate,
    String? description,
    Map<String, dynamic>? dimensions,
    List<String>? features,
    String? notes,
    double? securityDeposit,
    Map<String, dynamic>? customFields,
  }) async {
    state = const AsyncValue.loading();
    try {
      await UnitService.createUnit(
        facilityId: facilityId,
        unitNumber: unitNumber,
        unitType: unitType,
        monthlyRate: monthlyRate,
        description: description,
        dimensions: dimensions,
        features: features,
        notes: notes,
        securityDeposit: securityDeposit,
        customFields: customFields,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> updateUnit({
    required String facilityId,
    required String unitId,
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
    DateTime? reservationExpiry,
    String? reservedBy,
    Map<String, dynamic>? customFields,
  }) async {
    state = const AsyncValue.loading();
    try {
      await UnitService.updateUnit(
        facilityId: facilityId,
        unitId: unitId,
        unitNumber: unitNumber,
        unitType: unitType,
        status: status,
        tenantId: tenantId,
        tenantName: tenantName,
        monthlyRate: monthlyRate,
        securityDeposit: securityDeposit,
        description: description,
        dimensions: dimensions,
        features: features,
        notes: notes,
        lastMaintenance: lastMaintenance,
        nextMaintenance: nextMaintenance,
        moveInDate: moveInDate,
        moveOutDate: moveOutDate,
        reservationExpiry: reservationExpiry,
        reservedBy: reservedBy,
        customFields: customFields,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> deleteUnit(String facilityId, String unitId) async {
    state = const AsyncValue.loading();
    try {
      await UnitService.deleteUnit(facilityId, unitId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> assignTenantToUnit({
    required String facilityId,
    required String unitId,
    required String tenantId,
    required String tenantName,
    DateTime? moveInDate,
  }) async {
    state = const AsyncValue.loading();
    try {
      await UnitService.assignTenantToUnit(
        facilityId: facilityId,
        unitId: unitId,
        tenantId: tenantId,
        tenantName: tenantName,
        moveInDate: moveInDate,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> removeTenantFromUnit({
    required String facilityId,
    required String unitId,
    DateTime? moveOutDate,
  }) async {
    state = const AsyncValue.loading();
    try {
      await UnitService.removeTenantFromUnit(
        facilityId: facilityId,
        unitId: unitId,
        moveOutDate: moveOutDate,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> archiveUnit(String facilityId, String unitId) async {
    state = const AsyncValue.loading();
    try {
      await UnitService.archiveUnit(facilityId, unitId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}

final unitOperationsProvider = StateNotifierProvider<UnitOperationsNotifier, AsyncValue<void>>((ref) {
  return UnitOperationsNotifier();
});