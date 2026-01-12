import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/app_check_service.dart';
import '../theme/app_theme.dart';

/// Diagnostic widget for testing App Check (dev-only)
/// 
/// This widget should only be shown in debug mode
class AppCheckDiagnosticWidget extends StatefulWidget {
  const AppCheckDiagnosticWidget({super.key});

  @override
  State<AppCheckDiagnosticWidget> createState() => _AppCheckDiagnosticWidgetState();
}

class _AppCheckDiagnosticWidgetState extends State<AppCheckDiagnosticWidget> {
  bool _isRunning = false;
  Map<String, dynamic>? _results;
  String? _error;

  Future<void> _runDiagnostic() async {
    setState(() {
      _isRunning = true;
      _results = null;
      _error = null;
    });

    try {
      final results = await AppCheckService.runDiagnostic();
      setState(() {
        _results = results;
        _isRunning = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only show in debug mode
    if (!kDebugMode) {
      return const SizedBox.shrink();
    }

    final stats = AppCheckService.getMonitoringStats();

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.bug_report, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
                Text(
                  'App Check Diagnostic (Debug Only)',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Current Status
            _buildStatusSection(stats),
            
            const SizedBox(height: 16),
            
            // Debug Token (if available)
            if (AppCheckService.isDebugMode && AppCheckService.debugToken != null)
              _buildDebugTokenSection(),
            
            const SizedBox(height: 16),
            
            // Test Button
            ElevatedButton.icon(
              onPressed: _isRunning ? null : _runDiagnostic,
              icon: _isRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(_isRunning ? 'Running...' : 'Run Diagnostic'),
            ),
            
            // Results
            if (_results != null) ...[
              const SizedBox(height: 16),
              _buildResultsSection(_results!),
            ],
            
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.error),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error, color: AppTheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Error: $_error',
                        style: const TextStyle(color: AppTheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusSection(Map<String, dynamic> stats) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Current Status',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        _buildStatusRow('Activated', stats['isActivated'] == true),
        _buildStatusRow('Debug Mode', stats['isDebugMode'] == true),
        _buildStatusRow('Provider', stats['currentProvider'] ?? 'none'),
        _buildStatusRow('Hostname', stats['hostname'] ?? 'unknown'),
        _buildStatusRow('Token Success', '${stats['tokenSuccessCount']}'),
        _buildStatusRow('Token Failures', '${stats['tokenFailureCount']}'),
      ],
    );
  }

  Widget _buildStatusRow(String label, dynamic value) {
    final isBool = value is bool;
    final displayValue = isBool ? (value ? 'Yes' : 'No') : value.toString();
    final color = isBool && value ? AppTheme.success : AppTheme.textSecondary;
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(
            displayValue,
            style: TextStyle(color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugTokenSection() {
    final token = AppCheckService.debugToken;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warning.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.warning),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.key, color: AppTheme.warning, size: 20),
              const SizedBox(width: 8),
              Text(
                'Debug Token',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppTheme.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Copy this token to Firebase Console:',
            style: TextStyle(fontSize: 12),
          ),
          const Text(
            'App Check > Apps > [Your App] > Debug tokens',
            style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 8),
          SelectableText(
            token ?? '',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsSection(Map<String, dynamic> results) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Diagnostic Results',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (results['tokenTest'] != null)
            _buildTestResult('Token Test', results['tokenTest']),
          const SizedBox(height: 8),
          Text(
            'Full Results:',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          SelectableText(
            results.toString(),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTestResult(String label, Map<String, dynamic> result) {
    final success = result['success'] == true;
    return Row(
      children: [
        Icon(
          success ? Icons.check_circle : Icons.error,
          color: success ? AppTheme.success : AppTheme.error,
          size: 16,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$label: ${success ? 'PASS' : 'FAIL'}',
            style: TextStyle(
              color: success ? AppTheme.success : AppTheme.error,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (result['error'] != null)
          Text(
            result['error'],
            style: const TextStyle(fontSize: 12, color: AppTheme.error),
          ),
      ],
    );
  }
}
