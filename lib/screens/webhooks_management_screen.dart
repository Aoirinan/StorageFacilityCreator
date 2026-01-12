import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/webhook_model.dart';
import '../services/webhook_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';

/// Screen for managing webhook subscriptions
class WebhooksManagementScreen extends ConsumerStatefulWidget {
  const WebhooksManagementScreen({super.key});

  @override
  ConsumerState<WebhooksManagementScreen> createState() => _WebhooksManagementScreenState();
}

class _WebhooksManagementScreenState extends ConsumerState<WebhooksManagementScreen> {
  String? _selectedFacilityId;
  List<WebhookSubscription> _webhooks = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadWebhooks();
  }

  Future<void> _loadWebhooks() async {
    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = _selectedFacilityId ?? selectedFacility?.id;
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _webhooks = [];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final webhooks = await WebhookService.getWebhookSubscriptions(facilityId);
      setState(() {
        _webhooks = webhooks;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading webhooks: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedFacility = ref.watch(selectedFacilityProvider);
    final selectedFacilityId = selectedFacility?.id;

    // Update facility ID if changed
    if (_selectedFacilityId != selectedFacilityId) {
      _selectedFacilityId = selectedFacilityId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadWebhooks();
      });
    }

    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/webhooks';

    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Webhooks',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateWebhookDialog(),
          tooltip: 'Create Webhook',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadWebhooks,
          tooltip: 'Refresh',
        ),
      ],
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 64, color: AppTheme.error),
                      const SizedBox(height: 16),
                      Text(_error!, style: TextStyle(color: AppTheme.error)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadWebhooks,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _webhooks.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.webhook, size: 64, color: AppTheme.textTertiary),
                          const SizedBox(height: 16),
                          Text(
                            'No webhooks found',
                            style: TextStyle(color: AppTheme.textTertiary, fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Create webhooks to receive real-time event notifications',
                            style: TextStyle(color: AppTheme.textTertiary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () => _showCreateWebhookDialog(),
                            icon: const Icon(Icons.add),
                            label: const Text('Create Webhook'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _webhooks.length,
                      itemBuilder: (context, index) {
                        final webhook = _webhooks[index];
                        return _buildWebhookCard(webhook);
                      },
                    ),
    );
  }

  Widget _buildWebhookCard(WebhookSubscription webhook) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        webhook.url,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: AppTheme.primaryBlueDark,
                            ),
                      ),
                      if (webhook.description != null && webhook.description!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          webhook.description!,
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
                _buildStatusBadge(webhook.isActive),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _buildInfoChip(
                  Icons.event,
                  '${webhook.events.length} ${webhook.events.length == 1 ? 'event' : 'events'}',
                ),
                _buildInfoChip(
                  Icons.calendar_today,
                  'Created: ${DateFormat('MMM d, y').format(webhook.createdAt)}',
                ),
                if (webhook.lastTriggeredAt != null)
                  _buildInfoChip(
                    Icons.access_time,
                    'Last triggered: ${DateFormat('MMM d, y HH:mm').format(webhook.lastTriggeredAt!)}',
                  ),
              ],
            ),
            if (webhook.events.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: webhook.events.take(5).map((event) {
                  return Chip(
                    label: Text(_formatEventType(event)),
                    backgroundColor: AppTheme.accentBlueLight.withOpacity(0.2),
                    labelStyle: TextStyle(
                      color: AppTheme.primaryBlueDark,
                      fontSize: 12,
                    ),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _viewWebhookDetails(webhook),
                  icon: const Icon(Icons.visibility),
                  label: const Text('View'),
                ),
                TextButton.icon(
                  onPressed: () => _editWebhook(webhook),
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: () => _deleteWebhook(webhook),
                  icon: const Icon(Icons.delete, color: AppTheme.error),
                  label: const Text('Delete', style: TextStyle(color: AppTheme.error)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? AppTheme.success.withOpacity(0.1) : AppTheme.textSecondary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? AppTheme.success : AppTheme.textSecondary,
          width: 1,
        ),
      ),
      child: Text(
        isActive ? 'Active' : 'Inactive',
        style: TextStyle(
          color: isActive ? AppTheme.success : AppTheme.textSecondary,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
      ],
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

  void _showCreateWebhookDialog() {
    context.push('/webhooks/create');
  }

  void _viewWebhookDetails(WebhookSubscription webhook) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Webhook Details'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('URL: ${webhook.url}'),
              if (webhook.description != null) ...[
                const SizedBox(height: 8),
                Text('Description: ${webhook.description}'),
              ],
              const SizedBox(height: 8),
              Text('Events: ${webhook.events.map((e) => _formatEventType(e)).join(", ")}'),
              const SizedBox(height: 8),
              Text('Created: ${DateFormat('MMM d, y HH:mm').format(webhook.createdAt)}'),
              if (webhook.lastTriggeredAt != null)
                Text('Last Triggered: ${DateFormat('MMM d, y HH:mm').format(webhook.lastTriggeredAt!)}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _editWebhook(WebhookSubscription webhook) {
    context.push('/webhooks/${webhook.id}/edit');
  }

  Future<void> _deleteWebhook(WebhookSubscription webhook) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Webhook'),
        content: Text('Are you sure you want to delete the webhook for "${webhook.url}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && _selectedFacilityId != null) {
      try {
        await WebhookService.deleteWebhookSubscription(
          facilityId: _selectedFacilityId!,
          subscriptionId: webhook.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Webhook deleted successfully')),
          );
          _loadWebhooks();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting webhook: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }
}

