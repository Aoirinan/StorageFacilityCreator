import 'package:cloud_firestore/cloud_firestore.dart';

enum TransferStatus {
  pending,
  inProgress,
  completed,
  cancelled,
}

class TransferModel {
  final String id;
  final String facilityId;
  final String tenantId;
  final String fromUnitId;
  final String toUnitId;
  final String fromUnitNumber;
  final String toUnitNumber;
  final TransferStatus status;
  final DateTime transferDate;
  final double fromUnitProratedRent; // Refund from old unit
  final double toUnitProratedRent; // Charge for new unit
  final double fromUnitRate; // Monthly rate of old unit
  final double toUnitRate; // Monthly rate of new unit
  final double netAmount; // toUnitProratedRent - fromUnitProratedRent (positive = tenant owes, negative = refund)
  final String? notes;
  final List<String> ledgerEntryIds; // Links to ledger entries created
  final DateTime createdAt;
  final DateTime? completedAt;
  final String createdBy;
  final bool isActive;

  const TransferModel({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.fromUnitId,
    required this.toUnitId,
    required this.fromUnitNumber,
    required this.toUnitNumber,
    required this.status,
    required this.transferDate,
    required this.fromUnitProratedRent,
    required this.toUnitProratedRent,
    required this.fromUnitRate,
    required this.toUnitRate,
    required this.netAmount,
    this.notes,
    required this.ledgerEntryIds,
    required this.createdAt,
    this.completedAt,
    required this.createdBy,
    this.isActive = true,
  });

  factory TransferModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('TransferModel data is null');
    }

    return TransferModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      tenantId: data['tenantId'] ?? '',
      fromUnitId: data['fromUnitId'] ?? '',
      toUnitId: data['toUnitId'] ?? '',
      fromUnitNumber: data['fromUnitNumber'] ?? '',
      toUnitNumber: data['toUnitNumber'] ?? '',
      status: TransferStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => TransferStatus.pending,
      ),
      transferDate: (data['transferDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      fromUnitProratedRent: (data['fromUnitProratedRent'] ?? 0.0).toDouble(),
      toUnitProratedRent: (data['toUnitProratedRent'] ?? 0.0).toDouble(),
      fromUnitRate: (data['fromUnitRate'] ?? 0.0).toDouble(),
      toUnitRate: (data['toUnitRate'] ?? 0.0).toDouble(),
      netAmount: (data['netAmount'] ?? 0.0).toDouble(),
      notes: data['notes'],
      ledgerEntryIds: List<String>.from(data['ledgerEntryIds'] ?? []),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      completedAt: data['completedAt'] != null
          ? (data['completedAt'] as Timestamp).toDate()
          : null,
      createdBy: data['createdBy'] ?? '',
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'tenantId': tenantId,
      'fromUnitId': fromUnitId,
      'toUnitId': toUnitId,
      'fromUnitNumber': fromUnitNumber,
      'toUnitNumber': toUnitNumber,
      'status': status.name,
      'transferDate': Timestamp.fromDate(transferDate),
      'fromUnitProratedRent': fromUnitProratedRent,
      'toUnitProratedRent': toUnitProratedRent,
      'fromUnitRate': fromUnitRate,
      'toUnitRate': toUnitRate,
      'netAmount': netAmount,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      'ledgerEntryIds': ledgerEntryIds,
      'createdAt': Timestamp.fromDate(createdAt),
      if (completedAt != null) 'completedAt': Timestamp.fromDate(completedAt!),
      'createdBy': createdBy,
      'isActive': isActive,
    };
  }

  TransferModel copyWith({
    String? id,
    String? facilityId,
    String? tenantId,
    String? fromUnitId,
    String? toUnitId,
    String? fromUnitNumber,
    String? toUnitNumber,
    TransferStatus? status,
    DateTime? transferDate,
    double? fromUnitProratedRent,
    double? toUnitProratedRent,
    double? fromUnitRate,
    double? toUnitRate,
    double? netAmount,
    String? notes,
    List<String>? ledgerEntryIds,
    DateTime? createdAt,
    DateTime? completedAt,
    String? createdBy,
    bool? isActive,
  }) {
    return TransferModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      fromUnitId: fromUnitId ?? this.fromUnitId,
      toUnitId: toUnitId ?? this.toUnitId,
      fromUnitNumber: fromUnitNumber ?? this.fromUnitNumber,
      toUnitNumber: toUnitNumber ?? this.toUnitNumber,
      status: status ?? this.status,
      transferDate: transferDate ?? this.transferDate,
      fromUnitProratedRent: fromUnitProratedRent ?? this.fromUnitProratedRent,
      toUnitProratedRent: toUnitProratedRent ?? this.toUnitProratedRent,
      fromUnitRate: fromUnitRate ?? this.fromUnitRate,
      toUnitRate: toUnitRate ?? this.toUnitRate,
      netAmount: netAmount ?? this.netAmount,
      notes: notes ?? this.notes,
      ledgerEntryIds: ledgerEntryIds ?? this.ledgerEntryIds,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }

  String get statusDisplayName {
    switch (status) {
      case TransferStatus.pending:
        return 'Pending';
      case TransferStatus.inProgress:
        return 'In Progress';
      case TransferStatus.completed:
        return 'Completed';
      case TransferStatus.cancelled:
        return 'Cancelled';
    }
  }

  String get formattedNetAmount {
    if (netAmount >= 0) {
      return '\$${netAmount.toStringAsFixed(2)} (Tenant owes)';
    } else {
      return '\$${netAmount.abs().toStringAsFixed(2)} (Refund)';
    }
  }
}

