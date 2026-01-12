import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../providers/tenant_provider.dart';
import '../models/tenant_model.dart';
import '../services/email_service.dart';
import '../services/sms_service.dart';
import 'package:flutter/foundation.dart';

/// Screen for sending bulk messages to multiple tenants
class BulkMessagingScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const BulkMessagingScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<BulkMessagingScreen> createState() => _BulkMessagingScreenState();
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

  @override
  void dispose() {
    _messageController.dispose();
    _subjectController.dispose();
    super.dispose();
  }

  Future<void> _sendBulkMessages() async {
    if (_messageController.text.trim().isEmpty) {
      setState(() {
        _statusMessage = 'Please enter a message';
        _statusIsError = true;
      });
      return;
    }

    if (_selectedTenantIds.isEmpty) {
      setState(() {
        _statusMessage = 'Please select at least one tenant';
        _statusIsError = true;
      });
      return;
    }

    if (!_sendEmail && !_sendSMS) {
      setState(() {
        _statusMessage = 'Please select at least one delivery method';
        _statusIsError = true;
      });
      return;
    }

    if (_sendEmail && _subjectController.text.trim().isEmpty) {
      setState(() {
        _statusMessage = 'Please enter an email subject';
        _statusIsError = true;
      });
      return;
    }

    setState(() {
      _isSending = true;
      _statusMessage = null;
    });

    try {
      // Get selected tenants
      final tenantsAsync = ref.read(facilityTenantsProvider(widget.facilityId));
      final tenants = await tenantsAsync.when(
        data: (list) => list,
        loading: () => <TenantModel>[],
        error: (_, __) => <TenantModel>[],
      );

      final selectedTenants = tenants.where((t) => _selectedTenantIds.contains(t.id)).toList();

      int emailSuccessCount = 0;
      int emailFailureCount = 0;
      int smsSuccessCount = 0;
      int smsFailureCount = 0;

      final message = _messageController.text.trim();
      final subject = _subjectController.text.trim();

      for (final tenant in selectedTenants) {
        // Send email if enabled and tenant has email
        if (_sendEmail && tenant.email.isNotEmpty) {
          try {
            final result = await EmailService.sendEmail(
              to: tenant.email,
              subject: subject,
              html: _formatMessageAsHTML(message, tenant),
              text: message,
              facilityId: widget.facilityId,
              tenantId: tenant.id,
              relatedEntityType: 'bulk_message',
            );
            if (result.success) {
              emailSuccessCount++;
            } else {
              emailFailureCount++;
              if (kDebugMode) {
                print('Failed to send email to ${tenant.email}: ${result.error}');
              }
            }
          } catch (e) {
            emailFailureCount++;
            if (kDebugMode) {
              print('Error sending email to ${tenant.email}: $e');
            }
          }
        }

        // Send SMS if enabled and tenant has phone
        if (_sendSMS && tenant.phone.isNotEmpty) {
          try {
            final result = await SMSService.sendSMS(
              to: tenant.phone,
              message: message,
              facilityId: widget.facilityId,
              tenantId: tenant.id,
              relatedEntityType: 'bulk_message',
            );
            if (result.success) {
              smsSuccessCount++;
            } else {
              smsFailureCount++;
              if (kDebugMode) {
                print('Failed to send SMS to ${tenant.phone}: ${result.error}');
              }
            }
          } catch (e) {
            smsFailureCount++;
            if (kDebugMode) {
              print('Error sending SMS to ${tenant.phone}: $e');
            }
          }
        }
      }

      // Show results
      final List<String> resultParts = [];
      if (_sendEmail) {
        resultParts.add('Email: $emailSuccessCount sent${emailFailureCount > 0 ? ', $emailFailureCount failed' : ''}');
      }
      if (_sendSMS) {
        resultParts.add('SMS: $smsSuccessCount sent${smsFailureCount > 0 ? ', $smsFailureCount failed' : ''}');
      }

      setState(() {
        _isSending = false;
        _statusMessage = resultParts.join(' | ');
        _statusIsError = emailFailureCount > 0 || smsFailureCount > 0;
      });

      // Clear form on success
      if (emailFailureCount == 0 && smsFailureCount == 0) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _selectedTenantIds.clear();
              _messageController.clear();
              _subjectController.clear();
              _statusMessage = null;
            });
          }
        });
      }
    } catch (e) {
      setState(() {
        _isSending = false;
        _statusMessage = 'Error sending messages: $e';
        _statusIsError = true;
      });
    }
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
    final tenantsAsync = ref.read(facilityTenantsProvider(widget.facilityId));
    tenantsAsync.when(
      data: (tenants) {
        setState(() {
          _selectedTenantIds = tenants.where((t) => t.isActive).map((t) => t.id).toSet();
        });
      },
      loading: () {},
      error: (_, __) {},
    );
  }

  void _deselectAll() {
    setState(() {
      _selectedTenantIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tenantsAsync = ref.watch(facilityTenantsProvider(widget.facilityId));

    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/messaging/bulk';
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Bulk Messaging',
      child: SingleChildScrollView(
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
                    Row(
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
                                onChanged: (value) => _toggleTenantSelection(tenant.id),
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

            // Send Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSending ? null : _sendBulkMessages,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  foregroundColor: AppTheme.textOnDark,
                  padding: const EdgeInsets.symmetric(vertical: 16),
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
                        'Send to ${_selectedTenantIds.length} Tenant${_selectedTenantIds.length != 1 ? 's' : ''}',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

