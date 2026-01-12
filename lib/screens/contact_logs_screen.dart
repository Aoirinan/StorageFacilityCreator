import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../models/contact_log_model.dart';
import '../models/tenant_model.dart';
import '../services/contact_log_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../utils/error_message_helper.dart';

/// Provider for contact logs stream
final contactLogsProvider = StreamProvider.family<List<ContactLog>, Map<String, String>>((ref, params) {
  return ContactLogService.getContactLogStream(
    tenantId: params['tenantId']!,
    facilityId: params['facilityId']!,
  );
});

class ContactLogsScreen extends ConsumerStatefulWidget {
  final String tenantId;
  final String facilityId;
  final TenantModel? tenant; // Optional: for display

  const ContactLogsScreen({
    super.key,
    required this.tenantId,
    required this.facilityId,
    this.tenant,
  });

  @override
  ConsumerState<ContactLogsScreen> createState() => _ContactLogsScreenState();
}

class _ContactLogsScreenState extends ConsumerState<ContactLogsScreen> {
  ContactLogType? _typeFilter;
  ContactLogDirection? _directionFilter;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/contact-logs',
      title: 'Contact Logs${widget.tenant != null ? ' - ${widget.tenant!.name}' : ''}',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showAddContactLogDialog(),
          tooltip: 'Add Contact Log',
        ),
      ],
      child: Column(
        children: [
          _buildFilters(),
          Expanded(
            child: _buildContactLogsList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<ContactLogType?>(
              value: _typeFilter,
              decoration: InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('All Types')),
                ...ContactLogType.values.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Text(_getTypeLabel(type)),
                  );
                }),
              ],
              onChanged: (value) {
                setState(() {
                  _typeFilter = value;
                });
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<ContactLogDirection?>(
              value: _directionFilter,
              decoration: InputDecoration(
                labelText: 'Direction',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('All Directions')),
                ...ContactLogDirection.values.map((direction) {
                  return DropdownMenuItem(
                    value: direction,
                    child: Text(direction == ContactLogDirection.inbound ? 'Inbound' : 'Outbound'),
                  );
                }),
              ],
              onChanged: (value) {
                setState(() {
                  _directionFilter = value;
                });
              },
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () => _showDateRangeDialog(),
            tooltip: 'Select Date Range',
          ),
          if (_startDate != null || _endDate != null)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                setState(() {
                  _startDate = null;
                  _endDate = null;
                });
              },
              tooltip: 'Clear Date Filter',
            ),
        ],
      ),
    );
  }

  Widget _buildContactLogsList() {
    final logsAsync = ref.watch(contactLogsProvider({
      'tenantId': widget.tenantId,
      'facilityId': widget.facilityId,
    }));

    return logsAsync.when(
      data: (logs) {
        // Apply filters
        var filteredLogs = logs;
        
        if (_typeFilter != null) {
          filteredLogs = filteredLogs.where((log) => log.type == _typeFilter).toList();
        }
        
        if (_directionFilter != null) {
          filteredLogs = filteredLogs.where((log) => log.direction == _directionFilter).toList();
        }
        
        if (_startDate != null) {
          filteredLogs = filteredLogs.where((log) => 
            log.contactDate.isAfter(_startDate!) || log.contactDate.isAtSameMomentAs(_startDate!)
          ).toList();
        }
        
        if (_endDate != null) {
          filteredLogs = filteredLogs.where((log) => 
            log.contactDate.isBefore(_endDate!) || log.contactDate.isAtSameMomentAs(_endDate!)
          ).toList();
        }

        // Sort by date (newest first)
        filteredLogs.sort((a, b) => b.contactDate.compareTo(a.contactDate));

        if (filteredLogs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.phone_disabled, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                Text(
                  'No contact logs found',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () => _showAddContactLogDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add First Contact Log'),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16.0),
          itemCount: filteredLogs.length,
          itemBuilder: (context, index) {
            final log = filteredLogs[index];
            return _buildContactLogCard(log);
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(
              'Error loading contact logs',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppTheme.error,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(contactLogsProvider({
                'tenantId': widget.tenantId,
                'facilityId': widget.facilityId,
              })),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactLogCard(ContactLog log) {
    final icon = _getTypeIcon(log.type);
    final color = _getTypeColor(log.type);

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.1),
          child: Icon(icon, color: color),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                log.subject ?? _getTypeLabel(log.type),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (log.isAutoGenerated)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.info.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Auto',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.info,
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              '${_getTypeLabel(log.type)} • ${log.directionDisplayName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (log.contactMethod != null)
              Text(
                'Contact: ${log.contactMethod}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (log.message != null && log.message!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  log.message!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            const SizedBox(height: 4),
            Text(
              '${DateFormat('MMM d, y • h:mm a').format(log.contactDate)} • ${log.contactedByName ?? 'Unknown'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.more_vert),
          onPressed: () => _showContactLogMenu(log),
        ),
        isThreeLine: true,
      ),
    );
  }

  IconData _getTypeIcon(ContactLogType type) {
    switch (type) {
      case ContactLogType.call:
        return Icons.phone;
      case ContactLogType.email:
        return Icons.email;
      case ContactLogType.sms:
        return Icons.sms;
      case ContactLogType.inPerson:
        return Icons.person;
      case ContactLogType.note:
        return Icons.note;
      case ContactLogType.reminder:
        return Icons.notifications;
      case ContactLogType.other:
        return Icons.more_horiz;
    }
  }

  Color _getTypeColor(ContactLogType type) {
    switch (type) {
      case ContactLogType.call:
        return AppTheme.success;
      case ContactLogType.email:
        return AppTheme.primaryBlue;
      case ContactLogType.sms:
        return AppTheme.info;
      case ContactLogType.inPerson:
        return AppTheme.warning;
      case ContactLogType.note:
        return AppTheme.textSecondary;
      case ContactLogType.reminder:
        return AppTheme.primaryBlue;
      case ContactLogType.other:
        return AppTheme.textTertiary;
    }
  }

  String _getTypeLabel(ContactLogType type) {
    switch (type) {
      case ContactLogType.call:
        return 'Phone Call';
      case ContactLogType.email:
        return 'Email';
      case ContactLogType.sms:
        return 'SMS';
      case ContactLogType.inPerson:
        return 'In Person';
      case ContactLogType.note:
        return 'Note';
      case ContactLogType.reminder:
        return 'Reminder';
      case ContactLogType.other:
        return 'Other';
    }
  }

  void _showAddContactLogDialog() {
    final formKey = GlobalKey<FormState>();
    final subjectController = TextEditingController();
    final messageController = TextEditingController();
    final contactMethodController = TextEditingController();
    ContactLogType selectedType = ContactLogType.call;
    ContactLogDirection selectedDirection = ContactLogDirection.outbound;
    DateTime selectedDate = DateTime.now();
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Contact Log'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<ContactLogType>(
                    value: selectedType,
                    decoration: const InputDecoration(
                      labelText: 'Type',
                      border: OutlineInputBorder(),
                    ),
                    items: ContactLogType.values.map((type) {
                      return DropdownMenuItem(
                        value: type,
                        child: Text(_getTypeLabel(type)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() {
                          selectedType = value;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<ContactLogDirection>(
                    value: selectedDirection,
                    decoration: const InputDecoration(
                      labelText: 'Direction',
                      border: OutlineInputBorder(),
                    ),
                    items: ContactLogDirection.values.map((direction) {
                      return DropdownMenuItem(
                        value: direction,
                        child: Text(direction == ContactLogDirection.inbound
                            ? 'Inbound'
                            : 'Outbound'),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() {
                          selectedDirection = value;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: subjectController,
                    decoration: const InputDecoration(
                      labelText: 'Subject',
                      border: OutlineInputBorder(),
                      hintText: 'Brief subject or summary',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Subject is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: contactMethodController,
                    decoration: const InputDecoration(
                      labelText: 'Contact Method',
                      border: OutlineInputBorder(),
                      hintText: 'e.g., Phone, Email, In-person',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: messageController,
                    decoration: const InputDecoration(
                      labelText: 'Message/Notes',
                      border: OutlineInputBorder(),
                      hintText: 'Additional details or message content',
                    ),
                    maxLines: 4,
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    title: const Text('Contact Date'),
                    subtitle: Text(DateFormat('MMM d, y • h:mm a').format(selectedDate)),
                    trailing: IconButton(
                      icon: const Icon(Icons.calendar_today),
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now().add(const Duration(days: 1)),
                        );
                        if (date != null) {
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(selectedDate),
                          );
                          if (time != null) {
                            setDialogState(() {
                              selectedDate = DateTime(
                                date.year,
                                date.month,
                                date.day,
                                time.hour,
                                time.minute,
                              );
                            });
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSaving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: isSaving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) {
                        return;
                      }

                      setDialogState(() {
                        isSaving = true;
                      });

                      try {
                        await ContactLogService.createContactLog(
                          tenantId: widget.tenantId,
                          facilityId: widget.facilityId,
                          type: selectedType,
                          direction: selectedDirection,
                          subject: subjectController.text.trim(),
                          message: messageController.text.trim().isEmpty
                              ? null
                              : messageController.text.trim(),
                          contactMethod: contactMethodController.text.trim().isEmpty
                              ? null
                              : contactMethodController.text.trim(),
                          contactDate: selectedDate,
                        );

                        if (mounted) {
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Contact log created successfully'),
                              backgroundColor: AppTheme.success,
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          setDialogState(() {
                            isSaving = false;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error creating contact log: ${ErrorMessageHelper.getUserFriendlyMessage(e)}'),
                              backgroundColor: AppTheme.error,
                            ),
                          );
                        }
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: AppTheme.textOnDark,
              ),
              child: isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditContactLogDialog(ContactLog log) {
    final formKey = GlobalKey<FormState>();
    final subjectController = TextEditingController(text: log.subject ?? '');
    final messageController = TextEditingController(text: log.message ?? '');
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit Contact Log'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: subjectController,
                    decoration: const InputDecoration(
                      labelText: 'Subject',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Subject is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: messageController,
                    decoration: const InputDecoration(
                      labelText: 'Message/Notes',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 4,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSaving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: isSaving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) {
                        return;
                      }

                      setDialogState(() {
                        isSaving = true;
                      });

                      try {
                        await ContactLogService.updateContactLog(
                          tenantId: widget.tenantId,
                          facilityId: widget.facilityId,
                          logId: log.id,
                          subject: subjectController.text.trim(),
                          message: messageController.text.trim().isEmpty
                              ? null
                              : messageController.text.trim(),
                        );

                        if (mounted) {
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Contact log updated successfully'),
                              backgroundColor: AppTheme.success,
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          setDialogState(() {
                            isSaving = false;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error updating contact log: ${ErrorMessageHelper.getUserFriendlyMessage(e)}'),
                              backgroundColor: AppTheme.error,
                            ),
                          );
                        }
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: AppTheme.textOnDark,
              ),
              child: isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save Changes'),
            ),
          ],
        ),
      ),
    );
  }

  void _showContactLogMenu(ContactLog log) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.visibility),
            title: const Text('View Details'),
            onTap: () {
              Navigator.pop(context);
              _showContactLogDetails(log);
            },
          ),
          if (!log.isAutoGenerated)
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(context);
                _showEditContactLogDialog(log);
              },
            ),
          if (!log.isAutoGenerated)
            ListTile(
              leading: const Icon(Icons.delete, color: AppTheme.error),
              title: const Text('Delete', style: TextStyle(color: AppTheme.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(log);
              },
            ),
        ],
      ),
    );
  }

  void _showContactLogDetails(ContactLog log) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(log.subject ?? _getTypeLabel(log.type)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailRow('Type', _getTypeLabel(log.type)),
              _buildDetailRow('Direction', log.directionDisplayName),
              _buildDetailRow('Date', DateFormat('MMM d, y • h:mm a').format(log.contactDate)),
              if (log.contactMethod != null)
                _buildDetailRow('Contact Method', log.contactMethod!),
              if (log.contactedByName != null)
                _buildDetailRow('Contacted By', log.contactedByName!),
              if (log.message != null && log.message!.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('Message:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(log.message!),
              ],
              if (log.isAutoGenerated) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.info.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('This log was automatically generated'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _confirmDelete(ContactLog log) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Contact Log'),
        content: const Text('Are you sure you want to delete this contact log? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await ContactLogService.deleteContactLog(
                  facilityId: widget.facilityId,
                  tenantId: widget.tenantId,
                  logId: log.id,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Contact log deleted'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error deleting contact log: $e'),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showDateRangeDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Select Date Range'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Start Date'),
                subtitle: Text(_startDate != null ? DateFormat('MM/dd/yyyy').format(_startDate!) : 'None'),
                trailing: IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _startDate ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() {
                        _startDate = date;
                      });
                    }
                  },
                ),
              ),
              ListTile(
                title: const Text('End Date'),
                subtitle: Text(_endDate != null ? DateFormat('MM/dd/yyyy').format(_endDate!) : 'None'),
                trailing: IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _endDate ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() {
                        _endDate = date;
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _startDate = null;
                  _endDate = null;
                });
              },
              child: const Text('Clear'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() {});
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}

