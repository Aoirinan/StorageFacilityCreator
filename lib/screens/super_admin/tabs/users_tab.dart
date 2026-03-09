import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/user_model.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/services/super_admin_user_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class UsersTab extends ConsumerStatefulWidget {
  const UsersTab({super.key});

  @override
  ConsumerState<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends ConsumerState<UsersTab> {
  String _search = '';
  String _filter = 'all'; // all | 2fa | no2fa

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(allUsersProvider);

    return usersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (users) {
        final filtered = users.where((u) {
          final q = _search.toLowerCase();
          final matchSearch = q.isEmpty ||
              u.email.toLowerCase().contains(q) ||
              u.uid.toLowerCase().contains(q);
          final match2FA = _filter == 'all' ||
              (_filter == '2fa' && u.twoFactorEnabled) ||
              (_filter == 'no2fa' && !u.twoFactorEnabled);
          return matchSearch && match2FA;
        }).toList();

        return Column(
          children: [
            _buildToolbar(filtered.length, users.length),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No users match.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, i) =>
                          _UserRow(user: filtered[i], onUserChanged: () {
                            ref.invalidate(allUsersProvider);
                          }),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildToolbar(int shown, int total) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search by email or UID…',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _filter,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(value: '2fa', child: Text('2FA On')),
              DropdownMenuItem(value: 'no2fa', child: Text('2FA Off')),
            ],
            onChanged: (v) => setState(() => _filter = v!),
          ),
          const SizedBox(width: 12),
          Text('$shown / $total',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  final UserModel user;
  final VoidCallback? onUserChanged;

  const _UserRow({required this.user, this.onUserChanged});

  Future<void> _handleResetPassword(BuildContext context) async {
    try {
      await SuperAdminUserService.sendPasswordReset(user.uid);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Password reset email sent to ${user.email}')),
        );
      }
      onUserChanged?.call();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send reset email: $e')),
        );
      }
    }
  }

  Future<void> _handleDisable(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disable account?'),
        content: Text(
          '${user.email} will no longer be able to sign in. You can re-enable them later.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.warning),
            child: const Text('Disable'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await SuperAdminUserService.disableUser(user.uid);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account disabled')),
        );
      }
      onUserChanged?.call();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to disable: $e')),
        );
      }
    }
  }

  Future<void> _handleEnable(BuildContext context) async {
    try {
      await SuperAdminUserService.enableUser(user.uid);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account enabled')),
        );
      }
      onUserChanged?.call();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to enable: $e')),
        );
      }
    }
  }

  Future<void> _handleDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: Text(
          'Permanently delete ${user.email}? They will be removed from Firebase Auth and the users list. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await SuperAdminUserService.deleteUser(user.uid);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account deleted')),
        );
      }
      onUserChanged?.call();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSuperAdmin = SuperAdminService.isEmailSuperAdmin(user.email);
    final fmt = DateFormat('MMM d, yyyy');
    final lastLogin = user.lastLoginAt != null
        ? fmt.format(user.lastLoginAt!)
        : 'Never';
    final joined = user.createdAt != null
        ? fmt.format(user.createdAt!)
        : '—';
    final canManage = !isSuperAdmin;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: isSuperAdmin
                ? AppTheme.warning.withValues(alpha: 0.4)
                : AppTheme.borderLight),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: isSuperAdmin
              ? AppTheme.warning.withValues(alpha: 0.15)
              : AppTheme.primaryBlue.withValues(alpha: 0.1),
          child: Icon(
            isSuperAdmin ? Icons.shield : Icons.person,
            color: isSuperAdmin ? AppTheme.warning : AppTheme.primaryBlue,
            size: 18,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(user.email,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (isSuperAdmin)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('Super Admin',
                    style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.warning,
                        fontWeight: FontWeight.bold)),
              ),
            const SizedBox(width: 8),
            if (user.authDisabled)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('Disabled',
                    style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.error,
                        fontWeight: FontWeight.bold)),
              ),
            if (user.authDisabled) const SizedBox(width: 8),
            if (user.twoFactorEnabled)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('2FA',
                    style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.success,
                        fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        subtitle: Text(
          'Joined $joined  ·  Last login: $lastLogin  ·  UID: ${user.uid.length >= 8 ? '${user.uid.substring(0, 8)}…' : user.uid}',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppTheme.textSecondary),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              tooltip: 'Copy UID',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: user.uid));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('UID copied'),
                      duration: Duration(seconds: 1)),
                );
              },
            ),
            if (canManage)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                tooltip: 'Manage account',
                onSelected: (value) {
                  switch (value) {
                    case 'reset':
                      _handleResetPassword(context);
                      break;
                    case 'disable':
                      _handleDisable(context);
                      break;
                    case 'enable':
                      _handleEnable(context);
                      break;
                    case 'delete':
                      _handleDelete(context);
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'reset', child: Text('Reset password')),
                  if (user.authDisabled)
                    const PopupMenuItem(value: 'enable', child: Text('Enable account'))
                  else
                    const PopupMenuItem(value: 'disable', child: Text('Disable account')),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete account', style: TextStyle(color: AppTheme.error)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
