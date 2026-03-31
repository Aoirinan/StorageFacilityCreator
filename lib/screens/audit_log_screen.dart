import 'dart:convert';
import 'dart:html' as html;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../services/export_service.dart';
import '../providers/active_facility_provider.dart';

/// Provider for audit logs stream
final auditLogsProvider = StreamProvider.family<List<Map<String, dynamic>>, String>((ref, facilityId) {
  return FirebaseFirestore.instance
      .collection('facilities')
      .doc(facilityId)
      .collection('auditLogs')
      .orderBy('timestamp', descending: true)
      .limit(1000) // Limit to most recent 1000 entries
      .snapshots()
      .map((snapshot) => snapshot.docs.map((doc) {
            final data = doc.data();
            return {
              'id': doc.id,
              ...data,
            };
          }).toList());
});

class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  String _searchQuery = '';
  String? _eventTypeFilter;
  String? _targetTypeFilter;
  String? _actorRoleFilter;
  DateTime? _startDate;
  DateTime? _endDate;

  final List<String> _eventTypes = [
    'tenant.created',
    'tenant.edited',
    'tenant.archived',
    'tenant.deleted',
    'tenant.bulkDeleted',
    'unit.statusChanged',
    'unit.deleted',
    'payment.created',
    'payment.charged',
    'payment.refunded',
    'payment.refundRequested',
    'payment.deleted',
    'invoice.created',
    'invoice.voided',
    'template.created',
    'template.edited',
    'reminder.sent',
    'delinquency.lateFeeApplied',
    'delinquency.lockoutTriggered',
    'delinquency.unlocked',
    'portal.accessed',
    'team_note.deleted',
    'conversation.archived',
    'conversation.deleted',
    'contract.deleted',
  ];

  final List<String> _targetTypes = [
    'tenant',
    'unit',
    'payment',
    'invoice',
    'ledgerEntry',
    'template',
    'reminder',
    'gateAccess',
    'team_note',
    'conversation',
    'contract',
  ];

  final List<String> _actorRoles = [
    'owner',
    'manager',
    'employee',
    'system',
    'tenant',
  ];

  @override
  Widget build(BuildContext context) {
    final facilityId = ref.watch(activeFacilityIdProvider).value;

    if (facilityId == null) {
      return ModernPageWrapper(
        currentRoute: '/audit-logs',
        title: 'Audit Logs',
        child: const Center(
          child: Text('Please select a facility'),
        ),
      );
    }

    return ModernPageWrapper(
      currentRoute: '/audit-logs',
      title: 'Audit Logs',
      actions: [
        IconButton(
          icon: const Icon(Icons.download),
          onPressed: () => _exportAuditLogs(facilityId),
          tooltip: 'Export Audit Logs',
        ),
      ],
      child: Column(
        children: [
          _buildFilters(),
          Expanded(
            child: _buildAuditLogsList(facilityId),
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
      child: Column(
        children: [
          // Search bar
          TextField(
            decoration: InputDecoration(
              labelText: 'Search audit logs',
              hintText: 'Search by event type, actor, target...',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
          const SizedBox(height: 12),
          // Filter dropdowns
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  value: _eventTypeFilter,
                  decoration: InputDecoration(
                    labelText: 'Event Type',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Events')),
                    ..._eventTypes.map((type) {
                      return DropdownMenuItem(
                        value: type,
                        child: Text(type.replaceAll('.', ' ').replaceAll(RegExp(r'(?<=[a-z])(?=[A-Z])'), ' ')),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _eventTypeFilter = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  value: _targetTypeFilter,
                  decoration: InputDecoration(
                    labelText: 'Target Type',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Types')),
                    ..._targetTypes.map((type) {
                      return DropdownMenuItem(
                        value: type,
                        child: Text(type),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _targetTypeFilter = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  value: _actorRoleFilter,
                  decoration: InputDecoration(
                    labelText: 'Actor Role',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Roles')),
                    ..._actorRoles.map((role) {
                      return DropdownMenuItem(
                        value: role,
                        child: Text(role[0].toUpperCase() + role.substring(1)),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _actorRoleFilter = value;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Date range filters
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _startDate ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() {
                        _startDate = date;
                      });
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Start Date',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      suffixIcon: const Icon(Icons.calendar_today),
                    ),
                    child: Text(
                      _startDate != null
                          ? DateFormat('MM/dd/yyyy').format(_startDate!)
                          : 'Select start date',
                      style: TextStyle(
                        color: _startDate != null ? null : AppTheme.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _endDate ?? DateTime.now(),
                      firstDate: _startDate ?? DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() {
                        _endDate = date;
                      });
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'End Date',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      suffixIcon: const Icon(Icons.calendar_today),
                    ),
                    child: Text(
                      _endDate != null
                          ? DateFormat('MM/dd/yyyy').format(_endDate!)
                          : 'Select end date',
                      style: TextStyle(
                        color: _endDate != null ? null : AppTheme.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  setState(() {
                    _startDate = null;
                    _endDate = null;
                  });
                },
                tooltip: 'Clear date filters',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAuditLogsList(String facilityId) {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(auditLogsProvider(facilityId)).when(
          data: (logs) {
            // Apply filters
            final filteredLogs = logs.where((log) {
              // Event type filter
              if (_eventTypeFilter != null) {
                final eventType = log['eventType'] as String?;
                if (eventType != _eventTypeFilter) {
                  return false;
                }
              }

              // Target type filter
              if (_targetTypeFilter != null) {
                final targetType = log['targetType'] as String?;
                if (targetType != _targetTypeFilter) {
                  return false;
                }
              }

              // Actor role filter
              if (_actorRoleFilter != null) {
                final actorRole = log['actorRole'] as String?;
                if (actorRole != _actorRoleFilter) {
                  return false;
                }
              }

              // Date range filter
              final timestamp = log['timestamp'] as Timestamp?;
              if (timestamp != null) {
                final logDate = timestamp.toDate();
                if (_startDate != null && logDate.isBefore(_startDate!)) {
                  return false;
                }
                if (_endDate != null) {
                  final endDateEnd = DateTime(_endDate!.year, _endDate!.month, _endDate!.day, 23, 59, 59);
                  if (logDate.isAfter(endDateEnd)) {
                    return false;
                  }
                }
              }

              // Search filter
              if (_searchQuery.isNotEmpty) {
                final query = _searchQuery.toLowerCase();
                final eventType = (log['eventType'] as String? ?? '').toLowerCase();
                final actorEmail = (log['actorEmail'] as String? ?? '').toLowerCase();
                final targetId = (log['targetId'] as String? ?? '').toLowerCase();
                final targetType = (log['targetType'] as String? ?? '').toLowerCase();

                if (!eventType.contains(query) &&
                    !actorEmail.contains(query) &&
                    !targetId.contains(query) &&
                    !targetType.contains(query)) {
                  return false;
                }
              }

              return true;
            }).toList();

            if (filteredLogs.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.history, size: 64, color: AppTheme.textTertiary),
                    const SizedBox(height: 16),
                    Text(
                      _searchQuery.isNotEmpty || _eventTypeFilter != null || _targetTypeFilter != null
                          ? 'No audit logs match your filters'
                          : 'No audit logs yet',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
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
                return _buildAuditLogCard(log);
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
                  'Error loading audit logs: $error',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.error,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAuditLogCard(Map<String, dynamic> log) {
    final eventType = log['eventType'] as String? ?? 'unknown';
    final actorEmail = log['actorEmail'] as String? ?? 'Unknown';
    final actorRole = log['actorRole'] as String? ?? 'unknown';
    final targetType = log['targetType'] as String? ?? 'unknown';
    final targetId = log['targetId'] as String? ?? 'unknown';
    final timestamp = log['timestamp'] as Timestamp?;
    final tenantId = log['tenantId'] as String?;
    final metadata = log['metadata'] as Map<String, dynamic>?;

    final dateTime = timestamp != null
        ? DateFormat('MM/dd/yyyy HH:mm:ss').format(timestamp.toDate())
        : 'Unknown date';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: _getEventIcon(eventType),
        title: Text(
          eventType.replaceAll('.', ' ').replaceAll(RegExp(r'(?<=[a-z])(?=[A-Z])'), ' '),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          '$dateTime • $targetType: ${targetId.substring(0, 8)}...',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDetailRow('Actor', '$actorEmail (${actorRole})'),
                _buildDetailRow('Target', '$targetType: $targetId'),
                if (tenantId != null) _buildDetailRow('Tenant ID', tenantId),
                _buildDetailRow('Timestamp', dateTime),
                if (log['before'] != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Before:',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatJson(log['before']),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
                if (log['after'] != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'After:',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatJson(log['after']),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
                if (metadata != null && metadata.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Metadata:',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatJson(metadata),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ],
            ),
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
            width: 100,
            child: Text(
              '$label:',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Icon _getEventIcon(String eventType) {
    if (eventType.contains('deleted')) {
      return Icon(Icons.delete_forever, color: AppTheme.error);
    } else if (eventType.contains('tenant')) {
      return Icon(Icons.person, color: AppTheme.primaryBlue);
    } else if (eventType.contains('unit')) {
      return Icon(Icons.warehouse, color: AppTheme.info);
    } else if (eventType.contains('payment') || eventType.contains('charge') || eventType.contains('refund')) {
      return Icon(Icons.payment, color: AppTheme.success);
    } else if (eventType.contains('invoice')) {
      return Icon(Icons.receipt, color: AppTheme.info);
    } else if (eventType.contains('delinquency') || eventType.contains('lockout')) {
      return Icon(Icons.warning, color: AppTheme.error);
    } else if (eventType.contains('template')) {
      return Icon(Icons.description, color: AppTheme.warning);
    } else if (eventType.contains('reminder')) {
      return Icon(Icons.notifications, color: AppTheme.info);
    } else if (eventType.contains('portal')) {
      return Icon(Icons.login, color: AppTheme.primaryBlue);
    } else if (eventType.contains('conversation')) {
      return Icon(Icons.forum, color: AppTheme.primaryBlue);
    } else if (eventType.contains('team_note') || eventType.contains('note')) {
      return Icon(Icons.sticky_note_2, color: AppTheme.warning);
    } else if (eventType.contains('contract')) {
      return Icon(Icons.article, color: AppTheme.textSecondary);
    } else {
      return Icon(Icons.history, color: AppTheme.textTertiary);
    }
  }

  String _formatJson(dynamic data) {
    if (data is Map) {
      return data.entries
          .map((e) => '${e.key}: ${e.value}')
          .join('\n');
    }
    return data.toString();
  }

  Future<void> _exportAuditLogs(String facilityId) async {
    try {
      // Show loading indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 16),
                Text('Exporting audit logs...'),
              ],
            ),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // Export audit logs to CSV
      final csvContent = await ExportService.exportAuditLogsToCSV(
        facilityId: facilityId,
        startDate: _startDate,
        endDate: _endDate,
        eventType: _eventTypeFilter,
      );

      // Create download link for web
      final blob = html.Blob([csvContent], 'text/csv');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..setAttribute('download', 'audit_logs_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv')
        ..click();
      html.Url.revokeObjectUrl(url);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Audit logs exported successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error exporting audit logs: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}
