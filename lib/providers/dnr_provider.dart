import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/dnr_model.dart';
import '../models/global_dnr_model.dart';
import '../services/dnr_service.dart';
import '../services/global_dnr_service.dart';

// ----- Global DNR (global_dnr_entries) - platform-wide across all SFC operators -----

/// Global DNR list from the dedicated global collection (fixes permission-denied).
/// Use this when "All Facilities" is selected in the DNR screen.
final globalDnrEntriesFromGlobalCollectionProvider = StreamProvider.family<List<GlobalDNREntryModel>, GlobalDnrStatus?>((ref, status) {
  return GlobalDNRService.getGlobalDNREntriesStream(status: status, limit: 200);
});

/// Single global DNR entry by id.
final globalDnrEntryDetailProvider = FutureProvider.family<GlobalDNREntryModel?, String>((ref, entryId) async {
  return GlobalDNRService.getGlobalDNREntry(entryId);
});

/// Evidence list for a global DNR entry.
final globalDnrEvidenceProvider = StreamProvider.family<List<GlobalDNREvidenceModel>, String>((ref, entryId) {
  return GlobalDNRService.getEvidenceStream(entryId);
});

/// Search global DNR entries (client-side filter).
final globalDnrSearchProvider = FutureProvider.family<List<GlobalDNREntryModel>, Map<String, dynamic>>((ref, params) async {
  final query = params['query'] as String? ?? '';
  final statusStr = params['status'] as String?;
  GlobalDnrStatus? status;
  if (statusStr == 'active') status = GlobalDnrStatus.active;
  if (statusStr == 'inactive') status = GlobalDnrStatus.inactive;
  if (statusStr == 'appealed') status = GlobalDnrStatus.appealed;
  if (query.trim().isEmpty) {
    return GlobalDNRService.getGlobalDNREntries(limit: 200, status: status);
  }
  return GlobalDNRService.searchGlobalDNREntries(query: query, status: status, maxResults: 200);
});

// ----- Facility-scoped DNR (facilities/{id}/dnr) - unchanged -----

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