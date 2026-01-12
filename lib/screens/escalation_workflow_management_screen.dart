import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/escalation_workflow_model.dart';
import '../models/reminder_model.dart';
import '../services/escalation_workflow_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';

/// Screen for managing escalation workflows
class EscalationWorkflowManagementScreen extends ConsumerStatefulWidget {
  const EscalationWorkflowManagementScreen({super.key});

  @override
  ConsumerState<EscalationWorkflowManagementScreen> createState() => _EscalationWorkflowManagementScreenState();
}

class _EscalationWorkflowManagementScreenState extends ConsumerState<EscalationWorkflowManagementScreen> {
  String? _selectedFacilityId;
  List<EscalationWorkflow> _workflows = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadWorkflows();
  }

  Future<void> _loadWorkflows() async {
    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = _selectedFacilityId ?? selectedFacility?.id;
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _workflows = [];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final workflows = await EscalationWorkflowService.getWorkflowsForFacility(facilityId);
      setState(() {
        _workflows = workflows;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading workflows: $e';
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
        _loadWorkflows();
      });
    }

    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/automation/escalations';

    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Escalation Workflows',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => context.push('/automation/escalations/create'),
          tooltip: 'Create Workflow',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadWorkflows,
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
                        onPressed: _loadWorkflows,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _workflows.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.trending_up, size: 64, color: AppTheme.textTertiary),
                          const SizedBox(height: 16),
                          Text(
                            'No escalation workflows found',
                            style: TextStyle(color: AppTheme.textTertiary, fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Create escalation workflows to automate multi-step reminder sequences',
                            style: TextStyle(color: AppTheme.textTertiary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () => context.push('/automation/escalations/create'),
                            icon: const Icon(Icons.add),
                            label: const Text('Create Workflow'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _workflows.length,
                      itemBuilder: (context, index) {
                        final workflow = _workflows[index];
                        return _buildWorkflowCard(workflow);
                      },
                    ),
    );
  }

  Widget _buildWorkflowCard(EscalationWorkflow workflow) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _viewWorkflow(workflow),
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
                          workflow.name,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primaryBlueDark,
                              ),
                        ),
                        if (workflow.description != null && workflow.description!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            workflow.description!,
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _buildStatusBadge(workflow.isActive),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _buildInfoChip(
                    Icons.notifications_active,
                    'Trigger: ${_formatReminderType(workflow.triggerType)}',
                  ),
                  _buildInfoChip(
                    Icons.layers,
                    '${workflow.steps.length} ${workflow.steps.length == 1 ? 'step' : 'steps'}',
                  ),
                  _buildInfoChip(
                    Icons.calendar_today,
                    'Created: ${DateFormat('MMM d, y').format(workflow.createdAt)}',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => _viewWorkflow(workflow),
                    icon: const Icon(Icons.visibility),
                    label: const Text('View'),
                  ),
                  TextButton.icon(
                    onPressed: () => _deleteWorkflow(workflow),
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

  Widget _buildStatusBadge(bool isActive) {
    final color = isActive ? AppTheme.success : AppTheme.textSecondary;
    final label = isActive ? 'Active' : 'Inactive';

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

  String _formatReminderType(ReminderType type) {
    switch (type) {
      case ReminderType.rentDue:
        return 'Rent Due';
      case ReminderType.rentOverdue:
        return 'Rent Overdue';
      case ReminderType.contractExpiring:
        return 'Contract Expiring';
      case ReminderType.contractExpired:
        return 'Contract Expired';
      case ReminderType.paymentFailed:
        return 'Payment Failed';
      case ReminderType.maintenanceDue:
        return 'Maintenance Due';
      case ReminderType.inspectionDue:
        return 'Inspection Due';
      case ReminderType.custom:
        return 'Custom';
    }
  }

  void _viewWorkflow(EscalationWorkflow workflow) {
    // Could navigate to detail screen
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(workflow.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (workflow.description != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(workflow.description!),
                ),
              Text(
                'Trigger: ${_formatReminderType(workflow.triggerType)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('Steps: ${workflow.steps.length}'),
              const SizedBox(height: 16),
              const Text('Steps:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...workflow.steps.map((step) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Step ${step.order}: ${step.channel.name} after ${step.delayHours} hours'),
                  )),
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

  Future<void> _deleteWorkflow(EscalationWorkflow workflow) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Workflow'),
        content: Text('Are you sure you want to delete "${workflow.name}"? This action cannot be undone.'),
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
        await EscalationWorkflowService.deleteWorkflow(
          facilityId: _selectedFacilityId!,
          workflowId: workflow.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Workflow deleted successfully')),
          );
          _loadWorkflows();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting workflow: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }
}

