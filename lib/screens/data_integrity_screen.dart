import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../services/data_consistency_service.dart';
import '../services/error_handling_service.dart';
import '../providers/auth_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';
import 'facility_creation_wizard.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';

class DataIntegrityScreen extends ConsumerStatefulWidget {
  const DataIntegrityScreen({super.key});

  @override
  ConsumerState<DataIntegrityScreen> createState() => _DataIntegrityScreenState();
}

class _DataIntegrityScreenState extends ConsumerState<DataIntegrityScreen> {
  String _selectedFacilityId = '';
  ConsistencyReport? _currentReport;
  bool _isChecking = false;
  bool _isFixing = false;

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
  }

  Future<void> _loadUserFacilities() async {
    final authState = ref.read(authStateProvider);
    if (authState.hasValue && authState.value != null) {
      ref.invalidate(userFacilitiesProvider(authState.value!.uid));
      final facilities = await ref.read(userFacilitiesProvider(authState.value!.uid).future);
      if (facilities.isNotEmpty) {
        setState(() {
          _selectedFacilityId = facilities.first.id;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        title: Text(
          'Data Integrity',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
        ),
        actions: [
          if (_selectedFacilityId.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _isChecking ? null : _checkDataIntegrity,
            ),
            if (_currentReport != null && _currentReport!.hasIssues)
              IconButton(
                icon: const Icon(Icons.build),
                onPressed: _isFixing ? null : _fixIssues,
              ),
          ],
        ],
      ),
      body: _selectedFacilityId.isEmpty
          ? _buildNoFacilitiesMessage()
          : _buildContent(),
    );
  }

  Widget _buildNoFacilitiesMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.business,
            size: 64,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(height: 16),
          Text(
            'No Facilities Found',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'You must create a storage facility before checking data integrity.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => context.go(AppRoute.facilityCreate),
            child: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildOverview(),
          const SizedBox(height: 24),
          _buildErrorLog(),
          const SizedBox(height: 24),
          if (_currentReport != null) _buildConsistencyReport(),
        ],
      ),
    );
  }

  Widget _buildOverview() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Data Integrity Overview',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    'Total Errors',
                    '${ErrorHandlingService.errorLog.length}',
                    AppTheme.error,
                    Icons.error,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    'Critical Issues',
                    _currentReport?.getSeverityCounts()[ConsistencySeverity.critical]?.toString() ?? '0',
                    AppTheme.error,
                    Icons.dangerous,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    'High Issues',
                    _currentReport?.getSeverityCounts()[ConsistencySeverity.high]?.toString() ?? '0',
                    AppTheme.warning,
                    Icons.warning,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    'Medium Issues',
                    _currentReport?.getSeverityCounts()[ConsistencySeverity.medium]?.toString() ?? '0',
                    AppTheme.accentYellow,
                    Icons.info,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isChecking ? null : _checkDataIntegrity,
                    icon: _isChecking 
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: Text(_isChecking ? 'Checking...' : 'Check Data Integrity'),
                  ),
                ),
                const SizedBox(width: 8),
                if (_currentReport != null && _currentReport!.hasIssues)
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isFixing ? null : _fixIssues,
                      icon: _isFixing 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.build),
                      label: Text(_isFixing ? 'Fixing...' : 'Fix Issues'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        foregroundColor: AppTheme.textOnDark,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, Color color, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorLog() {
    final recentErrors = ErrorHandlingService.getRecentErrors(count: 10);
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent Errors',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    ErrorHandlingService.clearErrorLog();
                    setState(() {});
                  },
                  child: const Text('Clear Log'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (recentErrors.isEmpty)
              Center(
                child: Column(
                  children: [
                    Icon(Icons.check_circle, color: AppTheme.success, size: 64),
                    const SizedBox(height: 16),
                    Text(
                      'No recent errors',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: recentErrors.length,
                itemBuilder: (context, index) {
                  final error = recentErrors[index];
                  return _buildErrorCard(error);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(AppError error) {
    final color = _getErrorColor(error.type);
    final icon = _getErrorIcon(error.type);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: Icon(icon, color: AppTheme.textOnDark, size: 20),
        ),
        title: Text(
          error.message,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Type: ${error.type.name.toUpperCase()}',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            Text(
              'Time: ${error.timestamp.toLocal().toString().substring(0, 19)}',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            if (error.code != null)
              Text(
                'Code: ${error.code}',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
          ],
        ),
        trailing: Icon(
          Icons.arrow_forward_ios,
          size: 16,
          color: AppTheme.textTertiary,
        ),
        onTap: () => _showErrorDetails(error),
      ),
    );
  }

  Widget _buildConsistencyReport() {
    if (_currentReport == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Consistency Report',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            if (_currentReport!.issues.isEmpty)
              Center(
                child: Column(
                  children: [
                    Icon(Icons.check_circle, color: AppTheme.success, size: 64),
                    const SizedBox(height: 16),
                    Text(
                      'No consistency issues found',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              )
            else
              Column(
                children: [
                  _buildIssueSummary(),
                  const SizedBox(height: 16),
                  _buildIssuesList(),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildIssueSummary() {
    final issueCounts = _currentReport!.getIssueCounts();
    final severityCounts = _currentReport!.getSeverityCounts();

    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              Text(
                '${_currentReport!.issues.length}',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const Text('Total Issues'),
            ],
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                '${severityCounts[ConsistencySeverity.critical] ?? 0}',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.error),
              ),
              const Text('Critical'),
            ],
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                '${severityCounts[ConsistencySeverity.high] ?? 0}',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.warning),
              ),
              const Text('High'),
            ],
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                '${severityCounts[ConsistencySeverity.medium] ?? 0}',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.accentYellow),
              ),
              const Text('Medium'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIssuesList() {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _currentReport!.issues.length,
      itemBuilder: (context, index) {
        final issue = _currentReport!.issues[index];
        return _buildIssueCard(issue);
      },
    );
  }

  Widget _buildIssueCard(ConsistencyIssue issue) {
    final color = _getSeverityColor(issue.severity);
    final icon = _getSeverityIcon(issue.severity);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: Icon(icon, color: AppTheme.textOnDark, size: 20),
        ),
        title: Text(
          issue.message,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Type: ${issue.type.name.toUpperCase()}',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            Text(
              'Entity: ${issue.entityType} (${issue.entityId})',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            Text(
              'Severity: ${issue.severity.name.toUpperCase()}',
              style: TextStyle(fontSize: 12, color: color),
            ),
            if (issue.resolution != null) ...[
              const SizedBox(height: 6),
              Text(
                'Suggested fix:',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              Text(
                issue.resolution!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        trailing: Icon(
          Icons.arrow_forward_ios,
          size: 16,
          color: AppTheme.textTertiary,
        ),
      ),
    );
  }

  Color _getErrorColor(ErrorType type) {
    switch (type) {
      case ErrorType.network:
        return AppTheme.primaryBlue;
      case ErrorType.authentication:
        return AppTheme.warning;
      case ErrorType.permission:
        return AppTheme.error;
      case ErrorType.validation:
        return AppTheme.accentYellow;
      case ErrorType.notFound:
        return AppTheme.primaryBlueLight;
      case ErrorType.conflict:
        return AppTheme.warning;
      case ErrorType.server:
        return AppTheme.error;
      case ErrorType.unknown:
        return AppTheme.textTertiary;
    }
  }

  IconData _getErrorIcon(ErrorType type) {
    switch (type) {
      case ErrorType.network:
        return Icons.wifi_off;
      case ErrorType.authentication:
        return Icons.lock;
      case ErrorType.permission:
        return Icons.block;
      case ErrorType.validation:
        return Icons.warning;
      case ErrorType.notFound:
        return Icons.search_off;
      case ErrorType.conflict:
        return Icons.warning;
      case ErrorType.server:
        return Icons.error;
      case ErrorType.unknown:
        return Icons.help;
    }
  }

  Color _getSeverityColor(ConsistencySeverity severity) {
    switch (severity) {
      case ConsistencySeverity.low:
        return AppTheme.success;
      case ConsistencySeverity.medium:
        return AppTheme.accentYellow;
      case ConsistencySeverity.high:
        return AppTheme.warning;
      case ConsistencySeverity.critical:
        return AppTheme.error;
    }
  }

  IconData _getSeverityIcon(ConsistencySeverity severity) {
    switch (severity) {
      case ConsistencySeverity.low:
        return Icons.info;
      case ConsistencySeverity.medium:
        return Icons.warning;
      case ConsistencySeverity.high:
        return Icons.error;
      case ConsistencySeverity.critical:
        return Icons.dangerous;
    }
  }

  void _showErrorDetails(AppError error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Error Details'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Type: ${error.type.name.toUpperCase()}'),
              const SizedBox(height: 8),
              Text('Message: ${error.message}'),
              if (error.code != null) ...[
                const SizedBox(height: 8),
                Text('Code: ${error.code}'),
              ],
              if (error.details != null) ...[
                const SizedBox(height: 8),
                Text('Details: ${error.details}'),
              ],
              const SizedBox(height: 8),
              Text('Time: ${error.timestamp.toLocal().toString()}'),
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

  Future<void> _checkDataIntegrity() async {
    setState(() {
      _isChecking = true;
    });

    try {
      final report = await DataConsistencyService.checkFacilityConsistency(_selectedFacilityId);
      setState(() {
        _currentReport = report;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error checking data integrity: ${e.toString()}'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      setState(() {
        _isChecking = false;
      });
    }
  }

  Future<void> _fixIssues() async {
    if (_currentReport == null) return;

    setState(() {
      _isFixing = true;
    });

    try {
      final result = await DataConsistencyService.fixConsistencyIssues(_currentReport!);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Auto-fixed ${result.autoFixed} issue${result.autoFixed == 1 ? '' : 's'}.'
            '${result.manualCount > 0 ? ' ${result.manualCount} still require manual attention.' : ''}',
          ),
        ),
      );

      if (result.manualIssues.isNotEmpty && mounted) {
        await _showManualResolutionDialog(result.manualIssues);
      }

      await _checkDataIntegrity();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error fixing issues: ${e.toString()}'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      setState(() {
        _isFixing = false;
      });
    }
  }

  Future<void> _showManualResolutionDialog(List<ConsistencyIssue> issues) async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Manual Follow-up Required'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: issues.map((issue) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        issue.message,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        issue.resolution ?? 'Review this record manually and correct the data.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
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
}
