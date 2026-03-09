import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/ai_action_model.dart';

/// Config at Firestore /appConfig/aiAssistant
/// strictnessLevel: 0-100, default 60. Lower = less strict client-side guard (still safe).
class AIAssistantConfig {
  final bool enabled;
  final bool killSwitch;
  final String? provider;
  final List<String> allowlistFacilityIds;
  /// 0-100; default 60. Lower values relax client-side topic check slightly.
  final int strictnessLevel;

  const AIAssistantConfig({
    required this.enabled,
    required this.killSwitch,
    this.provider,
    this.allowlistFacilityIds = const [],
    this.strictnessLevel = 60,
  });

  static AIAssistantConfig fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return const AIAssistantConfig(enabled: false, killSwitch: false);
    }
    final list = data['allowlistFacilityIds'];
    final raw = data['strictnessLevel'];
    int level = 60;
    if (raw is int) level = raw.clamp(0, 100);
    if (raw is num) level = raw.toInt().clamp(0, 100);
    return AIAssistantConfig(
      enabled: data['enabled'] as bool? ?? false,
      killSwitch: data['killSwitch'] as bool? ?? false,
      provider: data['provider'] as String?,
      allowlistFacilityIds: list is List
          ? (list).map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList()
          : [],
      strictnessLevel: level,
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
      'provider: $providerUsed | model: $model | tokens: $tokensUsed | requestId: $requestId | latency: ${latencyMs}ms';
}

class AIAssistantService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static const _appConfigPath = 'appConfig';
  static const _aiAssistantDoc = 'aiAssistant';
  static const int maxInputChars = 2000;

  /// Storage-related keywords. Client-side scope check (mirrors backend).
  /// Broad enough so natural questions about storage facilities pass (e.g. "best practices for my property").
  static const _storageKeywords = [
    'storage', 'facility', 'facilities', 'tenant', 'tenants', 'unit', 'units',
    'occupancy', 'payment', 'payments', 'rent', 'lease', 'contract', 'move-in', 'move-out',
    'gate', 'access', 'auction', 'lien', 'delinquency', 'pricing', 'yield', 'insurance',
    'dnr', 'reservation', 'vacancy', 'deposit', 'billing', 'stripe', 'report', 'reports',
    'late fee', 'self-storage', 'self storage', 'management', 'app ', 'feature', 'how do i', 'how to',
    'property', 'properties', 'location', 'business', 'customer', 'rental', 'space', 'locker',
    'owner', 'operate', 'operating', 'running', 'best practice', 'setup', 'set up', 'tips', 'advice',
    'monthly', 'overdue', 'collections', 'evict', 'overlock', 'lock out', 'lockout',
    'charge', 'charges', 'fee', 'fees', 'price', 'rates', 'revenue', 'income',
  ];
  static const _offTopicKeywords = [
    'star trek', 'startrek', 'star wars', 'movie', 'movies', 'film', 'recipe', 'recipes',
    'cook', 'sports', 'football', 'basketball', 'game of thrones', 'lotr', 'music', 'celebrity',
    'joke', 'jokes', 'meme', 'trivia', 'recipe for',
    ' dog ', ' cat ', ' puppy', ' kitten', ' dog named', ' cat named', 'a dog', 'a cat',
  ];

  /// True if the message is about storage facility management. Reject off-topic before calling API.
  /// [strictnessLevel] 0-100 from config: lower allows slightly longer non-keyword messages (e.g. 35 -> 55 chars).
  static bool isStorageFacilityRelated(String message, {int strictnessLevel = 60}) {
    final m = message.trim().toLowerCase();
    if (m.length < 2) return true;
    final hasStorage = _storageKeywords.any((k) => m.contains(k));
    final hasOffTopic = _offTopicKeywords.any((k) => m.contains(k));
    if (hasOffTopic && !hasStorage) return false;
    if (hasStorage) return true;
    final maxLen = strictnessLevel >= 80 ? 25 : (strictnessLevel >= 60 ? 35 : 55);
    if (m.length <= maxLen && !hasOffTopic) return true;
    return false;
  }

  /// Reject personalized-message or nonsense requests (mirrors backend guard rails).
  static bool containsNonsenseOrPersonalizedRequest(String message) {
    final m = message.trim().toLowerCase();
    const personalized = [
      'give me a message to',
      'give me a message for',
      'write a message to',
      'draft a message to',
      'send a message to',
      'email to',
      'message to send to',
      'reminder for',
    ];
    if (personalized.any((p) => m.contains(p))) return true;
    const pets = ['dog', 'cat', 'puppy', 'kitten', 'pet'];
    const tenantCtx = ['rent', 'tenant', 'late', 'payment', 'message to', 'send to', 'email to'];
    final hasPet = pets.any((p) => m.contains(p));
    final hasCtx = tenantCtx.any((c) => m.contains(c));
    return hasPet && hasCtx;
  }

  static AIAssistantConfig? _cachedConfig;
  static Future<AIAssistantConfig>? _configFuture;

  /// Read /appConfig/aiAssistant config.
  static Future<AIAssistantConfig> getAIAssistantConfig({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedConfig != null) {
      return _cachedConfig!;
    }
    if (!forceRefresh && _configFuture != null) {
      return _configFuture!;
    }
    _configFuture = _loadAIAssistantConfig();
    final config = await _configFuture!;
    _cachedConfig = config;
    _configFuture = null;
    return config;
  }

  static Future<AIAssistantConfig> _loadAIAssistantConfig() async {
    try {
      final doc = await _firestore.collection(_appConfigPath).doc(_aiAssistantDoc).get();
      final config = AIAssistantConfig.fromMap(doc.data());
      print('📋 [AIAssistantService] Config loaded: enabled=${config.enabled}, killSwitch=${config.killSwitch}, provider=${config.provider}');
      if (!doc.exists) {
        print('⚠️ [AIAssistantService] Config document does not exist at appConfig/aiAssistant');
        print('   Create it in Firestore Console with: {"enabled": true, "killSwitch": false, "provider": "openai", "allowlistFacilityIds": []}');
      }
      return config;
    } catch (e) {
      print('❌ [AIAssistantService] Error reading appConfig/aiAssistant: $e');
      return const AIAssistantConfig(enabled: false, killSwitch: false);
    }
  }

  /// Call aiAssistantChat callable. Use when config.shouldUseOpenAI(facilityId) is true.
  static Future<AIAssistantChatResult> chatWithOpenAI({
    required String facilityId,
    required String message,
    String? conversationId,
    String? threadId,
    String? facilityName,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User not authenticated');

    print('📞 [AIAssistantService] Calling aiAssistantChat callable...');
    print('   facilityId: $facilityId');
    print('   message length: ${message.length}');
    
    final callable = _functions.httpsCallable('aiAssistantChat');
    try {
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'userId': user.uid,
        'message': message,
        if (conversationId != null) 'conversationId': conversationId,
        if (threadId != null) 'threadId': threadId,
        if (facilityName != null) 'facilityName': facilityName,
      });
      print('✅ [AIAssistantService] Callable response received');
      return AIAssistantChatResult.fromMap(Map<String, dynamic>.from(result.data as Map));
    } catch (e) {
      print('❌ [AIAssistantService] Callable error: $e');
      rethrow;
    }
  }

  static String? getFriendlyErrorMessage(Object error) {
    if (error is FirebaseFunctionsException) {
      switch (error.code) {
        case 'resource-exhausted':
          final msg = error.message ?? '';
          if (msg.contains('Daily limit')) return msg;
          return 'You\'ve hit the AI request limit. Please wait a minute and try again.';
        case 'invalid-argument':
          final msg = error.message ?? '';
          if (msg.contains('off-topic') ||
              msg.contains('storage facility management') ||
              msg.contains('draft messages') ||
              msg.contains('tenant data')) {
            return msg;
          }
          return msg.isNotEmpty ? msg : 'Your request was invalid. Please try again.';
        case 'permission-denied':
          return 'You don\'t have access to this facility\'s AI assistant.';
        case 'unauthenticated':
          return 'Please sign in to use the AI assistant.';
        case 'failed-precondition':
          return 'AI assistant is not enabled for this facility.';
      }
    }
    return null;
  }

  static String? getErrorCode(Object error) {
    if (error is FirebaseFunctionsException) {
      return error.code;
    }
    return null;
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
