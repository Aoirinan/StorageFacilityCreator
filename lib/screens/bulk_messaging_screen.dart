import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../utils/breakpoints.dart';
import '../providers/tenant_provider.dart';
import '../models/tenant_model.dart';
import '../services/email_service.dart';
import '../services/sms_service.dart';
import '../services/debug_logger.dart';
import 'package:flutter/foundation.dart';

/// Screen for sending bulk messages to multiple tenants.
/// [tenantsKey]: 'all' = all facilities, or comma-separated facility IDs. When empty, uses [facilityId] only.
class BulkMessagingScreen extends ConsumerStatefulWidget {
  final String facilityId;
  final String tenantsKey;
  final bool allFacilities;

  const BulkMessagingScreen({
    super.key,
    required this.facilityId,
    this.tenantsKey = '',
    this.allFacilities = false,
  });

  @override
  ConsumerState<BulkMessagingScreen> createState() => _BulkMessagingScreenState();
}

// Result model for tracking failures
class _MessageFailure {
  final String to;
  final String? code;
  final String message;
  final String type; // 'email' or 'sms'

  _MessageFailure({
    required this.to,
    this.code,
    required this.message,
    required this.type,
  });
}

class _BulkMessagingScreenState extends ConsumerState<BulkMessagingScreen> {
  final _messageController = TextEditingController();
  final _subjectController = TextEditingController();
  
  Set<String> _selectedTenantIds = {};
  bool _sendEmail = true;
  bool _sendSMS = false;
  bool _isSending = false;
  String? _statusMessage;
  bool _statusIsError = false;
  
  // Progress tracking
  int _currentProgress = 0;
  int _totalProgress = 0;
  
  // Results tracking
  List<String> _sentRecipients = [];
  List<_MessageFailure> _failedRecipients = [];
  bool _showFailureDetails = false;

  @override
  void dispose() {
    _messageController.dispose();
    _subjectController.dispose();
    super.dispose();
  }

  Future<void> _sendBulkMessages() async {
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H8',
      location: 'bulk_messaging_screen.dart:_sendBulkMessages',
      message: 'Bulk message send initiated',
      data: {
        'facilityId': widget.facilityId,
        'selectedTenantCount': _selectedTenantIds.length,
        'sendEmail': _sendEmail,
        'sendSMS': _sendSMS,
        'messageLength': _messageController.text.trim().length,
        'subjectLength': _subjectController.text.trim().length,
      },
    );
    // #endregion

    if (_messageController.text.trim().isEmpty) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H8',
        location: 'bulk_messaging_screen.dart:_sendBulkMessages',
        message: 'Validation failed - empty message',
      );
      // #endregion
      setState(() {
        _statusMessage = 'Please enter a message';
        _statusIsError = true;
      });
      return;
    }

    if (_selectedTenantIds.isEmpty) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H8',
        location: 'bulk_messaging_screen.dart:_sendBulkMessages',
        message: 'Validation failed - no tenants selected',
      );
      // #endregion
      setState(() {
        _statusMessage = 'Please select at least one tenant';
        _statusIsError = true;
      });
      return;
    }

    if (!_sendEmail && !_sendSMS) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H8',
        location: 'bulk_messaging_screen.dart:_sendBulkMessages',
        message: 'Validation failed - no delivery method selected',
      );
      // #endregion
      setState(() {
        _statusMessage = 'Please select at least one delivery method';
        _statusIsError = true;
      });
      return;
    }

    if (_sendEmail && _subjectController.text.trim().isEmpty) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H8',
        location: 'bulk_messaging_screen.dart:_sendBulkMessages',
        message: 'Validation failed - empty email subject',
      );
      // #endregion
      setState(() {
        _statusMessage = 'Please enter an email subject';
        _statusIsError = true;
      });
      return;
    }

    setState(() {
      _isSending = true;
      _statusMessage = null;
      _currentProgress = 0;
      _sentRecipients.clear();
      _failedRecipients.clear();
      _showFailureDetails = false;
    });

    try {
      // Get selected tenants (from multi-facility or single facility)
      List<TenantModel> tenants;
      if (widget.tenantsKey.isNotEmpty) {
        final async = ref.read(multiFacilityTenantsProvider(widget.tenantsKey));
        tenants = async.whenOrNull(data: (d) => d) ?? [];
      } else {
        final async = ref.read(facilityTenantsProvider(widget.facilityId));
        tenants = async.whenOrNull(data: (d) => d) ?? [];
      }

      final selectedTenants = tenants.where((t) => _selectedTenantIds.contains(t.id)).toList();

      // Calculate total messages to send
      int totalMessages = 0;
      for (final tenant in selectedTenants) {
        if (_sendEmail && tenant.email.isNotEmpty) totalMessages++;
        if (_sendSMS && tenant.phone.isNotEmpty) totalMessages++;
      }
      
      setState(() {
        _totalProgress = totalMessages;
      });

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H8',
        location: 'bulk_messaging_screen.dart:_sendBulkMessages',
        message: 'Tenants loaded',
        data: {
          'totalTenants': tenants.length,
          'selectedTenants': selectedTenants.length,
          'totalMessages': totalMessages,
        },
      );
      // #endregion

      final message = _messageController.text.trim();
      final subject = _subjectController.text.trim();

      for (final tenant in selectedTenants) {
        // Send email if enabled and tenant has email
        if (_sendEmail && tenant.email.isNotEmpty) {
          try {
            // #region agent log
            DebugLogger.log(
              hypothesisId: 'H8',
              location: 'bulk_messaging_screen.dart:_sendBulkMessages',
              message: 'Calling EmailService.sendEmail',
              data: {
                'tenantId': tenant.id,
                'hasEmail': tenant.email.isNotEmpty,
                'subject': subject,
                'facilityId': widget.facilityId,
              },
            );
            // #endregion

            final facilityId = tenant.facilityId.isNotEmpty ? tenant.facilityId : widget.facilityId;
            final result = await EmailService.sendEmail(
              to: tenant.email,
              subject: subject,
              html: _formatMessageAsHTML(message, tenant),
              text: message,
              facilityId: facilityId,
              tenantId: tenant.id,
              relatedEntityType: 'bulk_message',
            );

            setState(() {
              _currentProgress++;
            });

            if (result.success) {
              setState(() {
                _sentRecipients.add('${tenant.name} (${tenant.email})');
              });
            } else {
              setState(() {
                _failedRecipients.add(_MessageFailure(
                  to: '${tenant.name} (${tenant.email})',
                  code: result.errorCode,
                  message: result.error ?? 'Unknown error',
                  type: 'email',
                ));
              });
              // #region agent log
              DebugLogger.log(
                hypothesisId: 'H8',
                location: 'bulk_messaging_screen.dart:_sendBulkMessages',
                message: 'Email send failed',
                data: {
                  'tenantId': tenant.id,
                  'error': result.error,
                  'errorCode': result.errorCode,
                },
              );
              // #endregion
            }
          } catch (e) {
            setState(() {
              _currentProgress++;
              _failedRecipients.add(_MessageFailure(
                to: '${tenant.name} (${tenant.email})',
                code: null,
                message: e.toString(),
                type: 'email',
              ));
            });
            // #region agent log
            DebugLogger.log(
              hypothesisId: 'H8',
              location: 'bulk_messaging_screen.dart:_sendBulkMessages',
              message: 'Exception during email send',
              data: {
                'tenantId': tenant.id,
                'exception': e.toString(),
              },
            );
            // #endregion
          }
        }

        // Send SMS if enabled and tenant has phone
        if (_sendSMS && tenant.phone.isNotEmpty) {
          try {
            final facilityId = tenant.facilityId.isNotEmpty ? tenant.facilityId : widget.facilityId;
            final result = await SMSService.sendSMS(
              to: tenant.phone,
              message: message,
              facilityId: facilityId,
              tenantId: tenant.id,
              relatedEntityType: 'bulk_message',
            );
            
            setState(() {
              _currentProgress++;
            });
            
            if (result.success) {
              setState(() {
                _sentRecipients.add('${tenant.name} (${tenant.phone})');
              });
            } else {
              setState(() {
                _failedRecipients.add(_MessageFailure(
                  to: '${tenant.name} (${tenant.phone})',
                  code: result.errorCode,
                  message: result.error ?? 'Unknown error',
                  type: 'sms',
                ));
              });
            }
          } catch (e) {
            setState(() {
              _currentProgress++;
              _failedRecipients.add(_MessageFailure(
                to: '${tenant.name} (${tenant.phone})',
                code: null,
                message: e.toString(),
                type: 'sms',
              ));
            });
          }
        }
      }

      // Calculate counts by type
      final emailSent = _sentRecipients.where((r) => r.contains('@')).length;
      final emailFailed = _failedRecipients.where((f) => f.type == 'email').length;
      final smsSent = _sentRecipients.where((r) => !r.contains('@')).length;
      final smsFailed = _failedRecipients.where((f) => f.type == 'sms').length;

      // Show results
      final List<String> resultParts = [];
      if (_sendEmail) {
        resultParts.add('Email: $emailSent sent${emailFailed > 0 ? ', $emailFailed failed' : ''}');
      }
      if (_sendSMS) {
        resultParts.add('SMS: $smsSent sent${smsFailed > 0 ? ', $smsFailed failed' : ''}');
      }

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H8',
        location: 'bulk_messaging_screen.dart:_sendBulkMessages',
        message: 'Bulk message send completed',
        data: {
          'emailSent': emailSent,
          'emailFailed': emailFailed,
          'smsSent': smsSent,
          'smsFailed': smsFailed,
          'hasErrors': _failedRecipients.isNotEmpty,
        },
      );
      // #endregion

      setState(() {
        _isSending = false;
        _statusMessage = resultParts.join(' | ');
        _statusIsError = _failedRecipients.isNotEmpty;
        if (_failedRecipients.isNotEmpty) {
          _showFailureDetails = true;
        }
      });

      if (mounted &&
          _failedRecipients.any((f) => f.code == 'recipient-unsubscribed')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Some tenants unsubscribed from facility email. See details below — try SMS or a call.',
            ),
            backgroundColor: AppTheme.warning,
          ),
        );
      }

      // Clear form on success
      if (_failedRecipients.isEmpty) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _selectedTenantIds.clear();
              _messageController.clear();
              _subjectController.clear();
              _statusMessage = null;
              _showFailureDetails = false;
            });
          }
        });
      }
    } catch (e) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H8',
        location: 'bulk_messaging_screen.dart:_sendBulkMessages',
        message: 'Exception during bulk message send',
        data: {'exception': e.toString(), 'errorType': e.runtimeType.toString()},
      );
      // #endregion
      setState(() {
        _isSending = false;
        _statusMessage = 'Error sending messages: $e';
        _statusIsError = true;
      });
    }
  }

  /// Staff-facing explanation for a failed channel (e.g. email unsubscribe).
  String _failureStaffMessage(_MessageFailure f) {
    if (f.code == 'recipient-unsubscribed') {
      return 'Unsubscribed from facility emails — try SMS or a phone call if available.';
    }
    return f.message;
  }

  String _formatMessageAsHTML(String message, TenantModel tenant) {
    // Simple HTML formatting with line breaks
    final htmlMessage = message
        .replaceAll('\n', '<br>')
        .replaceAll(RegExp(r'\*\*(.*?)\*\*'), '<strong>\$1</strong>')
        .replaceAll(RegExp(r'\*(.*?)\*'), '<em>\$1</em>');
    
    return '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 600px;
            margin: 0 auto;
            padding: 20px;
        }
    </style>
</head>
<body>
    <p>Dear ${tenant.name},</p>
    <div>$htmlMessage</div>
    <p style="margin-top: 30px;">Best regards,<br>Management Team</p>
</body>
</html>
''';
  }

  void _toggleTenantSelection(String tenantId) {
    setState(() {
      if (_selectedTenantIds.contains(tenantId)) {
        _selectedTenantIds.remove(tenantId);
      } else {
        _selectedTenantIds.add(tenantId);
      }
    });
  }

  void _selectAll() {
    if (widget.tenantsKey.isNotEmpty) {
      final async = ref.read(multiFacilityTenantsProvider(widget.tenantsKey));
      final tenants = async.whenOrNull(data: (d) => d) ?? [];
      setState(() {
        _selectedTenantIds = tenants.where((t) => t.isActive).map((t) => t.id).toSet();
      });
    } else {
      ref.read(facilityTenantsProvider(widget.facilityId)).when(
        data: (tenants) {
          setState(() {
            _selectedTenantIds = tenants.where((t) => t.isActive).map((t) => t.id).toSet();
          });
        },
        loading: () {},
        error: (_, __) {},
      );
    }
  }

  void _deselectAll() {
    setState(() {
      _selectedTenantIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tenantsAsync = widget.tenantsKey.isNotEmpty
        ? ref.watch(multiFacilityTenantsProvider(widget.tenantsKey))
        : ref.watch(facilityTenantsProvider(widget.facilityId));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Delivery Method Selection
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Delivery Method',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Send Email'),
                      subtitle: const Text('Send message via email'),
                      value: _sendEmail,
                      onChanged: (value) {
                        setState(() {
                          _sendEmail = value;
                        });
                      },
                    ),
                    SwitchListTile(
                      title: const Text('Send SMS'),
                      subtitle: const Text('Send message via text message'),
                      value: _sendSMS,
                      onChanged: (value) {
                        setState(() {
                          _sendSMS = value;
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Message Composition
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Message',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 16),
                    if (_sendEmail) ...[
                      TextField(
                        controller: _subjectController,
                        enabled: !_isSending,
                        decoration: const InputDecoration(
                          labelText: 'Subject',
                          hintText: 'Enter email subject',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: _messageController,
                      enabled: !_isSending,
                      decoration: const InputDecoration(
                        labelText: 'Message',
                        hintText: 'Enter your message here',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                      maxLines: 8,
                      minLines: 5,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Use **text** for bold and *text* for italic. Line breaks are preserved.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Tenant Selection
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final isPhone = constraints.maxWidth < Breakpoints.xs;
                        return isPhone
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Select Tenants (${_selectedTenantIds.length} selected)',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      TextButton(
                                        onPressed: _selectAll,
                                        child: const Text('Select All'),
                                      ),
                                      TextButton(
                                        onPressed: _deselectAll,
                                        child: const Text('Deselect All'),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Select Tenants (${_selectedTenantIds.length} selected)',
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _selectAll,
                                    child: const Text('Select All'),
                                  ),
                                  TextButton(
                                    onPressed: _deselectAll,
                                    child: const Text('Deselect All'),
                                  ),
                                ],
                              );
                      },
                    ),
                    if (widget.allFacilities || (widget.tenantsKey.isNotEmpty && widget.tenantsKey != widget.facilityId))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          widget.allFacilities
                              ? 'Showing tenants from all facilities'
                              : 'Showing tenants from selected facilities',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 300,
                      child: tenantsAsync.when(
                        data: (tenants) {
                          final activeTenants = tenants.where((t) => t.isActive).toList();
                          if (activeTenants.isEmpty) {
                            return Center(
                              child: Text(
                                'No active tenants found',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: AppTheme.textSecondary,
                                    ),
                              ),
                            );
                          }
                          return ListView.builder(
                            itemCount: activeTenants.length,
                            itemBuilder: (context, index) {
                              final tenant = activeTenants[index];
                              final isSelected = _selectedTenantIds.contains(tenant.id);
                              return CheckboxListTile(
                                title: Text(tenant.name),
                                subtitle: Text(
                                  '${tenant.email.isNotEmpty ? tenant.email : "No email"}${tenant.phone.isNotEmpty ? " • ${tenant.phone}" : " • No phone"}',
                                ),
                                value: isSelected,
                                onChanged: _isSending ? null : (value) => _toggleTenantSelection(tenant.id),
                              );
                            },
                          );
                        },
                        loading: () => const Center(child: CircularProgressIndicator()),
                        error: (error, stack) => Center(
                          child: Text(
                            'Error loading tenants: $error',
                            style: TextStyle(color: AppTheme.error),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Status Message
            if (_statusMessage != null)
              Card(
                color: _statusIsError ? AppTheme.error.withOpacity(0.1) : AppTheme.success.withOpacity(0.1),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        _statusIsError ? Icons.error_outline : Icons.check_circle_outline,
                        color: _statusIsError ? AppTheme.error : AppTheme.success,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _statusMessage!,
                          style: TextStyle(
                            color: _statusIsError ? AppTheme.error : AppTheme.success,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_statusMessage != null) const SizedBox(height: 16),

            if (_showFailureDetails && _failedRecipients.isNotEmpty) ...[
              Card(
                child: Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    initiallyExpanded: true,
                    title: Text(
                      'Failed deliveries (${_failedRecipients.length})',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    subtitle: _failedRecipients.any((f) => f.code == 'recipient-unsubscribed')
                        ? const Text(
                            'Some tenants opted out of email. Use SMS or call for those contacts.',
                            style: TextStyle(fontSize: 12),
                          )
                        : null,
                    children: [
                      for (final f in _failedRecipients)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            f.type == 'email' ? Icons.email_outlined : Icons.sms_outlined,
                            color: AppTheme.textSecondary,
                          ),
                          title: Text(f.to, style: const TextStyle(fontSize: 13)),
                          subtitle: Text(
                            _failureStaffMessage(f),
                            style: TextStyle(
                              fontSize: 12,
                              color: f.code == 'recipient-unsubscribed'
                                  ? AppTheme.warning
                                  : AppTheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Send Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_isSending || _selectedTenantIds.isEmpty) ? null : _sendBulkMessages,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  foregroundColor: AppTheme.textOnDark,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  disabledBackgroundColor: AppTheme.textSecondary.withOpacity(0.3),
                ),
                child: _isSending
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(AppTheme.textOnDark),
                        ),
                      )
                    : Text(
                        _selectedTenantIds.isEmpty
                            ? 'Select Tenants to Send'
                            : 'Send to ${_selectedTenantIds.length} Tenant${_selectedTenantIds.length != 1 ? 's' : ''}',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
    );
  }
}

