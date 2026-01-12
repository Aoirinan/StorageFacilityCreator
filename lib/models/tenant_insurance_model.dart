import 'package:cloud_firestore/cloud_firestore.dart';

enum InsuranceType {
  facilityPlan,
  thirdParty,
  none,
}

class TenantInsuranceModel {
  final String id;
  final String tenantId;
  final String facilityId;
  final InsuranceType type;
  final String? planId; // If using facility plan
  final String? providerName; // If using third-party
  final String? policyNumber;
  final DateTime? expirationDate;
  final String? proofUrl; // URL to uploaded policy document
  final DateTime createdAt;
  final DateTime updatedAt;

  TenantInsuranceModel({
    required this.id,
    required this.tenantId,
    required this.facilityId,
    required this.type,
    this.planId,
    this.providerName,
    this.policyNumber,
    this.expirationDate,
    this.proofUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  factory TenantInsuranceModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return TenantInsuranceModel(
      id: doc.id,
      tenantId: data['tenantId'] as String,
      facilityId: data['facilityId'] as String,
      type: InsuranceType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => InsuranceType.none,
      ),
      planId: data['planId'] as String?,
      providerName: data['providerName'] as String?,
      policyNumber: data['policyNumber'] as String?,
      expirationDate: data['expirationDate'] != null
          ? (data['expirationDate'] as Timestamp).toDate()
          : null,
      proofUrl: data['proofUrl'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'tenantId': tenantId,
      'facilityId': facilityId,
      'type': type.name,
      'planId': planId,
      'providerName': providerName,
      'policyNumber': policyNumber,
      'expirationDate': expirationDate != null
          ? Timestamp.fromDate(expirationDate!)
          : null,
      'proofUrl': proofUrl,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  bool get isExpiringSoon {
    if (expirationDate == null) return false;
    final daysUntilExpiration = expirationDate!.difference(DateTime.now()).inDays;
    return daysUntilExpiration <= 30 && daysUntilExpiration >= 0;
  }

  bool get isExpired {
    if (expirationDate == null) return false;
    return expirationDate!.isBefore(DateTime.now());
  }
}

