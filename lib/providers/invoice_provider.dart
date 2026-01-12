import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/invoice_model.dart';
import '../services/invoice_service.dart';

/// Provider for invoices stream (by tenant)
final invoicesForTenantProvider = StreamProvider.family<List<InvoiceModel>, InvoiceParams>((ref, params) {
  return InvoiceService.getInvoicesForTenantStream(
    tenantId: params.tenantId,
    facilityId: params.facilityId,
  );
});

/// Provider for invoices stream (by facility)
final invoicesForFacilityProvider = StreamProvider.family<List<InvoiceModel>, String>((ref, facilityId) {
  return InvoiceService.getInvoicesForFacilityStream(facilityId);
});

/// Provider for overdue invoices
final overdueInvoicesProvider = FutureProvider.family<List<InvoiceModel>, String>((ref, facilityId) {
  return InvoiceService.getOverdueInvoices(facilityId);
});

/// Provider for invoice operations
final invoiceOperationsProvider = StateNotifierProvider<InvoiceOperationsNotifier, AsyncValue<void>>((ref) {
  return InvoiceOperationsNotifier();
});

class InvoiceOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  InvoiceOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> generateInvoice({
    required String tenantId,
    required String facilityId,
    List<String>? ledgerEntryIds,
    DateTime? issueDate,
    DateTime? dueDate,
    double? taxRate,
  }) async {
    state = const AsyncValue.loading();
    try {
      await InvoiceService.generateInvoiceFromLedger(
        tenantId: tenantId,
        facilityId: facilityId,
        ledgerEntryIds: ledgerEntryIds,
        issueDate: issueDate,
        dueDate: dueDate,
        taxRate: taxRate,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> generateAndUploadPDF({
    required InvoiceModel invoice,
    required String facilityId,
    required String invoiceId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await InvoiceService.generateAndUploadInvoicePDF(
        invoice: invoice,
        facilityId: facilityId,
        invoiceId: invoiceId,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> sendInvoice({
    required String facilityId,
    required String invoiceId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await InvoiceService.sendInvoice(
        facilityId: facilityId,
        invoiceId: invoiceId,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}

/// Parameters for invoice queries
class InvoiceParams {
  final String tenantId;
  final String facilityId;

  const InvoiceParams({
    required this.tenantId,
    required this.facilityId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InvoiceParams &&
          runtimeType == other.runtimeType &&
          tenantId == other.tenantId &&
          facilityId == other.facilityId;

  @override
  int get hashCode => tenantId.hashCode ^ facilityId.hashCode;
}

