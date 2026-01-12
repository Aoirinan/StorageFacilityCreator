import 'package:cloud_firestore/cloud_firestore.dart';

/// Email template model for managing email templates
class EmailTemplateModel {
  final String id;
  final String? facilityId; // null for global/system templates
  final String name;
  final String category; // payment, reminder, welcome, receipt, etc.
  final String subject;
  final String htmlBody;
  final String? textBody;
  final List<String> variables; // Available variables like {tenantName}, {amount}, etc.
  final String? language; // Language code (e.g., "en", "es", "fr") - null means default/English
  final bool isDefault; // Default template for this category
  final bool isActive;
  final String? description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;

  const EmailTemplateModel({
    required this.id,
    this.facilityId,
    required this.name,
    required this.category,
    required this.subject,
    required this.htmlBody,
    this.textBody,
    this.variables = const [],
    this.language,
    this.isDefault = false,
    this.isActive = true,
    this.description,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
  });

  factory EmailTemplateModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('EmailTemplate data is null');
    }

    return EmailTemplateModel(
      id: doc.id,
      facilityId: data['facilityId'],
      name: data['name'] ?? '',
      category: data['category'] ?? 'general',
      subject: data['subject'] ?? '',
      htmlBody: data['htmlBody'] ?? '',
      textBody: data['textBody'],
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
      'subject': subject,
      'htmlBody': htmlBody,
      'textBody': textBody,
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

  EmailTemplateModel copyWith({
    String? id,
    String? facilityId,
    String? name,
    String? category,
    String? subject,
    String? htmlBody,
    String? textBody,
    List<String>? variables,
    String? language,
    bool? isDefault,
    bool? isActive,
    String? description,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
  }) {
    return EmailTemplateModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      name: name ?? this.name,
      category: category ?? this.category,
      subject: subject ?? this.subject,
      htmlBody: htmlBody ?? this.htmlBody,
      textBody: textBody ?? this.textBody,
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
  String replaceVariables(String text, Map<String, String> values) {
    String result = text;
    for (final entry in values.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }

  /// Get subject with variables replaced
  String getSubject(Map<String, String> values) {
    return replaceVariables(subject, values);
  }

  /// Get HTML body with variables replaced
  String getHtmlBody(Map<String, String> values) {
    return replaceVariables(htmlBody, values);
  }

  /// Get text body with variables replaced
  String getTextBody(Map<String, String> values) {
    return replaceVariables(textBody ?? htmlBody.replaceAll(RegExp(r'<[^>]*>'), ''), values);
  }
}

/// Available email template variables
class EmailTemplateVariables {
  static const String tenantName = 'tenantName';
  static const String facilityName = 'facilityName';
  static const String amount = 'amount';
  static const String dueDate = 'dueDate';
  static const String unitNumber = 'unitNumber';
  static const String balance = 'balance';
  static const String gateCode = 'gateCode';
  static const String paymentDate = 'paymentDate';
  static const String receiptNumber = 'receiptNumber';
  static const String contractStartDate = 'contractStartDate';
  static const String contractEndDate = 'contractEndDate';
  static const String phoneNumber = 'phoneNumber';
  static const String emailAddress = 'emailAddress';

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
      contractStartDate,
      contractEndDate,
      phoneNumber,
      emailAddress,
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
      contractStartDate: 'Contract Start Date',
      contractEndDate: 'Contract End Date',
      phoneNumber: 'Phone Number',
      emailAddress: 'Email Address',
    };
    return names[variable] ?? variable;
  }
}

