import 'package:cloud_firestore/cloud_firestore.dart';

enum SaleStatus {
  pending,
  completed,
  cancelled,
  refunded,
}

enum PaymentMethod {
  cash,
  check,
  creditCard,
  ach,
}

class SaleLineItem {
  final String productId;
  final String productName;
  final double unitPrice;
  final int quantity;
  final double total;

  const SaleLineItem({
    required this.productId,
    required this.productName,
    required this.unitPrice,
    required this.quantity,
    required this.total,
  });

  Map<String, dynamic> toMap() {
    return {
      'productId': productId,
      'productName': productName,
      'unitPrice': unitPrice,
      'quantity': quantity,
      'total': total,
    };
  }

  factory SaleLineItem.fromMap(Map<String, dynamic> map) {
    return SaleLineItem(
      productId: map['productId'] ?? '',
      productName: map['productName'] ?? '',
      unitPrice: (map['unitPrice'] ?? 0.0).toDouble(),
      quantity: map['quantity'] ?? 1,
      total: (map['total'] ?? 0.0).toDouble(),
    );
  }
}

class SaleModel {
  final String id;
  final String facilityId;
  final String? tenantId; // If sold to a tenant, link to ledger
  final String saleNumber; // Auto-generated (e.g., "SALE-2025-001")
  final SaleStatus status;
  final PaymentMethod paymentMethod;
  final List<SaleLineItem> lineItems;
  final double subtotal;
  final double? tax;
  final double total;
  final DateTime saleDate;
  final String? notes;
  final String? depositId; // Link to deposit if included
  final String? ledgerEntryId; // Link to ledger entry if sold to tenant
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final bool isActive;

  const SaleModel({
    required this.id,
    required this.facilityId,
    this.tenantId,
    required this.saleNumber,
    required this.status,
    required this.paymentMethod,
    required this.lineItems,
    required this.subtotal,
    this.tax,
    required this.total,
    required this.saleDate,
    this.notes,
    this.depositId,
    this.ledgerEntryId,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
    this.isActive = true,
  });

  factory SaleModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('SaleModel data is null');
    }

    final lineItemsData = data['lineItems'] as List<dynamic>? ?? [];
    final lineItems = lineItemsData
        .map((item) => SaleLineItem.fromMap(item as Map<String, dynamic>))
        .toList();

    return SaleModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      tenantId: data['tenantId'],
      saleNumber: data['saleNumber'] ?? '',
      status: SaleStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => SaleStatus.pending,
      ),
      paymentMethod: PaymentMethod.values.firstWhere(
        (e) => e.name == data['paymentMethod'],
        orElse: () => PaymentMethod.cash,
      ),
      lineItems: lineItems,
      subtotal: (data['subtotal'] ?? 0.0).toDouble(),
      tax: data['tax'] != null ? (data['tax'] as num).toDouble() : null,
      total: (data['total'] ?? 0.0).toDouble(),
      saleDate: (data['saleDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      notes: data['notes'],
      depositId: data['depositId'],
      ledgerEntryId: data['ledgerEntryId'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
      createdBy: data['createdBy'] ?? '',
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      if (tenantId != null && tenantId!.isNotEmpty) 'tenantId': tenantId,
      'saleNumber': saleNumber,
      'status': status.name,
      'paymentMethod': paymentMethod.name,
      'lineItems': lineItems.map((item) => item.toMap()).toList(),
      'subtotal': subtotal,
      if (tax != null) 'tax': tax,
      'total': total,
      'saleDate': Timestamp.fromDate(saleDate),
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      if (depositId != null && depositId!.isNotEmpty) 'depositId': depositId,
      if (ledgerEntryId != null && ledgerEntryId!.isNotEmpty) 'ledgerEntryId': ledgerEntryId,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'createdBy': createdBy,
      'isActive': isActive,
    };
  }

  SaleModel copyWith({
    String? id,
    String? facilityId,
    String? tenantId,
    String? saleNumber,
    SaleStatus? status,
    PaymentMethod? paymentMethod,
    List<SaleLineItem>? lineItems,
    double? subtotal,
    double? tax,
    double? total,
    DateTime? saleDate,
    String? notes,
    String? depositId,
    String? ledgerEntryId,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    bool? isActive,
  }) {
    return SaleModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      saleNumber: saleNumber ?? this.saleNumber,
      status: status ?? this.status,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      lineItems: lineItems ?? this.lineItems,
      subtotal: subtotal ?? this.subtotal,
      tax: tax ?? this.tax,
      total: total ?? this.total,
      saleDate: saleDate ?? this.saleDate,
      notes: notes ?? this.notes,
      depositId: depositId ?? this.depositId,
      ledgerEntryId: ledgerEntryId ?? this.ledgerEntryId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }

  String get statusDisplayName {
    switch (status) {
      case SaleStatus.pending:
        return 'Pending';
      case SaleStatus.completed:
        return 'Completed';
      case SaleStatus.cancelled:
        return 'Cancelled';
      case SaleStatus.refunded:
        return 'Refunded';
    }
  }

  String get paymentMethodDisplayName {
    switch (paymentMethod) {
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.check:
        return 'Check';
      case PaymentMethod.creditCard:
        return 'Credit Card';
      case PaymentMethod.ach:
        return 'ACH';
    }
  }

  String get formattedTotal => '\$${total.toStringAsFixed(2)}';
  String get formattedSubtotal => '\$${subtotal.toStringAsFixed(2)}';
  String? get formattedTax => tax != null ? '\$${tax!.toStringAsFixed(2)}' : null;
}

