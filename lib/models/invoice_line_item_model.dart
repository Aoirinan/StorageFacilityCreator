import 'package:cloud_firestore/cloud_firestore.dart';

enum InvoiceLineItemType {
  rent,
  proratedRent,
  insurance,
  adminFee,
  moveInFee,
  securityDeposit,
  lateFee,
  otherFee,
  discount,
  credit,
  other,
}

class InvoiceLineItem {
  final String id;
  final InvoiceLineItemType type;
  final String description;
  final double amount;
  final bool isProrated;
  final DateTime? dueDate;
  final Map<String, dynamic>? metadata;

  const InvoiceLineItem({
    required this.id,
    required this.type,
    required this.description,
    required this.amount,
    this.isProrated = false,
    this.dueDate,
    this.metadata,
  });

  factory InvoiceLineItem.fromMap(Map<String, dynamic> data) {
    return InvoiceLineItem(
      id: data['id'] ?? '',
      type: InvoiceLineItemType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => InvoiceLineItemType.other,
      ),
      description: data['description'] ?? '',
      amount: (data['amount'] ?? 0.0).toDouble(),
      isProrated: data['isProrated'] ?? false,
      dueDate: data['dueDate'] != null ? (data['dueDate'] as Timestamp).toDate() : null,
      metadata: data['metadata'] != null ? Map<String, dynamic>.from(data['metadata']) : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      'description': description,
      'amount': amount,
      'isProrated': isProrated,
      if (dueDate != null) 'dueDate': Timestamp.fromDate(dueDate!),
      if (metadata != null) 'metadata': metadata,
    };
  }

  String get typeDisplayName {
    switch (type) {
      case InvoiceLineItemType.rent:
        return 'Rent';
      case InvoiceLineItemType.proratedRent:
        return 'Prorated Rent';
      case InvoiceLineItemType.insurance:
        return 'Insurance';
      case InvoiceLineItemType.adminFee:
        return 'Admin Fee';
      case InvoiceLineItemType.moveInFee:
        return 'Move-In Fee';
      case InvoiceLineItemType.securityDeposit:
        return 'Security Deposit';
      case InvoiceLineItemType.lateFee:
        return 'Late Fee';
      case InvoiceLineItemType.otherFee:
        return 'Other Fee';
      case InvoiceLineItemType.discount:
        return 'Discount';
      case InvoiceLineItemType.credit:
        return 'Credit';
      case InvoiceLineItemType.other:
        return 'Other';
    }
  }

  String get formattedAmount {
    if (amount < 0) {
      return '(\$${amount.abs().toStringAsFixed(2)})';
    }
    return '\$${amount.toStringAsFixed(2)}';
  }
}

