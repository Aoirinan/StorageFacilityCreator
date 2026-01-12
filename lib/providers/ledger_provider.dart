import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ledger_entry_model.dart';
import '../services/ledger_service.dart';

/// Provider for ledger entries stream (real-time)
final ledgerStreamProvider = StreamProvider.family<List<LedgerEntry>, LedgerParams>((ref, params) {
  return LedgerService.getLedgerStream(
    tenantId: params.tenantId,
    facilityId: params.facilityId,
  );
});

/// Provider for ledger entries (one-time fetch)
final ledgerEntriesProvider = FutureProvider.family<List<LedgerEntry>, LedgerParams>((ref, params) {
  return LedgerService.getLedgerEntries(
    tenantId: params.tenantId,
    facilityId: params.facilityId,
  );
});

/// Provider for ledger balance
final ledgerBalanceProvider = FutureProvider.family<double, LedgerParams>((ref, params) {
  return LedgerService.getLedgerBalance(
    tenantId: params.tenantId,
    facilityId: params.facilityId,
  );
});

/// Provider for ledger entries by date range
final ledgerEntriesByDateRangeProvider = FutureProvider.family<List<LedgerEntry>, LedgerDateRangeParams>((ref, params) {
  return LedgerService.getLedgerEntriesByDateRange(
    tenantId: params.tenantId,
    facilityId: params.facilityId,
    startDate: params.startDate,
    endDate: params.endDate,
  );
});

/// Parameters for ledger queries
class LedgerParams {
  final String tenantId;
  final String facilityId;

  const LedgerParams({
    required this.tenantId,
    required this.facilityId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LedgerParams &&
          runtimeType == other.runtimeType &&
          tenantId == other.tenantId &&
          facilityId == other.facilityId;

  @override
  int get hashCode => tenantId.hashCode ^ facilityId.hashCode;
}

/// Parameters for ledger date range queries
class LedgerDateRangeParams {
  final String tenantId;
  final String facilityId;
  final DateTime startDate;
  final DateTime endDate;

  const LedgerDateRangeParams({
    required this.tenantId,
    required this.facilityId,
    required this.startDate,
    required this.endDate,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LedgerDateRangeParams &&
          runtimeType == other.runtimeType &&
          tenantId == other.tenantId &&
          facilityId == other.facilityId &&
          startDate == other.startDate &&
          endDate == other.endDate;

  @override
  int get hashCode => tenantId.hashCode ^ facilityId.hashCode ^ startDate.hashCode ^ endDate.hashCode;
}

