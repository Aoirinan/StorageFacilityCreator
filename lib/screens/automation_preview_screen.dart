import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../widgets/permission_gate.dart';
import '../models/permission_model.dart';
import '../services/modern_navigation_service.dart';
import '../providers/active_facility_provider.dart';

class AutomationPreviewScreen extends ConsumerStatefulWidget {
  final String automationType; // 'monthlyCharges' or 'delinquency'

  const AutomationPreviewScreen({
    super.key,
    required this.automationType,
  });

  @override
  ConsumerState<AutomationPreviewScreen> createState() => _AutomationPreviewScreenState();
}

class _AutomationPreviewScreenState extends ConsumerState<AutomationPreviewScreen> {
  bool _isLoading = false;
  Map<String, dynamic>? _previewData;
  DateTime? _selectedDate;
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    final facilityId = ref.watch(activeFacilityIdProvider).value;

    if (facilityId == null) {
      return ModernPageWrapper(
        currentRoute: '/automation-preview',
        title: 'Automation Preview',
        child: const Center(
          child: Text('Please select a facility'),
        ),
      );
    }

    return ModernPageWrapper(
      currentRoute: '/automation-preview',
      title: widget.automationType == 'monthlyCharges'
          ? 'Monthly Charges Preview'
          : 'Delinquency Automation Preview',
      actions: [
        if (_previewData != null && !_confirmed)
          PermissionGate(
            permission: PermissionType.manageAutomation,
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : () => _executeAutomation(facilityId),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Execute'),
            ),
          ),
      ],
      child: Column(
        children: [
          if (widget.automationType == 'monthlyCharges') _buildMonthlyChargesControls(facilityId),
          if (widget.automationType == 'delinquency') _buildDelinquencyControls(facilityId),
          if (_isLoading)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            )
          else if (_previewData != null)
            Expanded(
              child: _buildPreviewResults(),
            )
          else
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.preview,
                      size: 64,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Run a preview to see what would happen',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMonthlyChargesControls(String facilityId) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _selectedDate ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() {
                        _selectedDate = date;
                        _previewData = null;
                        _confirmed = false;
                      });
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Target Month',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      suffixIcon: const Icon(Icons.calendar_today),
                    ),
                    child: Text(
                      _selectedDate != null
                          ? DateFormat('MMMM yyyy').format(_selectedDate!)
                          : 'Select month',
                      style: TextStyle(
                        color: _selectedDate != null ? null : AppTheme.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _isLoading ? null : () => _runPreview(facilityId),
                icon: const Icon(Icons.preview),
                label: const Text('Preview'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDelinquencyControls(String facilityId) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ElevatedButton.icon(
            onPressed: _isLoading ? null : () => _runPreview(facilityId),
            icon: const Icon(Icons.preview),
            label: const Text('Preview'),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewResults() {
    if (_previewData == null) return const SizedBox.shrink();

    final isDryRun = _previewData!['dryRun'] == true;
    final preview = _previewData!['preview'] as Map<String, dynamic>?;

    if (widget.automationType == 'monthlyCharges') {
      final totalCharges = preview?['totalCharges'] as int? ?? 0;
      final totalAmount = preview?['totalAmount'] as num? ?? 0.0;

      return Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: AppTheme.info.withOpacity(0.1),
              border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
            ),
            child: Row(
              children: [
                Icon(Icons.info, color: AppTheme.info),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Preview Results',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$totalCharges charges would be created for \$${totalAmount.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 64,
                    color: AppTheme.success,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Preview Complete',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Review the summary above and click "Execute" to create the charges.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    } else {
      // Delinquency preview
      final tenantsToProcess = preview?['tenantsToProcess'] as int? ?? 0;
      final estimatedLateFees = preview?['estimatedLateFees'] as num? ?? 0.0;
      final estimatedNotices = preview?['estimatedNotices'] as int? ?? 0;
      final estimatedLockouts = preview?['estimatedLockouts'] as int? ?? 0;

      return Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: AppTheme.info.withOpacity(0.1),
              border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info, color: AppTheme.info),
                    const SizedBox(width: 12),
                    Text(
                      'Preview Results',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _buildStatCard('Tenants', tenantsToProcess.toString(), AppTheme.primaryBlue),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildStatCard('Late Fees', '\$${estimatedLateFees.toStringAsFixed(2)}', AppTheme.warning),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildStatCard('Notices', estimatedNotices.toString(), AppTheme.info),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildStatCard('Lockouts', estimatedLockouts.toString(), AppTheme.error),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 64,
                    color: AppTheme.success,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Preview Complete',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Review the summary above and click "Execute" to run the automation.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
  }

  Widget _buildStatCard(String title, String value, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runPreview(String facilityId) async {
    setState(() {
      _isLoading = true;
      _previewData = null;
      _confirmed = false;
    });

    try {
      if (widget.automationType == 'monthlyCharges') {
        if (_selectedDate == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please select a target month'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
          setState(() {
            _isLoading = false;
          });
          return;
        }

        final functions = FirebaseFunctions.instance;
        final generateFunction = functions.httpsCallable('generateMonthlyRentCharges');
        final result = await generateFunction.call({
          'facilityId': facilityId,
          'forDate': _selectedDate!.toIso8601String(),
          'dryRun': true,
        });

        if (mounted) {
          setState(() {
            _previewData = Map<String, dynamic>.from(result.data as Map);
            _isLoading = false;
          });
        }
      } else {
        // Delinquency preview
        final functions = FirebaseFunctions.instance;
        final processFunction = functions.httpsCallable('processDelinquencyForFacilityCallable');
        final result = await processFunction.call({
          'facilityId': facilityId,
          'dryRun': true,
        });

        if (mounted) {
          setState(() {
            _previewData = Map<String, dynamic>.from(result.data as Map);
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error running preview: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _executeAutomation(String facilityId) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          widget.automationType == 'monthlyCharges'
              ? 'Execute Monthly Charges?'
              : 'Execute Delinquency Automation?',
        ),
        content: Text(
          widget.automationType == 'monthlyCharges'
              ? 'This will create charges for all eligible tenants. Are you sure?'
              : 'This will apply late fees, send notices, and trigger lockouts for delinquent tenants. Are you sure?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
            ),
            child: const Text('Execute'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isLoading = true;
    });

    try {
      if (widget.automationType == 'monthlyCharges') {
        if (_selectedDate == null) return;

        final functions = FirebaseFunctions.instance;
        final generateFunction = functions.httpsCallable('generateMonthlyRentCharges');
        final result = await generateFunction.call({
          'facilityId': facilityId,
          'forDate': _selectedDate!.toIso8601String(),
          'dryRun': false,
        });

        if (mounted) {
          setState(() {
            _isLoading = false;
            _confirmed = true;
          });

          final data = Map<String, dynamic>.from(result.data as Map);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Charges generated: ${data['successCount']} success, ${data['skippedCount']} skipped',
              ),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } else {
        // Delinquency execution
        final functions = FirebaseFunctions.instance;
        final processFunction = functions.httpsCallable('processDelinquencyForFacilityCallable');
        final result = await processFunction.call({
          'facilityId': facilityId,
          'dryRun': false,
        });

        if (mounted) {
          setState(() {
            _isLoading = false;
            _confirmed = true;
          });

          final data = Map<String, dynamic>.from(result.data as Map);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Automation complete: ${data['processedCount']} tenants processed',
              ),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error executing automation: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}
