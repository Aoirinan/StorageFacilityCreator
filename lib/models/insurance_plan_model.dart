import 'package:cloud_firestore/cloud_firestore.dart';

class InsurancePlanModel {
  final String id;
  final String facilityId;
  final String name;
  final double monthlyPrice;
  final double coverageAmount;
  final String? description;
  final bool isDefault;
  final bool isRequired;
  final bool active;
  final DateTime createdAt;
  final DateTime updatedAt;
  
  // Policy support fields
  final String? policyType; // "sfc_generic", "facility_custom", "external"
  final String? policyDocUrl; // URL to policy PDF (if uploaded)
  final String? policyExternalUrl; // External policy link (if hosted elsewhere)
  final String? providerName; // Insurance provider name (e.g., "State Farm")
  final String? providerUrl; // Provider website/contact link

  /// SFC Disclaimer (always displayed):
  /// "Storage Facility Creator (SFC) is not an insurance provider or broker. 
  /// Facilities are solely responsible for the insurance products they offer 
  /// and any compliance, claims handling, licensing, and disclosures."
  static const String sfcDisclaimer = 
      'Storage Facility Creator (SFC) is not an insurance provider or broker. '
      'Facilities are solely responsible for the insurance products they offer '
      'and any compliance, claims handling, licensing, and disclosures.';

  InsurancePlanModel({
    required this.id,
    required this.facilityId,
    required this.name,
    required this.monthlyPrice,
    required this.coverageAmount,
    this.description,
    this.isDefault = false,
    this.isRequired = false,
    this.active = true,
    required this.createdAt,
    required this.updatedAt,
    this.policyType,
    this.policyDocUrl,
    this.policyExternalUrl,
    this.providerName,
    this.providerUrl,
  });

  factory InsurancePlanModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return InsurancePlanModel(
      id: doc.id,
      facilityId: data['facilityId'] as String,
      name: data['name'] as String,
      monthlyPrice: (data['monthlyPrice'] as num).toDouble(),
      coverageAmount: (data['coverageAmount'] as num).toDouble(),
      description: data['description'] as String?,
      isDefault: data['isDefault'] as bool? ?? false,
      isRequired: data['isRequired'] as bool? ?? false,
      active: data['active'] as bool? ?? true,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      policyType: data['policyType'] as String?,
      policyDocUrl: data['policyDocUrl'] as String?,
      policyExternalUrl: data['policyExternalUrl'] as String?,
      providerName: data['providerName'] as String?,
      providerUrl: data['providerUrl'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'name': name,
      'monthlyPrice': monthlyPrice,
      'coverageAmount': coverageAmount,
      'description': description,
      'isDefault': isDefault,
      'isRequired': isRequired,
      'active': active,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      if (policyType != null) 'policyType': policyType,
      if (policyDocUrl != null) 'policyDocUrl': policyDocUrl,
      if (policyExternalUrl != null) 'policyExternalUrl': policyExternalUrl,
      if (providerName != null) 'providerName': providerName,
      if (providerUrl != null) 'providerUrl': providerUrl,
    };
  }

  InsurancePlanModel copyWith({
    String? id,
    String? facilityId,
    String? name,
    double? monthlyPrice,
    double? coverageAmount,
    String? description,
    bool? isDefault,
    bool? isRequired,
    bool? active,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? policyType,
    String? policyDocUrl,
    String? policyExternalUrl,
    String? providerName,
    String? providerUrl,
  }) {
    return InsurancePlanModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      name: name ?? this.name,
      monthlyPrice: monthlyPrice ?? this.monthlyPrice,
      coverageAmount: coverageAmount ?? this.coverageAmount,
      description: description ?? this.description,
      isDefault: isDefault ?? this.isDefault,
      isRequired: isRequired ?? this.isRequired,
      active: active ?? this.active,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      policyType: policyType ?? this.policyType,
      policyDocUrl: policyDocUrl ?? this.policyDocUrl,
      policyExternalUrl: policyExternalUrl ?? this.policyExternalUrl,
      providerName: providerName ?? this.providerName,
      providerUrl: providerUrl ?? this.providerUrl,
    );
  }
}

