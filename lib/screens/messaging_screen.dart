import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/messaging_model.dart';
import '../models/permission_model.dart';
import '../models/sms_conversation_model.dart';
import '../models/tenant_model.dart';
import '../providers/messaging_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/search_provider.dart';
import '../services/permission_service.dart';
import '../services/sms_conversation_service.dart';
import '../services/sms_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../widgets/sms_conversation_widget.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../services/tenant_service.dart';
import '../services/messaging_service.dart';
import '../services/debug_logger.dart';
import '../services/tenant_message_history_service.dart';
import '../models/tenant_message_history_model.dart';
import '../providers/tenant_provider.dart';
import '../providers/active_facility_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../models/facility_model.dart';
import '../router/app_route.dart';
import '../utils/breakpoints.dart';
import '../utils/renter_account_message.dart';
import 'bulk_messaging_screen.dart';
import '../widgets/email_composition_widget.dart';
import '../widgets/team_notes_panel.dart';

// Provider for SMS conversations
final smsConversationsProvider = FutureProvider.family<List<SMSConversationModel>, String>((ref, facilityId) async {
  return await SMSConversationService.getConversationsForFacility(facilityId: facilityId);
});

// Provider for tenant message history (real-time stream)
final tenantMessageHistoryProvider = StreamProvider.family<List<TenantMessageHistoryModel>, String>((ref, facilityId) {
  ref.keepAlive();
  if (facilityId == 'all' || facilityId.isEmpty) {
    return TenantMessageHistoryService.streamAllTenantMessagesForAllFacilities();
  }
  return TenantMessageHistoryService.streamAllTenantMessages(facilityId: facilityId);
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
  final FocusNode _messageInputFocusNode = FocusNode();
  final TextEditingController _conversationTitleController = TextEditingController();
  bool _loadingPermissions = true;
  bool _canViewConversations = false;
  bool _canManageConversations = false;
  bool _canManageUsersForFacility = false;
  String? _permissionReason;
  int _selectedTab = 0; // 0 = Employee Chat, 1 = Bulk Messaging, 2 = Email, 3 = SMS, 4 = Message History
  /// On phone, Employee Chat: 0 = conversation list, 1 = team notes.
  int _phoneChatNotesSegment = 0;

  // Message history filters
  String? _selectedTenantId;
  TenantMessageType? _selectedMessageType; // null = all
  TenantMessageStatus? _selectedStatus; // null = all
  DateTime? _startDate;
  DateTime? _endDate;
  final TextEditingController _searchController = TextEditingController();

  final ScrollController _employeeChatScrollController = ScrollController();
  String? _lastChatScrollConversationId;
  int _lastChatScrollMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _conversationTitleController.dispose();
    _searchController.dispose();
    _employeeChatScrollController.dispose();
    _messageInputFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MessagingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.facilityId != widget.facilityId) {
      _phoneChatNotesSegment = 0;
      _checkPermissions();
    }
  }

  Future<void> _checkPermissions() async {
    setState(() {
      _loadingPermissions = true;
    });
    var canManageUsers = false;
    if (widget.facilityId.isNotEmpty && widget.facilityId != 'all') {
      final mgr = await PermissionService.hasPermission(
        permission: PermissionType.manageUsers,
        facilityId: widget.facilityId,
      );
      canManageUsers = mgr.hasPermission;
    }
    if (!mounted) return;
    setState(() {
      _loadingPermissions = false;
      _canViewConversations = true;
      _canManageConversations = true;
      _canManageUsersForFacility = canManageUsers;
      _permissionReason = null;
    });
  }

  Map<String, String> _employeeChatNamesForUi() {
    return ref.read(employeeChatNamesProvider(widget.facilityId)).maybeWhen(
          data: (m) => m,
          orElse: () => <String, String>{},
        );
  }

  String _conversationDisplayTitle(ConversationModel conversation) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return conversation.displayTitleForViewer(
      uid,
      employeeChatNamesByUid: _employeeChatNamesForUi(),
    );
  }

  Future<void> _promptEmployeeChatDisplayName({
    required String targetUserId,
    required String title,
    String? subtitle,
  }) async {
    if (widget.facilityId.isEmpty || widget.facilityId == 'all') return;
    final initial = _employeeChatNamesForUi()[targetUserId] ?? '';
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (subtitle != null && subtitle.isNotEmpty) ...[
              Text(subtitle, style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: MessagingService.maxEmployeeChatNameLength,
              decoration: const InputDecoration(
                labelText: 'Display name',
                hintText: 'e.g. Alex (front desk)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(''),
            child: const Text('Remove'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    controller.dispose();
    if (result == null) return;

    final raw = result;
    try {
      await MessagingService.setEmployeeChatName(
        facilityId: widget.facilityId,
        targetUserId: targetUserId,
        rawName: raw,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(raw.trim().isEmpty
              ? 'Chat display name removed.'
              : 'Chat display name saved.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: AppTheme.error),
      );
    }
  }

  void _scheduleEmployeeChatScrollToEnd(List<MessageModel> messages) {
    final convId = _selectedConversationId;
    if (convId == null || messages.isEmpty) return;

    final convChanged = _lastChatScrollConversationId != convId;
    if (convChanged) {
      _lastChatScrollConversationId = convId;
      _lastChatScrollMessageCount = 0;
    }
    final grew = messages.length > _lastChatScrollMessageCount;
    _lastChatScrollMessageCount = messages.length;

    final nearBottom = !_employeeChatScrollController.hasClients ||
        (_employeeChatScrollController.position.maxScrollExtent -
                _employeeChatScrollController.position.pixels) <
            100;

    if (convChanged || (grew && (nearBottom || messages.length <= 2))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_employeeChatScrollController.hasClients) return;
        _employeeChatScrollController.jumpTo(
          _employeeChatScrollController.position.maxScrollExtent,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<String?>>(activeFacilityIdProvider, (prev, next) {
      if (!mounted) return;
      final activeId = next.whenOrNull(data: (d) => d);
      final wantedFacilityId = activeId == null ? 'all' : activeId;
      if (wantedFacilityId != widget.facilityId) {
        context.go('/messaging?facilityId=$wantedFacilityId');
      }
    });

    if (_loadingPermissions) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_canViewConversations) {
      return Center(
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
      );
    }

    return Consumer(
      builder: (context, ref, child) {
        // Pre-watch the message history provider to keep stream active
        ref.watch(tenantMessageHistoryProvider(widget.facilityId));
        return Column(
          children: [
            // Facility selector header
            _buildFacilitySelector(),
            // Tabs — single horizontal row; scroll on narrow screens so labels stay horizontal
            Builder(
              builder: (context) {
                final cs = Theme.of(context).colorScheme;
                final width = MediaQuery.of(context).size.width;
                final isPhone = Breakpoints.isPhone(width);
                final tabs = [
                  _buildTab(0, isPhone ? 'Chat' : 'Employee Chat', Icons.chat_bubble_outline, isPhone),
                  _buildTab(1, isPhone ? 'Bulk' : 'Bulk Messaging', Icons.message_outlined, isPhone),
                  _buildTab(2, 'Email', Icons.email_outlined, isPhone),
                  _buildTab(3, 'SMS', Icons.sms, isPhone),
                  _buildTab(4, isPhone ? 'History' : 'Message History', Icons.history, isPhone),
                ];
                return Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    border: Border(
                      bottom: BorderSide(color: cs.outline),
                    ),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(horizontal: isPhone ? 4 : 8, vertical: isPhone ? 4 : 0),
                    child: Row(children: tabs),
                  ),
                );
              },
            ),
          
          // Content based on selected tab (when "All Facilities" is selected, Bulk Messaging and Message History work)
          Expanded(
            child: widget.facilityId == 'all' && _selectedTab != 1 && _selectedTab != 4
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Select a specific facility from the dropdown above to use Employee Chat, Email, or SMS.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  )
                : _selectedTab == 1
                    ? _buildBulkMessagingTab()
                    : _selectedTab == 2
                        ? _buildEmailTab()
                        : _selectedTab == 4
                            ? _buildMessageHistoryTab()
                            : LayoutBuilder(
                                builder: (context, constraints) {
                                  final isPhone = constraints.maxWidth < Breakpoints.xs;
                                  if (isPhone) {
                                    // Mobile: stack — list OR messages; Employee Chat also has Team notes segment.
                                    final hasSelection = _selectedConversationId != null;
                                    return Column(
                                      children: [
                                        if (_selectedTab == 0 && !hasSelection)
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                                            child: SizedBox(
                                              width: double.infinity,
                                              child: SegmentedButton<int>(
                                                segments: const [
                                                  ButtonSegment<int>(
                                                    value: 0,
                                                    label: Text('Chats'),
                                                    icon: Icon(Icons.chat_bubble_outline),
                                                  ),
                                                  ButtonSegment<int>(
                                                    value: 1,
                                                    label: Text('Team notes'),
                                                    icon: Icon(Icons.note_alt_outlined),
                                                  ),
                                                ],
                                                selected: {_phoneChatNotesSegment},
                                                onSelectionChanged: (Set<int> selection) {
                                                  setState(() => _phoneChatNotesSegment = selection.first);
                                                },
                                              ),
                                            ),
                                          ),
                                        if (hasSelection)
                                          _buildMobileBackBar()
                                        else
                                          const SizedBox.shrink(),
                                        Expanded(
                                          child: _selectedTab == 0 &&
                                                  !hasSelection &&
                                                  _phoneChatNotesSegment == 1
                                              ? TeamNotesPanel(
                                                  facilityId: widget.facilityId,
                                                  compact: true,
                                                )
                                              : hasSelection
                                                  ? (_selectedTab == 0
                                                      ? _buildMessagesPane()
                                                      : _buildSMSMessagesPane())
                                                  : (_selectedTab == 0
                                                      ? _buildConversationsList()
                                                      : _buildSMSConversationsList()),
                                        ),
                                      ],
                                    );
                                  }
                                  return Row(
                                    children: [
                                      Expanded(
                                        flex: 2,
                                        child: _selectedTab == 0
                                            ? _buildConversationsList()
                                            : _buildSMSConversationsList(),
                                      ),
                                      Expanded(
                                        flex: 5,
                                        child: _selectedTab == 0
                                            ? (_selectedConversationId != null
                                                ? _buildMessagesPane()
                                                : _buildNoConversationSelected())
                                            : (_selectedConversationId != null
                                                ? _buildSMSMessagesPane()
                                                : _buildNoConversationSelected()),
                                      ),
                                    ],
                                  );
                                },
                              ),
          ),
          ],
        );
      },
    );
  }

  Widget _buildMobileBackBar() {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      child: InkWell(
        onTap: () => setState(() => _selectedConversationId = null),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.arrow_back, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                'Back to list',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openTeamNotesDialog() {
    if (widget.facilityId.isEmpty || widget.facilityId == 'all') return;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;
        final tt = theme.textTheme;
        return Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 420,
            height: 580,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  color: cs.surfaceContainerHighest,
                  child: ListTile(
                    leading: Icon(Icons.note_alt_outlined, color: cs.primary),
                    title: Text(
                      'Team notes',
                      style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      'Shared with everyone at this facility.',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                ),
                Divider(height: 1, color: cs.outline),
                Expanded(
                  child: TeamNotesPanel(
                    facilityId: widget.facilityId,
                    compact: true,
                    showHeader: false,
                    showTrailingBorder: false,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildConversationsList() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: cs.outline),
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
              color: cs.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(color: cs.outline),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Conversations',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Team notes',
                  icon: const Icon(Icons.note_alt_outlined),
                  onPressed: (widget.facilityId.isEmpty || widget.facilityId == 'all')
                      ? null
                      : _openTeamNotesDialog,
                ),
                IconButton(
                  tooltip: 'Your chat display name',
                  icon: const Icon(Icons.badge_outlined),
                  onPressed: (widget.facilityId.isEmpty || widget.facilityId == 'all')
                      ? null
                      : () {
                          final uid = FirebaseAuth.instance.currentUser?.uid;
                          if (uid == null) return;
                          _promptEmployeeChatDisplayName(
                            targetUserId: uid,
                            title: 'Your chat display name',
                            subtitle:
                                'Teammates see this in employee chat for this facility. Clear the field and tap Remove to use email or a default label.',
                          );
                        },
                ),
              ],
            ),
          ),
          if (_canManageConversations)
            Material(
              color: cs.surfaceContainerLow,
              child: LayoutBuilder(
                builder: (context, box) {
                  final stackActions = box.maxWidth < 340;
                  final direct = FilledButton.icon(
                    onPressed: _showNewPrivateMessageDialog,
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                    label: const Text('Direct message'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: AppTheme.textOnDark,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  );
                  final group = OutlinedButton.icon(
                    onPressed: _showCreateConversationDialog,
                    icon: const Icon(Icons.group_add_outlined, size: 18),
                    label: const Text('New group'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  );
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: stackActions
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              direct,
                              const SizedBox(height: 8),
                              group,
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: direct),
                              const SizedBox(width: 8),
                              Expanded(child: group),
                            ],
                          ),
                  );
                },
              ),
            ),
          Expanded(
            child: Consumer(
              builder: (context, ref, child) {
                return ref.watch(conversationsProvider(widget.facilityId)).when(
                  data: (conversations) {
                    final chatNames = ref
                        .watch(employeeChatNamesProvider(widget.facilityId))
                        .maybeWhen(
                          data: (m) => m,
                          orElse: () => <String, String>{},
                        );
                    // On phone, keep conversation list visible first (team notes + pick chat).
                    // Desktop: auto-open first conversation.
                    if (_selectedConversationId == null && conversations.isNotEmpty) {
                      final isPhone = MediaQuery.sizeOf(context).width < Breakpoints.xs;
                      if (!isPhone) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          if (_selectedConversationId == null) {
                            setState(() {
                              _selectedConversationId = conversations.first.id;
                            });
                          }
                        });
                      }
                    }

                    if (conversations.isEmpty) {
                      return Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.chat_bubble_outline,
                                size: 48,
                                color: AppTheme.textTertiary,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No conversations yet',
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _canManageConversations
                                    ? 'Use the buttons above to start a chat.'
                                    : 'You’ll see chats here when someone adds you.',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        final isSelected = conversation.id == _selectedConversationId;
                        final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
                        
                        final displayTitle = conversation.displayTitleForViewer(
                          currentUserId,
                          employeeChatNamesByUid: chatNames,
                        );
                        final cs = Theme.of(context).colorScheme;
                        Widget leadingIcon = CircleAvatar(
                          backgroundColor: isSelected ? cs.primary : cs.outline,
                          child: Icon(
                            conversation.isPrivate ? Icons.person : Icons.chat_bubble,
                            color: isSelected ? cs.onPrimary : cs.onSurfaceVariant,
                          ),
                        );

                        if (conversation.isPrivate) {
                          final initial = displayTitle.isEmpty
                              ? '?'
                              : String.fromCharCode(displayTitle.runes.first)
                                  .toUpperCase();
                          leadingIcon = CircleAvatar(
                            backgroundColor: isSelected ? cs.primary : cs.outline,
                            child: Text(
                              initial,
                              style: TextStyle(
                                color: isSelected ? cs.onPrimary : cs.onSurfaceVariant,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          );
                        }
                        
                        return ListTile(
                          selected: isSelected,
                          selectedTileColor: cs.primary.withOpacity(0.1),
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              const SizedBox(height: 2),
                              Text(
                                conversation.lastMessageAt != null
                                    ? _formatTime(conversation.lastMessageAt!)
                                    : _formatTime(conversation.createdAt),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final chatNames = ref.watch(employeeChatNamesProvider(widget.facilityId)).maybeWhen(
          data: (m) => m,
          orElse: () => <String, String>{},
        );

    ConversationModel? selectedConv;
    final conversationTitle = ref.watch(conversationsProvider(widget.facilityId)).maybeWhen(
          data: (conversations) {
            for (final conversation in conversations) {
              if (conversation.id == _selectedConversationId) {
                selectedConv = conversation;
                return conversation.displayTitleForViewer(
                  uid,
                  employeeChatNamesByUid: chatNames,
                );
              }
            }
            return 'Conversation';
          },
          orElse: () => 'Conversation',
        );

    final otherUid = selectedConv != null &&
            selectedConv!.isPrivate &&
            uid.isNotEmpty
        ? selectedConv!.getOtherParticipantUid(uid)
        : null;

    return Column(
      children: [
        // Messages header (match conversation list chrome)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.chat_bubble_outline, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  conversationTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (_selectedConversationId != null &&
                  widget.facilityId.isNotEmpty &&
                  widget.facilityId != 'all')
                PopupMenuButton<String>(
                  tooltip: 'Chat display names',
                  onSelected: (value) async {
                    if (value == 'self') {
                      final self = FirebaseAuth.instance.currentUser?.uid;
                      if (self == null) return;
                      await _promptEmployeeChatDisplayName(
                        targetUserId: self,
                        title: 'Your chat display name',
                        subtitle:
                            'Teammates see this in employee chat for this facility.',
                      );
                    } else if (value == 'other' && otherUid != null && otherUid.isNotEmpty) {
                      await _promptEmployeeChatDisplayName(
                        targetUserId: otherUid,
                        title: 'Teammate chat display name',
                        subtitle:
                            'Shown to everyone at this facility in employee chat.',
                      );
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'self',
                      child: Text('Your chat display name…'),
                    ),
                    if (otherUid != null &&
                        otherUid.isNotEmpty &&
                        _canManageUsersForFacility)
                      const PopupMenuItem(
                        value: 'other',
                        child: Text('Set teammate chat name…'),
                      ),
                  ],
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

                  _scheduleEmployeeChatScrollToEnd(messages);

                  return ListView.builder(
                    controller: _employeeChatScrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
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
              top: BorderSide(color: Theme.of(context).colorScheme.outline),
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
                      focusNode: _messageInputFocusNode,
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
    final chatNames = ref.watch(employeeChatNamesProvider(widget.facilityId)).maybeWhen(
          data: (m) => m,
          orElse: () => <String, String>{},
        );
    final nick = chatNames[message.senderUid]?.trim();
    final senderLabel =
        (nick != null && nick.isNotEmpty) ? nick : message.senderName;

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
                senderLabel.isNotEmpty
                    ? String.fromCharCode(senderLabel.runes.first).toUpperCase()
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
                      senderLabel,
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
                senderLabel.isNotEmpty
                    ? String.fromCharCode(senderLabel.runes.first).toUpperCase()
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
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _messageInputFocusNode.requestFocus();
          }
        });
      }
    }
  }

  void _archiveConversation(ConversationModel conversation) async {
    if (!_canManageConversations) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive Conversation'),
        content: Text('Archive "${_conversationDisplayTitle(conversation)}"?'),
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
                SnackBar(
                    content: Text(
                        'Conversation "${_conversationDisplayTitle(conversation)}" archived')),
      );
    }
  }

  void _deleteConversation(ConversationModel conversation) async {
    if (!_canManageConversations) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: Text(
            'Permanently delete "${_conversationDisplayTitle(conversation)}" and all its messages?'),
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
        SnackBar(
            content: Text(
                'Conversation "${_conversationDisplayTitle(conversation)}" deleted')),
      );
    }
  }

  Widget _buildFacilitySelector() {
    return Consumer(
      builder: (context, ref, child) {
        final authState = ref.watch(authStateProvider);
        return authState.when(
          data: (user) {
            if (user == null) return const SizedBox.shrink();
            final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
            return facilitiesAsync.when(
              data: (facilities) {
                if (facilities.isEmpty) return const SizedBox.shrink();
                final width = MediaQuery.of(context).size.width;
                final isPhone = Breakpoints.isPhone(width);
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundLight,
                    border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
                  ),
                  child: Row(
                    children: [
                      if (!isPhone) ...[
                        const Icon(Icons.business, color: AppTheme.primaryBlue),
                        const SizedBox(width: 8),
                        Text(
                          'Facility:',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: (widget.facilityId.isEmpty || widget.facilityId == 'all') ? 'all' : widget.facilityId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            isDense: true,
                          ),
                          selectedItemBuilder: (context) {
                            final style = AppTheme.dropdownItemTextStyle.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                            );
                            return [
                              Text(
                                'All Facilities',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: style,
                              ),
                              ...facilities.map((f) => Text(
                                f.name,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: style,
                              )),
                            ];
                          },
                          items: [
                            DropdownMenuItem<String>(
                              value: 'all',
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'All Facilities',
                                  style: AppTheme.dropdownItemTextStyle,
                                  softWrap: true,
                                ),
                              ),
                            ),
                            ...facilities.map((facility) {
                              return DropdownMenuItem<String>(
                                value: facility.id,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(
                                    facility.name,
                                    style: AppTheme.dropdownItemTextStyle,
                                    softWrap: true,
                                  ),
                                ),
                              );
                            }),
                          ],
                          onChanged: (value) {
                            if (value != null && value != widget.facilityId) {
                              ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(
                                value == 'all' ? null : value,
                              );
                              context.go('/messaging?facilityId=$value');
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
              loading: () => Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: const LinearProgressIndicator(),
              ),
              error: (_, __) => const SizedBox.shrink(),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildTab(int index, String label, IconData icon, [bool isPhone = false]) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = _selectedTab == index;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedTab = index;
          _selectedConversationId = null;
        });
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: isPhone ? 12 : 16,
          horizontal: isPhone ? 12 : 24,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? cs.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? cs.primary : cs.onSurfaceVariant,
              size: isPhone ? 18 : 20,
            ),
            SizedBox(width: isPhone ? 6 : 8),
            Text(
              label,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: isSelected ? cs.primary : cs.onSurfaceVariant,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: isPhone ? 13 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSMSConversationsList() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: cs.outline),
        ),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final isPhone = constraints.maxWidth < Breakpoints.xs;
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  border: Border(
                    bottom: BorderSide(color: cs.outline),
                  ),
                ),
                child: isPhone
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.sms),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'SMS Conversations',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _showSendSMSDialog,
                              icon: const Icon(Icons.send, size: 18),
                              label: const Text('Send SMS'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          const Icon(Icons.sms),
                          const SizedBox(width: 8),
                          Text(
                            'SMS Conversations',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          ElevatedButton.icon(
                            onPressed: _showSendSMSDialog,
                            icon: const Icon(Icons.send, size: 18),
                            label: const Text('Send SMS'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            ),
                          ),
                        ],
                      ),
              );
            },
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
                        
                        final csTile = Theme.of(context).colorScheme;
                        return ListTile(
                          selected: isSelected,
                          selectedTileColor: csTile.primary.withOpacity(0.1),
                          leading: CircleAvatar(
                            backgroundColor: isSelected ? csTile.primary : csTile.outline,
                            child: Icon(
                              Icons.sms,
                              color: isSelected ? csTile.onPrimary : csTile.onSurfaceVariant,
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
                                  color: csTile.onSurfaceVariant,
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
                                  color: csTile.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          trailing: conversation.unreadCount > 0
                              ? Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: csTile.primary,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '${conversation.unreadCount}',
                                    style: TextStyle(
                                      color: csTile.onPrimary,
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
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H5',
      location: 'messaging_screen.dart:_showSendSMSDialog',
      message: 'Show send SMS dialog called',
      data: {'facilityId': widget.facilityId},
    );
    // #endregion
    
    showDialog(
      context: context,
      builder: (context) => _SendSMSDialog(
        facilityId: widget.facilityId,
        onSent: () {
          // #region agent log
          DebugLogger.log(
            hypothesisId: 'H5',
            location: 'messaging_screen.dart:_showSendSMSDialog:onSent',
            message: 'SMS sent, refreshing providers',
            data: {},
          );
          // #endregion
          
          // Refresh SMS conversations after sending (message history will update automatically via stream)
          ref.invalidate(smsConversationsProvider(widget.facilityId));
        },
      ),
    );
  }

  Widget _buildMessageHistoryTab() {
    return Consumer(
      builder: (context, ref, child) {
        // Watch the provider to ensure stream stays active
        final messagesAsync = ref.watch(tenantMessageHistoryProvider(widget.facilityId));
        
        return messagesAsync.when(
          data: (messages) {
            // Debug: Log when data updates
            if (kDebugMode) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                print('📊 [MessageHistory] UI updated with ${messages.length} messages');
              });
            }
            if (messages.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.history, size: 64, color: AppTheme.textTertiary),
                    const SizedBox(height: 16),
                    Text(
                      'No message history',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Messages sent to tenants will appear here.',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }

            // Apply filters
            final filteredMessages = _applyFilters(messages);
            
            return Column(
              children: [
                // Header with count and actions
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isPhone = constraints.maxWidth < Breakpoints.xs;
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.backgroundLight,
                        border: Border(
                          bottom: BorderSide(color: AppTheme.borderLight),
                        ),
                      ),
                      child: isPhone
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.history, color: AppTheme.primaryBlue),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Message History',
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${filteredMessages.length} of ${messages.length} messages',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    IconButton(
                                      onPressed: () {
                                        ref.invalidate(tenantMessageHistoryProvider(widget.facilityId));
                                      },
                                      icon: const Icon(Icons.refresh),
                                      tooltip: 'Refresh',
                                    ),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: _showSendSMSDialog,
                                        icon: const Icon(Icons.send, size: 18),
                                        label: const Text('Send SMS'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppTheme.primaryBlue,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                const Icon(Icons.history, color: AppTheme.primaryBlue),
                                const SizedBox(width: 8),
                                Text(
                                  'Message History',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${filteredMessages.length} of ${messages.length} messages',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                IconButton(
                                  onPressed: () {
                                    ref.invalidate(tenantMessageHistoryProvider(widget.facilityId));
                                  },
                                  icon: const Icon(Icons.refresh),
                                  tooltip: 'Refresh message history',
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  onPressed: _showSendSMSDialog,
                                  icon: const Icon(Icons.send, size: 18),
                                  label: const Text('Send SMS'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryBlue,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  ),
                                ),
                              ],
                            ),
                    );
                  },
                ),
                
                // Filters: collapsed by default on phone so the message list stays visible
                Builder(
                  builder: (context) {
                    final isPhone = MediaQuery.sizeOf(context).width < Breakpoints.xs;
                    if (isPhone) {
                      return Material(
                        color: AppTheme.backgroundLight,
                        child: ExpansionTile(
                          initiallyExpanded: false,
                          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          title: Text(
                            'Search & filters',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          children: [
                            _buildMessageHistoryFilters(ref, showFiltersHeading: false),
                          ],
                        ),
                      );
                    }
                    return _buildMessageHistoryFilters(ref);
                  },
                ),
                
                // Messages list
                Expanded(
                  child: filteredMessages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.filter_alt_off, size: 64, color: AppTheme.textTertiary),
                              const SizedBox(height: 16),
                              Text(
                                'No messages match your filters',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _selectedTenantId = null;
                                    _selectedMessageType = null;
                                    _selectedStatus = null;
                                    _startDate = null;
                                    _endDate = null;
                                    _searchController.clear();
                                  });
                                },
                                child: const Text('Clear all filters'),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: filteredMessages.length,
                          itemBuilder: (context, index) {
                            final message = filteredMessages[index];
                            return _buildMessageHistoryItem(message);
                          },
                        ),
                ),
              ],
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
                    'Error loading message history',
                    style: TextStyle(color: AppTheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error.toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      ref.invalidate(tenantMessageHistoryProvider(widget.facilityId));
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBulkMessagingTab() {
    final isAllFacilities = widget.facilityId == 'all';
    final tenantsKey = isAllFacilities ? 'all' : widget.facilityId;
    return BulkMessagingScreen(
      facilityId: isAllFacilities ? '' : widget.facilityId,
      tenantsKey: tenantsKey,
      allFacilities: isAllFacilities,
    );
  }

  Widget _buildEmailTab() {
    return EmailCompositionWidget(facilityId: widget.facilityId);
  }

  List<TenantMessageHistoryModel> _applyFilters(List<TenantMessageHistoryModel> messages) {
    var filtered = messages;
    
    // Filter by tenant
    if (_selectedTenantId != null) {
      filtered = filtered.where((m) => m.tenantId == _selectedTenantId).toList();
    }
    
    // Filter by message type
    if (_selectedMessageType != null) {
      filtered = filtered.where((m) => m.type == _selectedMessageType).toList();
    }
    
    // Filter by status
    if (_selectedStatus != null) {
      filtered = filtered.where((m) => m.status == _selectedStatus).toList();
    }
    
    // Filter by date range
    if (_startDate != null) {
      filtered = filtered.where((m) => m.sentAt.isAfter(_startDate!) || m.sentAt.isAtSameMomentAs(_startDate!)).toList();
    }
    if (_endDate != null) {
      final endDate = DateTime(_endDate!.year, _endDate!.month, _endDate!.day, 23, 59, 59);
      filtered = filtered.where((m) => m.sentAt.isBefore(endDate) || m.sentAt.isAtSameMomentAs(endDate)).toList();
    }
    
    // Filter by search text
    final searchText = _searchController.text.toLowerCase().trim();
    if (searchText.isNotEmpty) {
      filtered = filtered.where((m) {
        return (m.title.toLowerCase().contains(searchText) ||
                m.message.toLowerCase().contains(searchText) ||
                (m.tenantName?.toLowerCase().contains(searchText) ?? false) ||
                (m.tenantEmail?.toLowerCase().contains(searchText) ?? false) ||
                (m.tenantPhone?.toLowerCase().contains(searchText) ?? false));
      }).toList();
    }
    
    return filtered;
  }

  Widget _buildMessageHistoryFilters(WidgetRef ref, {bool showFiltersHeading = true}) {
    final isAllFacilities = widget.facilityId == 'all' || widget.facilityId.isEmpty;
    final tenantsAsync = isAllFacilities
        ? ref.watch(multiFacilityTenantsProvider('all'))
        : ref.watch(facilityTenantsProvider(widget.facilityId));
    final screenW = MediaQuery.sizeOf(context).width;
    final isMobile = screenW < 900;
    final isPhone = Breakpoints.isPhone(screenW);
    final fieldComfort = isPhone; // roomier labels on small screens
    final filterFieldPadding = fieldComfort
        ? const EdgeInsets.fromLTRB(12, 20, 12, 14)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 8);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        isMobile ? 12 : 16,
        showFiltersHeading ? (isMobile ? 12 : 16) : 8,
        isMobile ? 12 : 16,
        isMobile ? 12 : 16,
      ),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderLight),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showFiltersHeading)
            LayoutBuilder(
              builder: (context, constraints) {
                final filtersRowNarrow = constraints.maxWidth < 400;
                final hasFilters = _selectedTenantId != null ||
                    _selectedMessageType != null ||
                    _selectedStatus != null ||
                    _startDate != null ||
                    _endDate != null ||
                    _searchController.text.isNotEmpty;
                return filtersRowNarrow
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.filter_list, size: 20, color: AppTheme.primaryBlue),
                              const SizedBox(width: 8),
                              Text(
                                'Filters',
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          if (hasFilters) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _selectedTenantId = null;
                                  _selectedMessageType = null;
                                  _selectedStatus = null;
                                  _startDate = null;
                                  _endDate = null;
                                  _searchController.clear();
                                });
                              },
                              icon: const Icon(Icons.clear, size: 16),
                              label: const Text('Clear'),
                            ),
                          ],
                        ],
                      )
                    : Row(
                        children: [
                          const Icon(Icons.filter_list, size: 20, color: AppTheme.primaryBlue),
                          const SizedBox(width: 8),
                          Text(
                            'Filters',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (hasFilters)
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _selectedTenantId = null;
                                  _selectedMessageType = null;
                                  _selectedStatus = null;
                                  _startDate = null;
                                  _endDate = null;
                                  _searchController.clear();
                                });
                              },
                              icon: const Icon(Icons.clear, size: 16),
                              label: const Text('Clear'),
                            ),
                        ],
                      );
              },
            ),
          if (showFiltersHeading) const SizedBox(height: 12),
          if (!showFiltersHeading)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    _selectedTenantId = null;
                    _selectedMessageType = null;
                    _selectedStatus = null;
                    _startDate = null;
                    _endDate = null;
                    _searchController.clear();
                  });
                },
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('Clear filters'),
              ),
            ),
          Wrap(
            spacing: isMobile ? 8 : 12,
            runSpacing: isMobile ? 8 : 12,
            children: [
              // Search text filter
              SizedBox(
                width: isMobile ? double.infinity : 250,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search messages...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              setState(() {
                                _searchController.clear();
                              });
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: filterFieldPadding,
                    isDense: !fieldComfort,
                  ),
                  onChanged: (value) => setState(() {}),
                ),
              ),
              
              // Tenant filter
              SizedBox(
                width: isMobile ? double.infinity : 200,
                child: tenantsAsync.when(
                  data: (tenants) => DropdownButtonFormField<String>(
                    value: _selectedTenantId,
                    decoration: InputDecoration(
                      labelText: 'Tenant',
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: filterFieldPadding,
                      isDense: !fieldComfort,
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('All Tenants'),
                      ),
                      ...tenants.map((tenant) => DropdownMenuItem<String>(
                        value: tenant.id,
                        child: Text(tenant.name, overflow: TextOverflow.ellipsis),
                      )),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedTenantId = value;
                      });
                    },
                  ),
                  loading: () => SizedBox(
                    width: isMobile ? double.infinity : 200,
                    height: 40,
                    child: const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                  ),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ),
              
              // Message type filter
              SizedBox(
                width: isMobile ? double.infinity : 150,
                child: DropdownButtonFormField<TenantMessageType?>(
                  value: _selectedMessageType,
                  decoration: InputDecoration(
                    labelText: 'Type',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: filterFieldPadding,
                    isDense: !fieldComfort,
                  ),
                  items: const [
                    DropdownMenuItem<TenantMessageType?>(
                      value: null,
                      child: Text('All Types'),
                    ),
                    DropdownMenuItem<TenantMessageType?>(
                      value: TenantMessageType.email,
                      child: Text('Email'),
                    ),
                    DropdownMenuItem<TenantMessageType?>(
                      value: TenantMessageType.sms,
                      child: Text('SMS'),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedMessageType = value;
                    });
                  },
                ),
              ),
              
              // Status filter
              SizedBox(
                width: isMobile ? double.infinity : 150,
                child: DropdownButtonFormField<TenantMessageStatus?>(
                  value: _selectedStatus,
                  decoration: InputDecoration(
                    labelText: 'Status',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: filterFieldPadding,
                    isDense: !fieldComfort,
                  ),
                  items: const [
                    DropdownMenuItem<TenantMessageStatus?>(
                      value: null,
                      child: Text('All Statuses'),
                    ),
                    DropdownMenuItem<TenantMessageStatus?>(
                      value: TenantMessageStatus.pending,
                      child: Text('Pending'),
                    ),
                    DropdownMenuItem<TenantMessageStatus?>(
                      value: TenantMessageStatus.sent,
                      child: Text('Sent'),
                    ),
                    DropdownMenuItem<TenantMessageStatus?>(
                      value: TenantMessageStatus.delivered,
                      child: Text('Delivered'),
                    ),
                    DropdownMenuItem<TenantMessageStatus?>(
                      value: TenantMessageStatus.failed,
                      child: Text('Failed'),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedStatus = value;
                    });
                  },
                ),
              ),
              
              // Date range filters
              SizedBox(
                width: isMobile ? double.infinity : 150,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _startDate ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() {
                        _startDate = date;
                      });
                    }
                  },
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_startDate == null 
                      ? 'Start Date' 
                      : '${_startDate!.month}/${_startDate!.day}/${_startDate!.year}'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ),
              
              SizedBox(
                width: isMobile ? double.infinity : 150,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _endDate ?? DateTime.now(),
                      firstDate: _startDate ?? DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() {
                        _endDate = date;
                      });
                    }
                  },
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_endDate == null 
                      ? 'End Date' 
                      : '${_endDate!.month}/${_endDate!.day}/${_endDate!.year}'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMessageHistoryItem(TenantMessageHistoryModel message) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: Type, Status, Date
            Row(
              children: [
                // Message type icon
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: message.type == TenantMessageType.sms
                        ? AppTheme.primaryBlue.withOpacity(0.1)
                        : AppTheme.success.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        message.type == TenantMessageType.sms
                            ? Icons.sms
                            : Icons.notifications,
                        size: 16,
                        color: message.type == TenantMessageType.sms
                            ? AppTheme.primaryBlue
                            : AppTheme.success,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        message.type.displayName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: message.type == TenantMessageType.sms
                              ? AppTheme.primaryBlue
                              : AppTheme.success,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getStatusColor(message.status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    message.status.displayName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _getStatusColor(message.status),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Date
                Text(
                  _formatTime(message.sentAt),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            
            // Tenant name
            if (message.tenantName != null) ...[
              Row(
                children: [
                  const Icon(Icons.person, size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    message.tenantName!,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            
            // Title
            Text(
              message.title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            
            // Message content
            Text(
              message.message,
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            
            // Channels and metadata
            if (message.channels.isNotEmpty || message.tenantPhone != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  // Channels
                  ...message.channels.map((channel) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundSecondary,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      channel.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  )),
                  // Phone number
                  if (message.tenantPhone != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.phone, size: 12, color: AppTheme.textSecondary),
                        const SizedBox(width: 2),
                        Text(
                          message.tenantPhone!,
                          style: TextStyle(
                            fontSize: 10,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(TenantMessageStatus status) {
    switch (status) {
      case TenantMessageStatus.pending:
        return const Color(0xFFFF9800); // Orange
      case TenantMessageStatus.sent:
        return const Color(0xFF2196F3); // Blue
      case TenantMessageStatus.delivered:
        return const Color(0xFF4CAF50); // Green
      case TenantMessageStatus.failed:
        return const Color(0xFFF44336); // Red
    }
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
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
    }
  }
}

class _QuickSmsTemplate {
  final String label;
  final String body;

  const _QuickSmsTemplate({
    required this.label,
    required this.body,
  });
}

/// Short SMS starters; placeholders: {{tenant_name}}, {{name}}, {{first_name}}, {{unit}}, {{email}}, {{phone}}.
const List<_QuickSmsTemplate> _kQuickSmsTemplates = [
  _QuickSmsTemplate(
    label: 'Payment reminder',
    body:
        'Hi {{first_name}}, friendly reminder: your storage rent is due soon. Reply with any questions.',
  ),
  _QuickSmsTemplate(
    label: 'Past due',
    body:
        '{{first_name}}, we show a past-due balance for unit {{unit}}. Please contact us to arrange payment. Thank you.',
  ),
  _QuickSmsTemplate(
    label: 'Thank you',
    body: 'Thanks {{first_name}}! We appreciate your business.',
  ),
  _QuickSmsTemplate(
    label: 'Please call',
    body:
        'Hi {{first_name}}, please call us about your storage account when you can. Thank you.',
  ),
  _QuickSmsTemplate(
    label: 'Quick hello',
    body: 'Hi {{first_name}}, this is a message from the storage office.',
  ),
];

String _interpolateSmsTemplate(String template, TenantModel t) {
  final n = t.name.trim();
  final first = n.isEmpty ? 'there' : n.split(RegExp(r'\s+')).first;
  return template
      .replaceAll('{{tenant_name}}', t.name)
      .replaceAll('{{name}}', t.name)
      .replaceAll('{{first_name}}', first)
      .replaceAll('{{unit}}', t.unitNumber)
      .replaceAll('{{email}}', t.email)
      .replaceAll('{{phone}}', t.phone);
}

String _personalizeRenterGreeting(String body, TenantModel tenant) {
  final n = tenant.name.trim();
  final first = n.isEmpty ? 'there' : n.split(RegExp(r'\s+')).first;
  if (body.startsWith('Hi,\n\n')) {
    return body.replaceFirst('Hi,\n\n', 'Hi $first,\n\n');
  }
  return body;
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
  bool _loadingRenterTemplate = false;

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
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H5',
      location: 'messaging_screen.dart:_SendSMSDialog:_loadTenants',
      message: 'Loading tenants for facility',
      data: {'facilityId': widget.facilityId},
    );
    // #endregion
    
    try {
      final tenants = await TenantService.getTenantsForFacility(widget.facilityId);
      
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'messaging_screen.dart:_SendSMSDialog:_loadTenants',
        message: 'Tenants loaded',
        data: {'totalTenants': tenants.length, 'tenantsWithPhone': tenants.where((t) => t.isActive && t.phone.isNotEmpty).length},
      );
      // #endregion
      
      setState(() {
        _allTenants = tenants.where((t) => t.isActive && t.phone.isNotEmpty).toList();
        _filteredTenants = _allTenants;
      });
    } catch (e) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'messaging_screen.dart:_SendSMSDialog:_loadTenants',
        message: 'Error loading tenants',
        data: {'error': e.toString()},
      );
      // #endregion
      
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

  void _applyQuickSmsTemplate(_QuickSmsTemplate template) {
    if (_selectedTenantId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a tenant first'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    TenantModel? tenant;
    for (final t in _allTenants) {
      if (t.id == _selectedTenantId) {
        tenant = t;
        break;
      }
    }

    if (tenant == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load tenant'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final resolved = tenant;
    setState(() {
      _messageController.text = _interpolateSmsTemplate(template.body, resolved);
    });
  }

  Future<void> _applyRenterLinksTemplate() async {
    if (_selectedTenantId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a tenant first'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    TenantModel? tenant;
    for (final t in _allTenants) {
      if (t.id == _selectedTenantId) {
        tenant = t;
        break;
      }
    }

    if (tenant == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load tenant'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final resolved = tenant;
    setState(() {
      _loadingRenterTemplate = true;
    });
    try {
      var body =
          await buildRenterAccountMessageForFacilityId(widget.facilityId);
      body = _personalizeRenterGreeting(body, resolved);
      if (!mounted) return;
      setState(() {
        _messageController.text = body;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Replace [AMOUNT] and [PAYMENT_LINK] (create pay link under Payment Links).',
          ),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load rent links: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingRenterTemplate = false;
        });
      }
    }
  }

  Future<void> _sendSMS() async {
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H5',
      location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
      message: 'Send SMS initiated',
      data: {'selectedTenantId': _selectedTenantId, 'messageLength': _messageController.text.length},
    );
    // #endregion
    
    if (_selectedTenantId == null) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
        message: 'Validation failed - no tenant selected',
        data: {},
      );
      // #endregion
      
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
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
        message: 'Validation failed - empty message',
        data: {},
      );
      // #endregion
      
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
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
        message: 'Validation failed - tenant has no phone',
        data: {'tenantId': tenant.id, 'tenantName': tenant.name},
      );
      // #endregion
      
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
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
        message: 'Calling SMSService.sendSMS',
        data: {'to': tenant.phone, 'facilityId': widget.facilityId, 'tenantId': tenant.id, 'messageLength': message.length},
      );
      // #endregion
      
      final result = await SMSService.sendSMS(
        to: tenant.phone,
        message: message,
        facilityId: widget.facilityId,
        tenantId: tenant.id,
        relatedEntityType: 'direct_sms',
      );

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
        message: 'SMS send result received',
        data: {'success': result.success, 'twilioStatus': result.twilioStatus, 'messageId': result.messageId},
      );
      // #endregion

      if (result.success) {
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H5',
          location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
          message: 'SMS sent successfully',
          data: {'twilioStatus': result.twilioStatus, 'statusMessage': result.statusMessage},
        );
        // #endregion
        
        if (mounted) {
          // Show status message if available (e.g., "queued" status with campaign approval info)
          final statusMsg = result.statusMessage ?? 'SMS sent successfully';
          final backgroundColor = result.twilioStatus == 'queued' 
              ? AppTheme.warning 
              : AppTheme.success;
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(statusMsg),
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
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H5',
          location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
          message: 'SMS send failed',
          data: {'error': result.error},
        );
        // #endregion
        
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
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'messaging_screen.dart:_SendSMSDialog:_sendSMS',
        message: 'Exception during SMS send',
        data: {'error': e.toString()},
      );
      // #endregion
      
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
            
            Text(
              'Quick messages',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap to fill the box below. Short templates use the selected tenant. '
              'Rent & portal loads your online rent URL and tenant portal for this facility.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ..._kQuickSmsTemplates.map((t) {
                  return ActionChip(
                    label: Text(t.label),
                    onPressed: (_isSending || _loadingRenterTemplate)
                        ? null
                        : () => _applyQuickSmsTemplate(t),
                  );
                }),
                ActionChip(
                  avatar: _loadingRenterTemplate
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link, size: 18),
                  label: const Text('Rent & portal'),
                  onPressed: (_isSending || _loadingRenterTemplate)
                      ? null
                      : _applyRenterLinksTemplate,
                ),
              ],
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
              maxLines: 10,
              minLines: 4,
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
  List<_UserWithProfile> _allWithProfiles = [];
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
      final chatNames = await MessagingService.getEmployeeChatNamesMap(widget.facilityId);

      // Load user profiles and filter out current user
      final usersWithProfiles = <_UserWithProfile>[];
      for (final userRole in userRoles) {
        // Skip current user (can't message yourself)
        if (userRole.userId == currentUser.uid) continue;

        final chatName = chatNames[userRole.userId]?.trim();
        final profile = await PermissionService.getUserProfile(userRole.userId);
        final rawEmail = (profile?['email'] as String?)?.trim() ?? '';
        final email = rawEmail.contains('@') ? rawEmail : '';
        var displayName = (chatName != null && chatName.isNotEmpty)
            ? chatName
            : (profile?['displayName'] as String?)?.trim() ?? '';
        if (displayName.isEmpty) {
          if (email.isNotEmpty) {
            displayName = email.split('@').first.replaceAll(RegExp(r'[._]+'), ' ').trim();
            if (displayName.isEmpty) {
              displayName = email;
            }
          } else {
            final id = userRole.userId;
            final tail = id.length >= 6 ? id.substring(id.length - 6) : id;
            displayName = 'Teammate ($tail)';
          }
        }

        usersWithProfiles.add(_UserWithProfile(
          userRole: userRole,
          email: email,
          displayName: displayName,
          hasVerifiedEmail: email.isNotEmpty,
        ));
      }

      // Sort by name
      usersWithProfiles.sort((a, b) => a.displayName.compareTo(b.displayName));

      setState(() {
        _allUsers = userRoles;
        _allWithProfiles = usersWithProfiles;
        _filteredUsers = List<_UserWithProfile>.from(usersWithProfiles);
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
    final query = _searchController.text.toLowerCase().trim();
    setState(() {
      if (query.isEmpty) {
        _filteredUsers = List<_UserWithProfile>.from(_allWithProfiles);
        return;
      }
      _filteredUsers = _allWithProfiles
          .where((user) {
            return user.displayName.toLowerCase().contains(query) ||
                user.email.toLowerCase().contains(query) ||
                user.userRole.roleType.name.toLowerCase().contains(query);
          })
          .toList();
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
                            final theme = Theme.of(context);
                            final onSurface = theme.colorScheme.onSurface;
                            final onVar = theme.colorScheme.onSurfaceVariant;
                            final initial = profile.displayName.isEmpty
                                ? '?'
                                : String.fromCharCode(profile.displayName.runes.first)
                                    .toUpperCase();

                            return ListTile(
                              selected: _selectedUserId == user.userId,
                              leading: CircleAvatar(
                                backgroundColor: AppTheme.primaryBlue,
                                child: Text(
                                  initial,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              title: Text(
                                profile.displayName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    profile.hasVerifiedEmail
                                        ? profile.email
                                        : 'No email on file',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: onVar,
                                      fontStyle: profile.hasVerifiedEmail
                                          ? FontStyle.normal
                                          : FontStyle.italic,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    role?.name ?? user.roleType.name,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: onVar,
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
  final bool hasVerifiedEmail;

  _UserWithProfile({
    required this.userRole,
    required this.email,
    required this.displayName,
    this.hasVerifiedEmail = false,
  });
}
