import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/api_key_model.dart';
import '../services/api_key_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';

/// Screen for managing API keys
class ApiKeysManagementScreen extends ConsumerStatefulWidget {
  const ApiKeysManagementScreen({super.key});

  @override
  ConsumerState<ApiKeysManagementScreen> createState() => _ApiKeysManagementScreenState();
}

class _ApiKeysManagementScreenState extends ConsumerState<ApiKeysManagementScreen> {
  String? _selectedFacilityId;
  List<ApiKey> _apiKeys = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadApiKeys();
  }

  Future<void> _loadApiKeys() async {
    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = _selectedFacilityId ?? selectedFacility?.id;
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _apiKeys = [];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final keys = await ApiKeyService.getApiKeys(facilityId);
      setState(() {
        _apiKeys = keys;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading API keys: $e';
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
        _loadApiKeys();
      });
    }

    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/api-keys';

    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'API Keys',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateApiKeyDialog(),
          tooltip: 'Create API Key',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadApiKeys,
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
                        onPressed: _loadApiKeys,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _apiKeys.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.vpn_key, size: 64, color: AppTheme.textTertiary),
                          const SizedBox(height: 16),
                          Text(
                            'No API keys found',
                            style: TextStyle(color: AppTheme.textTertiary, fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Create API keys to enable third-party integrations',
                            style: TextStyle(color: AppTheme.textTertiary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () => _showCreateApiKeyDialog(),
                            icon: const Icon(Icons.add),
                            label: const Text('Create API Key'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _apiKeys.length,
                      itemBuilder: (context, index) {
                        final apiKey = _apiKeys[index];
                        return _buildApiKeyCard(apiKey);
                      },
                    ),
    );
  }

  Widget _buildApiKeyCard(ApiKey apiKey) {
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
                        apiKey.name,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: AppTheme.primaryBlueDark,
                            ),
                      ),
                      if (apiKey.description != null && apiKey.description!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          apiKey.description!,
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
                _buildStatusBadge(apiKey.isValid, apiKey.isActive),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _buildInfoChip(
                  Icons.security,
                  'Permissions: ${apiKey.permissions.length}',
                ),
                if (apiKey.rateLimit != null)
                  _buildInfoChip(
                    Icons.speed,
                    'Rate Limit: ${apiKey.rateLimit}/min',
                  ),
                _buildInfoChip(
                  Icons.calendar_today,
                  'Created: ${DateFormat('MMM d, y').format(apiKey.createdAt)}',
                ),
                if (apiKey.expiresAt != null)
                  _buildInfoChip(
                    Icons.event,
                    'Expires: ${DateFormat('MMM d, y').format(apiKey.expiresAt!)}',
                  ),
                if (apiKey.lastUsedAt != null)
                  _buildInfoChip(
                    Icons.access_time,
                    'Last used: ${DateFormat('MMM d, y').format(apiKey.lastUsedAt!)}',
                  ),
              ],
            ),
            if (apiKey.permissions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: apiKey.permissions.take(5).map((perm) {
                  return Chip(
                    label: Text(perm),
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
                  onPressed: () => _viewApiKeyDetails(apiKey),
                  icon: const Icon(Icons.visibility),
                  label: const Text('View'),
                ),
                TextButton.icon(
                  onPressed: () => _deleteApiKey(apiKey),
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

  Widget _buildStatusBadge(bool isValid, bool isActive) {
    Color color;
    String label;

    if (!isActive) {
      color = AppTheme.textSecondary;
      label = 'Inactive';
    } else if (!isValid) {
      color = AppTheme.error;
      label = 'Expired';
    } else {
      color = AppTheme.success;
      label = 'Active';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
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

  void _showCreateApiKeyDialog() {
    context.push('/api-keys/create');
  }

  void _viewApiKeyDetails(ApiKey apiKey) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(apiKey.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (apiKey.description != null) ...[
                Text(
                  apiKey.description!,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
              ],
              Text('Permissions: ${apiKey.permissions.join(", ")}'),
              const SizedBox(height: 8),
              if (apiKey.rateLimit != null)
                Text('Rate Limit: ${apiKey.rateLimit} requests per minute'),
              const SizedBox(height: 8),
              Text('Created: ${DateFormat('MMM d, y HH:mm').format(apiKey.createdAt)}'),
              if (apiKey.expiresAt != null)
                Text('Expires: ${DateFormat('MMM d, y').format(apiKey.expiresAt!)}'),
              if (apiKey.lastUsedAt != null)
                Text('Last Used: ${DateFormat('MMM d, y HH:mm').format(apiKey.lastUsedAt!)}'),
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

  Future<void> _deleteApiKey(ApiKey apiKey) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete API Key'),
        content: Text('Are you sure you want to delete "${apiKey.name}"? This action cannot be undone and will immediately revoke access for this key.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && _selectedFacilityId != null) {
      try {
        await ApiKeyService.deleteApiKey(
          facilityId: _selectedFacilityId!,
          keyId: apiKey.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('API key deleted successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
          _loadApiKeys();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting API key: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }
}

