import 'package:cloud_firestore/cloud_firestore.dart';

/// One persisted AI assistant turn (from Cloud Functions `aiChatAuditLogs`).
class SuperAdminAiChatLog {
  final String id;
  final String facilityId;
  final String? facilityName;
  final String userId;
  final String? userEmail;
  final String userMessage;
  final String assistantReply;
  final String requestId;
  final String model;
  final int tokensUsed;
  final int latencyMs;
  final String providerUsed;
  final String source;
  final DateTime? createdAt;

  const SuperAdminAiChatLog({
    required this.id,
    required this.facilityId,
    this.facilityName,
    required this.userId,
    this.userEmail,
    required this.userMessage,
    required this.assistantReply,
    required this.requestId,
    required this.model,
    required this.tokensUsed,
    required this.latencyMs,
    required this.providerUsed,
    required this.source,
    this.createdAt,
  });

  factory SuperAdminAiChatLog.fromFirestore(QueryDocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final created = d['createdAt'];
    return SuperAdminAiChatLog(
      id: doc.id,
      facilityId: d['facilityId'] as String? ?? '',
      facilityName: d['facilityName'] as String?,
      userId: d['userId'] as String? ?? '',
      userEmail: d['userEmail'] as String?,
      userMessage: d['userMessage'] as String? ?? '',
      assistantReply: d['assistantReply'] as String? ?? '',
      requestId: d['requestId'] as String? ?? '',
      model: d['model'] as String? ?? '',
      tokensUsed: (d['tokensUsed'] as num?)?.toInt() ?? 0,
      latencyMs: (d['latencyMs'] as num?)?.toInt() ?? 0,
      providerUsed: d['providerUsed'] as String? ?? '',
      source: d['source'] as String? ?? '',
      createdAt: created is Timestamp ? created.toDate() : null,
    );
  }
}
