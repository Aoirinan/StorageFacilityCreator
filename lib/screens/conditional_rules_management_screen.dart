import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/conditional_rule_model.dart';
import '../models/reminder_model.dart';
import '../services/conditional_rule_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';

/// Screen for managing conditional rules for automation
class ConditionalRulesManagementScreen extends ConsumerStatefulWidget {
  const ConditionalRulesManagementScreen({super.key});

  @override
  ConsumerState<ConditionalRulesManagementScreen> createState() => _ConditionalRulesManagementScreenState();
}

class _ConditionalRulesManagementScreenState extends ConsumerState<ConditionalRulesManagementScreen> {
  String? _selectedFacilityId;
  List<ConditionalRule> _rules = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = _selectedFacilityId ?? selectedFacility?.id;
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _rules = [];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final rules = await ConditionalRuleService.getRulesForFacility(facilityId);
      setState(() {
        _rules = rules;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading rules: $e';
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
        _loadRules();
      });
    }

    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/automation/conditional-rules';

    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Conditional Rules',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateRuleDialog(),
          tooltip: 'Create Rule',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadRules,
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
                        onPressed: _loadRules,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _rules.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.rule, size: 64, color: AppTheme.textTertiary),
                          const SizedBox(height: 16),
                          Text(
                            'No conditional rules found',
                            style: TextStyle(color: AppTheme.textTertiary, fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Create conditional rules to customize reminder behavior based on tenant data',
                            style: TextStyle(color: AppTheme.textTertiary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _showCreateRuleDialog,
                            icon: const Icon(Icons.add),
                            label: const Text('Create Rule'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _rules.length,
                      itemBuilder: (context, index) {
                        final rule = _rules[index];
                        return _buildRuleCard(rule);
                      },
                    ),
    );
  }

  Widget _buildRuleCard(ConditionalRule rule) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _viewRule(rule),
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
                          rule.name,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primaryBlueDark,
                              ),
                        ),
                        if (rule.description != null && rule.description!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            rule.description!,
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _buildStatusBadge(rule.isActive),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _buildInfoChip(
                    Icons.notifications_active,
                    'Applies to: ${_formatReminderType(rule.appliesTo)}',
                  ),
                  _buildInfoChip(
                    Icons.tune,
                    '${rule.conditions.length} ${rule.conditions.length == 1 ? 'condition' : 'conditions'}',
                  ),
                  _buildInfoChip(
                    Icons.flag,
                    'Action: ${_formatAction(rule.action)}',
                  ),
                  if (rule.priority != 0)
                    _buildInfoChip(
                      Icons.priority_high,
                      'Priority: ${rule.priority}',
                    ),
                ],
              ),
              if (rule.conditions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlueLight.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Conditions:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...rule.conditions.map((condition) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              _formatCondition(condition),
                              style: const TextStyle(fontSize: 12),
                            ),
                          )),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => _viewRule(rule),
                    icon: const Icon(Icons.visibility),
                    label: const Text('View'),
                  ),
                  TextButton.icon(
                    onPressed: () => _editRule(rule),
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit'),
                  ),
                  TextButton.icon(
                    onPressed: () => _toggleRuleActive(rule),
                    icon: Icon(rule.isActive ? Icons.pause : Icons.play_arrow),
                    label: Text(rule.isActive ? 'Deactivate' : 'Activate'),
                  ),
                  TextButton.icon(
                    onPressed: () => _deleteRule(rule),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? AppTheme.success.withOpacity(0.2) : AppTheme.textTertiary.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        isActive ? 'Active' : 'Inactive',
        style: TextStyle(
          color: isActive ? AppTheme.success : AppTheme.textTertiary,
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

  String _formatAction(RuleAction action) {
    switch (action) {
      case RuleAction.sendReminder:
        return 'Send Reminder';
      case RuleAction.sendEscalation:
        return 'Send Escalation';
      case RuleAction.skipReminder:
        return 'Skip Reminder';
      case RuleAction.changeChannel:
        return 'Change Channel';
      case RuleAction.addTag:
        return 'Add Tag';
      case RuleAction.notifyStaff:
        return 'Notify Staff';
    }
  }

  String _formatCondition(Condition condition) {
    final operator = _formatOperator(condition.operator);
    final value = condition.value?.toString() ?? 'N/A';
    return '${condition.field} $operator $value';
  }

  String _formatOperator(ConditionOperator op) {
    switch (op) {
      case ConditionOperator.equals:
        return '==';
      case ConditionOperator.notEquals:
        return '!=';
      case ConditionOperator.greaterThan:
        return '>';
      case ConditionOperator.lessThan:
        return '<';
      case ConditionOperator.contains:
        return 'contains';
      case ConditionOperator.isEmpty:
        return 'is empty';
      case ConditionOperator.isNotEmpty:
        return 'is not empty';
      case ConditionOperator.inList:
        return 'in';
    }
  }

  void _viewRule(ConditionalRule rule) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(rule.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (rule.description != null) ...[
                Text(rule.description!),
                const SizedBox(height: 16),
              ],
              _buildDetailRow('Applies to', _formatReminderType(rule.appliesTo)),
              _buildDetailRow('Action', _formatAction(rule.action)),
              _buildDetailRow('Priority', rule.priority.toString()),
              _buildDetailRow('Status', rule.isActive ? 'Active' : 'Inactive'),
              const SizedBox(height: 16),
              const Text('Conditions:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (rule.conditions.isEmpty)
                const Text('No conditions (always applies)')
              else
                ...rule.conditions.map((c) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_formatCondition(c)),
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

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text('$label:', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _editRule(ConditionalRule rule) {
    _showCreateRuleDialog(rule: rule);
  }

  Future<void> _toggleRuleActive(ConditionalRule rule) async {
    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = selectedFacility?.id;
    if (facilityId == null) return;

    try {
      await ConditionalRuleService.updateRule(
        facilityId: facilityId,
        ruleId: rule.id,
        isActive: !rule.isActive,
      );
      await _loadRules();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(rule.isActive ? 'Rule deactivated' : 'Rule activated'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating rule: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _deleteRule(ConditionalRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Rule'),
        content: Text('Are you sure you want to delete "${rule.name}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = selectedFacility?.id;
    if (facilityId == null) return;

    try {
      await ConditionalRuleService.deleteRule(
        facilityId: facilityId,
        ruleId: rule.id,
      );
      await _loadRules();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Rule deleted'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting rule: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _showCreateRuleDialog({ConditionalRule? rule}) {
    // For now, show a simple message. In a full implementation, this would open
    // a dialog or navigate to a full screen editor for creating/editing rules
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(rule == null ? 'Create Conditional Rule' : 'Edit Conditional Rule'),
        content: const Text(
          'Rule editor will be implemented. This feature requires a comprehensive form '
          'for creating conditions and actions.',
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
}

