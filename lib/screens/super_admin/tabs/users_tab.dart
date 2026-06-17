import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/super_admin_auth_user.dart';
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

class _UsersTabState extends ConsumerState<UsersTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'App profiles'),
            Tab(text: 'Firebase Auth'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _FirestoreUsersPanel(
                onUserChanged: () => ref.invalidate(allUsersProvider),
              ),
              _AuthUsersPanel(
                onAuthUserChanged: () => ref.invalidate(allUsersProvider),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FirestoreUsersPanel extends ConsumerStatefulWidget {
  final VoidCallback onUserChanged;

  const _FirestoreUsersPanel({required this.onUserChanged});

  @override
  ConsumerState<_FirestoreUsersPanel> createState() =>
      _FirestoreUsersPanelState();
}

class _FirestoreUsersPanelState extends ConsumerState<_FirestoreUsersPanel> {
  String _search = '';
  String _filter = 'all';

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
            _buildFirestoreToolbar(filtered.length, users.length),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No users match.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, i) => _UserRow(
                        user: filtered[i],
                        onUserChanged: widget.onUserChanged,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFirestoreToolbar(int shown, int total) {
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

class _AuthUsersPanel extends ConsumerStatefulWidget {
  final VoidCallback onAuthUserChanged;

  const _AuthUsersPanel({required this.onAuthUserChanged});

  @override
  ConsumerState<_AuthUsersPanel> createState() => _AuthUsersPanelState();
}

class _AuthUsersPanelState extends ConsumerState<_AuthUsersPanel> {
  final _emailSearchController = TextEditingController();
  List<SuperAdminAuthUser> _users = [];
  String? _nextPageToken;
  bool _loading = false;
  bool _loadingMore = false;
  String? _lookupError;
  SuperAdminAuthUser? _lookupResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirstPage());
  }

  @override
  void dispose() {
    _emailSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _users = [];
      _nextPageToken = null;
    });
    try {
      final page = await SuperAdminUserService.listAuthUsers(maxResults: 50);
      if (!mounted) return;
      setState(() {
        _users = page.users;
        _nextPageToken = page.nextPageToken;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load Auth users: $e')),
        );
      }
    }
  }

  Future<void> _loadMore() async {
    final token = _nextPageToken;
    if (token == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await SuperAdminUserService.listAuthUsers(
        pageToken: token,
        maxResults: 50,
      );
      if (!mounted) return;
      setState(() {
        _users = [..._users, ...page.users];
        _nextPageToken = page.nextPageToken;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load more: $e')),
        );
      }
    }
  }

  Future<void> _lookupEmail() async {
    final email = _emailSearchController.text.trim();
    if (!email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid email address.')),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _lookupError = null;
      _lookupResult = null;
    });
    try {
      final result = await SuperAdminUserService.getAuthUserByEmail(email);
      if (!mounted) return;
      if (!result.found) {
        setState(() => _lookupError =
            'No Firebase Auth user exists for that email.');
        return;
      }
      setState(() => _lookupResult = result.user);
    } catch (e) {
      if (!mounted) return;
      setState(() => _lookupError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _emailSearchController,
                      decoration: InputDecoration(
                        hintText: 'Find by exact email (Auth)…',
                        prefixIcon: const Icon(Icons.email_outlined, size: 18),
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _lookupEmail(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _lookupEmail,
                    child: const Text('Find'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _loadFirstPage,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Refresh list'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Lists Firebase Authentication users. '
                      '“Auth only” means no Firestore app profile yet (e.g. signup not verified).',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppTheme.textSecondary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_lookupError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _lookupError!,
              style: TextStyle(color: AppTheme.error, fontSize: 13),
            ),
          ),
        if (_lookupResult != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: _AuthUserRow(
              user: _lookupResult!,
              onChanged: () {
                widget.onAuthUserChanged();
                _loadFirstPage();
              },
              onAfterDelete: () {
                setState(() {
                  _lookupResult = null;
                  _lookupError = null;
                });
              },
            ),
          ),
        if (_lookupError != null || _lookupResult != null)
          const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _users.isEmpty
                  ? const Center(child: Text('No Auth users returned.'))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: _users.length + (_nextPageToken != null ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= _users.length) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Center(
                              child: _loadingMore
                                  ? const CircularProgressIndicator()
                                  : TextButton(
                                      onPressed: _loadMore,
                                      child: const Text('Load more'),
                                    ),
                            ),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _AuthUserRow(
                            user: _users[i],
                            onChanged: () {
                              widget.onAuthUserChanged();
                              _loadFirstPage();
                            },
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _AuthUserRow extends StatelessWidget {
  final SuperAdminAuthUser user;
  final VoidCallback onChanged;
  final VoidCallback? onAfterDelete;

  const _AuthUserRow({
    required this.user,
    required this.onChanged,
    this.onAfterDelete,
  });

  Future<void> _handleResetPassword(BuildContext context) async {
    try {
      await SuperAdminUserService.sendPasswordReset(user.uid);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Password reset email sent to ${user.email}')),
        );
      }
      onChanged();
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
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
      onChanged();
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
      onChanged();
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
        title: const Text('Delete Auth user?'),
        content: Text(
          'Permanently delete ${user.email}? They will be removed from Firebase Auth and the app users collection if present. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
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
      onAfterDelete?.call();
      onChanged();
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
    final isSelf = user.uid == FirebaseAuth.instance.currentUser?.uid;
    final canManage = !isSelf;

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
          backgroundColor: user.hasFirestoreProfile
              ? AppTheme.primaryBlue.withValues(alpha: 0.1)
              : AppTheme.warning.withValues(alpha: 0.12),
          child: Icon(
            user.hasFirestoreProfile ? Icons.person : Icons.person_off_outlined,
            color: user.hasFirestoreProfile
                ? AppTheme.primaryBlue
                : AppTheme.warning,
            size: 18,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                user.email.isEmpty ? '(no email)' : user.email,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
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
            if (isSuperAdmin) const SizedBox(width: 8),
            if (!user.hasFirestoreProfile)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('Auth only',
                    style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.warning,
                        fontWeight: FontWeight.bold)),
              ),
            if (!user.hasFirestoreProfile) const SizedBox(width: 8),
            if (user.disabled)
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
            if (user.disabled) const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: user.emailVerified
                    ? AppTheme.success.withValues(alpha: 0.12)
                    : AppTheme.textSecondary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                user.emailVerified ? 'Verified' : 'Unverified',
                style: TextStyle(
                  fontSize: 10,
                  color: user.emailVerified
                      ? AppTheme.success
                      : AppTheme.textSecondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        subtitle: Text(
          'Created: ${user.creationTime ?? "—"}  ·  Last sign-in: ${user.lastSignInTime ?? "Never"}  ·  UID: ${user.uid.length >= 8 ? "${user.uid.substring(0, 8)}…" : user.uid}',
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
                  const PopupMenuItem(
                      value: 'reset', child: Text('Reset password')),
                  if (user.disabled)
                    const PopupMenuItem(
                        value: 'enable', child: Text('Enable account'))
                  else
                    const PopupMenuItem(
                        value: 'disable', child: Text('Disable account')),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete account',
                        style: TextStyle(color: AppTheme.error)),
                  ),
                ],
              ),
          ],
        ),
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
    final isSelf = user.uid == FirebaseAuth.instance.currentUser?.uid;
    final canManage = !isSelf;
    final fmt = DateFormat('MMM d, yyyy');
    final lastLogin = user.lastLoginAt != null
        ? fmt.format(user.lastLoginAt!)
        : 'Never';
    final joined = user.createdAt != null
        ? fmt.format(user.createdAt!)
        : '—';

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
