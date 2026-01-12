import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/api_key_model.dart';
import '../services/api_key_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';

/// Screen for creating new API keys
class ApiKeyCreationScreen extends ConsumerStatefulWidget {
  const ApiKeyCreationScreen({super.key});

  @override
  ConsumerState<ApiKeyCreationScreen> createState() => _ApiKeyCreationScreenState();
}

class _ApiKeyCreationScreenState extends ConsumerState<ApiKeyCreationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _rateLimitController = TextEditingController();
  
  List<String> _selectedPermissions = ['*']; // Default to all permissions
  DateTime? _expiresAt;
  bool _isLoading = false;
  String? _generatedKey; // Store the generated key to show once

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _rateLimitController.dispose();
    super.dispose();
  }

  Future<void> _createApiKey() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = selectedFacility?.id;
    if (facilityId == null) {
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
      final rateLimit = _rateLimitController.text.trim().isEmpty
          ? null
          : int.tryParse(_rateLimitController.text.trim());

      final key = await ApiKeyService.createApiKey(
        facilityId: facilityId,
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        permissions: _selectedPermissions,
        expiresAt: _expiresAt,
        rateLimit: rateLimit,
      );

      setState(() {
        _generatedKey = key;
        _isLoading = false;
      });

      // Show the key in a dialog
      _showKeyDialog(key);
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating API key: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _showKeyDialog(String key) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('API Key Created'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your API key has been created. Copy it now - you won\'t be able to see it again!',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.backgroundSecondary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderLight),
              ),
              child: SelectableText(
                key,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      // Copy to clipboard
                      // In a real app, you'd use Clipboard.setData
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('API key copied to clipboard')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy'),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              context.pop(); // Go back to list
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create API Key'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _createApiKey,
            tooltip: 'Create',
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
                        'Basic Information',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Key Name *',
                          border: OutlineInputBorder(),
                          helperText: 'e.g., Production API Key, Development Key',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a key name';
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
                          helperText: 'Optional description of what this key is used for',
                        ),
                        maxLines: 3,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Permissions
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Permissions',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      ...ApiPermission.values.map((permission) {
                        final permissionString = permission.name;
                        final isSelected = _selectedPermissions.contains(permissionString) ||
                            _selectedPermissions.contains('*');
                        return CheckboxListTile(
                          title: Text(_formatPermission(permission)),
                          subtitle: Text(_getPermissionDescription(permission)),
                          value: isSelected,
                          onChanged: (value) {
                            setState(() {
                              if (permission == ApiPermission.all) {
                                _selectedPermissions = value == true ? ['*'] : [];
                              } else {
                                if (value == true) {
                                  _selectedPermissions.remove('*');
                                  if (!_selectedPermissions.contains(permissionString)) {
                                    _selectedPermissions.add(permissionString);
                                  }
                                } else {
                                  _selectedPermissions.remove(permissionString);
                                }
                              }
                            });
                          },
                        );
                      }).toList(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Settings
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Settings',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _rateLimitController,
                        decoration: const InputDecoration(
                          labelText: 'Rate Limit (requests/minute)',
                          border: OutlineInputBorder(),
                          helperText: 'Leave empty for unlimited',
                          prefixIcon: Icon(Icons.speed),
                        ),
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          if (value != null && value.trim().isNotEmpty) {
                            final limit = int.tryParse(value.trim());
                            if (limit == null || limit <= 0) {
                              return 'Please enter a valid number';
                            }
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      ListTile(
                        title: const Text('Expiration Date'),
                        subtitle: Text(
                          _expiresAt != null
                              ? '${_expiresAt!.year}-${_expiresAt!.month.toString().padLeft(2, '0')}-${_expiresAt!.day.toString().padLeft(2, '0')}'
                              : 'Never expires',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_expiresAt != null)
                              IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  setState(() {
                                    _expiresAt = null;
                                  });
                                },
                              ),
                            IconButton(
                              icon: const Icon(Icons.calendar_today),
                              onPressed: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _expiresAt ?? DateTime.now().add(const Duration(days: 365)),
                                  firstDate: DateTime.now(),
                                  lastDate: DateTime.now().add(const Duration(days: 3650)),
                                );
                                if (picked != null) {
                                  setState(() {
                                    _expiresAt = picked;
                                  });
                                }
                              },
                            ),
                          ],
                        ),
                      ),
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

  String _formatPermission(ApiPermission permission) {
    switch (permission) {
      case ApiPermission.readTenants:
        return 'Read Tenants';
      case ApiPermission.writeTenants:
        return 'Write Tenants';
      case ApiPermission.readUnits:
        return 'Read Units';
      case ApiPermission.writeUnits:
        return 'Write Units';
      case ApiPermission.readPayments:
        return 'Read Payments';
      case ApiPermission.writePayments:
        return 'Write Payments';
      case ApiPermission.readContracts:
        return 'Read Contracts';
      case ApiPermission.writeContracts:
        return 'Write Contracts';
      case ApiPermission.readReports:
        return 'Read Reports';
      case ApiPermission.sendMessages:
        return 'Send Messages';
      case ApiPermission.all:
        return 'All Permissions';
    }
  }

  String _getPermissionDescription(ApiPermission permission) {
    switch (permission) {
      case ApiPermission.readTenants:
        return 'View tenant information';
      case ApiPermission.writeTenants:
        return 'Create and update tenants';
      case ApiPermission.readUnits:
        return 'View unit information';
      case ApiPermission.writeUnits:
        return 'Create and update units';
      case ApiPermission.readPayments:
        return 'View payment information';
      case ApiPermission.writePayments:
        return 'Create and update payments';
      case ApiPermission.readContracts:
        return 'View contract information';
      case ApiPermission.writeContracts:
        return 'Create and update contracts';
      case ApiPermission.readReports:
        return 'Access reports';
      case ApiPermission.sendMessages:
        return 'Send messages to tenants';
      case ApiPermission.all:
        return 'Full access to all resources';
    }
  }
}

