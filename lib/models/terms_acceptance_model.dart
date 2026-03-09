import 'package:cloud_firestore/cloud_firestore.dart';

/// Model for recording facility-level terms acceptance for contract features
class TermsAcceptanceModel {
  final String facilityId;
  final DateTime acceptedAt; // Server timestamp
  final String acceptedByUserId;
  final String tosVersion; // Terms version accepted
  final String textHash; // Hash of the terms text for verification

  TermsAcceptanceModel({
    required this.facilityId,
    required this.acceptedAt,
    required this.acceptedByUserId,
    required this.tosVersion,
    required this.textHash,
  });

  factory TermsAcceptanceModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return TermsAcceptanceModel(
      facilityId: doc.id, // Document ID is the facilityId
      acceptedAt: (data['acceptedAt'] as Timestamp).toDate(),
      acceptedByUserId: data['acceptedByUserId'] ?? '',
      tosVersion: data['tosVersion'] ?? '1.0',
      textHash: data['textHash'] ?? '',
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'acceptedAt': Timestamp.fromDate(acceptedAt),
      'acceptedByUserId': acceptedByUserId,
      'tosVersion': tosVersion,
      'textHash': textHash,
    };
  }
}
