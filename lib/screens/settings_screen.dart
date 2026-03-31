import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/feature_flag_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/permission_management_screen.dart';
import 'package:sfcapp/providers/dashboard_provider.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/services/two_factor_service.dart';
import 'package:sfcapp/providers/two_factor_provider.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';

const String _kMarketingBase = 'https://storagefacilitycreator.com';

Future<void> _openLegalUrl(String path) async {
  final uri = Uri.parse('$_kMarketingBase$path');
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// #region agent log
void _debugLog(String location, String message, Map<String, dynamic> data,
    String hypothesisId) {
  if (!kDebugMode) return; // Only log in debug mode
  final logEntry = jsonEncode({
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'location': location,
    'message': message,
    'data': data,
    'sessionId': 'debug-session',
    'runId': 'run1',
    'hypothesisId': hypothesisId,
  });
  print('[DEBUG] $logEntry');
}
// #endregion

/// Settings screen for user preferences and account management
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  bool? _is2FAEnabled;
  bool _isLoading2FA = false;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load2FAStatus();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load2FAStatus() async {
    setState(() => _isLoading2FA = true);
    try {
      final enabled = await TwoFactorService.is2FAEnabled();
      if (mounted) {
        setState(() {
          _is2FAEnabled = enabled;
          _isLoading2FA = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading2FA = false);
      }
    }
  }

  Future<void> _toggle2FA(bool value) async {
    setState(() => _isLoading2FA = true);
    try {
      final success = value
          ? await TwoFactorService.enable2FA()
          : await TwoFactorService.disable2FA();

      if (success && mounted) {
        // Invalidate the provider cache so route guards and login screen see the change
        ref.invalidate(twoFactorEnabledProvider);

        // If disabling, also mark as verified so user doesn't get stuck
        if (!value) {
          ref.read(twoFactorVerifiedProvider.notifier).state = true;
        }

        // Reload 2FA status to ensure it's accurate
        await _load2FAStatus();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              value
                  ? 'Two-factor authentication enabled'
                  : 'Two-factor authentication disabled. You will not be required to use 2FA on your next login.',
            ),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        if (mounted) {
          setState(() => _isLoading2FA = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Failed to update 2FA settings. ${value ? "Please try again." : "You may need to verify your identity first."}',
              ),
              backgroundColor: AppTheme.error,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading2FA = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // #region agent log
    _debugLog(
        'settings_screen.dart:20', 'SettingsScreen build started', {}, 'A');
    // #endregion
    final authState = ref.watch(authStateProvider);
    final user = authState.value;
    // #region agent log
    _debugLog('settings_screen.dart:22', 'User auth state',
        {'userEmail': user?.email, 'hasUser': user != null}, 'A');
    // #endregion

    // Defer navigation if auth is loading - let router handle redirect
    if (authState.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primaryBlue,
          labelColor: AppTheme.primaryBlue,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: const [
            Tab(icon: Icon(Icons.settings_outlined), text: 'Settings'),
            Tab(icon: Icon(Icons.flag_outlined), text: 'Onboarding'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              KeyboardScrollable(
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
                          icon: Icons.credit_card_outlined,
                          title: 'Billing & Payments',
                          subtitle:
                              'Subscription, payment processing (Stripe Connect), and accounting',
                          onTap: () {
                            context.go(AppRoute.subscription);
                          },
                        ),
                        // Two-Factor Authentication Toggle
                        Card(
                          child: SwitchListTile(
                            secondary: _isLoading2FA
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(
                                    Icons.security,
                                    color: AppTheme.primaryBlue,
                                  ),
                            title: const Text('Two-Factor Authentication'),
                            subtitle: Text(
                              _is2FAEnabled == true
                                  ? 'Enabled - Required at login'
                                  : 'Disabled - Enable for extra security at login',
                            ),
                            value: _is2FAEnabled ?? false,
                            onChanged: _isLoading2FA ? null : _toggle2FA,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Facility Section
                    // #region agent log
                    Builder(builder: (_) {
                      _debugLog(
                          'settings_screen.dart:62',
                          'Building Facility section with Permissions tile',
                          {},
                          'A');
                      final userId = user?.uid;
                      final facilitiesAsync = userId != null
                          ? ref.watch(userFacilitiesProvider(userId))
                          : null;
                      final textingOnboardingEnabled = ref.watch(
                          featureFlagEnabledProvider('TEXTING_ONBOARDING_V1'));

                      return _SettingsSection(
                        title: 'Facility',
                        children: [
                          _SettingsTile(
                            icon: Icons.security_outlined,
                            title: 'Permissions',
                            subtitle: 'Manage user permissions',
                            onTap: () {
                              // #region agent log
                              _debugLog('settings_screen.dart:70',
                                  'Permissions tile onTap called', {}, 'B');
                              // #endregion
                              try {
                                // #region agent log
                                _debugLog(
                                    'settings_screen.dart:73',
                                    'Calling context.push with legacyScreen route',
                                    {'route': AppRoute.legacyScreen},
                                    'B');
                                // #endregion
                                context.go(AppRoute.permissionManagement);
                                // #region agent log
                                _debugLog('settings_screen.dart:76',
                                    'context.push completed', {}, 'B');
                                // #endregion
                              } catch (e, stackTrace) {
                                // #region agent log
                                _debugLog(
                                    'settings_screen.dart:79',
                                    'Navigation error',
                                    {
                                      'error': e.toString(),
                                      'stackTrace': stackTrace.toString()
                                    },
                                    'B');
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
                                    context.push(
                                        '${AppRoute.insuranceSettings}?facilityId=$facilityId');
                                  }
                                },
                                loading: () {},
                                error: (_, __) {},
                              );
                            },
                          ),
                          // Notifications (single entry - toggles persist via facility billingSettings)
                          _SettingsTile(
                            icon: Icons.notifications_outlined,
                            title: 'Notifications',
                            subtitle:
                                'Configure automated messages and reminders',
                            onTap: () {
                              facilitiesAsync?.when(
                                data: (facilities) {
                                  if (facilities.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            'Please create a facility first'),
                                        backgroundColor: AppTheme.warning,
                                      ),
                                    );
                                  } else if (facilities.length == 1) {
                                    context.push(
                                        '${AppRoute.notificationSettings}?facilityId=${facilities.first.id}');
                                  } else {
                                    showDialog(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Select Facility'),
                                        content: SizedBox(
                                          width: double.maxFinite,
                                          child: ListView.builder(
                                            shrinkWrap: true,
                                            itemCount: facilities.length,
                                            itemBuilder: (context, index) {
                                              final facility =
                                                  facilities[index];
                                              return ListTile(
                                                title: Text(facility.name),
                                                onTap: () {
                                                  Navigator.of(ctx).pop();
                                                  context.push(
                                                      '${AppRoute.notificationSettings}?facilityId=${facility.id}');
                                                },
                                              );
                                            },
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(ctx).pop(),
                                            child: const Text('Cancel'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                },
                                loading: () {},
                                error: (_, __) {},
                              );
                            },
                          ),
                          _SettingsTile(
                            icon: Icons.mark_email_unread_outlined,
                            title: 'Email opt-outs',
                            subtitle:
                                'See who unsubscribed and allow facility emails again',
                            onTap: () {
                              facilitiesAsync?.when(
                                data: (facilities) {
                                  if (facilities.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            'Please create a facility first'),
                                        backgroundColor: AppTheme.warning,
                                      ),
                                    );
                                  } else if (facilities.length == 1) {
                                    context.push(
                                        '${AppRoute.emailOptOutsSettings}?facilityId=${facilities.first.id}');
                                  } else {
                                    showDialog(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Select Facility'),
                                        content: SizedBox(
                                          width: double.maxFinite,
                                          child: ListView.builder(
                                            shrinkWrap: true,
                                            itemCount: facilities.length,
                                            itemBuilder: (context, index) {
                                              final facility =
                                                  facilities[index];
                                              return ListTile(
                                                title: Text(facility.name),
                                                onTap: () {
                                                  Navigator.of(ctx).pop();
                                                  context.push(
                                                      '${AppRoute.emailOptOutsSettings}?facilityId=${facility.id}');
                                                },
                                              );
                                            },
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(ctx).pop(),
                                            child: const Text('Cancel'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                },
                                loading: () {},
                                error: (_, __) {},
                              );
                            },
                          ),
                          if (textingOnboardingEnabled)
                            _SettingsTile(
                              icon: Icons.sms_outlined,
                              title: 'Texting',
                              subtitle: 'Enable dedicated number + A2P setup',
                              onTap: () {
                                facilitiesAsync?.when(
                                  data: (facilities) {
                                    if (facilities.isEmpty) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                              'Please create a facility first'),
                                          backgroundColor: AppTheme.warning,
                                        ),
                                      );
                                    } else if (facilities.length == 1) {
                                      context.push(
                                          '${AppRoute.textingSetup}?facilityId=${facilities.first.id}');
                                    } else {
                                      showDialog(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('Select Facility'),
                                          content: SizedBox(
                                            width: double.maxFinite,
                                            child: ListView.builder(
                                              shrinkWrap: true,
                                              itemCount: facilities.length,
                                              itemBuilder: (context, index) {
                                                final facility =
                                                    facilities[index];
                                                return ListTile(
                                                  title: Text(facility.name),
                                                  onTap: () {
                                                    Navigator.of(ctx).pop();
                                                    context.push(
                                                        '${AppRoute.textingSetup}?facilityId=${facility.id}');
                                                  },
                                                );
                                              },
                                            ),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.of(ctx).pop(),
                                              child: const Text('Cancel'),
                                            ),
                                          ],
                                        ),
                                      );
                                    }
                                  },
                                  loading: () {},
                                  error: (_, __) {},
                                );
                              },
                            ),
                          // Payment Processing is now in Billing & Payments (Subscription screen)
                        ],
                      );
                    }),
                    // #endregion
                    const SizedBox(height: 24),

                    // General Section (single Notifications entry is under Account/Notifications above)
                    _SettingsSection(
                      title: 'General',
                      children: [
                        _SettingsTile(
                          icon: Icons.palette_outlined,
                          title: 'Appearance',
                          subtitle: 'Theme and display settings',
                          onTap: () {
                            context.go(AppRoute.appearanceSettings);
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

                    // Legal Section
                    _SettingsSection(
                      title: 'Legal',
                      icon: Icons.gavel_outlined,
                      children: [
                        _SettingsTile(
                          icon: Icons.description_outlined,
                          title: 'Terms of Service',
                          subtitle: 'Your rights and responsibilities',
                          onTap: () => _openLegalUrl('/terms'),
                        ),
                        _SettingsTile(
                          icon: Icons.privacy_tip_outlined,
                          title: 'Privacy Policy',
                          subtitle: 'How we collect and use your data',
                          onTap: () => _openLegalUrl('/privacy'),
                        ),
                        _SettingsTile(
                          icon: Icons.sms_outlined,
                          title: 'SMS Terms',
                          subtitle:
                              'SMS consent, opt-out, and message frequency',
                          onTap: () => _openLegalUrl('/sms-terms'),
                        ),
                        _SettingsTile(
                          icon: Icons.cookie_outlined,
                          title: 'Cookie Policy',
                          subtitle: 'Cookies and similar technologies we use',
                          onTap: () => _openLegalUrl('/cookies'),
                        ),
                        _SettingsTile(
                          icon: Icons.gavel_outlined,
                          title: 'Acceptable Use',
                          subtitle: 'What is and is not permitted',
                          onTap: () => _openLegalUrl('/acceptable-use'),
                        ),
                        _SettingsTile(
                          icon: Icons.receipt_long_outlined,
                          title: 'Billing & Refund Policy',
                          subtitle: 'Subscription, cancellation, and refunds',
                          onTap: () => _openLegalUrl('/billing'),
                        ),
                      ],
                    ),
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
                                content: const Text(
                                    'Are you sure you want to sign out?'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(false),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(true),
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
              _SettingsOnboardingTab(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Onboarding tab: startup checklist for new users (things to do to use the software).
class _SettingsOnboardingTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId =
        ref.watch(authStateProvider).whenOrNull(data: (d) => d)?.uid ?? '';
    final facilitiesAsync = ref.watch(userFacilitiesProvider(userId));
    final dashboardAsync = ref.watch(dashboardStatsProvider);

    return facilitiesAsync.when(
      data: (facilities) {
        final hasFacility = facilities.isNotEmpty;
        final stripeComplete =
            facilities.any((f) => f.stripeConnectOnboardingComplete);

        final firstFacilityId =
            facilities.isNotEmpty ? facilities.first.id : null;
        return dashboardAsync.when(
          data: (stats) => _buildChecklist(
            context,
            hasFacility: hasFacility,
            totalUnits: stats.totalUnits,
            totalTenants: stats.totalTenants,
            stripeComplete: stripeComplete,
            hasFacilities: hasFacility,
            firstFacilityId: firstFacilityId,
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => _buildChecklist(
            context,
            hasFacility: hasFacility,
            totalUnits: 0,
            totalTenants: 0,
            stripeComplete: stripeComplete,
            hasFacilities: hasFacility,
            firstFacilityId: firstFacilityId,
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _buildChecklist(
        context,
        hasFacility: false,
        totalUnits: 0,
        totalTenants: 0,
        stripeComplete: false,
        hasFacilities: false,
        firstFacilityId: null,
      ),
    );
  }

  Widget _buildChecklist(
    BuildContext context, {
    required bool hasFacility,
    required int totalUnits,
    required int totalTenants,
    required bool stripeComplete,
    required bool hasFacilities,
    required String? firstFacilityId,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Get started',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Complete these steps to set up your account and start using the software.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        _OnboardingStep(
          number: 1,
          title: 'Create your first facility',
          subtitle: 'Add name, address, and basic settings.',
          done: hasFacility,
          onTap: () => context.go(AppRoute.facilityCreate),
        ),
        const SizedBox(height: 12),
        _OnboardingStep(
          number: 2,
          title: 'Add units',
          subtitle: 'Use Unit Map or Unit List from the sidebar.',
          done: totalUnits > 0,
          onTap: hasFacilities
              ? () => context.go(AppRoute.units)
              : () => _showCreateFacilityFirst(context),
        ),
        const SizedBox(height: 12),
        _OnboardingStep(
          number: 3,
          title: 'Add a tenant',
          subtitle: 'Use Move-In Wizard or Tenants → Create Tenant.',
          done: totalTenants > 0,
          onTap: hasFacilities
              ? () => context.go(AppRoute.tenants)
              : () => _showCreateFacilityFirst(context),
        ),
        const SizedBox(height: 12),
        _OnboardingStep(
          number: 4,
          title: 'Connect Stripe for payments',
          subtitle: 'Receive rent and process payments securely.',
          done: stripeComplete,
          onTap: () => context.go('${AppRoute.subscription}?tab=processing'),
        ),
        const SizedBox(height: 12),
        _OnboardingStep(
          number: 5,
          title: 'Set up notifications (optional)',
          subtitle: 'Configure reminders and automated messages.',
          done: false,
          onTap: firstFacilityId != null
              ? () => context.push(
                  '${AppRoute.notificationSettings}?facilityId=$firstFacilityId')
              : () => _showCreateFacilityFirst(context),
        ),
      ],
    );
  }

  void _showCreateFacilityFirst(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create a facility first'),
        content: const Text(
          'You need to create a facility before you can add units, tenants, or configure notifications.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.go(AppRoute.facilityCreate);
            },
            child: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }
}

class _OnboardingStep extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  final bool done;
  final VoidCallback onTap;

  const _OnboardingStep({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.done,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: done
                      ? AppTheme.success.withOpacity(0.2)
                      : colorScheme.primary.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: done
                    ? Icon(Icons.check, size: 18, color: AppTheme.success)
                    : Text(
                        '$number',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: colorScheme.primary,
                          fontSize: 14,
                        ),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationColor: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (!done)
                Icon(Icons.arrow_forward_ios,
                    size: 14, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final IconData? icon;

  const _SettingsSection({
    required this.title,
    required this.children,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
              ],
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
              ),
            ],
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
