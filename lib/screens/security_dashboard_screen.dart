import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/security_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/services/security_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';

class SecurityDashboardScreen extends ConsumerStatefulWidget {
  const SecurityDashboardScreen({super.key});

  @override
  ConsumerState<SecurityDashboardScreen> createState() => _SecurityDashboardScreenState();
}

class _SecurityDashboardScreenState extends ConsumerState<SecurityDashboardScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  List<SecurityEvent> _recentEvents = [];
  List<SecurityAlert> _alerts = [];
  Map<String, int> _statistics = {};
  SecuritySettings? _settings;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    try {
      // Get accountId from current user
      final authState = ref.read(authStateProvider);
      if (!authState.hasValue || authState.value == null) {
        if (mounted) {
          setState(() => _isLoading = false);
        }
        return;
      }

      final user = authState.value!;
      final account = await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
      
      if (account == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No account found. Please create a facility first.')),
          );
          setState(() => _isLoading = false);
        }
        return;
      }

      final accountId = account.id;

      final futures = await Future.wait([
        SecurityService.getSecurityEvents(accountId: accountId, limit: 50),
        SecurityService.getSecurityAlerts(accountId: accountId, limit: 20),
        SecurityService.getSecurityStatistics(accountId: accountId),
        SecurityService.getSecuritySettings(accountId: accountId),
      ]);

      if (mounted) {
        setState(() {
          _recentEvents = futures[0] as List<SecurityEvent>;
          _alerts = futures[1] as List<SecurityAlert>;
          _statistics = futures[2] as Map<String, int>;
          _settings = futures[3] as SecuritySettings?;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading security data: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/security',
      title: 'Security Dashboard',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: Column(
        children: [
          // Tab bar
          Container(
            color: AppTheme.error,
            child: TabBar(
              controller: _tabController,
              indicatorColor: AppTheme.textOnDark,
              labelColor: AppTheme.textOnDark,
              unselectedLabelColor: AppTheme.textOnDark.withOpacity(0.7),
              tabs: const [
                Tab(icon: Icon(Icons.dashboard), text: 'Overview'),
                Tab(icon: Icon(Icons.security), text: 'Events'),
                Tab(icon: Icon(Icons.warning), text: 'Alerts'),
                Tab(icon: Icon(Icons.settings), text: 'Settings'),
              ],
            ),
          ),
          // Tab content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildOverviewTab(),
                      _buildEventsTab(),
                      _buildAlertsTab(),
                      _buildSettingsTab(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Security Statistics Cards
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  'Total Events',
                  _statistics['totalEvents']?.toString() ?? '0',
                  Icons.event,
                  AppTheme.primaryBlue,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildStatCard(
                  'Critical Events',
                  _statistics['criticalEvents']?.toString() ?? '0',
                  Icons.error,
                  AppTheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  'High Events',
                  _statistics['highEvents']?.toString() ?? '0',
                  Icons.warning,
                  AppTheme.warning,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildStatCard(
                  'Unresolved Alerts',
                  _statistics['unresolvedAlerts']?.toString() ?? '0',
                  Icons.notifications_active,
                  AppTheme.primaryBlueLight,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          
          // Recent Critical Events
          const Text(
            'Recent Critical Events',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          _buildRecentEventsList(),
          
          const SizedBox(height: 24),
          
          // Security Status
          const Text(
            'Security Status',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          _buildSecurityStatusCard(),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Text(
              title,
              style: TextStyle(color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentEventsList() {
    final criticalEvents = _recentEvents
        .where((event) => event.level == SecurityLevel.critical)
        .take(5)
        .toList();

    if (criticalEvents.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: Text('No critical events in the last 30 days'),
          ),
        ),
      );
    }

    return Card(
      child: ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: criticalEvents.length,
        itemBuilder: (context, index) {
          final event = criticalEvents[index];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: event.level.color.withOpacity(0.1),
              child: Icon(Icons.security, color: event.level.color),
            ),
            title: Text(event.type.displayName),
            subtitle: Text(event.description),
            trailing: Text(
              _formatTimeAgo(event.timestamp),
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSecurityStatusCard() {
    final isSecure = (_statistics['criticalEvents'] ?? 0) == 0 && 
                    (_statistics['unresolvedAlerts'] ?? 0) == 0;
    
    return Card(
      color: isSecure ? AppTheme.success.withOpacity(0.1) : AppTheme.error.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              isSecure ? Icons.check_circle : Icons.warning,
              color: isSecure ? AppTheme.success : AppTheme.error,
              size: 32,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isSecure ? 'System Secure' : 'Security Issues Detected',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isSecure ? AppTheme.success : AppTheme.error,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isSecure 
                        ? 'No critical events or unresolved alerts'
                        : 'Please review critical events and alerts',
                    style: TextStyle(
                      color: isSecure ? AppTheme.success : AppTheme.error,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEventsTab() {
    if (_recentEvents.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.security,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              'No Security Events',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'No security events have been recorded yet.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _recentEvents.length,
      itemBuilder: (context, index) {
        final event = _recentEvents[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: event.level.color.withOpacity(0.1),
              child: Icon(_getEventIcon(event.type), color: event.level.color),
            ),
            title: Text(event.type.displayName),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.description),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Chip(
                      label: Text(event.level.displayName),
                      backgroundColor: event.level.color.withOpacity(0.1),
                      labelStyle: TextStyle(color: event.level.color),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatTimeAgo(event.timestamp),
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
            trailing: event.isResolved
                ? Icon(Icons.check_circle, color: AppTheme.success)
                : Icon(Icons.pending, color: AppTheme.warning),
          ),
        );
      },
    );
  }

  Widget _buildAlertsTab() {
    if (_alerts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.notifications_none,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              'No Security Alerts',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'No security alerts have been generated yet.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _alerts.length,
      itemBuilder: (context, index) {
        final alert = _alerts[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: alert.level.color.withOpacity(0.1),
              child: Icon(Icons.warning, color: alert.level.color),
            ),
            title: Text(alert.title),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(alert.description),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Chip(
                      label: Text(alert.level.displayName),
                      backgroundColor: alert.level.color.withOpacity(0.1),
                      labelStyle: TextStyle(color: alert.level.color),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatTimeAgo(alert.timestamp),
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
            trailing: alert.isAcknowledged
                ? Icon(Icons.check_circle, color: AppTheme.success)
                : IconButton(
                    icon: const Icon(Icons.check),
                    onPressed: () => _acknowledgeAlert(alert),
                  ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsTab() {
    if (_settings == null) {
      return const Center(
        child: Text('Security settings not available'),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Security Settings',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          
          // Audit Logging
          Card(
            child: SwitchListTile(
              title: const Text('Audit Logging'),
              subtitle: const Text('Log all security events and user actions'),
              value: _settings!.enableAuditLogging,
              onChanged: (value) => _updateSetting('enableAuditLogging', value),
            ),
          ),
          
          // Real-time Monitoring
          Card(
            child: SwitchListTile(
              title: const Text('Real-time Monitoring'),
              subtitle: const Text('Monitor security events in real-time'),
              value: _settings!.enableRealTimeMonitoring,
              onChanged: (value) => _updateSetting('enableRealTimeMonitoring', value),
            ),
          ),
          
          // Suspicious Activity Detection
          Card(
            child: SwitchListTile(
              title: const Text('Suspicious Activity Detection'),
              subtitle: const Text('Automatically detect suspicious activities'),
              value: _settings!.enableSuspiciousActivityDetection,
              onChanged: (value) => _updateSetting('enableSuspiciousActivityDetection', value),
            ),
          ),
          
          // Data Encryption
          Card(
            child: SwitchListTile(
              title: const Text('Data Encryption'),
              subtitle: const Text('Encrypt sensitive data at rest'),
              value: _settings!.enableDataEncryption,
              onChanged: (value) => _updateSetting('enableDataEncryption', value),
            ),
          ),
          
          // Two-Factor Authentication
          Card(
            child: SwitchListTile(
              title: const Text('Two-Factor Authentication'),
              subtitle: const Text('Require 2FA for all users'),
              value: _settings!.enableTwoFactorAuth,
              onChanged: (value) => _updateSetting('enableTwoFactorAuth', value),
            ),
          ),
          
          // Session Timeout
          Card(
            child: ListTile(
              title: const Text('Session Timeout'),
              subtitle: Text('${_settings!.sessionTimeoutMinutes} minutes'),
              trailing: Switch(
                value: _settings!.enableSessionTimeout,
                onChanged: (value) => _updateSetting('enableSessionTimeout', value),
              ),
            ),
          ),
          
          // Password Policy
          Card(
            child: ListTile(
              title: const Text('Password Policy'),
              subtitle: Text('Min length: ${_settings!.passwordMinLength} characters'),
              trailing: Switch(
                value: _settings!.enablePasswordPolicy,
                onChanged: (value) => _updateSetting('enablePasswordPolicy', value),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getEventIcon(SecurityEventType type) {
    switch (type) {
      case SecurityEventType.login:
      case SecurityEventType.logout:
        return Icons.login;
      case SecurityEventType.loginFailed:
        return Icons.block;
      case SecurityEventType.passwordChanged:
        return Icons.lock;
      case SecurityEventType.dataViewed:
        return Icons.visibility;
      case SecurityEventType.dataCreated:
        return Icons.add;
      case SecurityEventType.dataUpdated:
        return Icons.edit;
      case SecurityEventType.dataDeleted:
        return Icons.delete;
      case SecurityEventType.roleAssigned:
      case SecurityEventType.roleRemoved:
        return Icons.admin_panel_settings;
      case SecurityEventType.paymentProcessed:
        return Icons.payment;
      case SecurityEventType.facilityCreated:
        return Icons.business;
      case SecurityEventType.tenantCreated:
        return Icons.person;
      default:
        return Icons.security;
    }
  }

  String _formatTimeAgo(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    
    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }

  Future<void> _acknowledgeAlert(SecurityAlert alert) async {
    final controller = TextEditingController();
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Acknowledge Alert'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Acknowledge: ${alert.title}'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Acknowledgment Note',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Acknowledge'),
          ),
        ],
      ),
    );

    if (result != null) {
      final success = await SecurityService.acknowledgeAlert(
        alertId: alert.id,
        acknowledgmentNote: result,
      );
      
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Alert acknowledged')),
        );
        _loadData();
      }
    }
  }

  Future<void> _updateSetting(String settingName, dynamic value) async {
    if (_settings == null) return;
    
    final updatedSettings = _settings!.copyWith(
      updatedAt: DateTime.now(),
      updatedBy: 'current_user', // In real app, get current user ID
    );
    
    // Update the specific setting
    switch (settingName) {
      case 'enableAuditLogging':
        updatedSettings.copyWith(enableAuditLogging: value);
        break;
      case 'enableRealTimeMonitoring':
        updatedSettings.copyWith(enableRealTimeMonitoring: value);
        break;
      case 'enableSuspiciousActivityDetection':
        updatedSettings.copyWith(enableSuspiciousActivityDetection: value);
        break;
      case 'enableDataEncryption':
        updatedSettings.copyWith(enableDataEncryption: value);
        break;
      case 'enableTwoFactorAuth':
        updatedSettings.copyWith(enableTwoFactorAuth: value);
        break;
      case 'enableSessionTimeout':
        updatedSettings.copyWith(enableSessionTimeout: value);
        break;
      case 'enablePasswordPolicy':
        updatedSettings.copyWith(enablePasswordPolicy: value);
        break;
    }
    
    final success = await SecurityService.updateSecuritySettings(updatedSettings);
    if (success && mounted) {
      setState(() {
        _settings = updatedSettings;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Setting updated')),
      );
    }
  }
}
