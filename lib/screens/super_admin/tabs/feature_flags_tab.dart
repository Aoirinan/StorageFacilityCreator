import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/feature_flag_model.dart';
import 'package:sfcapp/providers/feature_flag_provider.dart';
import 'package:sfcapp/theme/app_theme.dart';

class FeatureFlagsTab extends ConsumerWidget {
  const FeatureFlagsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flagsAsync = ref.watch(featureFlagsProvider);

    return flagsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (flags) => Column(
        children: [
          _RiskLegend(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: flags.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) =>
                  _FlagCard(flag: flags[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _RiskLegend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppTheme.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'High-risk flags can break the app for all users. '
              'A confirmation dialog will appear before toggling them.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.warning),
            ),
          ),
          const SizedBox(width: 16),
          _RiskBadge(FlagRiskLevel.low),
          const SizedBox(width: 6),
          _RiskBadge(FlagRiskLevel.medium),
          const SizedBox(width: 6),
          _RiskBadge(FlagRiskLevel.high),
        ],
      ),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  final FlagRiskLevel level;
  const _RiskBadge(this.level);

  @override
  Widget build(BuildContext context) {
    final (label, color) = _labelColor(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10, color: color, fontWeight: FontWeight.bold)),
    );
  }

  static (String, Color) _labelColor(FlagRiskLevel l) {
    switch (l) {
      case FlagRiskLevel.low:
        return ('Low Risk', AppTheme.success);
      case FlagRiskLevel.medium:
        return ('Medium Risk', AppTheme.warning);
      case FlagRiskLevel.high:
        return ('High Risk', AppTheme.error);
    }
  }
}

class _FlagCard extends ConsumerStatefulWidget {
  final FeatureFlagModel flag;
  const _FlagCard({required this.flag});

  @override
  ConsumerState<_FlagCard> createState() => _FlagCardState();
}

class _FlagCardState extends ConsumerState<_FlagCard> {
  bool _saving = false;

  (String, Color) get _riskInfo {
    switch (widget.flag.riskLevel) {
      case FlagRiskLevel.low:
        return ('Low Risk', AppTheme.success);
      case FlagRiskLevel.medium:
        return ('Medium Risk', AppTheme.warning);
      case FlagRiskLevel.high:
        return ('High Risk', AppTheme.error);
    }
  }

  Future<void> _toggle(bool newValue) async {
    if (widget.flag.riskLevel == FlagRiskLevel.high) {
      final confirmed = await _showConfirmDialog(newValue);
      if (!confirmed) return;
    }

    setState(() => _saving = true);
    try {
      final email =
          FirebaseAuth.instance.currentUser?.email ?? 'superadmin';
      await FeatureFlagService.setFlag(
        key: widget.flag.key,
        enabled: newValue,
        updatedByEmail: email,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to update flag: $e'),
              backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _showConfirmDialog(bool enabling) async {
    final action = enabling ? 'ENABLE' : 'DISABLE';
    final consequence = enabling
        ? 'This will enable "${widget.flag.label}" for ALL users immediately.'
        : 'This will DISABLE "${widget.flag.label}" for ALL users immediately. '
            'This may break functionality.';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppTheme.error, size: 22),
            const SizedBox(width: 8),
            Text('$action High-Risk Flag'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(consequence),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppTheme.error.withValues(alpha: 0.3)),
              ),
              child: Text(
                'Flag: ${widget.flag.key}\n'
                'Risk: High\n'
                'Action: $action',
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final flag = widget.flag;
    final (riskLabel, riskColor) = _riskInfo;
    final fmt = DateFormat('MMM d, yyyy HH:mm');

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: flag.enabled
              ? AppTheme.borderLight
              : AppTheme.borderMedium,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(flag.label,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                  fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: riskColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: riskColor.withValues(alpha: 0.3)),
                        ),
                        child: Text(riskLabel,
                            style: TextStyle(
                                fontSize: 10,
                                color: riskColor,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(flag.description,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                              color: AppTheme.textSecondary)),
                  if (flag.updatedAt != null || flag.updatedBy != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          if (flag.updatedBy != null)
                            'Last changed by ${flag.updatedBy}',
                          if (flag.updatedAt != null)
                            fmt.format(flag.updatedAt!),
                        ].join(' · '),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color: AppTheme.textTertiary,
                                fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            _saving
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child:
                        CircularProgressIndicator(strokeWidth: 2))
                : Switch(
                    value: flag.enabled,
                    activeThumbColor: AppTheme.success,
                    onChanged: _toggle,
                  ),
          ],
        ),
      ),
    );
  }
}
