import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/scheduled_report_model.dart';
import '../services/report_scheduling_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';

/// Screen for managing scheduled reports
class ReportSchedulingManagementScreen extends ConsumerStatefulWidget {
  const ReportSchedulingManagementScreen({super.key});

  @override
  ConsumerState<ReportSchedulingManagementScreen> createState() => _ReportSchedulingManagementScreenState();
}

class _ReportSchedulingManagementScreenState extends ConsumerState<ReportSchedulingManagementScreen> {
  String? _selectedFacilityId;
  List<ScheduledReport> _scheduledReports = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadScheduledReports();
  }

  Future<void> _loadScheduledReports() async {
    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = _selectedFacilityId ?? selectedFacility?.id ?? '';
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _scheduledReports = [];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final reports = await ReportSchedulingService.getScheduledReports(facilityId);
      setState(() {
        _scheduledReports = reports;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading scheduled reports: $e';
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
        _loadScheduledReports();
      });
    }

    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/report-scheduling';

    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Scheduled Reports',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateScheduleDialog(),
          tooltip: 'Schedule Report',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadScheduledReports,
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
                        onPressed: _loadScheduledReports,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _scheduledReports.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.schedule, size: 64, color: AppTheme.textTertiary),
                          const SizedBox(height: 16),
                          Text(
                            'No scheduled reports',
                            style: TextStyle(color: AppTheme.textTertiary, fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Schedule reports to be automatically generated and emailed',
                            style: TextStyle(color: AppTheme.textTertiary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () => _showCreateScheduleDialog(),
                            icon: const Icon(Icons.add),
                            label: const Text('Schedule Report'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _scheduledReports.length,
                      itemBuilder: (context, index) {
                        final schedule = _scheduledReports[index];
                        return _buildScheduleCard(schedule);
                      },
                    ),
    );
  }

  Widget _buildScheduleCard(ScheduledReport schedule) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _viewScheduleDetails(schedule),
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
                          schedule.name,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primaryBlueDark,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatReportType(schedule.reportType),
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  _buildActiveBadge(schedule.isActive),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _buildInfoChip(
                    Icons.repeat,
                    'Frequency: ${_formatFrequency(schedule.frequency)}',
                  ),
                  _buildInfoChip(
                    Icons.email,
                    '${schedule.recipients.length} ${schedule.recipients.length == 1 ? 'recipient' : 'recipients'}',
                  ),
                  _buildInfoChip(
                    Icons.file_download,
                    'Format: ${schedule.format.name.toUpperCase()}',
                  ),
                  if (schedule.nextScheduledAt != null)
                    _buildInfoChip(
                      Icons.calendar_today,
                      'Next: ${DateFormat('MMM d, y').format(schedule.nextScheduledAt!)}',
                    ),
                ],
              ),
              if (schedule.lastSentAt != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Last sent: ${DateFormat('MMM d, y HH:mm').format(schedule.lastSentAt!)}',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => _viewScheduleDetails(schedule),
                    icon: const Icon(Icons.visibility),
                    label: const Text('View'),
                  ),
                  TextButton.icon(
                    onPressed: () => _editSchedule(schedule),
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit'),
                  ),
                  TextButton.icon(
                    onPressed: () => _deleteSchedule(schedule),
                    icon: const Icon(Icons.delete, color: AppTheme.error),
                    label: const Text('Delete', style: TextStyle(color: AppTheme.error)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveBadge(bool isActive) {
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

  String _formatReportType(ScheduledReportType type) {
    switch (type) {
      case ScheduledReportType.financial:
        return 'Financial Report';
      case ScheduledReportType.arAging:
        return 'AR Aging Report';
      case ScheduledReportType.occupancy:
        return 'Occupancy Report';
      case ScheduledReportType.delinquency:
        return 'Delinquency Report';
      case ScheduledReportType.deposits:
        return 'Deposits Report';
      case ScheduledReportType.communicationAnalytics:
        return 'Communication Analytics';
      case ScheduledReportType.all:
        return 'All Reports';
    }
  }

  String _formatFrequency(ReportScheduleFrequency frequency) {
    switch (frequency) {
      case ReportScheduleFrequency.daily:
        return 'Daily';
      case ReportScheduleFrequency.weekly:
        return 'Weekly';
      case ReportScheduleFrequency.monthly:
        return 'Monthly';
      case ReportScheduleFrequency.quarterly:
        return 'Quarterly';
      case ReportScheduleFrequency.custom:
        return 'Custom';
    }
  }

  void _showCreateScheduleDialog() {
    context.push('/report-scheduling/create');
  }

  void _viewScheduleDetails(ScheduledReport schedule) {
    context.push('/report-scheduling/${schedule.id}');
  }

  void _editSchedule(ScheduledReport schedule) {
    context.push('/report-scheduling/${schedule.id}/edit');
  }

  Future<void> _deleteSchedule(ScheduledReport schedule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Scheduled Report'),
        content: Text('Are you sure you want to delete "${schedule.name}"? This action cannot be undone.'),
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
        await ReportSchedulingService.deleteScheduledReport(
          facilityId: _selectedFacilityId!,
          reportId: schedule.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Scheduled report deleted successfully')),
          );
          _loadScheduledReports();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting scheduled report: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }
}

