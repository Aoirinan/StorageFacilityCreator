import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/contract_model.dart';
import '../models/contract_template_model.dart';
import '../services/contract_service.dart';
import '../models/provider_params.dart';

// Contract Providers (real-time stream)
final contractsProvider = StreamProvider.family<List<ContractModel>, String>((ref, facilityId) {
  return ContractService.getContractsForFacilityStream(facilityId);
});

final tenantContractsProvider = FutureProvider.family<List<ContractModel>, FacilityTenantParams>((ref, params) async {
  if (!params.isValid) return const <ContractModel>[];
  return ContractService.getContractsForTenant(params.facilityId, params.tenantId);
});

final contractProvider = FutureProvider.family<ContractModel?, Map<String, String>>((ref, params) async {
  return ContractService.getContract(params['facilityId']!, params['contractId']!);
});

// Contract Template Providers (Phase 2: Facility-scoped)
final contractTemplatesProvider = FutureProvider.family<List<ContractTemplateModel>, String>((ref, facilityId) async {
  return ContractService.getContractTemplates(facilityId);
});

final contractTemplateProvider = FutureProvider.family<ContractTemplateModel?, Map<String, String>>((ref, params) async {
  return ContractService.getContractTemplate(
    facilityId: params['facilityId']!,
    templateId: params['templateId']!,
  );
});

// Contract Operations Provider
final contractOperationsProvider = StateNotifierProvider<ContractOperationsNotifier, AsyncValue<void>>((ref) {
  return ContractOperationsNotifier();
});

class ContractOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  ContractOperationsNotifier() : super(const AsyncValue.data(null));

  Future<String> createContract({
    required String facilityId,
    required String tenantId,
    required String title,
    required String description,
    required ContractType type,
    String? templateId,
    String? fileUrl,
    DateTime? expiresAt,
    Map<String, dynamic>? customFields,
    String? notes,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      final contractId = await ContractService.createContract(
        facilityId: facilityId,
        tenantId: tenantId,
        title: title,
        description: description,
        type: type,
        templateId: templateId,
        fileUrl: fileUrl,
        expiresAt: expiresAt,
        customFields: customFields,
        notes: notes,
      );
      
      state = const AsyncValue.data(null);
      return contractId;
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  Future<void> updateContract({
    required String facilityId,
    required String contractId,
    String? title,
    String? description,
    ContractType? type,
    ContractStatus? status,
    String? fileUrl,
    String? signedFileUrl,
    DateTime? sentAt,
    DateTime? signedAt,
    DateTime? expiresAt,
    String? sentBy,
    String? signedBy,
    Map<String, dynamic>? customFields,
    String? notes,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await ContractService.updateContract(
        facilityId: facilityId,
        contractId: contractId,
        title: title,
        description: description,
        type: type,
        status: status,
        fileUrl: fileUrl,
        signedFileUrl: signedFileUrl,
        sentAt: sentAt,
        signedAt: signedAt,
        expiresAt: expiresAt,
        sentBy: sentBy,
        signedBy: signedBy,
        customFields: customFields,
        notes: notes,
      );
      
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> deleteContract(String facilityId, String contractId) async {
    state = const AsyncValue.loading();
    
    try {
      await ContractService.deleteContract(facilityId, contractId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> sendContract({
    required String facilityId,
    required String contractId,
    required String sentBy,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await ContractService.sendContract(
        facilityId: facilityId,
        contractId: contractId,
        sentBy: sentBy,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> signContract({
    required String facilityId,
    required String contractId,
    required String signedBy,
    required String signedFileUrl,
    String? signingToken,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await ContractService.signContract(
        facilityId: facilityId,
        contractId: contractId,
        signedBy: signedBy,
        signedFileUrl: signedFileUrl,
        signingToken: signingToken,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }


  // Reset the state to initial
  void resetState() {
    state = const AsyncValue.data(null);
  }
}

// Contract Template Operations Provider
final contractTemplateOperationsProvider = StateNotifierProvider<ContractTemplateOperationsNotifier, AsyncValue<void>>((ref) {
  return ContractTemplateOperationsNotifier();
});

class ContractTemplateOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  ContractTemplateOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createContractTemplate({
    required String facilityId,
    required String name,
    required String description,
    required String content,
    required ContractType type,
    List<TemplateSigner>? signers,
    List<SignaturePlaceholder>? signaturePlaceholders,
    List<String>? requiredFields,
    Map<String, dynamic>? defaultValues,
  }) async {
    state = const AsyncValue.loading();
    
    try {
      await ContractService.createContractTemplate(
        facilityId: facilityId,
        name: name,
        description: description,
        content: content,
        type: type,
        signers: signers,
        signaturePlaceholders: signaturePlaceholders,
        requiredFields: requiredFields,
        defaultValues: defaultValues,
      );
      
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}

// Contract Filter Provider
final contractFilterProvider = StateNotifierProvider<ContractFilterNotifier, ContractFilter>((ref) {
  return ContractFilterNotifier();
});

class ContractFilter {
  final ContractStatus? status;
  final ContractType? type;
  final String searchQuery;
  final DateTime? dateFrom;
  final DateTime? dateTo;

  ContractFilter({
    this.status,
    this.type,
    this.searchQuery = '',
    this.dateFrom,
    this.dateTo,
  });

  ContractFilter copyWith({
    ContractStatus? status,
    ContractType? type,
    String? searchQuery,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) {
    return ContractFilter(
      status: status ?? this.status,
      type: type ?? this.type,
      searchQuery: searchQuery ?? this.searchQuery,
      dateFrom: dateFrom ?? this.dateFrom,
      dateTo: dateTo ?? this.dateTo,
    );
  }
}

class ContractFilterNotifier extends StateNotifier<ContractFilter> {
  ContractFilterNotifier() : super(ContractFilter());

  void updateStatus(ContractStatus? status) {
    state = state.copyWith(status: status);
  }

  void updateType(ContractType? type) {
    state = state.copyWith(type: type);
  }

  void updateSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  void updateDateRange(DateTime? from, DateTime? to) {
    state = state.copyWith(dateFrom: from, dateTo: to);
  }

  void clearFilters() {
    state = ContractFilter();
  }
}
