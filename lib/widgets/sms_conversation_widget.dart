import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/sms_conversation_model.dart';
import '../models/sms_message_model.dart';
import '../services/sms_conversation_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_message_helper.dart';

/// Widget to display SMS conversation and allow replies
class SMSConversationWidget extends ConsumerStatefulWidget {
  final String facilityId;
  final String conversationId;
  final String tenantId;
  final String phoneNumber;
  final String? tenantName;

  const SMSConversationWidget({
    super.key,
    required this.facilityId,
    required this.conversationId,
    required this.tenantId,
    required this.phoneNumber,
    this.tenantName,
  });

  @override
  ConsumerState<SMSConversationWidget> createState() => _SMSConversationWidgetState();
}

class _SMSConversationWidgetState extends ConsumerState<SMSConversationWidget> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;
  List<SMSMessageModel> _messages = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    // Mark messages as read when widget is shown
    _markMessagesAsRead();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final messages = await SMSConversationService.getMessagesForConversation(
        facilityId: widget.facilityId,
        conversationId: widget.conversationId,
      );

      setState(() {
        _messages = messages;
        _isLoading = false;
      });

      // Scroll to bottom after loading
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    } catch (e) {
      setState(() {
        _errorMessage = ErrorMessageHelper.getUserFriendlyMessage(e);
        _isLoading = false;
      });
    }
  }

  Future<void> _markMessagesAsRead() async {
    try {
      await SMSConversationService.markMessagesAsRead(
        facilityId: widget.facilityId,
        conversationId: widget.conversationId,
      );
    } catch (e) {
      // Don't show error for read marking failures
      if (mounted) {
        debugPrint('Failed to mark messages as read: $e');
      }
    }
  }

  Future<void> _sendReply() async {
    final message = _messageController.text.trim();
    if (message.isEmpty || _isSending) return;

    setState(() {
      _isSending = true;
    });

    try {
      final result = await SMSConversationService.sendReply(
        facilityId: widget.facilityId,
        conversationId: widget.conversationId,
        tenantId: widget.tenantId,
        phoneNumber: widget.phoneNumber,
        message: message,
      );

      if (result.success) {
        _messageController.clear();
        // Reload messages to show the sent message
        await _loadMessages();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Message sent successfully'),
              backgroundColor: AppTheme.success,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'Failed to send message'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
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

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
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
              const Icon(Icons.sms, color: AppTheme.primaryBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.tenantName ?? 'SMS Conversation',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      widget.phoneNumber,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Messages list
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _errorMessage != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.error_outline, size: 48, color: AppTheme.error),
                            const SizedBox(height: 16),
                            Text(
                              _errorMessage!,
                              style: TextStyle(color: AppTheme.error),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadMessages,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _messages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.chat_bubble_outline, size: 48, color: AppTheme.textSecondary),
                              const SizedBox(height: 16),
                              Text(
                                'No messages yet',
                                style: TextStyle(color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(16),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final message = _messages[index];
                            return _buildMessageBubble(message);
                          },
                        ),
        ),

        // Reply input
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary,
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
                    hintText: 'Type a message...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendReply(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                onPressed: _isSending ? null : _sendReply,
                color: AppTheme.primaryBlue,
                tooltip: 'Send message',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageBubble(SMSMessageModel message) {
    final isOutgoing = message.direction == SMSDirection.outgoing;
    final alignment = isOutgoing ? Alignment.centerRight : Alignment.centerLeft;
    final color = isOutgoing ? AppTheme.primaryBlue : AppTheme.backgroundSecondary;
    final textColor = isOutgoing ? Colors.white : AppTheme.textPrimary;

    return Align(
      alignment: alignment,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.body,
              style: TextStyle(color: textColor),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTimestamp(message.timestamp),
                  style: TextStyle(
                    color: textColor.withOpacity(0.7),
                    fontSize: 12,
                  ),
                ),
                if (isOutgoing) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _getStatusIcon(message.status),
                    size: 12,
                    color: textColor.withOpacity(0.7),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getStatusIcon(SMSStatus status) {
    switch (status) {
      case SMSStatus.sent:
        return Icons.check;
      case SMSStatus.delivered:
        return Icons.done_all;
      case SMSStatus.failed:
        return Icons.error;
      default:
        return Icons.check;
    }
  }

  String _formatTimestamp(DateTime timestamp) {
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

