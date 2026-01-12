import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/webhook_model.dart';
import '../services/webhook_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';

/// Screen for creating/editing webhook subscriptions
class WebhookEditorScreen extends ConsumerStatefulWidget {
  final String? webhookId; // If provided, editing existing webhook

  const WebhookEditorScreen({
    super.key,
    this.webhookId,
  });

  @override
  ConsumerState<WebhookEditorScreen> createState() => _WebhookEditorScreenState();
}

class _WebhookEditorScreenState extends ConsumerState<WebhookEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _secretController = TextEditingController();
  
  List<WebhookEventType> _selectedEvents = [];
  bool _isLoading = false;
  WebhookSubscription? _existingWebhook;

  @override
  void initState() {
    super.initState();
    if (widget.webhookId != null) {
      _loadWebhook();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _descriptionController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _loadWebhook() async {
    if (widget.webhookId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final selectedFacility = ref.read(selectedFacilityProvider);
      final facilityId = selectedFacility?.id;
      if (facilityId == null) {
        throw Exception('No facility selected');
      }

      final webhooks = await WebhookService.getWebhookSubscriptions(facilityId);
      final webhook = webhooks.firstWhere((w) => w.id == widget.webhookId);

      setState(() {
        _existingWebhook = webhook;
        _urlController.text = webhook.url;
        _descriptionController.text = webhook.description ?? '';
        _secretController.text = webhook.secret ?? '';
        _selectedEvents = List.from(webhook.events);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading webhook: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _saveWebhook() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedEvents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one event type'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = selectedFacility?.id;
    if (facilityId == null || facilityId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a facility'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      if (widget.webhookId != null && _existingWebhook != null) {
        // Update existing webhook
        await WebhookService.updateWebhookSubscription(
          facilityId: facilityId,
          subscriptionId: widget.webhookId!,
          url: _urlController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          events: _selectedEvents,
          secret: _secretController.text.trim().isEmpty ? null : _secretController.text.trim(),
        );
      } else {
        // Create new webhook
        await WebhookService.createWebhookSubscription(
          facilityId: facilityId,
          url: _urlController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          events: _selectedEvents,
          secret: _secretController.text.trim().isEmpty ? null : _secretController.text.trim(),
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Webhook saved successfully')),
        );
        context.pop();
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving webhook: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _existingWebhook == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.webhookId != null ? 'Edit Webhook' : 'Create Webhook'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveWebhook,
            tooltip: 'Save',
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Basic Information
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Webhook Configuration',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _urlController,
                        decoration: const InputDecoration(
                          labelText: 'Webhook URL *',
                          border: OutlineInputBorder(),
                          helperText: 'The URL where events will be sent (must be HTTPS)',
                          prefixIcon: Icon(Icons.link),
                        ),
                        keyboardType: TextInputType.url,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a webhook URL';
                          }
                          final uri = Uri.tryParse(value.trim());
                          if (uri == null || !uri.hasScheme) {
                            return 'Please enter a valid URL';
                          }
                          if (uri.scheme != 'https') {
                            return 'Webhook URL must use HTTPS';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _descriptionController,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                          helperText: 'Optional description of what this webhook is used for',
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _secretController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Webhook Secret',
                          border: OutlineInputBorder(),
                          helperText: 'Optional secret for signing webhook payloads',
                          prefixIcon: Icon(Icons.lock),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Event Types
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Event Types',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Select which events should trigger this webhook',
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 16),
                      ...WebhookEventType.values.map((eventType) {
                        final isSelected = _selectedEvents.contains(eventType);
                        return CheckboxListTile(
                          title: Text(_formatEventType(eventType)),
                          subtitle: Text(_getEventDescription(eventType)),
                          value: isSelected,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                if (!_selectedEvents.contains(eventType)) {
                                  _selectedEvents.add(eventType);
                                }
                              } else {
                                _selectedEvents.remove(eventType);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatEventType(WebhookEventType eventType) {
    switch (eventType) {
      case WebhookEventType.tenantCreated:
        return 'Tenant Created';
      case WebhookEventType.tenantUpdated:
        return 'Tenant Updated';
      case WebhookEventType.tenantDeleted:
        return 'Tenant Deleted';
      case WebhookEventType.paymentReceived:
        return 'Payment Received';
      case WebhookEventType.paymentFailed:
        return 'Payment Failed';
      case WebhookEventType.contractSigned:
        return 'Contract Signed';
      case WebhookEventType.contractExpired:
        return 'Contract Expired';
      case WebhookEventType.reminderSent:
        return 'Reminder Sent';
      case WebhookEventType.unitOccupied:
        return 'Unit Occupied';
      case WebhookEventType.unitVacated:
        return 'Unit Vacated';
      case WebhookEventType.all:
        return 'All Events';
    }
  }

  String _getEventDescription(WebhookEventType eventType) {
    switch (eventType) {
      case WebhookEventType.tenantCreated:
        return 'Triggered when a new tenant is created';
      case WebhookEventType.tenantUpdated:
        return 'Triggered when tenant information is updated';
      case WebhookEventType.tenantDeleted:
        return 'Triggered when a tenant is deleted';
      case WebhookEventType.paymentReceived:
        return 'Triggered when a payment is received';
      case WebhookEventType.paymentFailed:
        return 'Triggered when a payment fails';
      case WebhookEventType.contractSigned:
        return 'Triggered when a contract is signed';
      case WebhookEventType.contractExpired:
        return 'Triggered when a contract expires';
      case WebhookEventType.reminderSent:
        return 'Triggered when a reminder is sent';
      case WebhookEventType.unitOccupied:
        return 'Triggered when a unit becomes occupied';
      case WebhookEventType.unitVacated:
        return 'Triggered when a unit becomes vacant';
      case WebhookEventType.all:
        return 'Triggered for all events';
    }
  }
}

