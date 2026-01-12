import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'dart:convert';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../widgets/keyboard_scrollable.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../services/facility_service.dart';
import 'auth/login_screen.dart';
import 'subscription_test_screen.dart';
import 'permission_management_screen.dart';
import 'ai_assistant_screen.dart';
import 'stripe_connect_onboarding_screen.dart';
import 'notification_settings_screen.dart';
import 'profile_edit_screen.dart';
import 'appearance_settings_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';

// #region agent log
void _debugLog(String location, String message, Map<String, dynamic> data, String hypothesisId) {
  final logEntry = jsonEncode({
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'location': location,
    'message': message,
    'data': data,
    'sessionId': 'debug-session',
    'runId': 'run1',
    'hypothesisId': hypothesisId,
  });
  // Always print for immediate visibility (works on web and desktop)
  print('[DEBUG] $logEntry');
}
// #endregion

/// Settings screen for user preferences and account management
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // #region agent log
    _debugLog('settings_screen.dart:20', 'SettingsScreen build started', {}, 'A');
    // #endregion
    final authState = ref.watch(authStateProvider);
    final user = authState.value;
    // #region agent log
    _debugLog('settings_screen.dart:22', 'User auth state', {'userEmail': user?.email, 'hasUser': user != null}, 'A');
    // #endregion

    // Defer navigation if auth is loading - let router handle redirect
    if (authState.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return ModernPageWrapper(
      currentRoute: '/settings',
      title: 'Settings',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: KeyboardScrollable(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
          // Account Section
          _SettingsSection(
            title: 'Account',
            children: [
              if (user != null)
                _SettingsTile(
                  icon: Icons.person_outline,
                  title: 'Profile',
                  subtitle: user.email,
                  onTap: () {
                    context.push(AppRoute.profileEdit);
                  },
                ),
              _SettingsTile(
                icon: Icons.subscriptions_outlined,
                title: 'Subscription',
                subtitle: 'Manage your subscription',
                onTap: () {
                  context.go(AppRoute.subscription);
                },
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Facility Section
          // #region agent log
          Builder(builder: (_) {
            _debugLog('settings_screen.dart:62', 'Building Facility section with Permissions tile', {}, 'A');
            final userId = user?.uid;
            final facilitiesAsync = userId != null ? ref.watch(userFacilitiesProvider(userId)) : null;
            
            return _SettingsSection(
              title: 'Facility',
              children: [
                _SettingsTile(
                icon: Icons.security_outlined,
                title: 'Permissions',
                subtitle: 'Manage user permissions',
                onTap: () {
                  // #region agent log
                  _debugLog('settings_screen.dart:70', 'Permissions tile onTap called', {}, 'B');
                  // #endregion
                  try {
                    // #region agent log
                    _debugLog('settings_screen.dart:73', 'Calling context.push with legacyScreen route', {'route': AppRoute.legacyScreen}, 'B');
                    // #endregion
                    context.push(AppRoute.legacyScreen, extra: const PermissionManagementScreen());
                    // #region agent log
                    _debugLog('settings_screen.dart:76', 'context.push completed', {}, 'B');
                    // #endregion
                  } catch (e, stackTrace) {
                    // #region agent log
                    _debugLog('settings_screen.dart:79', 'Navigation error', {'error': e.toString(), 'stackTrace': stackTrace.toString()}, 'B');
                    // #endregion
                  }
                },
              ),
              // Insurance Settings
              _SettingsTile(
                icon: Icons.shield_outlined,
                title: 'Insurance Settings',
                subtitle: 'Manage Tenant Protection Program',
                onTap: () {
                  facilitiesAsync?.when(
                    data: (facilities) {
                      if (facilities.isNotEmpty) {
                        final facilityId = facilities.first.id;
                        context.push('${AppRoute.insuranceSettings}?facilityId=$facilityId');
                      }
                    },
                    loading: () {},
                    error: (_, __) {},
                  );
                },
              ),
              // Notification Settings
              _SettingsTile(
                icon: Icons.notifications_outlined,
                title: 'Notification Settings',
                subtitle: 'Configure automated messages and reminders',
                onTap: () {
                  facilitiesAsync?.when(
                    data: (facilities) {
                      if (facilities.isNotEmpty) {
                        final facilityId = facilities.first.id;
                        context.push('${AppRoute.notificationSettings}?facilityId=$facilityId');
                      }
                    },
                    loading: () {},
                    error: (_, __) {},
                  );
                },
              ),
              // Stripe Connect Status
              facilitiesAsync?.when(
                data: (facilities) {
                  if (facilities.isEmpty) return const SizedBox.shrink();
                  final facility = facilities.first;
                  final isConnected = facility.stripeConnectAccountId != null && 
                                      facility.stripeConnectOnboardingComplete;
                  
                  return _SettingsTile(
                    icon: Icons.account_balance_wallet,
                    title: 'Payment Processing',
                    subtitle: isConnected 
                        ? 'Stripe Connected ✓' 
                        : 'Connect Stripe to receive payments',
                    iconColor: isConnected ? AppTheme.success : AppTheme.warning,
                    onTap: () {
                      context.push(
                        '/stripe-connect',
                        extra: facility,
                      );
                    },
                  );
                },
                loading: () => _SettingsTile(
                  icon: Icons.account_balance_wallet,
                  title: 'Payment Processing',
                  subtitle: 'Loading...',
                  onTap: () {},
                ),
                error: (_, __) => const SizedBox.shrink(),
              ) ?? const SizedBox.shrink(),
            ],
            );
          }),
          // #endregion
          const SizedBox(height: 24),

          // General Section
          _SettingsSection(
            title: 'General',
            children: [
              _SettingsTile(
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                subtitle: 'Manage notification preferences',
                onTap: () {
                  // Show facility selection dialog if user has multiple facilities
                  final userId = user?.uid;
                  if (userId != null) {
                    final facilitiesAsync = ref.read(userFacilitiesProvider(userId));
                    facilitiesAsync.whenData((facilities) {
                      if (facilities.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Please create a facility first'),
                            backgroundColor: AppTheme.warning,
                          ),
                        );
                      } else if (facilities.length == 1) {
                        // Single facility - go directly to notification settings
                        context.push('${AppRoute.notificationSettings}?facilityId=${facilities.first.id}');
                      } else {
                        // Multiple facilities - show selection dialog
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Select Facility'),
                            content: SizedBox(
                              width: double.maxFinite,
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: facilities.length,
                                itemBuilder: (context, index) {
                                  final facility = facilities[index];
                                  return ListTile(
                                    title: Text(facility.name),
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      context.push('${AppRoute.notificationSettings}?facilityId=${facility.id}');
                                    },
                                  );
                                },
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Cancel'),
                              ),
                            ],
                          ),
                        );
                      }
                    });
                  }
                },
              ),
              _SettingsTile(
                icon: Icons.palette_outlined,
                title: 'Appearance',
                subtitle: 'Theme and display settings',
                onTap: () {
                  context.push(AppRoute.appearanceSettings);
                },
              ),
              _SettingsTile(
                icon: Icons.smart_toy_outlined,
                title: 'AI Assistant',
                subtitle: 'Get help with storage facility questions',
                onTap: () {
                  context.push(AppRoute.aiAssistant);
                },
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Communications Section
          Builder(builder: (_) {
            final userId = user?.uid;
            final facilitiesAsync = userId != null ? ref.watch(userFacilitiesProvider(userId)) : null;
            
            return _SettingsSection(
              title: 'Communications',
              children: [
                _SettingsTile(
                  icon: Icons.message_outlined,
                  title: 'Bulk Messaging',
                  subtitle: 'Send messages to multiple tenants',
                  onTap: () {
                    facilitiesAsync?.when(
                      data: (facilities) {
                        if (facilities.isNotEmpty) {
                          final facilityId = facilities.first.id;
                          context.push('${AppRoute.bulkMessaging}?facilityId=$facilityId');
                        }
                      },
                      loading: () {},
                      error: (_, __) {},
                    );
                  },
                ),
              ],
            );
          }),
          const SizedBox(height: 24),

          // Account Actions
          _SettingsSection(
            title: 'Actions',
            children: [
              _SettingsTile(
                icon: Icons.logout,
                title: 'Sign Out',
                subtitle: 'Sign out of your account',
                iconColor: AppTheme.error,
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Sign Out'),
                      content: const Text('Are you sure you want to sign out?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.error,
                            foregroundColor: AppTheme.textOnDark,
                          ),
                          child: const Text('Sign Out'),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true && context.mounted) {
                    await FirebaseAuth.instance.signOut();
                    if (context.mounted) {
                      context.go(AppRoute.login);
                    }
                  }
                },
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
          ),
        ),
        Card(
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? iconColor;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        icon,
        color: iconColor ?? AppTheme.primaryBlue,
      ),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

