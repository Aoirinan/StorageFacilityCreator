import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/tenant_model.dart';
import '../models/contract_model.dart';
import '../models/payment_model.dart';
import '../models/provider_params.dart';
import '../services/tenant_service.dart';
import '../services/contract_service.dart';
import '../services/payment_service.dart';
import '../services/facility_service.dart';
import '../providers/auth_provider.dart';

// Provider for all tenants across all facilities
final allTenantsProvider = FutureProvider<List<TenantModel>>((ref) async {
  return await TenantService.getAllTenants();
});

/// Key: 'all' = tenants from all user facilities; else comma-separated facility IDs.
final multiFacilityTenantsProvider = FutureProvider.family<List<TenantModel>, String>((ref, key) async {
  final user = ref.watch(authStateProvider).whenOrNull(data: (d) => d);
  if (user == null) return [];
  if (key == 'all' || key.isEmpty) {
    final facilities = await FacilityService.getUserFacilities();
    final all = <TenantModel>[];
    for (final f in facilities) {
      final t = await TenantService.getTenantsForFacility(f.id);
      all.addAll(t);
    }
    return all;
  }
  final ids = key.split(',').where((s) => s.isNotEmpty).toList();
  if (ids.isEmpty) return [];
  final all = <TenantModel>[];
  for (final id in ids) {
    final t = await TenantService.getTenantsForFacility(id);
    all.addAll(t);
  }
  return all;
});

// Provider for tenant search
final tenantSearchProvider = StateProvider<String>((ref) => '');

// Sort options for tenants
enum TenantSortOption {
  nameAsc,
  nameDesc,
  unitNumberAsc,
  unitNumberDesc,
  dateCreatedAsc,
  dateCreatedDesc,
  monthlyRateAsc,
  monthlyRateDesc,
  status,
}

// Provider for tenant sort option
final tenantSortProvider = StateProvider<TenantSortOption>((ref) => TenantSortOption.nameAsc);

// Provider for tenants of a specific facility (real-time stream)
final facilityTenantsProvider = StreamProvider.family<List<TenantModel>, String>((ref, facilityId) {
  if (facilityId.isEmpty) return Stream.value([]);
  return TenantService.getTenantsForFacilityStream(facilityId);
});

// Provider for active tenants of a specific facility (real-time stream)
final activeTenantsProvider = StreamProvider.family<List<TenantModel>, String>((ref, facilityId) {
  if (facilityId.isEmpty) return Stream.value([]);
  return TenantService.getActiveTenantsForFacilityStream(facilityId);
});

// Provider for filtered tenants based on search and facility (real-time stream)
final filteredTenantsProvider = StreamProvider.family<List<TenantModel>, String>((ref, facilityId) {
  final searchQuery = ref.watch(tenantSearchProvider);
  final sortOption = ref.watch(tenantSortProvider);
  final tenantsAsync = ref.watch(facilityTenantsProvider(facilityId));

  return tenantsAsync.when(
    data: (tenants) {
      // Apply search filter
      List<TenantModel> filtered = tenants;
      if (searchQuery.isNotEmpty) {
        final normalizedQuery = searchQuery.toLowerCase().trim();
        filtered = tenants.where((tenant) {
          return tenant.name.toLowerCase().contains(normalizedQuery) ||
                 tenant.email.toLowerCase().contains(normalizedQuery) ||
                 tenant.phone.contains(normalizedQuery) ||
                 tenant.unitNumber.toLowerCase().contains(normalizedQuery);
        }).toList();
      }
      
      // Apply sorting
      final sorted = List<TenantModel>.from(filtered);
      switch (sortOption) {
        case TenantSortOption.nameAsc:
          sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          break;
        case TenantSortOption.nameDesc:
          sorted.sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
          break;
        case TenantSortOption.unitNumberAsc:
          sorted.sort((a, b) {
            // Extract numeric part for natural sorting (e.g., "A101" -> 101)
            final aNum = _extractUnitNumber(a.unitNumber);
            final bNum = _extractUnitNumber(b.unitNumber);
            if (aNum != bNum) return aNum.compareTo(bNum);
            return a.unitNumber.toLowerCase().compareTo(b.unitNumber.toLowerCase());
          });
          break;
        case TenantSortOption.unitNumberDesc:
          sorted.sort((a, b) {
            final aNum = _extractUnitNumber(a.unitNumber);
            final bNum = _extractUnitNumber(b.unitNumber);
            if (aNum != bNum) return bNum.compareTo(aNum);
            return b.unitNumber.toLowerCase().compareTo(a.unitNumber.toLowerCase());
          });
          break;
        case TenantSortOption.dateCreatedAsc:
          sorted.sort((a, b) {
            final aDate = a.createdAt;
            final bDate = b.createdAt;
            if (aDate == null && bDate == null) return 0;
            if (aDate == null) return 1;
            if (bDate == null) return -1;
            return aDate.compareTo(bDate);
          });
          break;
        case TenantSortOption.dateCreatedDesc:
          sorted.sort((a, b) {
            final aDate = a.createdAt;
            final bDate = b.createdAt;
            if (aDate == null && bDate == null) return 0;
            if (aDate == null) return 1;
            if (bDate == null) return -1;
            return bDate.compareTo(aDate);
          });
          break;
        case TenantSortOption.monthlyRateAsc:
          sorted.sort((a, b) => a.monthlyRate.compareTo(b.monthlyRate));
          break;
        case TenantSortOption.monthlyRateDesc:
          sorted.sort((a, b) => b.monthlyRate.compareTo(a.monthlyRate));
          break;
        case TenantSortOption.status:
          sorted.sort((a, b) {
            // Active first, then inactive
            if (a.isActive != b.isActive) {
              return a.isActive ? -1 : 1;
            }
            // Within same status, sort by name
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
          break;
      }
      
      return Stream.value(sorted);
    },
    loading: () => Stream.value([]),
    error: (error, stack) => Stream<List<TenantModel>>.error(error, stack),
  );
});

// Helper function to extract numeric part from unit number for natural sorting
int _extractUnitNumber(String unitNumber) {
  // Extract all digits from the unit number
  final digits = unitNumber.replaceAll(RegExp(r'[^\d]'), '');
  return int.tryParse(digits) ?? 0;
}

/// Apply search and sort to a tenant list (e.g. for "All Facilities" view).
List<TenantModel> filterAndSortTenantsForDisplay(
  List<TenantModel> tenants,
  String searchQuery,
  TenantSortOption sortOption,
) {
  List<TenantModel> filtered = tenants;
  if (searchQuery.isNotEmpty) {
    final q = searchQuery.toLowerCase().trim();
    filtered = tenants.where((t) {
      return t.name.toLowerCase().contains(q) ||
          t.email.toLowerCase().contains(q) ||
          t.phone.contains(q) ||
          t.unitNumber.toLowerCase().contains(q);
    }).toList();
  }
  final sorted = List<TenantModel>.from(filtered);
  switch (sortOption) {
    case TenantSortOption.nameAsc:
      sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      break;
    case TenantSortOption.nameDesc:
      sorted.sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      break;
    case TenantSortOption.unitNumberAsc:
      sorted.sort((a, b) {
        final aNum = _extractUnitNumber(a.unitNumber);
        final bNum = _extractUnitNumber(b.unitNumber);
        if (aNum != bNum) return aNum.compareTo(bNum);
        return a.unitNumber.toLowerCase().compareTo(b.unitNumber.toLowerCase());
      });
      break;
    case TenantSortOption.unitNumberDesc:
      sorted.sort((a, b) {
        final aNum = _extractUnitNumber(a.unitNumber);
        final bNum = _extractUnitNumber(b.unitNumber);
        if (aNum != bNum) return bNum.compareTo(aNum);
        return b.unitNumber.toLowerCase().compareTo(a.unitNumber.toLowerCase());
      });
      break;
    case TenantSortOption.dateCreatedAsc:
      sorted.sort((a, b) {
        final aDate = a.createdAt;
        final bDate = b.createdAt;
        if (aDate == null && bDate == null) return 0;
        if (aDate == null) return 1;
        if (bDate == null) return -1;
        return aDate.compareTo(bDate);
      });
      break;
    case TenantSortOption.dateCreatedDesc:
      sorted.sort((a, b) {
        final aDate = a.createdAt;
        final bDate = b.createdAt;
        if (aDate == null && bDate == null) return 0;
        if (aDate == null) return 1;
        if (bDate == null) return -1;
        return bDate.compareTo(aDate);
      });
      break;
    case TenantSortOption.monthlyRateAsc:
      sorted.sort((a, b) => a.monthlyRate.compareTo(b.monthlyRate));
      break;
    case TenantSortOption.monthlyRateDesc:
      sorted.sort((a, b) => b.monthlyRate.compareTo(a.monthlyRate));
      break;
    case TenantSortOption.status:
      sorted.sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      break;
  }
  return sorted;
}

// Provider for tenant operations (create, update, delete)
final tenantOperationsProvider = StateNotifierProvider<TenantOperationsNotifier, AsyncValue<void>>((ref) {
  return TenantOperationsNotifier();
});

class TenantOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  TenantOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createTenant({
    required String facilityId,
    required String name,
    required String email,
    required String phone,
    required String unitNumber,
    required double monthlyRate,
    String? notes,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? governmentIdCountry,
    DateTime? governmentIdIssuedAt,
    DateTime? governmentIdExpiresAt,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
    bool portalEnabled = false,
    String? portalAccessCode,
    String? portalWelcomeMessage,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await TenantService.createTenant(
        facilityId: facilityId,
        name: name,
        email: email,
        phone: phone,
        unitNumber: unitNumber,
        monthlyRate: monthlyRate,
        notes: notes,
        governmentIdType: governmentIdType,
        governmentIdNumber: governmentIdNumber,
        governmentIdState: governmentIdState,
        governmentIdCountry: governmentIdCountry,
        governmentIdIssuedAt: governmentIdIssuedAt,
        governmentIdExpiresAt: governmentIdExpiresAt,
        emergencyContacts: emergencyContacts,
        vehicles: vehicles,
        portalEnabled: portalEnabled,
        portalAccessCode: portalAccessCode,
        portalWelcomeMessage: portalWelcomeMessage,
      );
      
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> updateTenant({
    required String facilityId,
    required String tenantId,
    String? name,
    String? email,
    String? phone,
    String? unitNumber,
    double? monthlyRate,
    String? notes,
    bool? isActive,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? governmentIdCountry,
    DateTime? governmentIdIssuedAt,
    DateTime? governmentIdExpiresAt,
    bool clearGovernmentIdIssuedAt = false,
    bool clearGovernmentIdExpiresAt = false,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
    bool? portalEnabled,
    String? portalAccessCode,
    bool clearPortalAccessCode = false,
    String? portalWelcomeMessage,
    DateTime? portalLastAccessAt,
    bool resetPortalStats = false,
    DateTime? smsOptInDate,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await TenantService.updateTenant(
        facilityId: facilityId,
        tenantId: tenantId,
        name: name,
        email: email,
        phone: phone,
        unitNumber: unitNumber,
        monthlyRate: monthlyRate,
        notes: notes,
        isActive: isActive,
        governmentIdType: governmentIdType,
        governmentIdNumber: governmentIdNumber,
        governmentIdState: governmentIdState,
        governmentIdCountry: governmentIdCountry,
        governmentIdIssuedAt: governmentIdIssuedAt,
        governmentIdExpiresAt: governmentIdExpiresAt,
        clearGovernmentIdIssuedAt: clearGovernmentIdIssuedAt,
        clearGovernmentIdExpiresAt: clearGovernmentIdExpiresAt,
        emergencyContacts: emergencyContacts,
        vehicles: vehicles,
        portalEnabled: portalEnabled,
        portalAccessCode: portalAccessCode,
        clearPortalAccessCode: clearPortalAccessCode,
        portalWelcomeMessage: portalWelcomeMessage,
        portalLastAccessAt: portalLastAccessAt,
        resetPortalStats: resetPortalStats,
        smsOptInDate: smsOptInDate,
      );
      
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> archiveTenant({
    required String facilityId,
    required String tenantId,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await TenantService.archiveTenant(
        facilityId: facilityId,
        tenantId: tenantId,
      );
      
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> deleteTenant({
    required String facilityId,
    required String tenantId,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await TenantService.deleteTenant(
        facilityId: facilityId,
        tenantId: tenantId,
      );
      
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> deleteTenants({
    required String facilityId,
    required List<String> tenantIds,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await TenantService.deleteTenants(
        facilityId: facilityId,
        tenantIds: tenantIds,
      );
      
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}

// Provider for tenant contracts
final tenantContractsProvider = FutureProvider.family<List<ContractModel>, FacilityTenantParams>((ref, params) async {
  if (!params.isValid) return const <ContractModel>[];
  return ContractService.getContractsForTenant(params.facilityId, params.tenantId);
});

// Provider for tenant payments
final tenantPaymentsProvider = FutureProvider.family<List<PaymentModel>, FacilityTenantParams>((ref, params) async {
  if (!params.isValid) return const <PaymentModel>[];
  return PaymentService.getPaymentsForTenant(params.facilityId, params.tenantId);
});
