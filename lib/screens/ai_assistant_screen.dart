import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/active_facility_service.dart';
import 'package:sfcapp/services/ai_assistant_service.dart';
import 'package:sfcapp/services/ai_debug_logger.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

const bool kShowAiDebug = kDebugMode;

class AIAssistantScreen extends ConsumerStatefulWidget {
  const AIAssistantScreen({super.key});

  @override
  ConsumerState<AIAssistantScreen> createState() => _AIAssistantScreenState();
}

class _AIAssistantScreenState extends ConsumerState<AIAssistantScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _addWelcomeMessage();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _addWelcomeMessage() {
    setState(() {
      _messages.add(ChatMessage(
        text: 'Hi! I\'m your storage facility assistant. Ask me anything about running your facility, managing tenants, payments, best practices, or how to use this app.',
        isUser: false,
        timestamp: DateTime.now(),
      ));
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isLoading) return;

    // #region agent log
    aiDebugLog(
      sessionId: 'debug-session',
      runId: 'pre-fix',
      hypothesisId: 'H5',
      location: 'ai_assistant_screen.dart:_sendMessage',
      message: 'Send message entry',
      data: {
        'textLength': text.length,
        'isLoading': _isLoading,
      },
    );
    // #endregion

    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ));
    });
    _messageController.clear();
    _scrollToBottom();

    setState(() {
      _isLoading = true;
    });

    String? facilityContext;
    String? facilityId;
    String? facilityName;
    try {
      facilityId = await ActiveFacilityService.getActiveFacilityId();
      final facilities = await FacilityService.getUserFacilities();
      if (facilityId == null && facilities.isNotEmpty) {
        facilityId = facilities.first.id;
      }
      if (facilities.isNotEmpty) {
        facilityContext = 'Facility: ${facilities.first.name}, ${facilities.length} total facility(ies)';
        final match = facilityId != null
            ? facilities.where((e) => e.id == facilityId).toList()
            : <FacilityModel>[];
        facilityName = match.isNotEmpty ? match.first.name : facilities.first.name;
      }
    } catch (_) {}

    String replyText;
    String? debugLine;

    try {
      final config = await AIAssistantService.getAIAssistantConfig();
      final useOpenAI = facilityId != null && config.shouldUseOpenAI(facilityId);
      final allowlistHasFacility = facilityId != null
          ? config.allowlistFacilityIds.contains(facilityId)
          : false;
      final facilityIdSuffix = facilityId != null && facilityId.length > 4
          ? facilityId.substring(facilityId.length - 4)
          : (facilityId ?? '');

      // PRODUCTION DEBUG: Log config evaluation to console
      print('🔍 [AI Assistant] Config check:');
      print('   enabled: ${config.enabled}');
      print('   killSwitch: ${config.killSwitch}');
      print('   provider: ${config.provider}');
      print('   facilityId: ${facilityId ?? "null"}');
      print('   allowlistLength: ${config.allowlistFacilityIds.length}');
      print('   allowlistHasFacility: $allowlistHasFacility');
      print('   useOpenAI: $useOpenAI');

      // #region agent log
      aiDebugLog(
        sessionId: 'debug-session',
        runId: 'pre-fix',
        hypothesisId: 'H1',
        location: 'ai_assistant_screen.dart:_sendMessage',
        message: 'Config evaluated',
        data: {
          'enabled': config.enabled,
          'killSwitch': config.killSwitch,
          'provider': config.provider,
          'allowlistLength': config.allowlistFacilityIds.length,
          'allowlistHasFacility': allowlistHasFacility,
          'facilityIdPresent': facilityId != null,
          'facilityIdSuffix': facilityIdSuffix,
          'useOpenAI': useOpenAI,
        },
      );
      // #endregion

      if (useOpenAI) {
        final fid = facilityId;
        print('🚀 [AI Assistant] Calling OpenAI via aiAssistantChat callable...');
        try {
          // #region agent log
          aiDebugLog(
            sessionId: 'debug-session',
            runId: 'pre-fix',
            hypothesisId: 'H2',
            location: 'ai_assistant_screen.dart:_sendMessage',
            message: 'Calling aiAssistantChat',
            data: {
              'facilityIdSuffix': facilityIdSuffix,
              'textLength': text.length,
              'hasFacilityName': facilityName != null,
            },
          );
          // #endregion
          final result = await AIAssistantService.chatWithOpenAI(
            facilityId: fid,
            message: text,
            facilityName: facilityName,
          );
          print('✅ [AI Assistant] OpenAI response received: ${result.providerUsed} | ${result.model} | ${result.tokensUsed} tokens');
          replyText = result.replyText;
          debugLine = result.debugLine;
          // #region agent log
          aiDebugLog(
            sessionId: 'debug-session',
            runId: 'pre-fix',
            hypothesisId: 'H3',
            location: 'ai_assistant_screen.dart:_sendMessage',
            message: 'aiAssistantChat success',
            data: {
              'providerUsed': result.providerUsed,
              'model': result.model,
              'tokensUsed': result.tokensUsed,
              'latencyMs': result.latencyMs,
            },
          );
          // #endregion
          if (kDebugMode) {
            debugPrint('AI Assistant (OpenAI): ${result.debugLine}');
          }
        } catch (e) {
          final errorCode = AIAssistantService.getErrorCode(e);
          print('❌ [AI Assistant] OpenAI call failed: $errorCode - ${e.toString()}');
          // #region agent log
          aiDebugLog(
            sessionId: 'debug-session',
            runId: 'pre-fix',
            hypothesisId: 'H3',
            location: 'ai_assistant_screen.dart:_sendMessage',
            message: 'aiAssistantChat error',
            data: {
              'errorCode': errorCode ?? 'unknown',
              'errorType': e.runtimeType.toString(),
            },
          );
          // #endregion
          if (errorCode == 'failed-precondition') {
            print('⚠️ [AI Assistant] Falling back to tips due to failed-precondition');
            await Future.delayed(const Duration(milliseconds: 400));
            replyText = await _getAIResponse(text, facilityContext);
          } else {
            replyText = AIAssistantService.getFriendlyErrorMessage(e) ??
                'Sorry, the AI assistant is unavailable right now. Please try again.';
          }
        }
      } else {
        print('⚠️ [AI Assistant] OpenAI disabled - using tips fallback');
        print('   Reason: enabled=${config.enabled}, killSwitch=${config.killSwitch}, provider=${config.provider}, facilityId=${facilityId ?? "null"}');
        // #region agent log
        aiDebugLog(
          sessionId: 'debug-session',
          runId: 'pre-fix',
          hypothesisId: 'H1',
          location: 'ai_assistant_screen.dart:_sendMessage',
          message: 'OpenAI disabled, using tips fallback',
          data: {
            'facilityIdPresent': facilityId != null,
          },
        );
        // #endregion
        await Future.delayed(const Duration(milliseconds: 400));
        replyText = await _getAIResponse(text, facilityContext);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AI Assistant error: $e');
      }
      final errorCode = AIAssistantService.getErrorCode(e);
      if (errorCode == 'failed-precondition') {
        await Future.delayed(const Duration(milliseconds: 400));
        replyText = await _getAIResponse(text, facilityContext);
      } else {
        replyText = AIAssistantService.getFriendlyErrorMessage(e) ??
            'Sorry, the AI assistant is unavailable right now. Please try again.';
      }
    }

    setState(() {
      _messages.add(ChatMessage(
        text: replyText,
        isUser: false,
        timestamp: DateTime.now(),
        debugLine: debugLine,
      ));
      _isLoading = false;
    });
    _scrollToBottom();
  }

  Future<String> _getAIResponse(String question, String? facilityContext) async {
    // Keyword fallback when the OpenAI-backed path is not used (see `aiAssistantChat` / appConfig).
    
    final lowerQuestion = question.toLowerCase();
    
    // Check if question is storage-related
    if (!_isStorageRelated(lowerQuestion)) {
      return 'I\'m designed to help with self-storage facility management questions. '
          'Could you ask me something about:\n'
          '• Using this app\'s features\n'
          '• Storage facility operations\n'
          '• Tenant management\n'
          '• Pricing strategies\n'
          '• Or other storage-related topics?';
    }

    // Provide helpful responses based on keywords
    if (lowerQuestion.contains('price') || lowerQuestion.contains('rate') || lowerQuestion.contains('cost')) {
      return 'For pricing strategies:\n\n'
          '• Monitor occupancy rates - if >90% full, consider raising rates\n'
          '• Check the Yield Management page for pricing recommendations\n'
          '• Compare your rates to local market rates\n'
          '• Consider seasonal adjustments for high-demand periods\n\n'
          '${facilityContext != null ? "Context: $facilityContext" : ""}';
    } else if (lowerQuestion.contains('tenant') || lowerQuestion.contains('client')) {
      return 'Tenant management tips:\n\n'
          '• Use the Tenants page to search and manage all clients\n'
          '• Set up automatic reminders for overdue payments\n'
          '• Track insurance requirements in the Insurance section\n'
          '• Use the DNR system to flag problematic tenants\n\n'
          '${facilityContext != null ? "Context: $facilityContext" : ""}';
    } else if (lowerQuestion.contains('unit') || lowerQuestion.contains('map')) {
      return 'Unit management:\n\n'
          '• Use the Map to visualize and organize your units\n'
          '• Drag units to reposition them on the map\n'
          '• Click units to view details or assign tenants\n'
          '• Use resize handles to adjust unit sizes\n\n'
          '${facilityContext != null ? "Context: $facilityContext" : ""}';
    } else if (lowerQuestion.contains('payment') || lowerQuestion.contains('billing') || lowerQuestion.contains('overdue')) {
      return 'Payment management:\n\n'
          '• Check Rent & payments → Past due for tenants behind on rent\n'
          '• Send reminders from the Reminders tab\n'
          '• View all payments in the Billing section\n'
          '• Set up automatic late fees if needed\n\n'
          '${facilityContext != null ? "Context: $facilityContext" : ""}';
    } else if (lowerQuestion.contains('contract') || lowerQuestion.contains('lease')) {
      return 'Contract management:\n\n'
          '• Create contracts in the Contracts section\n'
          '• Add insurance requirements during contract creation\n'
          '• Track contract status and expiration dates\n'
          '• Send contracts for tenant signing\n\n'
          '${facilityContext != null ? "Context: $facilityContext" : ""}';
    } else if (lowerQuestion.contains('insurance')) {
      return 'Insurance management:\n\n'
          '• Create insurance plans in the Insurance section\n'
          '• Set default or required plans for tenants\n'
          '• Track tenant insurance status\n'
          '• Monitor expiring third-party policies\n\n'
          '${facilityContext != null ? "Context: $facilityContext" : ""}';
    } else {
      return 'I understand you\'re asking about storage facility management. '
          'Here are some ways I can help:\n\n'
          '• Navigate to specific features using the sidebar\n'
          '• Ask about pricing, tenants, units, payments, or contracts\n'
          '• Get tips on facility operations\n\n'
          'Try asking something like:\n'
          '"How do I set rental rates?"\n'
          '"How do I send payment reminders?"\n'
          '"How do I manage units on the map?"\n\n'
          '${facilityContext != null ? "Context: $facilityContext" : ""}';
    }
  }

  bool _isStorageRelated(String question) {
    final storageKeywords = [
      'storage', 'facility', 'tenant', 'unit', 'payment', 'billing',
      'contract', 'lease', 'insurance', 'map', 'occupancy', 'rate',
      'price', 'overdue', 'reminder', 'yield', 'dnr', 'access',
      'gate', 'report', 'revenue', 'occupancy', 'rent', 'rental',
    ];
    return storageKeywords.any((keyword) => question.contains(keyword));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_isLoading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _messages.length) {
                  // Loading indicator
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        const CircularProgressIndicator(strokeWidth: 2),
                        const SizedBox(width: 16),
                        Text(
                          'Thinking...',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                  );
                }
                return _buildMessageBubble(_messages[index]);
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                top: BorderSide(color: AppTheme.borderLight),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Ask about storage facility management...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isLoading ? null : _sendMessage,
                  icon: const Icon(Icons.send),
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!message.isUser) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.1),
              child: Icon(Icons.smart_toy, size: 20, color: AppTheme.primaryBlue),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: message.isUser
                    ? AppTheme.primaryBlue
                    : AppTheme.backgroundLight,
                borderRadius: BorderRadius.circular(20),
                border: message.isUser
                    ? null
                    : Border.all(color: AppTheme.borderLight),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.text,
                    style: TextStyle(
                      color: message.isUser
                          ? Colors.white
                          : AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatTime(message.timestamp),
                    style: TextStyle(
                      fontSize: 10,
                      color: message.isUser
                          ? Colors.white70
                          : AppTheme.textTertiary,
                    ),
                  ),
                  if (!message.isUser && message.debugLine != null && kShowAiDebug) ...[
                    const SizedBox(height: 6),
                    Text(
                      message.debugLine!,
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.textTertiary,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (message.isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primaryBlue,
              child: const Icon(Icons.person, size: 16, color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
    }
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final String? debugLine;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.debugLine,
  });
}

