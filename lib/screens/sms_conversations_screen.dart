import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/sms_conversation_model.dart';
import '../services/sms_conversation_service.dart';
import '../services/tenant_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../widgets/sms_conversation_widget.dart';
import '../services/modern_navigation_service.dart';
import '../utils/error_message_helper.dart';

/// Provider for SMS conversations
final smsConversationsProvider = FutureProvider.family<List<SMSConversationModel>, String>((ref, facilityId) async {
  return await SMSConversationService.getConversationsForFacility(facilityId: facilityId);
});

/// Screen to display and manage SMS conversations
class SMSConversationsScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const SMSConversationsScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<SMSConversationsScreen> createState() => _SMSConversationsScreenState();
}

class _SMSConversationsScreenState extends ConsumerState<SMSConversationsScreen> {
  String? _selectedConversationId;
  SMSConversationModel? _selectedConversation;

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/messaging/sms',
      title: 'SMS Conversations',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: Row(
        children: [
          // Conversations list
          Expanded(
            flex: 1,
            child: _buildConversationsList(),
          ),
          
          // Conversation view
          Expanded(
            flex: 2,
            child: _selectedConversation != null
                ? _buildConversationView()
                : _buildNoConversationSelected(),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationsList() {
    return Consumer(
      builder: (context, ref, child) {
        final conversationsAsync = ref.watch(smsConversationsProvider(widget.facilityId));

        return Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary,
            border: Border(
              right: BorderSide(color: AppTheme.borderLight),
            ),
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  border: Border(
                    bottom: BorderSide(color: AppTheme.borderLight),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.sms, color: AppTheme.primaryBlue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'SMS Conversations',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: () {
                        ref.invalidate(smsConversationsProvider(widget.facilityId));
                      },
                      tooltip: 'Refresh',
                    ),
                  ],
                ),
              ),

              // Conversations list
              Expanded(
                child: conversationsAsync.when(
                  data: (conversations) {
                    if (conversations.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.chat_bubble_outline, size: 48, color: AppTheme.textSecondary),
                            const SizedBox(height: 16),
                            Text(
                              'No SMS conversations yet',
                              style: TextStyle(color: AppTheme.textSecondary),
                            ),
                          ],
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        return _buildConversationTile(conversation);
                      },
                    );
                  },
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (error, stackTrace) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.error_outline, size: 48, color: AppTheme.error),
                          const SizedBox(height: 16),
                          Text(
                            ErrorMessageHelper.getUserFriendlyMessage(error),
                            style: TextStyle(color: AppTheme.error),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () {
                              ref.invalidate(smsConversationsProvider(widget.facilityId));
                            },
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildConversationTile(SMSConversationModel conversation) {
    final isSelected = _selectedConversationId == conversation.id;
    final hasUnread = conversation.unreadCount > 0;

    return InkWell(
      onTap: () {
        setState(() {
          _selectedConversationId = conversation.id;
          _selectedConversation = conversation;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primaryBlueLight.withOpacity(0.1) : AppTheme.surface,
          border: Border(
            bottom: BorderSide(color: AppTheme.borderLight),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    conversation.phoneNumber,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
                if (hasUnread)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${conversation.unreadCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              conversation.lastMessage,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
                fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatLastMessageTime(conversation.lastMessageAt),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textTertiary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationView() {
    if (_selectedConversation == null) return _buildNoConversationSelected();

    return FutureBuilder<String?>(
      future: _getTenantName(_selectedConversation!.tenantId),
      builder: (context, snapshot) {
        return SMSConversationWidget(
          facilityId: widget.facilityId,
          conversationId: _selectedConversation!.id,
          tenantId: _selectedConversation!.tenantId,
          phoneNumber: _selectedConversation!.phoneNumber,
          tenantName: snapshot.data,
        );
      },
    );
  }

  Widget _buildNoConversationSelected() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sms, size: 64, color: AppTheme.textSecondary),
          const SizedBox(height: 16),
          Text(
            'Select a conversation',
            style: TextStyle(
              fontSize: 18,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Choose a conversation from the list to view messages',
            style: TextStyle(color: AppTheme.textTertiary),
          ),
        ],
      ),
    );
  }

  Future<String?> _getTenantName(String tenantId) async {
    try {
      final tenant = await TenantService.getTenantById(widget.facilityId, tenantId);
      return tenant?.name;
    } catch (e) {
      return null;
    }
  }

  String _formatLastMessageTime(DateTime? timestamp) {
    if (timestamp == null) return '';
    
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inDays == 0) {
      // Today - show time
      return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${timestamp.month}/${timestamp.day}/${timestamp.year}';
    }
  }
}

