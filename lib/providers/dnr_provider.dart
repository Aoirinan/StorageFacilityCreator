import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/dnr_model.dart';
import '../services/dnr_service.dart';

// DNR entries for facility provider (real-time stream)
final dnrEntriesForFacilityProvider = StreamProvider.family<List<DNRModel>, String>((ref, facilityId) {
  return DNRService.getDNREntriesForFacilityStream(facilityId: facilityId);
});

// Global DNR entries provider (with optional active filter)
final globalDnrEntriesProvider = FutureProvider.family<List<DNRModel>, bool?>((ref, activeOnly) async {
  return await DNRService.getGlobalDNREntries(activeOnly: activeOnly);
});

// Local DNR entries provider
final localDnrEntriesProvider = FutureProvider.family<List<DNRModel>, String>((ref, facilityId) async {
  return await DNRService.getLocalDNREntries(facilityId);
});

// DNR search provider
final dnrSearchProvider = FutureProvider.family<List<DNRModel>, Map<String, dynamic>>((ref, params) async {
  final facilityId = params['facilityId'] as String?;
  final query = params['query'] as String?;
  final active = params['active'] as bool?;
  
  if (facilityId != null && facilityId.isNotEmpty) {
    return await DNRService.searchDNREntries(
      facilityId: facilityId,
      query: query,
      active: active,
    );
  } else {
    // For global search, get all DNR entries and filter client-side
    final allEntries = await DNRService.getAllDNREntries();
    
    // Apply client-side filtering
    var filteredEntries = allEntries;
    
    if (active != null) {
      filteredEntries = filteredEntries.where((entry) => entry.active == active).toList();
    }
    
    if (query != null && query.isNotEmpty) {
      final searchTerm = query.toLowerCase();
      filteredEntries = filteredEntries.where((entry) => 
        entry.nameLower.contains(searchTerm) ||
        entry.emailLower.contains(searchTerm) ||
        entry.phoneDigits.contains(searchTerm.replaceAll(RegExp(r'[^\d]'), ''))
      ).toList();
    }
    
    return filteredEntries;
  }
});

// DNR screening provider
final dnrScreeningProvider = FutureProvider.family<List<DNRModel>, Map<String, dynamic>>((ref, params) async {
  final facilityId = params['facilityId'] as String;
  final name = params['name'] as String? ?? '';
  final email = params['email'] as String? ?? '';
  final phone = params['phone'] as String? ?? '';
  
  return await DNRService.checkDNRScreening(
    facilityId: facilityId,
    name: name,
    email: email,
    phone: phone,
  );
});

// DNR operations provider
final dnrOperationsProvider = StateNotifierProvider<DNROperationsNotifier, AsyncValue<void>>((ref) {
  return DNROperationsNotifier();
});

class DNROperationsNotifier extends StateNotifier<AsyncValue<void>> {
  DNROperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createDNREntry({
    required String facilityId,
    required String name,
    required String email,
    required String phone,
    required String reason,
    bool active = true,
    DateTime? expiresAt,
    List<String>? evidenceUrls,
        required String facilityName,
        required String ownerEmail,
        required String facilityPhone,
        required String addedByEmail,
        required String addedByName,
    String? linkedTenantId,
    String? linkedTenantName,
  }) async {
    state = const AsyncValue.loading();
    try {
      await DNRService.createDNREntry(
        facilityId: facilityId,
        name: name,
        email: email,
        phone: phone,
        reason: reason,
        active: active,
        expiresAt: expiresAt,
        evidenceUrls: evidenceUrls,
        facilityName: facilityName,
        ownerEmail: ownerEmail,
        facilityPhone: facilityPhone,
        addedByEmail: addedByEmail,
        addedByName: addedByName,
        linkedTenantId: linkedTenantId,
        linkedTenantName: linkedTenantName,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> updateDNREntry({
    required String facilityId,
    required String dnrId,
    String? name,
    String? email,
    String? phone,
    String? reason,
    bool? active,
    DateTime? expiresAt,
    List<String>? evidenceUrls,
    String? linkedTenantId,
    String? linkedTenantName,
    String? previousLinkedTenantId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await DNRService.updateDNREntry(
        facilityId: facilityId,
        dnrId: dnrId,
        name: name,
        email: email,
        phone: phone,
        reason: reason,
        active: active,
        expiresAt: expiresAt,
        evidenceUrls: evidenceUrls,
        linkedTenantId: linkedTenantId,
        linkedTenantName: linkedTenantName,
        previousLinkedTenantId: previousLinkedTenantId,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> deleteDNREntry(String facilityId, String dnrId) async {
    state = const AsyncValue.loading();
    try {
      await DNRService.deleteDNREntry(facilityId: facilityId, dnrId: dnrId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}