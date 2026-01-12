import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/tenant_model.dart';
import '../models/contract_model.dart';
import '../models/payment_model.dart';
import '../models/provider_params.dart';
import '../services/tenant_service.dart';
import '../services/contract_service.dart';
import '../services/payment_service.dart';

// Provider for all tenants across all facilities
final allTenantsProvider = FutureProvider<List<TenantModel>>((ref) async {
  return await TenantService.getAllTenants();
});

// Provider for tenant search
final tenantSearchProvider = StateProvider<String>((ref) => '');

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
  final tenantsAsync = ref.watch(facilityTenantsProvider(facilityId));

  return tenantsAsync.when(
    data: (tenants) {
      if (searchQuery.isEmpty) {
        return Stream.value(tenants);
      }
      
      final normalizedQuery = searchQuery.toLowerCase().trim();
      final filtered = tenants.where((tenant) {
        return tenant.name.toLowerCase().contains(normalizedQuery) ||
               tenant.email.toLowerCase().contains(normalizedQuery) ||
               tenant.phone.contains(normalizedQuery) ||
               tenant.unitNumber.toLowerCase().contains(normalizedQuery);
      }).toList();
      
      return Stream.value(filtered);
    },
    loading: () => Stream.value([]),
    error: (error, stack) => Stream.value([]),
  );
});

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
