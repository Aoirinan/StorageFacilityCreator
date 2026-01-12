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
    );
  }
}

