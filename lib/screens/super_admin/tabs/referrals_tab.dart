import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class ReferralsTab extends ConsumerStatefulWidget {
  const ReferralsTab({super.key});

  @override
  ConsumerState<ReferralsTab> createState() => _ReferralsTabState();
}

class _ReferralsTabState extends ConsumerState<ReferralsTab> {
  int _pendingLimit = 100;
  int _pendingReloadKey = 0;
  bool _pendingActionBusy = false;

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(allAccountsProvider);
    final facilitiesAsync = ref.watch(referralFacilityAuditProvider);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                'Referral Program Visibility',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              DropdownButton<int>(
                value: _pendingLimit,
                items: const [
                  DropdownMenuItem(value: 50, child: Text('50 pending')),
                  DropdownMenuItem(value: 100, child: Text('100 pending')),
                  DropdownMenuItem(value: 200, child: Text('200 pending')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _pendingLimit = v;
                    _pendingReloadKey++;
                  });
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildPendingQueueCard(context),
              const SizedBox(height: 12),
              accountsAsync.when(
                loading: () => const _LoadingCard(),
                error: (e, _) => _ErrorCard(message: 'Accounts load failed: $e'),
                data: (accounts) => _AccountsReferralCard(accounts: accounts),
              ),
              const SizedBox(height: 12),
              facilitiesAsync.when(
                loading: () => const _LoadingCard(),
                error: (e, _) => _ErrorCard(message: 'Facilities load failed: $e'),
                data: (rows) => _FacilityReferralCard(rows: rows),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPendingQueueCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: FutureBuilder<List<ReferralPendingItem>>(
          key: ValueKey('pending_${_pendingLimit}_$_pendingReloadKey'),
          future: SuperAdminDataService.listReferralRewardsPending(limit: _pendingLimit),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return _ErrorInline(message: 'Pending queue unavailable: ${snap.error}');
            }
            final items = snap.data ?? const <ReferralPendingItem>[];
            final openItems = items.where((e) => e.status != 'resolved').toList();
            final resolvedCount = items.length - openItems.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Manual Review Queue',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Source: backend-only referral queue from webhook processing.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 10),
                if (openItems.isEmpty)
                  Text(
                    'No pending referral items.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                else
                  ...openItems.take(25).map((i) => _pendingRow(context, i)),
                if (resolvedCount > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '$resolvedCount resolved item(s) hidden. Increase limit to inspect history.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.textSecondary),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _resolvePendingItem(
    ReferralPendingItem i, {
    required String action,
  }) async {
    final noteController = TextEditingController();
    String? selectedTargetFacilityId;
    final facilities = ref
        .read(referralFacilityAuditProvider)
        .maybeWhen(data: (v) => v, orElse: () => const <ReferralFacilityAuditRow>[]);
    final referrerFacilities = facilities
        .where((f) => f.facilityCreatorAccountId == i.referrerAccountId)
        .toList();

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return AlertDialog(
            title: Text(action == 'apply_reward' ? 'Apply manual reward' : 'Mark as resolved'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pending: ${i.id}'),
                const SizedBox(height: 8),
                TextField(
                  controller: noteController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Resolution note (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (action == 'apply_reward' && referrerFacilities.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTargetFacilityId,
                    decoration: const InputDecoration(
                      labelText: 'Target reward facility (optional override)',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('Use account preference / auto'),
                      ),
                      ...referrerFacilities.map(
                        (f) => DropdownMenuItem<String>(
                          value: f.facilityId,
                          child: Text(
                            '${f.facilityName} (${f.facilityId})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) => setModalState(() => selectedTargetFacilityId = v),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Confirm'),
              ),
            ],
          );
        },
      ),
    );

    if (proceed != true || !mounted) return;

    setState(() => _pendingActionBusy = true);
    try {
      await SuperAdminDataService.resolveReferralPending(
        pendingId: i.id,
        action: action,
        note: noteController.text.trim(),
        targetFacilityId: selectedTargetFacilityId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(action == 'apply_reward'
              ? 'Manual reward applied and pending item resolved.'
              : 'Pending item marked resolved.'),
          backgroundColor: AppTheme.success,
        ),
      );
      setState(() => _pendingReloadKey++);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Resolution failed: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _pendingActionBusy = false);
    }
  }

  Widget _pendingRow(BuildContext context, ReferralPendingItem i) {
    final fmt = DateFormat('MMM d, yyyy h:mm a');
    final created = i.createdAt == null ? '—' : fmt.format(i.createdAt!);
    final reason = (i.reason ?? 'unknown').trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border.all(color: AppTheme.borderLight),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _pill(reason),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Created: $created',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppTheme.textSecondary),
                ),
              ),
              IconButton(
                tooltip: 'Copy pending item id',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () => Clipboard.setData(ClipboardData(text: i.id)),
              ),
            ],
          ),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _kv('Pending ID', i.id),
              _kv('Referrer', i.referrerAccountId ?? '—'),
              _kv('Referee account', i.refereeAccountId ?? '—'),
              _kv('Referee facility', i.refereeFacilityId ?? '—'),
              _kv('Stripe invoice', i.stripeInvoiceId ?? '—'),
            ],
          ),
          if ((i.error ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Error: ${i.error}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.error),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                onPressed: _pendingActionBusy
                    ? null
                    : () => _resolvePendingItem(i, action: 'resolve_only'),
                icon: const Icon(Icons.task_alt, size: 16),
                label: const Text('Mark resolved'),
              ),
              FilledButton.icon(
                onPressed: _pendingActionBusy
                    ? null
                    : () => _resolvePendingItem(i, action: 'apply_reward'),
                icon: const Icon(Icons.redeem, size: 16),
                label: const Text('Apply reward + resolve'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: AppTheme.warning,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AccountsReferralCard extends StatelessWidget {
  final List<FacilityCreatorAccountModel> accounts;
  const _AccountsReferralCard({required this.accounts});

  @override
  Widget build(BuildContext context) {
    final rows = accounts.where((a) {
      final code = a.referralCode?.trim();
      final by = a.referredByAccountId?.trim();
      final pref = a.referralRewardPreferredFacilityId?.trim();
      return (code != null && code.isNotEmpty) ||
          (by != null && by.isNotEmpty) ||
          (pref != null && pref.isNotEmpty);
    }).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Account Referral Fields',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Accounts with referral code/linkage/preferred reward facility: ${rows.length}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              const Text('No referral data on accounts yet.')
            else
              ...rows.take(40).map((a) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.borderLight),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      _kv('Account', a.accountId),
                      _kv('Owner', a.ownerEmail),
                      _kv('Referral code', a.referralCode ?? '—'),
                      _kv('Referred by', a.referredByAccountId ?? '—'),
                      _kv(
                        'Preferred reward facility',
                        a.referralRewardPreferredFacilityId ?? 'Automatic',
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _FacilityReferralCard extends StatelessWidget {
  final List<ReferralFacilityAuditRow> rows;
  const _FacilityReferralCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d, yyyy');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Facility Referral Audit',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Facilities with referral tracking or reward outcome: ${rows.length}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              const Text('No referral facility rows yet.')
            else
              ...rows.take(60).map((r) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.borderLight),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      _kv('Facility', '${r.facilityName} (${r.facilityId})'),
                      _kv('Account', r.facilityCreatorAccountId ?? '—'),
                      _kv('Referred by', r.referredByAccountId ?? '—'),
                      _kv(
                        'Reward granted',
                        r.rewardGrantedAt == null ? 'No' : fmt.format(r.rewardGrantedAt!),
                      ),
                      _kv('Reward invoice', r.rewardStripeInvoiceId ?? '—'),
                      _kv('Applied to facility', r.rewardAppliedToFacilityId ?? '—'),
                      _kv('Pending manual', r.rewardPendingManual ? 'Yes' : 'No'),
                      _kv('Cap reached', r.rewardCapReached ? 'Yes' : 'No'),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message, style: const TextStyle(color: AppTheme.error)),
      ),
    );
  }
}

class _ErrorInline extends StatelessWidget {
  final String message;
  const _ErrorInline({required this.message});

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: AppTheme.error),
    );
  }
}

Widget _kv(String label, String value) {
  return SizedBox(
    width: 250,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
        ),
        Text(value, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}
