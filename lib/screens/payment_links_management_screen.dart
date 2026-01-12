import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/public_payment_link_service.dart';
import '../services/tenant_service.dart';
import '../models/tenant_model.dart';
import 'package:intl/intl.dart';

/// Screen for managing public payment links
class PaymentLinksManagementScreen extends StatefulWidget {
  final String facilityId;

  const PaymentLinksManagementScreen({
    super.key,
    required this.facilityId,
  });

  @override
  State<PaymentLinksManagementScreen> createState() => _PaymentLinksManagementScreenState();
}

class _PaymentLinksManagementScreenState extends State<PaymentLinksManagementScreen> {
  List<PublicPaymentLink> _links = [];
  List<TenantModel> _tenants = [];
  bool _isLoading = true;
  String? _error;
  String? _statusFilter;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Load payment links
      final links = await PublicPaymentLinkService.getPaymentLinksForFacility(
        facilityId: widget.facilityId,
        status: _statusFilter,
      );

      // Load tenants for display
      final tenants = await TenantService.getTenantsForFacility(widget.facilityId);

      setState(() {
        _links = links;
        _tenants = tenants;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading payment links: $e';
        _isLoading = false;
      });
    }
  }

  TenantModel? _getTenant(String tenantId) {
    try {
      return _tenants.firstWhere((t) => t.id == tenantId);
    } catch (e) {
      return null;
    }
  }

  Future<void> _createPaymentLink() async {
    // Show dialog to select tenant and enter amount
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _CreatePaymentLinkDialog(tenants: _tenants),
    );

    if (result == null) return;

    try {
      await PublicPaymentLinkService.createPaymentLink(
        facilityId: widget.facilityId,
        tenantId: result['tenantId'] as String,
        amount: result['amount'] as double,
        description: result['description'] as String?,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Payment link created successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        _loadData();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating payment link: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _copyLink(PublicPaymentLink link) async {
    final url = link.paymentUrl;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment link copied to clipboard'),
          backgroundColor: AppTheme.success,
        ),
      );
    }
  }

  Future<void> _shareLink(PublicPaymentLink link) async {
    // Platform-specific sharing
    // For now, just copy to clipboard
    await _copyLink(link);
  }

  Future<void> _revokeLink(PublicPaymentLink link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke Payment Link'),
        content: const Text('Are you sure you want to revoke this payment link? It will no longer be usable.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await PublicPaymentLinkService.revokePaymentLink(link.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Payment link revoked'),
              backgroundColor: AppTheme.success,
            ),
          );
          _loadData();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error revoking link: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/payment-links';
    
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Payment Links',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadData,
          tooltip: 'Refresh',
        ),
        ElevatedButton.icon(
          onPressed: _createPaymentLink,
          icon: const Icon(Icons.add),
          label: const Text('Create Link'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: AppTheme.textOnDark,
          ),
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
                      Text(_error!),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadData,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Filter chips
                    Container(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          FilterChip(
                            label: const Text('All'),
                            selected: _statusFilter == null,
                            onSelected: (selected) {
                              setState(() {
                                _statusFilter = null;
                              });
                              _loadData();
                            },
                          ),
                          FilterChip(
                            label: const Text('Pending'),
                            selected: _statusFilter == 'pending',
                            onSelected: (selected) {
                              setState(() {
                                _statusFilter = 'pending';
                              });
                              _loadData();
                            },
                          ),
                          FilterChip(
                            label: const Text('Paid'),
                            selected: _statusFilter == 'paid',
                            onSelected: (selected) {
                              setState(() {
                                _statusFilter = 'paid';
                              });
                              _loadData();
                            },
                          ),
                          FilterChip(
                            label: const Text('Revoked'),
                            selected: _statusFilter == 'revoked',
                            onSelected: (selected) {
                              setState(() {
                                _statusFilter = 'revoked';
                              });
                              _loadData();
                            },
                          ),
                        ],
                      ),
                    ),
                    const Divider(),
                    // Links list
                    Expanded(
                      child: _links.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.link_off, size: 64, color: AppTheme.textTertiary),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No payment links',
                                    style: TextStyle(color: AppTheme.textTertiary),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton.icon(
                                    onPressed: _createPaymentLink,
                                    icon: const Icon(Icons.add),
                                    label: const Text('Create Payment Link'),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount: _links.length,
                              itemBuilder: (context, index) {
                                final link = _links[index];
                                final tenant = _getTenant(link.tenantId);
                                return _buildLinkCard(link, tenant);
                              },
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildLinkCard(PublicPaymentLink link, TenantModel? tenant) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getStatusColor(link.status).withOpacity(0.1),
          child: Icon(
            _getStatusIcon(link.status),
            color: _getStatusColor(link.status),
          ),
        ),
        title: Text(
          tenant?.name ?? 'Unknown Tenant',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              'Amount: \$${link.amount.toStringAsFixed(2)}',
              style: TextStyle(
                color: AppTheme.primaryBlue,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Description: ${link.description}',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Chip(
                  label: Text(link.status.toUpperCase()),
                  labelStyle: TextStyle(
                    fontSize: 10,
                    color: _getStatusColor(link.status),
                  ),
                  backgroundColor: _getStatusColor(link.status).withOpacity(0.1),
                ),
                const SizedBox(width: 4),
                Text(
                  'Expires: ${DateFormat('MM/dd/yyyy').format(link.expiresAt)}',
                  style: TextStyle(color: AppTheme.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            if (link.status == 'pending')
              const PopupMenuItem(
                value: 'copy',
                child: Row(
                  children: [
                    Icon(Icons.copy, size: 18),
                    SizedBox(width: 8),
                    Text('Copy Link'),
                  ],
                ),
              ),
            if (link.status == 'pending')
              const PopupMenuItem(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.share, size: 18),
                    SizedBox(width: 8),
                    Text('Share Link'),
                  ],
                ),
              ),
            if (link.status == 'pending')
              const PopupMenuDivider(),
            if (link.status == 'pending')
              const PopupMenuItem(
                value: 'revoke',
                child: Row(
                  children: [
                    Icon(Icons.block, color: AppTheme.error, size: 18),
                    SizedBox(width: 8),
                    Text('Revoke', style: TextStyle(color: AppTheme.error)),
                  ],
                ),
              ),
          ],
          onSelected: (value) {
            switch (value) {
              case 'copy':
                _copyLink(link);
                break;
              case 'share':
                _shareLink(link);
                break;
              case 'revoke':
                _revokeLink(link);
                break;
            }
          },
        ),
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'paid':
        return AppTheme.success;
      case 'pending':
        return AppTheme.primaryBlue;
      case 'revoked':
        return AppTheme.error;
      default:
        return AppTheme.textTertiary;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'paid':
        return Icons.check_circle;
      case 'pending':
        return Icons.pending;
      case 'revoked':
        return Icons.block;
      default:
        return Icons.help_outline;
    }
  }
}

class _CreatePaymentLinkDialog extends StatefulWidget {
  final List<TenantModel> tenants;

  const _CreatePaymentLinkDialog({required this.tenants});

  @override
  State<_CreatePaymentLinkDialog> createState() => _CreatePaymentLinkDialogState();
}

class _CreatePaymentLinkDialogState extends State<_CreatePaymentLinkDialog> {
  String? _selectedTenantId;
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Payment Link'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _selectedTenantId,
                decoration: const InputDecoration(
                  labelText: 'Tenant',
                  border: OutlineInputBorder(),
                ),
                items: widget.tenants.map((tenant) {
                  return DropdownMenuItem<String>(
                    value: tenant.id,
                    child: Text(tenant.name),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedTenantId = value;
                  });
                },
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please select a tenant';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amountController,
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  border: OutlineInputBorder(),
                  prefixText: '\$',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter an amount';
                  }
                  final amount = double.tryParse(value);
                  if (amount == null || amount <= 0) {
                    return 'Please enter a valid amount';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.of(context).pop({
                'tenantId': _selectedTenantId,
                'amount': double.parse(_amountController.text),
                'description': _descriptionController.text.isEmpty
                    ? null
                    : _descriptionController.text,
              });
            }
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

