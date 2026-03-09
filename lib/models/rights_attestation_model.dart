import 'package:cloud_firestore/cloud_firestore.dart';

/// Model for recording user attestation of rights to upload and use contract documents
class RightsAttestationModel {
  final String id;
  final String facilityId;
  final String uploaderUserId;
  final String uploaderEmail;
  final DateTime timestamp; // Server timestamp
  final String tosVersion; // Terms of service version
  final String attestationText; // The exact text the user attested to
  final String documentId; // Contract or template ID
  final String? documentSha256; // SHA-256 hash of the document
  final String? userAgent; // User agent string from web client

  RightsAttestationModel({
    required this.id,
    required this.facilityId,
    required this.uploaderUserId,
    required this.uploaderEmail,
    required this.timestamp,
    required this.tosVersion,
    required this.attestationText,
    required this.documentId,
    this.documentSha256,
    this.userAgent,
  });

  factory RightsAttestationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return RightsAttestationModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      uploaderUserId: data['uploaderUserId'] ?? '',
      uploaderEmail: data['uploaderEmail'] ?? '',
      timestamp: (data['timestamp'] as Timestamp).toDate(),
      tosVersion: data['tosVersion'] ?? '1.0',
      attestationText: data['attestationText'] ?? '',
      documentId: data['documentId'] ?? '',
      documentSha256: data['documentSha256'],
      userAgent: data['userAgent'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'uploaderUserId': uploaderUserId,
      'uploaderEmail': uploaderEmail,
      'timestamp': Timestamp.fromDate(timestamp),
      'tosVersion': tosVersion,
      'attestationText': attestationText,
      'documentId': documentId,
      if (documentSha256 != null) 'documentSha256': documentSha256,
      if (userAgent != null) 'userAgent': userAgent,
    };
  }
}
