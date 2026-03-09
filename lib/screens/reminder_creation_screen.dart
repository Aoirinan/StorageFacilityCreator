import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/reminder_model.dart';
import '../providers/reminder_provider.dart';
import '../providers/tenant_provider.dart';
import '../models/provider_params.dart';
import '../router/app_route.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../theme/app_theme.dart';

class ReminderCreationScreen extends ConsumerStatefulWidget {
  final String facilityId;
  
  const ReminderCreationScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<ReminderCreationScreen> createState() => _ReminderCreationScreenState();
}

class _ReminderCreationScreenState extends ConsumerState<ReminderCreationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _messageController = TextEditingController();
  
  String _selectedTenantId = '';
  String? _selectedContractId;
  String? _selectedPaymentId;
  ReminderType _selectedType = ReminderType.custom;
  List<ReminderChannel> _selectedChannels = [ReminderChannel.inApp];
  DateTime _selectedScheduledFor = DateTime.now().add(const Duration(hours: 1));

  @override
  void dispose() {
    _titleController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Tenant selection
              Consumer(
                builder: (context, ref, child) {
                  return ref.watch(facilityTenantsProvider(widget.facilityId)).when(
                    data: (tenants) {
                      if (tenants.isEmpty) {
                        return const Card(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('No tenants found for this facility'),
                          ),
                        );
                      }
                      
                      return DropdownButtonFormField<String>(
                        value: _selectedTenantId.isEmpty ? null : _selectedTenantId,
                        decoration: const InputDecoration(
                          labelText: 'Tenant *',
                          border: OutlineInputBorder(),
                        ),
                        items: tenants.map((tenant) {
                          return DropdownMenuItem(
                            value: tenant.id,
                            child: Text(tenant.name),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedTenantId = value ?? '';
                            _selectedContractId = null; // Reset contract selection
                            _selectedPaymentId = null; // Reset payment selection
                          });
                        },
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please select a tenant';
                          }
                          return null;
                        },
                      );
                    },
                    loading: () => const _InlineLoader(message: 'Loading tenants...'),
                    error: (_, __) => const Text('Error loading tenants'),
                  );
                },
              ),
              const SizedBox(height: 16),
              
              // Reminder type
              DropdownButtonFormField<ReminderType>(
                value: _selectedType,
                decoration: const InputDecoration(
                  labelText: 'Reminder Type *',
                  border: OutlineInputBorder(),
                ),
                items: ReminderType.values.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Text(type.displayName),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedType = value ?? ReminderType.custom;
                    _updateMessageTemplate();
                  });
                },
              ),
              const SizedBox(height: 16),
              
              // Contract selection (if applicable)
              if (_selectedTenantId.isNotEmpty && _selectedType != ReminderType.custom)
                Consumer(
                  builder: (context, ref, child) {
                    final tenantParams = FacilityTenantParams(
                      facilityId: widget.facilityId,
                      tenantId: _selectedTenantId,
                    );
                    return ref.watch(tenantContractsProvider(tenantParams)).when(
                      data: (contracts) {
                        if (contracts.isEmpty) {
                          return const Card(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('No contracts found for this tenant'),
                            ),
                          );
                        }
                        
                        return DropdownButtonFormField<String?>(
                          value: _selectedContractId,
                          decoration: const InputDecoration(
                            labelText: 'Contract',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('No specific contract'),
                            ),
                            ...contracts.map((contract) {
                              final label = contract.title.trim().isNotEmpty
                                  ? contract.title
                                  : 'Contract ${contract.id.substring(0, 8)}...';
                              return DropdownMenuItem(
                                value: contract.id,
                                child: Text(label),
                              );
                            }),
                          ],
                          onChanged: (value) {
                            setState(() {
                              _selectedContractId = value;
                            });
                          },
                        );
                      },
                      loading: () => const _InlineLoader(message: 'Loading contracts...'),
                      error: (_, __) => const Text('Error loading contracts'),
                    );
                  },
                ),
              if (_selectedTenantId.isNotEmpty && _selectedType != ReminderType.custom)
                const SizedBox(height: 16),
              
              // Payment selection (if applicable)
              if (_selectedTenantId.isNotEmpty && _selectedType == ReminderType.rentOverdue)
                Consumer(
                  builder: (context, ref, child) {
                    final tenantParams = FacilityTenantParams(
                      facilityId: widget.facilityId,
                      tenantId: _selectedTenantId,
                    );
                    return ref.watch(tenantPaymentsProvider(tenantParams)).when(
                      data: (payments) {
                        final overduePayments = payments.where((p) => p.isOverdue).toList();
                        if (overduePayments.isEmpty) {
                          return const Card(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('No overdue payments found for this tenant'),
                            ),
                          );
                        }
                        
                        return DropdownButtonFormField<String?>(
                          value: _selectedPaymentId,
                          decoration: const InputDecoration(
                            labelText: 'Overdue Payment',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('All overdue payments'),
                            ),
                            ...overduePayments.map((payment) {
                              return DropdownMenuItem(
                                value: payment.id,
                                child: Text('${payment.formattedAmount} - ${_formatDate(payment.dueDate)}'),
                              );
                            }),
                          ],
                          onChanged: (value) {
                            setState(() {
                              _selectedPaymentId = value;
                            });
                          },
                        );
                      },
                      loading: () => const _InlineLoader(message: 'Loading overdue payments...'),
                      error: (_, __) => const Text('Error loading payments'),
                    );
                  },
                ),
              if (_selectedTenantId.isNotEmpty && _selectedType == ReminderType.rentOverdue)
                const SizedBox(height: 16),
              
              // Title
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title *',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a title';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Message
              TextFormField(
                controller: _messageController,
                decoration: const InputDecoration(
                  labelText: 'Message *',
                  border: OutlineInputBorder(),
                ),
                maxLines: 4,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a message';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Channels
              Text(
                'Delivery Channels *',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: ReminderChannel.values.map((channel) {
                  final isSelected = _selectedChannels.contains(channel);
                  return FilterChip(
                    label: Text(channel.displayName),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _selectedChannels.add(channel);
                        } else {
                          _selectedChannels.remove(channel);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              
              // Scheduled for
              InkWell(
                onTap: _selectScheduledFor,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Scheduled For *',
                    border: OutlineInputBorder(),
                  ),
                  child: Text(_formatDateTime(_selectedScheduledFor)),
                ),
              ),
              const SizedBox(height: 24),
              
              // Quick templates
              if (_selectedType == ReminderType.custom)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Quick Templates',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            _buildTemplateButton('Rent Due', 'Your rent payment is due soon.'),
                            _buildTemplateButton('Maintenance', 'Scheduled maintenance is coming up.'),
                            _buildTemplateButton('Inspection', 'Unit inspection is scheduled.'),
                            _buildTemplateButton('Contract Renewal', 'Your contract is expiring soon.'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              
              // Prominent Save Button
              ElevatedButton(
                onPressed: _submitForm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  foregroundColor: AppTheme.textOnDark,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.save),
                    SizedBox(width: 8),
                    Text(
                      'Create Reminder',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      );
  }

  Widget _buildTemplateButton(String title, String message) {
    return ElevatedButton(
      onPressed: () {
        setState(() {
          _titleController.text = title;
          _messageController.text = message;
        });
      },
      child: Text(title),
    );
  }

  void _updateMessageTemplate() {
    switch (_selectedType) {
      case ReminderType.rentDue:
        _titleController.text = 'Rent Payment Due Soon';
        _messageController.text = 'Your rent payment is due soon. Please ensure payment is made on time.';
        break;
      case ReminderType.rentOverdue:
        _titleController.text = 'Rent Payment Overdue';
        _messageController.text = 'Your rent payment is overdue. Please contact us immediately to resolve this matter.';
        break;
      case ReminderType.contractExpiring:
        _titleController.text = 'Contract Expiring Soon';
        _messageController.text = 'Your storage contract is expiring soon. Please contact us to renew.';
        break;
      case ReminderType.contractExpired:
        _titleController.text = 'Contract Expired';
        _messageController.text = 'Your storage contract has expired. Please contact us immediately to renew or vacate the unit.';
        break;
      case ReminderType.paymentFailed:
        _titleController.text = 'Payment Failed';
        _messageController.text = 'Your recent payment could not be processed. Please try again or contact support.';
        break;
      case ReminderType.maintenanceDue:
        _titleController.text = 'Maintenance Due';
        _messageController.text = 'Scheduled maintenance is coming up. Please prepare accordingly.';
        break;
      case ReminderType.inspectionDue:
        _titleController.text = 'Inspection Due';
        _messageController.text = 'Unit inspection is scheduled. Please ensure the unit is accessible.';
        break;
      case ReminderType.custom:
        // Don't auto-fill for custom
        break;
    }
  }

  void _selectScheduledFor() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedScheduledFor,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    
    if (date != null) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_selectedScheduledFor),
      );
      
      if (time != null) {
        setState(() {
          _selectedScheduledFor = DateTime(
            date.year,
            date.month,
            date.day,
            time.hour,
            time.minute,
          );
        });
      }
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  String _formatDateTime(DateTime date) {
    return '${date.month}/${date.day}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _submitForm() async {
    if (!_formKey.currentState!.validate()) return;
    
    if (_selectedChannels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one delivery channel')),
      );
      return;
    }
    
    try {
      await ref.read(reminderOperationsProvider.notifier).createReminder(
        tenantId: _selectedTenantId,
        facilityId: widget.facilityId,
        contractId: _selectedContractId,
        paymentId: _selectedPaymentId,
        type: _selectedType,
        channels: _selectedChannels,
        title: _titleController.text.trim(),
        message: _messageController.text.trim(),
        scheduledFor: _selectedScheduledFor,
      );
      
      if (mounted) {
        ref.invalidate(reminderListProvider(widget.facilityId));
        ref.invalidate(reminderStatsProvider(widget.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reminder created successfully')),
        );
        // Always go to reminders list so we never land on a blank screen
        // (e.g. when user arrived via calendar's "Add to date" which uses context.go)
        context.go(AppRoute.reminders);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating reminder: $e')),
        );
      }
    }
  }
}

class _InlineLoader extends StatelessWidget {
  final String message;
  const _InlineLoader({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(message),
        ],
      ),
    );
  }
}
