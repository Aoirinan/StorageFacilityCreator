import 'package:cloud_firestore/cloud_firestore.dart';

/// SMS template model for managing SMS templates
class SMSTemplateModel {
  final String id;
  final String? facilityId; // null for global/system templates
  final String name;
  final String category; // payment, reminder, welcome, receipt, etc.
  final String message;
  final List<String> variables; // Available variables like {tenantName}, {amount}, etc.
  final String? language; // Language code (e.g., "en", "es", "fr") - null means default/English
  final bool isDefault; // Default template for this category
  final bool isActive;
  final String? description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;

  const SMSTemplateModel({
    required this.id,
    this.facilityId,
    required this.name,
    required this.category,
    required this.message,
    this.variables = const [],
    this.language,
    this.isDefault = false,
    this.isActive = true,
    this.description,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
  });

  factory SMSTemplateModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('SMSTemplate data is null');
    }

    return SMSTemplateModel(
      id: doc.id,
      facilityId: data['facilityId'],
      name: data['name'] ?? '',
      category: data['category'] ?? 'general',
      message: data['message'] ?? '',
      variables: (data['variables'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      language: data['language'] as String?,
      isDefault: data['isDefault'] ?? false,
      isActive: data['isActive'] ?? true,
      description: data['description'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] ?? '',
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'name': name,
      'category': category,
      'message': message,
      'variables': variables,
      'language': language,
      'isDefault': isDefault,
      'isActive': isActive,
      'description': description,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'createdBy': createdBy,
    };
  }

  SMSTemplateModel copyWith({
    String? id,
    String? facilityId,
    String? name,
    String? category,
    String? message,
    List<String>? variables,
    String? language,
    bool? isDefault,
    bool? isActive,
    String? description,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
  }) {
    return SMSTemplateModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      name: name ?? this.name,
      category: category ?? this.category,
      message: message ?? this.message,
      variables: variables ?? this.variables,
      language: language ?? this.language,
      isDefault: isDefault ?? this.isDefault,
      isActive: isActive ?? this.isActive,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }

  /// Replace template variables with actual values
  String replaceVariables(Map<String, String> values) {
    String result = message;
    for (final entry in values.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }

  /// Get message with variables replaced
  String getMessage(Map<String, String> values) {
    return replaceVariables(values);
  }

  /// Get character count (important for SMS)
  int get characterCount => message.length;

  /// Check if message would require multiple SMS (over 160 chars)
  bool get requiresMultipleSMS => characterCount > 160;
}

/// Available SMS template variables (same as email)
class SMSTemplateVariables {
  static const String tenantName = 'tenantName';
  static const String facilityName = 'facilityName';
  static const String amount = 'amount';
  static const String dueDate = 'dueDate';
  static const String unitNumber = 'unitNumber';
  static const String balance = 'balance';
  static const String gateCode = 'gateCode';
  static const String paymentDate = 'paymentDate';
  static const String receiptNumber = 'receiptNumber';

  static List<String> getAll() {
    return [
      tenantName,
      facilityName,
      amount,
      dueDate,
      unitNumber,
      balance,
      gateCode,
      paymentDate,
      receiptNumber,
    ];
  }

  static String getDisplayName(String variable) {
    const names = {
      tenantName: 'Tenant Name',
      facilityName: 'Facility Name',
      amount: 'Amount',
      dueDate: 'Due Date',
      unitNumber: 'Unit Number',
      balance: 'Balance',
      gateCode: 'Gate Code',
      paymentDate: 'Payment Date',
      receiptNumber: 'Receipt Number',
    };
    return names[variable] ?? variable;
  }
}

