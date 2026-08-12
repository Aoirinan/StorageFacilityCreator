import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/email_sequence_model.dart';
import '../services/email_sequence_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';

/// Screen for managing email sequences (drip campaigns)
class EmailSequenceManagementScreen extends ConsumerStatefulWidget {
  const EmailSequenceManagementScreen({super.key});

  @override
  ConsumerState<EmailSequenceManagementScreen> createState() => _EmailSequenceManagementScreenState();
}

class _EmailSequenceManagementScreenState extends ConsumerState<EmailSequenceManagementScreen> {
  String? _selectedFacilityId;
  List<EmailSequence> _sequences = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSequences();
  }

  Future<void> _loadSequences() async {
    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = _selectedFacilityId ?? selectedFacility?.id;
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _sequences = [];
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final sequences = await EmailSequenceService.getEmailSequences(facilityId);
      setState(() {
        _sequences = sequences;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading sequences: $e';
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
        _loadSequences();
      });
    }

    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/email-sequences';

    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Email Sequences',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateSequenceDialog(),
          tooltip: 'Create Sequence',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadSequences,
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
                        onPressed: _loadSequences,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _sequences.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.email_outlined, size: 64, color: AppTheme.textTertiary),
                          const SizedBox(height: 16),
                          Text(
                            'No email sequences found',
                            style: TextStyle(color: AppTheme.textTertiary, fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Create your first automated email sequence to engage with tenants',
                            style: TextStyle(color: AppTheme.textTertiary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () => _showCreateSequenceDialog(),
                            icon: const Icon(Icons.add),
                            label: const Text('Create Sequence'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _sequences.length,
                      itemBuilder: (context, index) {
                        final sequence = _sequences[index];
                        return _buildSequenceCard(sequence);
                      },
                    ),
    );
  }

  Widget _buildSequenceCard(EmailSequence sequence) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _viewSequence(sequence),
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
                          sequence.name,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primaryBlueDark,
                              ),
                        ),
                        if (sequence.description != null && sequence.description!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            sequence.description!,
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _buildStatusBadge(sequence.status),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _buildInfoChip(
                    Icons.bolt,
                    'Trigger: ${_formatTriggerType(sequence.triggerType)}',
                  ),
                  _buildInfoChip(
                    Icons.email,
                    '${sequence.steps.length} ${sequence.steps.length == 1 ? 'step' : 'steps'}',
                  ),
                  _buildInfoChip(
                    Icons.calendar_today,
                    'Created: ${DateFormat('MMM d, y').format(sequence.createdAt)}',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => _viewSequence(sequence),
                    icon: const Icon(Icons.visibility),
                    label: const Text('View'),
                  ),
                  TextButton.icon(
                    onPressed: () => _editSequence(sequence),
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit'),
                  ),
                  TextButton.icon(
                    onPressed: () => _deleteSequence(sequence),
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

  Widget _buildStatusBadge(SequenceStatus status) {
    Color color;
    String label;

    switch (status) {
      case SequenceStatus.active:
        color = AppTheme.success;
        label = 'Active';
        break;
      case SequenceStatus.paused:
        color = AppTheme.warning;
        label = 'Paused';
        break;
      case SequenceStatus.completed:
        color = AppTheme.textSecondary;
        label = 'Completed';
        break;
      case SequenceStatus.cancelled:
        color = AppTheme.error;
        label = 'Cancelled';
        break;
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

  String _formatTriggerType(SequenceTriggerType type) {
    switch (type) {
      case SequenceTriggerType.tenantCreated:
        return 'New Tenant';
      case SequenceTriggerType.moveInCompleted:
        return 'Move-In Complete';
      case SequenceTriggerType.contractSigned:
        return 'Contract Signed';
      case SequenceTriggerType.paymentReceived:
        return 'Payment Received';
      case SequenceTriggerType.manualStart:
        return 'Manual';
      case SequenceTriggerType.custom:
        return 'Custom';
    }
  }

  void _showCreateSequenceDialog() {
    // Navigate to create/edit sequence screen
    context.push('/email-sequences/create');
  }

  void _viewSequence(EmailSequence sequence) {
    // Navigate to sequence detail/view screen
    context.push('/email-sequences/${sequence.id}');
  }

  void _editSequence(EmailSequence sequence) {
    // Navigate to edit sequence screen
    context.push('/email-sequences/${sequence.id}/edit');
  }

  Future<void> _deleteSequence(EmailSequence sequence) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Sequence'),
        content: Text('Are you sure you want to delete "${sequence.name}"? This action cannot be undone.'),
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
        await EmailSequenceService.deleteEmailSequence(
          facilityId: _selectedFacilityId!,
          sequenceId: sequence.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Sequence deleted successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
          _loadSequences();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting sequence: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }
}

