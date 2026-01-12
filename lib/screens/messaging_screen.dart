import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/messaging_model.dart';
import '../models/permission_model.dart';
import '../models/sms_conversation_model.dart';
import '../models/tenant_model.dart';
import '../providers/messaging_provider.dart';
import '../providers/auth_provider.dart';
import '../services/permission_service.dart';
import '../services/sms_conversation_service.dart';
import '../services/sms_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../widgets/sms_conversation_widget.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../services/tenant_service.dart';
import '../services/messaging_service.dart';
import 'package:firebase_auth/firebase_auth.dart';

// Provider for SMS conversations
final smsConversationsProvider = FutureProvider.family<List<SMSConversationModel>, String>((ref, facilityId) async {
  return await SMSConversationService.getConversationsForFacility(facilityId: facilityId);
});

class MessagingScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const MessagingScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<MessagingScreen> createState() => _MessagingScreenState();
}

class _MessagingScreenState extends ConsumerState<MessagingScreen> {
  String? _selectedConversationId;
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _conversationTitleController = TextEditingController();
  bool _loadingPermissions = true;
  bool _canViewConversations = false;
  bool _canManageConversations = false;
  String? _permissionReason;
  int _selectedTab = 0; // 0 = Conversations, 1 = SMS

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    setState(() {
      _loadingPermissions = true;
    });
    final viewCheck = await PermissionService.hasPermission(
      permission: PermissionType.viewReminder,
      facilityId: widget.facilityId,
    );
    final manageCheck = await PermissionService.hasPermission(
      permission: PermissionType.editReminder,
      facilityId: widget.facilityId,
    );
    if (!mounted) return;
    setState(() {
      _loadingPermissions = false;
      _canViewConversations = viewCheck.hasPermission;
      _canManageConversations = manageCheck.hasPermission;
      _permissionReason = viewCheck.reason ?? manageCheck.reason;
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _conversationTitleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingPermissions) {
      return ModernPageWrapper(
        currentRoute: '/messages',
        title: 'Messaging',
        onNavigate: (route) {
          ModernNavigationService.navigateToRoute(context, route);
        },
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (!_canViewConversations) {
      return ModernPageWrapper(
        currentRoute: '/messages',
        title: 'Messaging',
        onNavigate: (route) {
          ModernNavigationService.navigateToRoute(context, route);
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: AppTheme.warning),
                const SizedBox(height: 16),
                Text(
                  'Messaging access restricted',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _permissionReason ??
                      'You do not have permission to view conversations for this facility.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ModernPageWrapper(
      currentRoute: '/messages',
      title: 'Messaging',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        if (_selectedTab == 0)
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: 'New message',
            onSelected: (value) {
              if (value == 'private') {
                _showNewPrivateMessageDialog();
              } else if (value == 'group') {
                // Only allow group conversations if user has manage permissions
                if (_canManageConversations) {
                  _showCreateConversationDialog();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(_permissionReason ?? 'You need permission to create group conversations.'),
                    ),
                  );
                }
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'private',
                child: Row(
                  children: [
                    Icon(Icons.person, size: 20),
                    SizedBox(width: 8),
                    Text('New Private Message'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'group',
                enabled: _canManageConversations,
                child: Row(
                  children: [
                    Icon(Icons.group, size: 20),
                    SizedBox(width: 8),
                    Text('New Group Conversation'),
                    if (!_canManageConversations)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Icon(Icons.lock_outline, size: 14, color: AppTheme.textTertiary),
                      ),
                  ],
                ),
              ),
            ],
          ),
        if (_selectedTab == 1)
          IconButton(
            icon: const Icon(Icons.sms),
            tooltip: 'Send new SMS',
            onPressed: _showSendSMSDialog,
          ),
      ],
      child: Column(
        children: [
          // Tabs
          Container(
            decoration: BoxDecoration(
              color: AppTheme.backgroundSecondary,
              border: Border(
                bottom: BorderSide(color: AppTheme.borderLight),
              ),
            ),
            child: Row(
              children: [
                _buildTab(0, 'Conversations', Icons.chat_bubble_outline),
                _buildTab(1, 'SMS', Icons.sms),
              ],
            ),
          ),
          
          // Content based on selected tab
          Expanded(
            child: Row(
              children: [
                // Conversations/SMS list
                Expanded(
                  flex: 1,
                  child: _selectedTab == 0
                      ? _buildConversationsList()
                      : _buildSMSConversationsList(),
                ),
                
                // Messages pane
                Expanded(
                  flex: 2,
                  child: _selectedTab == 0
                      ? (_selectedConversationId != null
                          ? _buildMessagesPane()
                          : _buildNoConversationSelected())
                      : (_selectedConversationId != null
                          ? _buildSMSMessagesPane()
                          : _buildNoConversationSelected()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationsList() {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: AppTheme.borderLight),
        ),
      ),
      child: Column(
        children: [
          if (!_canManageConversations)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: AppTheme.warning.withOpacity(0.1),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, color: AppTheme.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _permissionReason ??
                          'You can view conversations but cannot create or modify them.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.backgroundLight,
              border: Border(
                bottom: BorderSide(color: AppTheme.borderLight),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline),
                const SizedBox(width: 8),
                Text(
                  'Conversations',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Consumer(
              builder: (context, ref, child) {
                return ref.watch(conversationsProvider(widget.facilityId)).when(
                  data: (conversations) {
                    if (_selectedConversationId == null && conversations.isNotEmpty) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        if (_selectedConversationId == null) {
                          setState(() {
                            _selectedConversationId = conversations.first.id;
                          });
                        }
                      });
                    }

                    if (conversations.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.chat_bubble_outline,
                              size: 64,
                              color: AppTheme.textTertiary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No conversations yet',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Create your first conversation to start messaging.',
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        final isSelected = conversation.id == _selectedConversationId;
                        final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
                        
                        // For private conversations, show the other participant's name
                        String displayTitle = conversation.title;
                        Widget leadingIcon = CircleAvatar(
                          backgroundColor: isSelected ? AppTheme.primaryBlue : AppTheme.borderLight,
                          child: Icon(
                            conversation.isPrivate ? Icons.person : Icons.chat_bubble,
                            color: isSelected ? AppTheme.textOnDark : AppTheme.textSecondary,
                          ),
                        );
                        
                        if (conversation.isPrivate) {
                          final otherParticipantName = conversation.getOtherParticipantName(currentUserId);
                          if (otherParticipantName != null) {
                            displayTitle = otherParticipantName;
                            // Show avatar with initial
                            leadingIcon = CircleAvatar(
                              backgroundColor: isSelected ? AppTheme.primaryBlue : AppTheme.borderLight,
                              child: Text(
                                otherParticipantName.isNotEmpty 
                                    ? otherParticipantName[0].toUpperCase() 
                                    : '?',
                                style: TextStyle(
                                  color: isSelected ? AppTheme.textOnDark : AppTheme.textSecondary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            );
                          }
                        }
                        
                        return ListTile(
                          selected: isSelected,
                          selectedTileColor: AppTheme.primaryBlue.withOpacity(0.1),
                          leading: leadingIcon,
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  displayTitle,
                                  style: TextStyle(
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (conversation.isPrivate)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: Icon(
                                    Icons.lock_outline,
                                    size: 14,
                                    color: AppTheme.textTertiary,
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (conversation.lastMessagePreview != null)
                                Text(
                                  conversation.lastMessagePreview!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              const SizedBox(height: 2),
                              Text(
                                conversation.lastMessageAt != null
                                    ? _formatTime(conversation.lastMessageAt!)
                                    : _formatTime(conversation.createdAt),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textTertiary,
                                ),
                              ),
                            ],
                          ),
                          trailing: _canManageConversations && !conversation.isPrivate
                              ? PopupMenuButton(
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                      value: 'archive',
                                      child: Text('Archive'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete'),
                                    ),
                                  ],
                                  onSelected: (value) {
                                    if (value == 'archive') {
                                      _archiveConversation(conversation);
                                    } else if (value == 'delete') {
                                      _deleteConversation(conversation);
                                    }
                                  },
                                )
                              : null,
                          onTap: () {
                            setState(() {
                              _selectedConversationId = conversation.id;
                            });
                          },
                        );
                      },
                    );
                  },
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (error, stackTrace) => Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error,
                          size: 64,
                          color: AppTheme.error,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Error loading conversations',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          error.toString(),
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () {
                            ref.invalidate(conversationsProvider(widget.facilityId));
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessagesPane() {
    final conversationTitle = ref.watch(conversationsProvider(widget.facilityId)).maybeWhen(
          data: (conversations) {
            for (final conversation in conversations) {
              if (conversation.id == _selectedConversationId) {
                return conversation.title.isNotEmpty ? conversation.title : 'Conversation';
              }
            }
            return 'Conversation';
          },
          orElse: () => 'Conversation',
        );

    return Column(
      children: [
        // Messages header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary,
            border: Border(
              bottom: BorderSide(color: AppTheme.borderLight),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.chat),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  conversationTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        
        // Messages list
        Expanded(
          child: Consumer(
            builder: (context, ref, child) {
              return ref.watch(messagesProvider((widget.facilityId, _selectedConversationId!))).when(
                data: (messages) {
                  if (messages.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.message,
                            size: 64,
                            color: AppTheme.textTertiary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No messages yet',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Send the first message to start the conversation.',
                            style: Theme.of(context).textTheme.bodyMedium,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    reverse: true, // Show newest at bottom
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[messages.length - 1 - index];
                      return _buildMessageBubble(message);
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error,
                        size: 64,
                        color: AppTheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Error loading messages',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        error.toString(),
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          ref.invalidate(messagesProvider((widget.facilityId, _selectedConversationId!)));
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        
        // Message input
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: AppTheme.borderLight),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_canManageConversations) ...[
                Text(
                  'You can read this conversation but cannot send messages with your current permissions.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _canManageConversations ? (text) => _sendMessage() : null,
                      readOnly: !_canManageConversations,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _canManageConversations ? _sendMessage : null,
                    icon: const Icon(Icons.send),
                    style: IconButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: AppTheme.textOnDark,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNoConversationSelected() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(height: 16),
          Text(
            'Select a conversation',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Choose a conversation from the list to view messages.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(MessageModel message) {
    final authState = ref.read(authStateProvider);
    final isCurrentUser = authState.hasValue && authState.value?.uid == message.senderUid;
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: isCurrentUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isCurrentUser) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.borderLight,
              child: Text(
                message.senderName.isNotEmpty 
                    ? message.senderName[0].toUpperCase()
                    : '?',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isCurrentUser ? AppTheme.primaryBlue : AppTheme.backgroundLight,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isCurrentUser)
                    Text(
                      message.senderName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  Text(
                    message.text,
                    style: TextStyle(
                      color: isCurrentUser ? AppTheme.textOnDark : AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message.timeDisplay,
                    style: TextStyle(
                      fontSize: 10,
                      color: isCurrentUser 
                          ? AppTheme.textOnDark.withOpacity(0.7)
                          : AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isCurrentUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primaryBlue,
              child: Text(
                message.senderName.isNotEmpty 
                    ? message.senderName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                  fontSize: 12, 
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textOnDark,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showCreateConversationDialog() {
    if (!_canManageConversations) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _permissionReason ?? 'You do not have permission to create conversations.',
          ),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Group Conversation'),
        content: TextField(
          controller: _conversationTitleController,
          decoration: const InputDecoration(
            labelText: 'Title',
            border: OutlineInputBorder(),
            hintText: 'e.g., Team Discussion',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _conversationTitleController.clear();
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final title = _conversationTitleController.text.trim();
              if (title.isNotEmpty) {
                Navigator.of(context).pop();
                final conversationId = await ref.read(messagingOperationsProvider.notifier).createConversation(
                  facilityId: widget.facilityId,
                  title: title,
                );
                _conversationTitleController.clear();
                setState(() {
                  _selectedConversationId = conversationId;
                });
                ref.invalidate(conversationsProvider(widget.facilityId));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Group conversation "$title" created')),
                );
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showNewPrivateMessageDialog() {
    // Private messaging is available to all facility staff
    // No permission check needed - Firestore rules will enforce access
    showDialog(
      context: context,
      builder: (context) => _PrivateMessageUserPickerDialog(
        facilityId: widget.facilityId,
        onUserSelected: (userId, userName, userEmail) async {
          Navigator.of(context).pop();
          
          try {
            final conversationId = await MessagingService.createOrGetPrivateConversation(
              facilityId: widget.facilityId,
              otherUserId: userId,
              otherUserName: userName,
              otherUserEmail: userEmail,
            );
            
            if (!mounted) return;
            setState(() {
              _selectedConversationId = conversationId;
            });
            ref.invalidate(conversationsProvider(widget.facilityId));
            
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Started conversation with $userName')),
            );
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error starting conversation: $e'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
        },
      ),
    );
  }

  void _sendMessage() async {
    if (!_canManageConversations) return;
    final text = _messageController.text.trim();
    if (text.isNotEmpty && _selectedConversationId != null) {
      _messageController.clear();
      await ref.read(messagingOperationsProvider.notifier).sendMessage(
        facilityId: widget.facilityId,
        conversationId: _selectedConversationId!,
        text: text,
      );
    }
  }

  void _archiveConversation(ConversationModel conversation) async {
    if (!_canManageConversations) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive Conversation'),
        content: Text('Archive "${conversation.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(messagingOperationsProvider.notifier).archiveConversation(
        facilityId: widget.facilityId,
        conversationId: conversation.id,
      );
      ref.invalidate(conversationsProvider(widget.facilityId));
      if (_selectedConversationId == conversation.id) {
        setState(() {
          _selectedConversationId = null;
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Conversation "${conversation.title}" archived')),
      );
    }
  }

  void _deleteConversation(ConversationModel conversation) async {
    if (!_canManageConversations) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: Text('Permanently delete "${conversation.title}" and all its messages?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(messagingOperationsProvider.notifier).deleteConversation(
        facilityId: widget.facilityId,
        conversationId: conversation.id,
      );
      ref.invalidate(conversationsProvider(widget.facilityId));
      if (_selectedConversationId == conversation.id) {
        setState(() {
          _selectedConversationId = null;
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Conversation "${conversation.title}" deleted')),
      );
    }
  }

  Widget _buildTab(int index, String label, IconData icon) {
    final isSelected = _selectedTab == index;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedTab = index;
            _selectedConversationId = null; // Reset selection when switching tabs
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? AppTheme.primaryBlue : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: isSelected ? AppTheme.primaryBlue : AppTheme.textSecondary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: isSelected ? AppTheme.primaryBlue : AppTheme.textSecondary,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSMSConversationsList() {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: AppTheme.borderLight),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.backgroundLight,
              border: Border(
                bottom: BorderSide(color: AppTheme.borderLight),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.sms),
                const SizedBox(width: 8),
                Text(
                  'SMS Conversations',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Consumer(
              builder: (context, ref, child) {
                final smsConversationsAsync = ref.watch(smsConversationsProvider(widget.facilityId));
                
                return smsConversationsAsync.when(
                  data: (conversations) {
                    if (conversations.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.sms_outlined, size: 64, color: AppTheme.textTertiary),
                            const SizedBox(height: 16),
                            Text(
                              'No SMS conversations yet',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'SMS conversations will appear here when tenants reply.',
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        final isSelected = conversation.id == _selectedConversationId;
                        
                        return ListTile(
                          selected: isSelected,
                          selectedTileColor: AppTheme.primaryBlue.withOpacity(0.1),
                          leading: CircleAvatar(
                            backgroundColor: isSelected ? AppTheme.primaryBlue : AppTheme.borderLight,
                            child: Icon(
                              Icons.sms,
                              color: isSelected ? AppTheme.textOnDark : AppTheme.textSecondary,
                            ),
                          ),
                          title: Text(
                            conversation.phoneNumber,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                conversation.lastMessage,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontWeight: conversation.unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                conversation.lastMessageAt != null
                                    ? _formatTime(conversation.lastMessageAt!)
                                    : '',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textTertiary,
                                ),
                              ),
                            ],
                          ),
                          trailing: conversation.unreadCount > 0
                              ? Container(
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
                                )
                              : null,
                          onTap: () {
                            setState(() {
                              _selectedConversationId = conversation.id;
                            });
                          },
                        );
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
                            'Error loading SMS conversations',
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSMSMessagesPane() {
    if (_selectedConversationId == null) return _buildNoConversationSelected();
    
    return Consumer(
      builder: (context, ref, child) {
        final conversationsAsync = ref.watch(smsConversationsProvider(widget.facilityId));
        
        return conversationsAsync.when(
          data: (conversations) {
            final conversation = conversations.firstWhere(
              (c) => c.id == _selectedConversationId,
              orElse: () => conversations.isNotEmpty ? conversations.first : throw Exception('Conversation not found'),
            );
            
            return FutureBuilder<String?>(
              future: _getTenantName(conversation.tenantId),
              builder: (context, snapshot) {
                return SMSConversationWidget(
                  facilityId: widget.facilityId,
                  conversationId: conversation.id,
                  tenantId: conversation.tenantId,
                  phoneNumber: conversation.phoneNumber,
                  tenantName: snapshot.data,
                );
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
                    'Error loading conversation',
                    style: TextStyle(color: AppTheme.error),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

  void _showSendSMSDialog() {
    showDialog(
      context: context,
      builder: (context) => _SendSMSDialog(
        facilityId: widget.facilityId,
        onSent: () {
          // Refresh SMS conversations after sending
          ref.invalidate(smsConversationsProvider(widget.facilityId));
        },
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

/// Dialog for sending SMS to a tenant
class _SendSMSDialog extends ConsumerStatefulWidget {
  final String facilityId;
  final VoidCallback? onSent;

  const _SendSMSDialog({
    required this.facilityId,
    this.onSent,
  });

  @override
  ConsumerState<_SendSMSDialog> createState() => _SendSMSDialogState();
}

class _SendSMSDialogState extends ConsumerState<_SendSMSDialog> {
  String? _selectedTenantId;
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  List<TenantModel> _allTenants = [];
  List<TenantModel> _filteredTenants = [];
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _loadTenants();
    _searchController.addListener(_filterTenants);
  }

  @override
  void dispose() {
    _messageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTenants() async {
    try {
      final tenants = await TenantService.getTenantsForFacility(widget.facilityId);
      setState(() {
        _allTenants = tenants.where((t) => t.isActive && t.phone.isNotEmpty).toList();
        _filteredTenants = _allTenants;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading tenants: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _filterTenants() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredTenants = _allTenants;
      } else {
        _filteredTenants = _allTenants.where((tenant) {
          return tenant.name.toLowerCase().contains(query) ||
              tenant.email.toLowerCase().contains(query) ||
              tenant.phone.contains(query);
        }).toList();
      }
    });
  }

  Future<void> _sendSMS() async {
    if (_selectedTenantId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a tenant'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final message = _messageController.text.trim();
    if (message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a message'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final tenant = _allTenants.firstWhere((t) => t.id == _selectedTenantId);
    if (tenant.phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selected tenant does not have a phone number'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      _isSending = true;
    });

    try {
      final result = await SMSService.sendSMS(
        to: tenant.phone,
        message: message,
        facilityId: widget.facilityId,
        tenantId: tenant.id,
        relatedEntityType: 'direct_sms',
      );

      if (result.success) {
        if (mounted) {
          // Show status message if available (e.g., "queued" status with campaign approval info)
          final message = result.statusMessage ?? 'SMS sent successfully';
          final backgroundColor = result.twilioStatus == 'queued' 
              ? AppTheme.warning 
              : AppTheme.success;
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: backgroundColor,
              duration: result.twilioStatus == 'queued' 
                  ? const Duration(seconds: 8) 
                  : const Duration(seconds: 4),
            ),
          );
          widget.onSent?.call();
          Navigator.of(context).pop();
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'Failed to send SMS'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending SMS: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 600,
        height: 700,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sms, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
                Text(
                  'Send SMS',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 24),
            
            // Tenant selection
            Text(
              'Select Tenant',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search tenants by name, email, or phone',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Tenant list
            Expanded(
              child: _filteredTenants.isEmpty
                  ? Center(
                      child: Text(
                        _allTenants.isEmpty
                            ? 'No tenants with phone numbers found'
                            : 'No tenants match your search',
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filteredTenants.length,
                      itemBuilder: (context, index) {
                        final tenant = _filteredTenants[index];
                        final isSelected = _selectedTenantId == tenant.id;
                        
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _selectedTenantId = tenant.id;
                            });
                          },
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppTheme.primaryBlue.withOpacity(0.1)
                                  : AppTheme.backgroundSecondary,
                              border: Border.all(
                                color: isSelected
                                    ? AppTheme.primaryBlue
                                    : AppTheme.borderLight,
                                width: isSelected ? 2 : 1,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                                  color: isSelected ? AppTheme.primaryBlue : AppTheme.textSecondary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tenant.name,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: isSelected ? AppTheme.primaryBlue : AppTheme.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        tenant.phone,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            
            const SizedBox(height: 16),
            
            // Message input
            Text(
              'Message',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Type your message...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Send button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSending ? null : _sendSMS,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.send, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            'Send SMS',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog for selecting a user to start a private conversation with
class _PrivateMessageUserPickerDialog extends ConsumerStatefulWidget {
  final String facilityId;
  final Function(String userId, String userName, String? userEmail) onUserSelected;

  const _PrivateMessageUserPickerDialog({
    required this.facilityId,
    required this.onUserSelected,
  });

  @override
  ConsumerState<_PrivateMessageUserPickerDialog> createState() => _PrivateMessageUserPickerDialogState();
}

class _PrivateMessageUserPickerDialogState extends ConsumerState<_PrivateMessageUserPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  List<UserRole> _allUsers = [];
  List<_UserWithProfile> _filteredUsers = [];
  bool _isLoading = true;
  String? _selectedUserId;

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _searchController.addListener(_filterUsers);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        setState(() => _isLoading = false);
        return;
      }

      // Get all facility users
      final userRoles = await PermissionService.getFacilityUsers(widget.facilityId);
      
      // Load user profiles and filter out current user
      final usersWithProfiles = <_UserWithProfile>[];
      for (final userRole in userRoles) {
        // Skip current user (can't message yourself)
        if (userRole.userId == currentUser.uid) continue;
        
        final profile = await PermissionService.getUserProfile(userRole.userId);
        final email = profile?['email'] ?? 'Unknown email';
        final displayName = profile?['displayName'] ?? email.split('@').first;
        
        usersWithProfiles.add(_UserWithProfile(
          userRole: userRole,
          email: email,
          displayName: displayName,
        ));
      }

      // Sort by name
      usersWithProfiles.sort((a, b) => a.displayName.compareTo(b.displayName));

      setState(() {
        _allUsers = userRoles;
        _filteredUsers = usersWithProfiles;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading users: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      setState(() => _isLoading = false);
    }
  }

  void _filterUsers() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        // Show all users (already filtered in _loadUsers)
        return;
      } else {
        // Filter existing list
        _filteredUsers = _filteredUsers.where((user) {
          return user.displayName.toLowerCase().contains(query) ||
              user.email.toLowerCase().contains(query) ||
              user.userRole.roleType.name.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select User to Message'),
      content: SizedBox(
        width: 400,
        height: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search field
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by name or email...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // User list
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredUsers.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.person_off, size: 48, color: AppTheme.textTertiary),
                              const SizedBox(height: 16),
                              Text(
                                'No users found',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Try a different search term',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _filteredUsers.length,
                          itemBuilder: (context, index) {
                            final userWithProfile = _filteredUsers[index];
                            final user = userWithProfile.userRole;
                            final profile = userWithProfile;
                            final role = PermissionService.getRoleByType(user.roleType);
                            
                            return ListTile(
                              selected: _selectedUserId == user.userId,
                              leading: CircleAvatar(
                                backgroundColor: AppTheme.primaryBlue,
                                child: Text(
                                  profile.displayName.isNotEmpty
                                      ? profile.displayName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              title: Text(profile.displayName),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(profile.email),
                                  const SizedBox(height: 4),
                                  Text(
                                    role?.name ?? user.roleType.name,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () {
                                setState(() {
                                  _selectedUserId = user.userId;
                                });
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selectedUserId == null
              ? null
              : () {
                  final selectedUser = _filteredUsers.firstWhere(
                    (u) => u.userRole.userId == _selectedUserId,
                  );
                  widget.onUserSelected(
                    selectedUser.userRole.userId,
                    selectedUser.displayName,
                    selectedUser.email,
                  );
                },
          child: const Text('Start Conversation'),
        ),
      ],
    );
  }
}

/// Helper class to hold user role with profile information
class _UserWithProfile {
  final UserRole userRole;
  final String email;
  final String displayName;

  _UserWithProfile({
    required this.userRole,
    required this.email,
    required this.displayName,
  });
}
