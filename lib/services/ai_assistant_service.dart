import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/ai_action_model.dart';

/// Config at Firestore /appConfig/aiAssistant
class AIAssistantConfig {
  final bool enabled;
  final bool killSwitch;
  final String? provider;
  final List<String> allowlistFacilityIds;

  const AIAssistantConfig({
    required this.enabled,
    required this.killSwitch,
    this.provider,
    this.allowlistFacilityIds = const [],
  });

  static AIAssistantConfig fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return const AIAssistantConfig(enabled: false, killSwitch: false);
    }
    final list = data['allowlistFacilityIds'];
    return AIAssistantConfig(
      enabled: data['enabled'] as bool? ?? false,
      killSwitch: data['killSwitch'] as bool? ?? false,
      provider: data['provider'] as String?,
      allowlistFacilityIds: list is List
          ? (list).map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList()
          : [],
    );
  }

  /// Use OpenAI when enabled && !killSwitch && provider == 'openai' &&
  /// (allowlist empty OR facilityId in allowlist).
  bool shouldUseOpenAI(String facilityId) {
    if (killSwitch || !enabled || provider != 'openai') return false;
    if (allowlistFacilityIds.isEmpty) return true;
    return allowlistFacilityIds.contains(facilityId);
  }
}

/// Result from aiAssistantChat callable
class AIAssistantChatResult {
  final String replyText;
  final String providerUsed;
  final String model;
  final String requestId;
  final int tokensUsed;
  final int latencyMs;

  const AIAssistantChatResult({
    required this.replyText,
    required this.providerUsed,
    required this.model,
    required this.requestId,
    required this.tokensUsed,
    required this.latencyMs,
  });

  factory AIAssistantChatResult.fromMap(Map<String, dynamic> map) {
    return AIAssistantChatResult(
      replyText: map['replyText'] as String? ?? '',
      providerUsed: map['providerUsed'] as String? ?? 'openai',
      model: map['model'] as String? ?? '',
      requestId: map['requestId'] as String? ?? '',
      tokensUsed: (map['tokensUsed'] as num?)?.toInt() ?? 0,
      latencyMs: (map['latencyMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// Debug line: provider | model | tokens | requestId
  String get debugLine =>
      'provider: $providerUsed | model: $model | tokens: $tokensUsed | requestId: $requestId';
}

class AIAssistantService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static const _appConfigPath = 'appConfig';
  static const _aiAssistantDoc = 'aiAssistant';

  /// Read /appConfig/aiAssistant config.
  static Future<AIAssistantConfig> getAIAssistantConfig() async {
    try {
      final doc = await _firestore.collection(_appConfigPath).doc(_aiAssistantDoc).get();
      return AIAssistantConfig.fromMap(doc.data());
    } catch (e) {
      if (kDebugMode) {
        print('❌ [AIAssistantService] Error reading appConfig/aiAssistant: $e');
      }
      return const AIAssistantConfig(enabled: false, killSwitch: false);
    }
  }

  /// Call aiAssistantChat callable. Use when config.shouldUseOpenAI(facilityId) is true.
  static Future<AIAssistantChatResult> chatWithOpenAI({
    required String facilityId,
    required String message,
    String? conversationId,
    String? facilityName,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User not authenticated');

    final callable = _functions.httpsCallable('aiAssistantChat');
    final result = await callable.call(<String, dynamic>{
      'facilityId': facilityId,
      'userId': user.uid,
      'message': message,
      if (conversationId != null) 'conversationId': conversationId,
      if (facilityName != null) 'facilityName': facilityName,
    });
    return AIAssistantChatResult.fromMap(Map<String, dynamic>.from(result.data as Map));
  }

  /// Send a message to the AI assistant and get response with potential actions
  static Future<Map<String, dynamic>> sendMessage({
    required String facilityId,
    required String message,
    String? conversationId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final callable = _functions.httpsCallable('aiAssistant');
      final result = await callable.call({
        'facilityId': facilityId,
        'message': message,
        'conversationId': conversationId,
        'userId': user.uid,
      });

      return Map<String, dynamic>.from(result.data as Map);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error sending message to AI assistant: $e');
      }
      rethrow;
    }
  }

  /// Execute a confirmed AI action
  static Future<Map<String, dynamic>> executeAction({
    required String facilityId,
    required String conversationId,
    required AIAction action,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final callable = _functions.httpsCallable('aiAssistantExecuteAction');
      final result = await callable.call({
        'facilityId': facilityId,
        'conversationId': conversationId,
        'action': action.toMap(),
        'userId': user.uid,
      });

      return Map<String, dynamic>.from(result.data as Map);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error executing AI action: $e');
      }
      rethrow;
    }
  }

  /// Get conversation history
  static Future<AIConversation?> getConversation({
    required String facilityId,
    required String conversationId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('aiConversations')
          .doc(conversationId)
          .get();

      if (!doc.exists) return null;
      return AIConversation.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting conversation: $e');
      }
      return null;
    }
  }

  /// Get all conversations for a facility
  static Stream<List<AIConversation>> getConversationsStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('aiConversations')
        .orderBy('updatedAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => AIConversation.fromFirestore(doc))
            .toList());
  }

  /// Create a new conversation
  static Future<String> createConversation(String facilityId) async {
    try {
      final now = DateTime.now();
      final conversationRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('aiConversations')
          .doc();

      await conversationRef.set({
        'facilityId': facilityId,
        'messages': [],
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
      });

      return conversationRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating conversation: $e');
      }
      rethrow;
    }
  }
}
