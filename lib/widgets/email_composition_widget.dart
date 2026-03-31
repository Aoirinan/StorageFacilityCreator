import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../providers/tenant_provider.dart';
import '../models/tenant_model.dart';
import '../services/email_service.dart';
import '../services/debug_logger.dart';
import '../utils/email_send_feedback.dart';

class _QuickEmailTemplate {
  final String label;
  final String? subject;
  final String body;

  const _QuickEmailTemplate({
    required this.label,
    this.subject,
    required this.body,
  });
}

/// Starter messages for the tenant email tab. Use {{tenant_name}}, {{first_name}}, {{unit}}, {{email}}, {{phone}}.
const List<_QuickEmailTemplate> _kQuickEmailTemplates = [
  _QuickEmailTemplate(
    label: 'Payment reminder',
    subject: 'Reminder: storage rent',
    body:
        'Hi {{first_name}},\n\n'
        'This is a friendly reminder about your upcoming storage rent. If you have already paid, please disregard this message.\n\n'
        'Thank you,\nManagement',
  ),
  _QuickEmailTemplate(
    label: 'Past due notice',
    subject: 'Important: past due balance',
    body:
        'Hi {{first_name}},\n\n'
        'Our records show a past-due balance on your account for unit {{unit}}. Please contact us at your earliest convenience to arrange payment or discuss options.\n\n'
        'Thank you,\nManagement',
  ),
  _QuickEmailTemplate(
    label: 'Thank you',
    subject: 'Thank you',
    body:
        'Hi {{first_name}},\n\n'
        'Thank you for being a valued customer. We appreciate your business.\n\n'
        'Best regards,\nManagement',
  ),
  _QuickEmailTemplate(
    label: 'Document / update needed',
    subject: 'Action needed for your account',
    body:
        'Hi {{first_name}},\n\n'
        'We need a quick update for your account (unit {{unit}}). Please reply to this email or call the office when you have a moment.\n\n'
        'Thank you,\nManagement',
  ),
  _QuickEmailTemplate(
    label: 'Blank greeting',
    body:
        'Hi {{first_name}},\n\n'
        '\n\n'
        'Best regards,\nManagement',
  ),
];

/// Widget for composing and sending a single email to a tenant
class EmailCompositionWidget extends ConsumerStatefulWidget {
  final String facilityId;

  const EmailCompositionWidget({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<EmailCompositionWidget> createState() => _EmailCompositionWidgetState();
}

class _EmailCompositionWidgetState extends ConsumerState<EmailCompositionWidget> {
  final _messageController = TextEditingController();
  final _subjectController = TextEditingController();
  
  String? _selectedTenantId;
  bool _isSending = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void dispose() {
    _messageController.dispose();
    _subjectController.dispose();
    super.dispose();
  }

  static String _firstNameFromTenant(TenantModel t) {
    final n = t.name.trim();
    if (n.isEmpty) return 'there';
    return n.split(RegExp(r'\s+')).first;
  }

  static String _interpolateTemplate(String template, TenantModel t) {
    return template
        .replaceAll('{{tenant_name}}', t.name)
        .replaceAll('{{name}}', t.name)
        .replaceAll('{{first_name}}', _firstNameFromTenant(t))
        .replaceAll('{{unit}}', t.unitNumber)
        .replaceAll('{{email}}', t.email)
        .replaceAll('{{phone}}', t.phone);
  }

  void _applyQuickTemplate(_QuickEmailTemplate template) {
    if (_selectedTenantId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a tenant first')),
      );
      return;
    }

    final tenantsAsync = ref.read(facilityTenantsProvider(widget.facilityId));
    final tenants = tenantsAsync.maybeWhen(
      data: (list) => list,
      orElse: () => <TenantModel>[],
    );

    TenantModel? tenant;
    for (final t in tenants) {
      if (t.id == _selectedTenantId) {
        tenant = t;
        break;
      }
    }

    if (tenant == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load tenant')),
      );
      return;
    }

    final t = tenant;
    setState(() {
      _messageController.text = _interpolateTemplate(template.body, t);
      if (template.subject != null) {
        _subjectController.text = _interpolateTemplate(template.subject!, t);
      }
    });
  }

  Future<void> _sendEmail() async {
    if (_messageController.text.trim().isEmpty) {
      setState(() {
        _statusMessage = 'Please enter a message';
        _statusIsError = true;
      });
      return;
    }

    if (_subjectController.text.trim().isEmpty) {
      setState(() {
        _statusMessage = 'Please enter an email subject';
        _statusIsError = true;
      });
      return;
    }

    if (_selectedTenantId == null) {
      setState(() {
        _statusMessage = 'Please select a tenant';
        _statusIsError = true;
      });
      return;
    }

    // Get selected tenant
    final tenantsAsync = ref.read(facilityTenantsProvider(widget.facilityId));
    final tenants = tenantsAsync.maybeWhen(
      data: (list) => list,
      orElse: () => <TenantModel>[],
    );

    final tenant = tenants.firstWhere(
      (t) => t.id == _selectedTenantId,
      orElse: () => throw Exception('Tenant not found'),
    );

    if (tenant.email.isEmpty) {
      setState(() {
        _statusMessage = 'Selected tenant does not have an email address';
        _statusIsError = true;
      });
      return;
    }

    setState(() {
      _isSending = true;
      _statusMessage = null;
    });

    try {
      final message = _messageController.text.trim();
      final subject = _subjectController.text.trim();

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H9',
        location: 'email_composition_widget.dart:_sendEmail',
        message: 'Sending email',
        data: {
          'tenantId': tenant.id,
          'tenantEmail': tenant.email,
          'subject': subject,
          'facilityId': widget.facilityId,
        },
      );
      // #endregion

      final result = await EmailService.sendEmail(
        to: tenant.email,
        subject: subject,
        html: _formatMessageAsHTML(message, tenant),
        text: message,
        facilityId: widget.facilityId,
        tenantId: tenant.id,
        relatedEntityType: 'manual_email',
      );

      if (result.success) {
        setState(() {
          _isSending = false;
          _statusMessage = 'Email sent successfully to ${tenant.name}';
          _statusIsError = false;
        });

        // Clear form after successful send
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _messageController.clear();
              _subjectController.clear();
              _statusMessage = null;
            });
          }
        });
      } else {
        final hint = EmailService.staffEmailFailureHint(result);
        setState(() {
          _isSending = false;
          _statusMessage = hint;
          _statusIsError = true;
        });
        if (mounted && recipientUnsubscribedEmailFailure(result)) {
          showStaffEmailFailureSnackBar(context, result);
        }
      }
    } catch (e) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H9',
        location: 'email_composition_widget.dart:_sendEmail',
        message: 'Exception during email send',
        data: {
          'tenantId': tenant.id,
          'exception': e.toString(),
        },
      );
      // #endregion

      setState(() {
        _isSending = false;
        _statusMessage = 'Error sending email: $e';
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

  @override
  Widget build(BuildContext context) {
    final tenantsAsync = ref.watch(facilityTenantsProvider(widget.facilityId));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tenant Selection
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select Tenant',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 16),
                  tenantsAsync.when(
                    data: (tenants) {
                      final activeTenants = tenants.where((t) => t.isActive && t.email.isNotEmpty).toList();
                      if (activeTenants.isEmpty) {
                        return Center(
                          child: Text(
                            'No active tenants with email addresses found',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                          ),
                        );
                      }
                      return DropdownButtonFormField<String>(
                        value: _selectedTenantId,
                        decoration: const InputDecoration(
                          labelText: 'Tenant',
                          border: OutlineInputBorder(),
                        ),
                        items: activeTenants.map((tenant) {
                          return DropdownMenuItem<String>(
                            value: tenant.id,
                            child: Text('${tenant.name} (${tenant.email})'),
                          );
                        }).toList(),
                        onChanged: _isSending
                            ? null
                            : (value) {
                                setState(() {
                                  _selectedTenantId = value;
                                });
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
                    'Email',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Quick messages',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap to fill the message (and subject when provided). Names and unit come from the tenant you selected.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _kQuickEmailTemplates.map((t) {
                      return ActionChip(
                        label: Text(t.label),
                        onPressed:
                            _isSending ? null : () => _applyQuickTemplate(t),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
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
              onPressed: (_isSending || _selectedTenantId == null) ? null : _sendEmail,
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
                  : const Text(
                      'Send Email',
                      style: TextStyle(fontSize: 16),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
