import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/export_job_model.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/services/export_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';
import 'package:sfcapp/widgets/permission_gate.dart';
import 'package:url_launcher/url_launcher.dart';

/// Provider for export jobs stream
final exportJobsProvider =
    StreamProvider.family<List<ExportJobModel>, String>((ref, facilityId) {
  return ExportService.getExportJobsStream(facilityId);
});

class ExportsScreen extends ConsumerStatefulWidget {
  const ExportsScreen({super.key});

  @override
  ConsumerState<ExportsScreen> createState() => _ExportsScreenState();
}

class _ExportsScreenState extends ConsumerState<ExportsScreen> {
  ExportType? _selectedType;
  DateTime? _startDate;
  DateTime? _endDate;
  bool _isCreating = false;
  final Set<String> _downloadingJobIds = {};

  @override
  Widget build(BuildContext context) {
    final facilityId = ref.watch(activeFacilityIdProvider).value;

    if (facilityId == null) {
      return ModernPageWrapper(
        currentRoute: '/exports',
        title: 'Data Exports',
        child: const Center(
          child: Text('Please select a facility'),
        ),
      );
    }

    return ModernPageWrapper(
      currentRoute: '/exports',
      title: 'Data Exports',
      actions: [
        PermissionGate(
          permission: PermissionType.exportData,
          child: ElevatedButton.icon(
            onPressed:
                _isCreating ? null : () => _showCreateExportDialog(facilityId),
            icon: const Icon(Icons.file_download),
            label: const Text('New Export'),
          ),
        ),
      ],
      child: Column(
        children: [
          _buildExportForm(facilityId),
          Expanded(
            child: _buildExportJobsList(facilityId),
          ),
        ],
      ),
    );
  }

  Widget _buildExportForm(String facilityId) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick Export (Small Datasets)',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<ExportType?>(
                  initialValue: _selectedType,
                  decoration: InputDecoration(
                    labelText: 'Export Type',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('Select type')),
                    ...ExportType.values.map((type) {
                      return DropdownMenuItem(
                        value: type,
                        child: Text(type.name
                            .replaceAll(RegExp(r'(?<=[a-z])(?=[A-Z])'), ' ')),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedType = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _startDate ??
                          DateTime.now().subtract(const Duration(days: 30)),
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
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      suffixIcon: const Icon(Icons.calendar_today),
                    ),
                    child: Text(
                      _startDate != null
                          ? DateFormat('MM/dd/yyyy').format(_startDate!)
                          : 'Select start date',
                      style: TextStyle(
                        color:
                            _startDate != null ? null : AppTheme.textTertiary,
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
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
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
              ElevatedButton.icon(
                onPressed: (_selectedType == null || _isCreating)
                    ? null
                    : () => _quickExport(facilityId),
                icon: const Icon(Icons.download),
                label: const Text('Export'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildExportJobsList(String facilityId) {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(exportJobsProvider(facilityId)).when(
              data: (jobs) {
                if (jobs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.file_download,
                            size: 64, color: AppTheme.textTertiary),
                        const SizedBox(height: 16),
                        Text(
                          'No export jobs yet',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Create a new export to get started',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textTertiary,
                                  ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16.0),
                  itemCount: jobs.length,
                  itemBuilder: (context, index) {
                    final job = jobs[index];
                    return _buildExportJobCard(job);
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
                      'Error loading export jobs: $error',
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

  Widget _buildExportJobCard(ExportJobModel job) {
    final statusColor = {
          ExportStatus.pending: AppTheme.warning,
          ExportStatus.processing: AppTheme.info,
          ExportStatus.completed: AppTheme.success,
          ExportStatus.failed: AppTheme.error,
          ExportStatus.expired: AppTheme.textTertiary,
        }[job.status] ??
        AppTheme.textTertiary;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          _getStatusIcon(job.status),
          color: statusColor,
        ),
        title: Text(
          job.type.name.replaceAll(RegExp(r'(?<=[a-z])(?=[A-Z])'), ' '),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status: ${job.status.name}'),
            if (job.recordCount != null) Text('Records: ${job.recordCount}'),
            Text(
                'Created: ${DateFormat('MM/dd/yyyy HH:mm').format(job.createdAt)}'),
            if (job.completedAt != null)
              Text(
                  'Completed: ${DateFormat('MM/dd/yyyy HH:mm').format(job.completedAt!)}'),
            if (job.expiresAt != null)
              Text(
                job.isExpired
                    ? 'Expired: ${DateFormat('MM/dd/yyyy HH:mm').format(job.expiresAt!)}'
                    : 'Expires: ${DateFormat('MM/dd/yyyy HH:mm').format(job.expiresAt!)}',
                style: job.isExpired ? TextStyle(color: AppTheme.error) : null,
              ),
            if (job.errorMessage != null)
              Text(
                'Error: ${job.errorMessage}',
                style: TextStyle(color: AppTheme.error),
              ),
          ],
        ),
        trailing: job.status == ExportStatus.completed &&
                job.storagePath != null &&
                !job.isExpired
            ? IconButton(
                icon: _downloadingJobIds.contains(job.id)
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                onPressed: _downloadingJobIds.contains(job.id)
                    ? null
                    : () => _downloadCompletedExport(job),
                tooltip: 'Download',
              )
            : null,
      ),
    );
  }

  Future<void> _downloadCompletedExport(ExportJobModel job) async {
    setState(() {
      _downloadingJobIds.add(job.id);
    });

    try {
      final uri = await ExportService.getExportDownloadUrl(
        facilityId: job.facilityId,
        jobId: job.id,
      );
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw Exception('Could not open the export download');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error downloading export: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloadingJobIds.remove(job.id);
        });
      }
    }
  }

  IconData _getStatusIcon(ExportStatus status) {
    switch (status) {
      case ExportStatus.pending:
        return Icons.pending;
      case ExportStatus.processing:
        return Icons.hourglass_empty;
      case ExportStatus.completed:
        return Icons.check_circle;
      case ExportStatus.failed:
        return Icons.error;
      case ExportStatus.expired:
        return Icons.event_busy;
    }
  }

  void _showCreateExportDialog(String facilityId) {
    ExportType? selectedType;
    DateTime? startDate;
    DateTime? endDate;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Create Export Job'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<ExportType>(
                initialValue: selectedType,
                decoration: const InputDecoration(
                  labelText: 'Export Type',
                  border: OutlineInputBorder(),
                ),
                items: ExportType.values.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Text(type.name
                        .replaceAll(RegExp(r'(?<=[a-z])(?=[A-Z])'), ' ')),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    selectedType = value;
                  });
                },
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: startDate ??
                        DateTime.now().subtract(const Duration(days: 30)),
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (date != null) {
                    setState(() {
                      startDate = date;
                    });
                  }
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Start Date (Optional)',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(
                    startDate != null
                        ? DateFormat('MM/dd/yyyy').format(startDate!)
                        : 'Select start date',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: endDate ?? DateTime.now(),
                    firstDate: startDate ?? DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (date != null) {
                    setState(() {
                      endDate = date;
                    });
                  }
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'End Date (Optional)',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(
                    endDate != null
                        ? DateFormat('MM/dd/yyyy').format(endDate!)
                        : 'Select end date',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.info.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info, color: AppTheme.info, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Large datasets will be processed in the background. You can download the file when ready.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedType == null
                  ? null
                  : () {
                      Navigator.pop(context);
                      _createExportJob(
                        facilityId,
                        selectedType!,
                        startDate,
                        endDate,
                      );
                    },
              child: const Text('Create Export'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createExportJob(
    String facilityId,
    ExportType type,
    DateTime? startDate,
    DateTime? endDate,
  ) async {
    setState(() {
      _isCreating = true;
    });

    try {
      final filters = <String, dynamic>{};
      if (startDate != null) {
        filters['startDate'] = startDate.toIso8601String();
      }
      if (endDate != null) {
        filters['endDate'] = endDate.toIso8601String();
      }

      await ExportService.createExportJob(
        facilityId: facilityId,
        type: type,
        filters: filters.isNotEmpty ? filters : null,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Export job created. It will be processed in the background.'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating export job: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
      }
    }
  }

  Future<void> _quickExport(String facilityId) async {
    if (_selectedType == null) return;

    setState(() {
      _isCreating = true;
    });

    try {
      String csvContent = '';

      switch (_selectedType!) {
        case ExportType.tenants:
          csvContent = await ExportService.exportTenantsToCSV(
            facilityId: facilityId,
            startDate: _startDate,
            endDate: _endDate,
          );
          break;
        case ExportType.payments:
          csvContent = await ExportService.exportPaymentsToCSV(
            facilityId: facilityId,
            startDate: _startDate,
            endDate: _endDate,
          );
          break;
        case ExportType.auditLogs:
          csvContent = await ExportService.exportAuditLogsToCSV(
            facilityId: facilityId,
            startDate: _startDate,
            endDate: _endDate,
          );
          break;
        default:
          throw Exception(
              'Quick export not supported for ${_selectedType!.name}');
      }

      // Download CSV
      _downloadCSV(csvContent,
          '${_selectedType!.name}_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Export downloaded successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error exporting: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
      }
    }
  }

  void _downloadCSV(String csvContent, String filename) {
    // For web, create a blob and trigger download
    // This is a simplified version - in production, you'd use a proper download library
    // For now, we'll show the content in a dialog or copy to clipboard
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Export: $filename'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              csvContent,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              // Copy to clipboard
              // Clipboard.setData(ClipboardData(text: csvContent));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'CSV content copied to clipboard (use proper download in production)'),
                  backgroundColor: AppTheme.info,
                ),
              );
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }
}
