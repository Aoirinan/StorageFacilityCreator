import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Super-admin only: irreversibly wipe all customer/platform data.
class PlatformResetTab extends ConsumerStatefulWidget {
  const PlatformResetTab({super.key});

  @override
  ConsumerState<PlatformResetTab> createState() => _PlatformResetTabState();
}

class _PlatformResetTabState extends ConsumerState<PlatformResetTab> {
  final _phraseController = TextEditingController();
  final _emailController = TextEditingController();
  bool _purging = false;

  @override
  void dispose() {
    _phraseController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  String get _callerEmail =>
      FirebaseAuth.instance.currentUser?.email?.trim() ?? '';

  bool get _canSubmit {
    if (_purging) return false;
    if (_phraseController.text.trim() != 'PURGE PLATFORM') return false;
    final typed = _emailController.text.trim().toLowerCase();
    final expected = _callerEmail.toLowerCase();
    return typed.isNotEmpty && typed == expected;
  }

  Future<void> _runPurge() async {
    if (!_canSubmit) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Final confirmation'),
        content: const Text(
          'This permanently deletes every facility, tenant, account, reservation, '
          'lead, and non–super-admin login. Super-admin profiles are preserved.\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _purging = true);
    try {
      final stats = await SuperAdminDataService.purgePlatformData(
        confirmationPhrase: _phraseController.text.trim(),
        callerEmailConfirmation: _emailController.text.trim(),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Platform reset complete'),
          content: SingleChildScrollView(
            child: Text(_formatStats(stats)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      _phraseController.clear();
      _emailController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Purge failed: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  String _formatStats(Map<String, dynamic> stats) {
    final preserved = stats['preservedSuperAdminEmails'];
    final preservedList = preserved is List
        ? preserved.map((e) => e.toString()).join('\n  • ')
        : '';
    return [
      'Facilities deleted: ${stats['facilitiesDeleted'] ?? 0}',
      'Facility creator accounts deleted: ${stats['facilityCreatorAccountsDeleted'] ?? 0}',
      'Firestore user profiles deleted: ${stats['firestoreUsersDeleted'] ?? 0}',
      'Firebase Auth users deleted: ${stats['authUsersDeleted'] ?? 0}',
      'Stripe subscriptions cancelled: ${stats['stripeSubscriptionsCancelled'] ?? 0}',
      'Storage facilities/ prefix cleared: ${stats['storagePrefixCleared'] ?? false}',
      '',
      'Preserved super admins:',
      '  • $preservedList',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final superAdmins = SuperAdminService.superAdminEmails;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.error.withValues(alpha: 0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: AppTheme.error, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Platform reset (clean slate)',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.error,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Removes all facilities, tenants, facility-creator accounts, '
                    'public reservations, leads, referrals, bug reports, roles, '
                    'rate-limit records, and every Firebase Auth login except '
                    'super-admin accounts.',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Preserved: appConfig, configs, and these super-admin emails:\n'
                    '${superAdmins.map((e) => '• $e').join('\n')}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Stripe Connect connected accounts are not deleted automatically—'
                    'archive them in the Stripe Dashboard if needed.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.textTertiary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _phraseController,
              decoration: const InputDecoration(
                labelText: 'Type PURGE PLATFORM to confirm',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              decoration: InputDecoration(
                labelText: 'Type your super-admin email to confirm',
                hintText: _callerEmail,
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _canSubmit ? _runPurge : null,
              icon: _purging
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.delete_forever),
              label: Text(_purging ? 'Purging…' : 'Purge all customer data'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.error,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
