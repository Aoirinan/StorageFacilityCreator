import 'package:cloud_firestore/cloud_firestore.dart';
import 'invoice_line_item_model.dart';

enum InvoiceStatus {
  draft,
  sent,
  paid,
  overdue,
  voided,
}

class InvoiceModel {
  final String id;
  final String tenantId;
  final String facilityId;
  final String invoiceNumber;
  final InvoiceStatus status;
  final DateTime issueDate;
  final DateTime dueDate;
  final DateTime? paidDate;
  final double subtotal;
  final double? tax;
  final double total;
  final double balance; // Remaining unpaid amount
  final List<InvoiceLineItem> lineItems;
  final List<String> ledgerEntryIds; // Links to ledger entries
  final List<String> paymentIds; // Payments applied to this invoice
  final String? pdfUrl; // Generated PDF in Firebase Storage
  final String? notes;
  final DateTime createdAt;
  final String createdBy;
  final DateTime? sentAt;
  final bool isActive;

  const InvoiceModel({
    required this.id,
    required this.tenantId,
    required this.facilityId,
    required this.invoiceNumber,
    required this.status,
    required this.issueDate,
    required this.dueDate,
    this.paidDate,
    required this.subtotal,
    this.tax,
    required this.total,
    required this.balance,
    required this.lineItems,
    required this.ledgerEntryIds,
    required this.paymentIds,
    this.pdfUrl,
    this.notes,
    required this.createdAt,
    required this.createdBy,
    this.sentAt,
    this.isActive = true,
  });

  factory InvoiceModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('InvoiceModel data is null');
    }

    // Parse line items
    final lineItemsData = data['lineItems'] as List<dynamic>? ?? [];
    final lineItems = lineItemsData
        .map((item) => InvoiceLineItem.fromMap(item as Map<String, dynamic>))
        .toList();

    return InvoiceModel(
      id: doc.id,
      tenantId: data['tenantId'] ?? '',
      facilityId: data['facilityId'] ?? '',
      invoiceNumber: data['invoiceNumber'] ?? '',
      status: InvoiceStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => InvoiceStatus.draft,
      ),
      issueDate: (data['issueDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      dueDate: (data['dueDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      paidDate: data['paidDate'] != null
          ? (data['paidDate'] as Timestamp).toDate()
          : null,
      subtotal: (data['subtotal'] ?? 0.0).toDouble(),
      tax: data['tax'] != null ? (data['tax'] as num).toDouble() : null,
      total: (data['total'] ?? 0.0).toDouble(),
      balance: (data['balance'] ?? 0.0).toDouble(),
      lineItems: lineItems,
      ledgerEntryIds: List<String>.from(data['ledgerEntryIds'] ?? []),
      paymentIds: List<String>.from(data['paymentIds'] ?? []),
      pdfUrl: data['pdfUrl'],
      notes: data['notes'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] ?? '',
      sentAt: data['sentAt'] != null
          ? (data['sentAt'] as Timestamp).toDate()
          : null,
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'tenantId': tenantId,
      'facilityId': facilityId,
      'invoiceNumber': invoiceNumber,
      'status': status.name,
      'issueDate': Timestamp.fromDate(issueDate),
      'dueDate': Timestamp.fromDate(dueDate),
      if (paidDate != null) 'paidDate': Timestamp.fromDate(paidDate!),
      'subtotal': subtotal,
      if (tax != null) 'tax': tax,
      'total': total,
      'balance': balance,
      'lineItems': lineItems.map((item) => item.toMap()).toList(),
      'ledgerEntryIds': ledgerEntryIds,
      'paymentIds': paymentIds,
      if (pdfUrl != null && pdfUrl!.isNotEmpty) 'pdfUrl': pdfUrl,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      'createdAt': Timestamp.fromDate(createdAt),
      'createdBy': createdBy,
      if (sentAt != null) 'sentAt': Timestamp.fromDate(sentAt!),
      'isActive': isActive,
    };
  }

  InvoiceModel copyWith({
    String? id,
    String? tenantId,
    String? facilityId,
    String? invoiceNumber,
    InvoiceStatus? status,
    DateTime? issueDate,
    DateTime? dueDate,
    DateTime? paidDate,
    double? subtotal,
    double? tax,
    double? total,
    double? balance,
    List<InvoiceLineItem>? lineItems,
    List<String>? ledgerEntryIds,
    List<String>? paymentIds,
    String? pdfUrl,
    String? notes,
    DateTime? createdAt,
    String? createdBy,
    DateTime? sentAt,
    bool? isActive,
  }) {
    return InvoiceModel(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      facilityId: facilityId ?? this.facilityId,
      invoiceNumber: invoiceNumber ?? this.invoiceNumber,
      status: status ?? this.status,
      issueDate: issueDate ?? this.issueDate,
      dueDate: dueDate ?? this.dueDate,
      paidDate: paidDate ?? this.paidDate,
      subtotal: subtotal ?? this.subtotal,
      tax: tax ?? this.tax,
      total: total ?? this.total,
      balance: balance ?? this.balance,
      lineItems: lineItems ?? this.lineItems,
      ledgerEntryIds: ledgerEntryIds ?? this.ledgerEntryIds,
      paymentIds: paymentIds ?? this.paymentIds,
      pdfUrl: pdfUrl ?? this.pdfUrl,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      createdBy: createdBy ?? this.createdBy,
      sentAt: sentAt ?? this.sentAt,
      isActive: isActive ?? this.isActive,
    );
  }

  // Helper getters
  bool get isPaid => status == InvoiceStatus.paid || balance <= 0;
  bool get isOverdue =>
      status == InvoiceStatus.overdue ||
      (status == InvoiceStatus.sent &&
          DateTime.now().isAfter(dueDate) &&
          balance > 0);
  int get daysOverdue => isOverdue
      ? DateTime.now().difference(dueDate).inDays
      : 0;

  String get statusDisplayName {
    switch (status) {
      case InvoiceStatus.draft:
        return 'Draft';
      case InvoiceStatus.sent:
        return 'Sent';
      case InvoiceStatus.paid:
        return 'Paid';
      case InvoiceStatus.overdue:
        return 'Overdue';
      case InvoiceStatus.voided:
        return 'Voided';
    }
  }

  String get formattedTotal => '\$${total.toStringAsFixed(2)}';
  String get formattedBalance => '\$${balance.toStringAsFixed(2)}';
  String get formattedSubtotal => '\$${subtotal.toStringAsFixed(2)}';
  String get formattedTax => tax != null ? '\$${tax!.toStringAsFixed(2)}' : 'N/A';
}

