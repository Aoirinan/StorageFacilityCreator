import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/services/super_admin_user_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class AccountsTab extends ConsumerStatefulWidget {
  const AccountsTab({super.key});

  @override
  ConsumerState<AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends ConsumerState<AccountsTab> {
  String _search = '';
  String _statusFilter = 'all';

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(allAccountsProvider);
    final usersAsync = ref.watch(allUsersProvider);

    return usersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (users) => accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (accounts) {
        final userByUid = {for (final u in users) u.uid: u};
        final pendingCount = accounts
            .where((a) =>
                a.subscriptionStatus == SubscriptionStatus.pendingApproval)
            .length;

        final filtered = accounts.where((a) {
          final q = _search.toLowerCase();
          final matchSearch = q.isEmpty ||
              a.ownerEmail.toLowerCase().contains(q) ||
              a.ownerName.toLowerCase().contains(q) ||
              a.accountId.toLowerCase().contains(q);
          final matchStatus = _statusFilter == 'all' ||
              a.subscriptionStatus.name.toLowerCase() == _statusFilter;
          return matchSearch && matchStatus;
        }).toList();

        return Column(
          children: [
            // Pending approval alert banner
            if (pendingCount > 0)
              _PendingBanner(
                count: pendingCount,
                onFilter: () =>
                    setState(() => _statusFilter = 'pendingapproval'),
              ),
            _buildToolbar(filtered.length, accounts.length),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No accounts match.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _AccountRow(
                            account: filtered[i],
                            ownerAuthDisabled:
                                userByUid[filtered[i].ownerUid]?.authDisabled == true,
                          ),
                    ),
            ),
          ],
        );
      }),
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
                hintText: 'Search by email, name, account ID…',
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
            value: _statusFilter,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(
                  value: 'pendingapproval', child: Text('Pending Approval')),
              DropdownMenuItem(value: 'active', child: Text('Active')),
              DropdownMenuItem(value: 'trialing', child: Text('Trial')),
              DropdownMenuItem(value: 'pastdue', child: Text('Past Due')),
              DropdownMenuItem(value: 'cancelled', child: Text('Cancelled')),
              DropdownMenuItem(value: 'unpaid', child: Text('Unpaid')),
            ],
            onChanged: (v) => setState(() => _statusFilter = v!),
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

/// Amber alert banner shown when there are accounts awaiting approval.
class _PendingBanner extends StatelessWidget {
  const _PendingBanner({required this.count, required this.onFilter});
  final int count;
  final VoidCallback onFilter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade700,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.pending_actions, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$count account${count == 1 ? '' : 's'} waiting for your approval',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: onFilter,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Review'),
          ),
        ],
      ),
    );
  }
}

class _AccountRow extends ConsumerStatefulWidget {
  final FacilityCreatorAccountModel account;
  final bool ownerAuthDisabled;
  const _AccountRow({required this.account, required this.ownerAuthDisabled});

  @override
  ConsumerState<_AccountRow> createState() => _AccountRowState();
}

class _AccountRowState extends ConsumerState<_AccountRow> {
  bool _extending = false;
  bool _granting = false;
  bool _revoking = false;
  bool _approving = false;
  bool _rejecting = false;
  bool _suspending = false;
  bool _reenablingOwner = false;
  bool _disablingOwner = false;
  bool _deletingAccount = false;

  Color _statusColor(SubscriptionStatus s) {
    switch (s) {
      case SubscriptionStatus.active:
        return AppTheme.success;
      case SubscriptionStatus.trialing:
        return AppTheme.info;
      case SubscriptionStatus.pastDue:
        return AppTheme.warning;
      case SubscriptionStatus.pendingApproval:
        return Colors.amber.shade700;
      case SubscriptionStatus.cancelled:
      case SubscriptionStatus.unpaid:
      case SubscriptionStatus.incomplete:
      case SubscriptionStatus.incompleteExpired:
        return AppTheme.error;
    }
  }

  bool get _isBusy =>
      _extending ||
      _granting ||
      _revoking ||
      _approving ||
      _rejecting ||
      _suspending ||
      _reenablingOwner ||
      _disablingOwner ||
      _deletingAccount;

  Future<void> _deleteFacilityCreatorAccountPermanently() async {
    final a = widget.account;
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid != null && currentUid == a.ownerUid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'You cannot delete your own account while signed in as that owner.',
            ),
          ),
        );
      }
      return;
    }

    final confirmationEmail = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DeleteFacilityCreatorAccountDialog(account: a),
    );
    if (confirmationEmail == null || confirmationEmail.isEmpty || !mounted) {
      return;
    }

    setState(() => _deletingAccount = true);
    try {
      await SuperAdminDataService.deleteFacilityCreatorAccount(
        accountId: a.accountId,
        ownerEmailConfirmation: confirmationEmail,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted account and data for ${a.ownerEmail}.'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Delete failed: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
  }

  Future<void> _extendTrial(int days) async {
    setState(() => _extending = true);
    try {
      await SuperAdminDataService.extendTrial(widget.account.accountId, days);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Trial extended by $days days.'),
              backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _extending = false);
    }
  }

  Future<void> _grantTrial(int days) async {
    final confirmed = await _confirm(
      title: 'Grant $days-Day Trial',
      message:
          'This will set ${widget.account.ownerEmail} to trialing status '
          'with a $days-day trial period, regardless of their current status. Continue?',
      confirmLabel: 'Grant Trial',
      confirmColor: AppTheme.info,
    );
    if (!confirmed || !mounted) return;

    setState(() => _granting = true);
    try {
      await SuperAdminDataService.grantTrial(
          widget.account.accountId, days: days);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('$days-day trial granted.'),
              backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _granting = false);
    }
  }

  Future<void> _revokeTrial() async {
    final confirmed = await _confirm(
      title: 'Revoke Trial',
      message:
          'This will immediately end the trial for ${widget.account.ownerEmail} '
          'and set their status to cancelled. They will lose access. Continue?',
      confirmLabel: 'Revoke Trial',
      confirmColor: AppTheme.error,
    );
    if (!confirmed || !mounted) return;

    setState(() => _revoking = true);
    try {
      await SuperAdminDataService.revokeTrial(widget.account.accountId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Trial revoked. Account set to cancelled.'),
              backgroundColor: AppTheme.warning),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _revoking = false);
    }
  }

  Future<void> _approveTrial() async {
    final confirmed = await _confirm(
      title: 'Approve Account',
      message:
          'Approve ${widget.account.ownerEmail}? This will start their 30-day '
          'free trial immediately and grant full access.',
      confirmLabel: 'Approve & Start Trial',
      confirmColor: AppTheme.success,
    );
    if (!confirmed || !mounted) return;

    setState(() => _approving = true);
    try {
      await SuperAdminDataService.approveTrial(widget.account.accountId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  '${widget.account.ownerEmail} approved — 30-day trial started.'),
              backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  Future<void> _rejectAccount() async {
    final confirmed = await _confirm(
      title: 'Reject Account',
      message:
          'Reject ${widget.account.ownerEmail}? Their status will be set to '
          'cancelled and they will not gain access.',
      confirmLabel: 'Reject',
      confirmColor: AppTheme.error,
    );
    if (!confirmed || !mounted) return;

    setState(() => _rejecting = true);
    try {
      await SuperAdminDataService.rejectAccount(widget.account.accountId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${widget.account.ownerEmail} rejected.'),
              backgroundColor: AppTheme.warning),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _rejecting = false);
    }
  }

  Future<void> _suspendForAbuse() async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Suspend Account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This immediately blocks account access. Add a short reason for audit history.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: reasonController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Abusive usage of messaging functions',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Suspend'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final reason = reasonController.text.trim();
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Suspension reason is required.')),
      );
      return;
    }
    final actor = FirebaseAuth.instance.currentUser;
    setState(() => _suspending = true);
    try {
      await SuperAdminDataService.setAccountSuspended(
        accountId: widget.account.accountId,
        suspended: true,
        reason: reason,
        actorUid: actor?.uid ?? 'unknown',
        actorEmail: actor?.email ?? 'unknown',
      );
      await SuperAdminUserService.disableUser(widget.account.ownerUid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account suspended and owner login disabled.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _suspending = false);
    }
  }

  Future<void> _enableOwnerLogin() async {
    final actor = FirebaseAuth.instance.currentUser;
    setState(() => _reenablingOwner = true);
    try {
      await SuperAdminUserService.enableUser(widget.account.ownerUid);
      await SuperAdminDataService.setAccountSuspended(
        accountId: widget.account.accountId,
        suspended: false,
        actorUid: actor?.uid ?? 'unknown',
        actorEmail: actor?.email ?? 'unknown',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Owner login enabled and account unsuspended.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _reenablingOwner = false);
    }
  }

  Future<void> _disableOwnerLoginOnly() async {
    setState(() => _disablingOwner = true);
    try {
      await SuperAdminUserService.disableUser(widget.account.ownerUid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Owner login disabled.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _disablingOwner = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    required Color confirmColor,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: confirmColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final color = _statusColor(a.subscriptionStatus);
    final fmt = DateFormat('MMM d, yyyy');
    final isTrialing = a.subscriptionStatus == SubscriptionStatus.trialing;
    final isPending = a.subscriptionStatus == SubscriptionStatus.pendingApproval;
    final isSuspended = a.suspended;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: ExpansionTile(
        tilePadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding:
            const EdgeInsets.fromLTRB(16, 0, 16, 16),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.1),
          child: Icon(
            isPending ? Icons.pending_outlined : Icons.account_circle,
            color: color,
            size: 18,
          ),
        ),
        title: Text(a.ownerEmail,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(a.ownerName,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.textSecondary)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.delete_forever_outlined,
                  color: AppTheme.error, size: 22),
              tooltip:
                  'Delete facility creator account (Firestore + facilities + owner login)',
              onPressed: _isBusy ? null : _deleteFacilityCreatorAccountPermanently,
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Text(a.subscriptionStatus.displayName,
                  style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _kv(context, 'Account ID', a.accountId),
              _kv(context, 'Owner UID', a.ownerUid),
              _kv(context, 'Facilities', '${a.facilityIds.length}'),
              _kv(context, 'Stripe Customer', a.stripeCustomerId ?? '—'),
              _kv(context, 'Stripe Sub', a.stripeSubscriptionId ?? '—'),
              _kv(context, 'Created', fmt.format(a.createdAt)),
              _kv(context, 'Owner login', widget.ownerAuthDisabled ? 'Disabled' : 'Enabled'),
              _kv(context, 'Suspended', isSuspended ? 'Yes' : 'No'),
              if ((a.suspensionReason ?? '').trim().isNotEmpty)
                _kv(context, 'Suspension reason', a.suspensionReason!.trim()),
              if (a.subscriptionCurrentPeriodEnd != null)
                _kv(context, 'Period End',
                    fmt.format(a.subscriptionCurrentPeriodEnd!)),
              if (a.subscriptionTrialEnd != null)
                _kv(context, 'Trial End',
                    fmt.format(a.subscriptionTrialEnd!)),
              if (a.subscriptionCancelAtPeriodEnd)
                _kv(context, 'Cancel At Period End', 'Yes'),
            ],
          ),
          const SizedBox(height: 12),

          // ── Action bar ────────────────────────────────────────────────
          if (_isBusy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                // Copy ID — always visible
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 14),
                  label: const Text('Copy ID'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: a.accountId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Account ID copied'),
                          duration: Duration(seconds: 1)),
                    );
                  },
                ),

                // ── Pending Approval actions ───────────────────────────
                if (isPending) ...[
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.success),
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text('Approve'),
                    onPressed: _approveTrial,
                  ),
                  const SizedBox(width: 4),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.error,
                        side: BorderSide(color: AppTheme.error)),
                    icon: const Icon(Icons.cancel_outlined, size: 16),
                    label: const Text('Reject'),
                    onPressed: _rejectAccount,
                  ),
                ],

                // Grant Trial — shown when NOT currently trialing and NOT pending
                if (!isTrialing && !isPending)
                  PopupMenuButton<int>(
                    tooltip: 'Grant Trial',
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 14, child: Text('Grant 14-day trial')),
                      PopupMenuItem(value: 30, child: Text('Grant 30-day trial')),
                      PopupMenuItem(value: 60, child: Text('Grant 60-day trial')),
                    ],
                    onSelected: _grantTrial,
                    child: TextButton.icon(
                      icon: Icon(Icons.star_outline,
                          size: 14, color: AppTheme.info),
                      label: Text('Grant Trial',
                          style: TextStyle(color: AppTheme.info)),
                      onPressed: null,
                    ),
                  ),

                // Extend Trial — shown only while trialing
                if (isTrialing)
                  PopupMenuButton<int>(
                    tooltip: 'Extend Trial',
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 7, child: Text('+7 days')),
                      PopupMenuItem(value: 14, child: Text('+14 days')),
                      PopupMenuItem(value: 30, child: Text('+30 days')),
                    ],
                    onSelected: _extendTrial,
                    child: TextButton.icon(
                      icon: const Icon(Icons.more_time, size: 14),
                      label: const Text('Extend Trial'),
                      onPressed: null,
                    ),
                  ),

                // Revoke Trial — shown only while trialing
                if (isTrialing)
                  TextButton.icon(
                    icon: Icon(Icons.block, size: 14, color: AppTheme.error),
                    label: Text('Revoke Trial',
                        style: TextStyle(color: AppTheme.error)),
                    onPressed: _revokeTrial,
                  ),
                const SizedBox(width: 8),
                if (!isSuspended)
                  TextButton.icon(
                    icon: const Icon(Icons.gpp_bad, size: 14, color: AppTheme.error),
                    label: const Text('Suspend Abuse',
                        style: TextStyle(color: AppTheme.error)),
                    onPressed: _suspendForAbuse,
                  )
                else
                  TextButton.icon(
                    icon: const Icon(Icons.gpp_good, size: 14, color: AppTheme.success),
                    label: const Text('Unsuspend',
                        style: TextStyle(color: AppTheme.success)),
                    onPressed: _enableOwnerLogin,
                  ),
                if (!widget.ownerAuthDisabled)
                  TextButton.icon(
                    icon: const Icon(Icons.person_off, size: 14),
                    label: const Text('Disable Owner Login'),
                    onPressed: _disableOwnerLoginOnly,
                  )
                else
                  TextButton.icon(
                    icon: const Icon(Icons.person, size: 14),
                    label: const Text('Enable Owner Login'),
                    onPressed: _enableOwnerLogin,
                  ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: Icon(Icons.delete_forever, size: 14, color: AppTheme.error),
                  label: Text(
                    'Delete account & data',
                    style: TextStyle(color: AppTheme.error),
                  ),
                  onPressed: _deleteFacilityCreatorAccountPermanently,
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    return SizedBox(
      width: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textTertiary)),
          Text(value,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Confirmation dialog: user must type the account owner email exactly.
class _DeleteFacilityCreatorAccountDialog extends StatefulWidget {
  const _DeleteFacilityCreatorAccountDialog({required this.account});

  final FacilityCreatorAccountModel account;

  @override
  State<_DeleteFacilityCreatorAccountDialog> createState() =>
      _DeleteFacilityCreatorAccountDialogState();
}

class _DeleteFacilityCreatorAccountDialogState
    extends State<_DeleteFacilityCreatorAccountDialog> {
  late final TextEditingController _controller;
  late final bool _isPayingLike;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    final s = widget.account.subscriptionStatus;
    _isPayingLike = s == SubscriptionStatus.active ||
        s == SubscriptionStatus.trialing ||
        s == SubscriptionStatus.pastDue;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _emailsMatch {
    final typed = _controller.text.trim().toLowerCase();
    final expected = widget.account.ownerEmail.trim().toLowerCase();
    return typed.isNotEmpty && typed == expected;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete account permanently?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isPayingLike)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'This account is active, trialing, or past due. Deletion removes '
                  'all facility data and the owner login. Cancel or resolve billing in Stripe if needed.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.warning,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            Text(
              'This will permanently delete every facility owned by '
              '${widget.account.ownerEmail}, the facility creator account record '
              '(and subcollections), and remove the owner from Firebase Auth and the '
              'users list. This cannot be undone.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Stripe subscriptions are not automatically cancelled—handle those in the Stripe Dashboard if applicable.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textTertiary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Type owner email to confirm',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _emailsMatch
              ? () => Navigator.pop(context, _controller.text.trim())
              : null,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
          child: const Text('Delete everything'),
        ),
      ],
    );
  }
}
