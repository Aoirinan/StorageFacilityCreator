import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../models/cancellation_retention_model.dart';
import '../../../services/cancellation_retention_service.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/error_message_helper.dart';

class RetentionTab extends StatefulWidget {
  const RetentionTab({super.key});

  @override
  State<RetentionTab> createState() => _RetentionTabState();
}

class _RetentionTabState extends State<RetentionTab> {
  bool _loading = true;
  String? _error;
  CancellationRetentionConfig? _config;
  List<CancellationEventRow> _events = const [];
  String _planFilter = 'all';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await CancellationRetentionService.getConfig();
      final events = await CancellationRetentionService.listEvents(
        planType: _planFilter,
        limit: 300,
      );
      if (!mounted) return;
      setState(() {
        _config = config;
        _events = events;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorMessageHelper.getUserFriendlyMessage(e);
      });
    }
  }

  Future<void> _saveConfig() async {
    final config = _config;
    if (config == null) return;
    setState(() => _saving = true);
    try {
      final saved = await CancellationRetentionService.upsertConfig(config);
      if (!mounted) return;
      setState(() {
        _config = saved;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Retention config saved (Stripe coupons synced).'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Map<String, int> _countsBy(String Function(CancellationEventRow e) keyOf) {
    final map = <String, int>{};
    for (final e in _events) {
      final key = keyOf(e);
      if (key.isEmpty) continue;
      map[key] = (map[key] ?? 0) + 1;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _config == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: AppTheme.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      );
    }

    final config = _config!;
    final finished = _events
        .where((e) => e.outcome == 'cancelled' || e.outcome == 'retained')
        .toList();
    final cancelled =
        finished.where((e) => e.outcome == 'cancelled').length;
    final retained = finished.where((e) => e.outcome == 'retained').length;
    final finishedCount = finished.length;
    final cancelPct =
        finishedCount == 0 ? 0.0 : (cancelled / finishedCount) * 100;
    final retainPct =
        finishedCount == 0 ? 0.0 : (retained / finishedCount) * 100;
    final reasonCounts = _countsBy((e) => e.primaryReason ?? '');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text(
              'Cancellation retention',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            DropdownButton<String>(
              value: _planFilter,
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All plans')),
                DropdownMenuItem(value: 'platform', child: Text('\$75 platform')),
                DropdownMenuItem(value: 'website', child: Text('\$25 website')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _planFilter = v);
                _refresh();
              },
            ),
            const SizedBox(width: 8),
            IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _saving ? null : _saveConfig,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving…' : 'Save config'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _statCard('Finished flows', '$finishedCount'),
            _statCard('Cancelled',
                '${cancelPct.toStringAsFixed(0)}% ($cancelled)'),
            _statCard(
                'Retained (accepted offer)',
                '${retainPct.toStringAsFixed(0)}% ($retained)'),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Primary reason breakdown',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (reasonCounts.isEmpty)
                  const Text('No survey answers yet.')
                else
                  ...reasonCounts.entries.map((e) {
                    final matches = config.primaryReasons
                        .where((r) => r.id == e.key)
                        .toList();
                    final label =
                        matches.isEmpty ? e.key : matches.first.label;
                    final pct = finishedCount == 0
                        ? 0.0
                        : (e.value / finishedCount) * 100;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(child: Text(label)),
                          Text(
                            '${pct.toStringAsFixed(0)}% (${e.value})',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Stay promotions',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ...List.generate(config.promos.length, (index) {
          final promo = config.promos[index];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: promo.title,
                          decoration: const InputDecoration(
                            labelText: 'Title',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) {
                            final next = [...config.promos];
                            next[index] = promo.copyWith(title: v);
                            setState(() {
                              _config = CancellationRetentionConfig(
                                primaryReasons: config.primaryReasons,
                                detailReasonsByPrimary:
                                    config.detailReasonsByPrimary,
                                promos: next,
                                platformLossCopy: config.platformLossCopy,
                                websiteLossCopy: config.websiteLossCopy,
                              );
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Switch(
                        value: promo.active,
                        onChanged: (v) {
                          final next = [...config.promos];
                          next[index] = promo.copyWith(active: v);
                          setState(() {
                            _config = CancellationRetentionConfig(
                              primaryReasons: config.primaryReasons,
                              detailReasonsByPrimary:
                                  config.detailReasonsByPrimary,
                              promos: next,
                              platformLossCopy: config.platformLossCopy,
                              websiteLossCopy: config.websiteLossCopy,
                            );
                          });
                        },
                      ),
                      const Text('Active'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: promo.body,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Body',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final next = [...config.promos];
                      next[index] = promo.copyWith(body: v);
                      setState(() {
                        _config = CancellationRetentionConfig(
                          primaryReasons: config.primaryReasons,
                          detailReasonsByPrimary:
                              config.detailReasonsByPrimary,
                          promos: next,
                          platformLossCopy: config.platformLossCopy,
                          websiteLossCopy: config.websiteLossCopy,
                        );
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: '${promo.percentOff ?? ''}',
                          decoration: const InputDecoration(
                            labelText: '% off',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: (v) {
                            final next = [...config.promos];
                            next[index] = promo.copyWith(
                              percentOff: int.tryParse(v.trim()),
                            );
                            setState(() {
                              _config = CancellationRetentionConfig(
                                primaryReasons: config.primaryReasons,
                                detailReasonsByPrimary:
                                    config.detailReasonsByPrimary,
                                promos: next,
                                platformLossCopy: config.platformLossCopy,
                                websiteLossCopy: config.websiteLossCopy,
                              );
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          initialValue: '${promo.durationMonths}',
                          decoration: const InputDecoration(
                            labelText: 'Months',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: (v) {
                            final next = [...config.promos];
                            next[index] = promo.copyWith(
                              durationMonths: int.tryParse(v.trim()) ?? 1,
                            );
                            setState(() {
                              _config = CancellationRetentionConfig(
                                primaryReasons: config.primaryReasons,
                                detailReasonsByPrimary:
                                    config.detailReasonsByPrimary,
                                promos: next,
                                platformLossCopy: config.platformLossCopy,
                                websiteLossCopy: config.websiteLossCopy,
                              );
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Plans: ${promo.planTypes.join(', ')}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            final next = [
              ...config.promos,
              CancellationPromo(
                id: 'promo_${DateTime.now().millisecondsSinceEpoch}',
                planTypes: const ['platform'],
                title: 'New stay offer',
                body: 'Describe the discount for customers who stay.',
                percentOff: 15,
                durationMonths: 2,
                active: false,
                sortOrder: config.promos.length + 1,
              ),
            ];
            setState(() {
              _config = CancellationRetentionConfig(
                primaryReasons: config.primaryReasons,
                detailReasonsByPrimary: config.detailReasonsByPrimary,
                promos: next,
                platformLossCopy: config.platformLossCopy,
                websiteLossCopy: config.websiteLossCopy,
              );
            });
          },
          icon: const Icon(Icons.add),
          label: const Text('Add promotion'),
        ),
        const SizedBox(height: 20),
        const Text('Primary reasons (dropdown labels)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ...List.generate(config.primaryReasons.length, (index) {
          final reason = config.primaryReasons[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextFormField(
              initialValue: reason.label,
              decoration: InputDecoration(
                labelText: 'Reason ${reason.id}',
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) {
                final next = [...config.primaryReasons];
                next[index] = CancellationReasonOption(id: reason.id, label: v);
                setState(() {
                  _config = CancellationRetentionConfig(
                    primaryReasons: next,
                    detailReasonsByPrimary: config.detailReasonsByPrimary,
                    promos: config.promos,
                    platformLossCopy: config.platformLossCopy,
                    websiteLossCopy: config.websiteLossCopy,
                  );
                });
              },
            ),
          );
        }),
        const SizedBox(height: 16),
        const Text('Recent cancellation events',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('When')),
                DataColumn(label: Text('Plan')),
                DataColumn(label: Text('Facility')),
                DataColumn(label: Text('Primary')),
                DataColumn(label: Text('Detail')),
                DataColumn(label: Text('Outcome')),
              ],
              rows: _events.take(100).map((e) {
                final when = e.createdAt == null
                    ? '—'
                    : DateFormat('MMM d, yyyy h:mm a').format(e.createdAt!);
                final primaryMatches = config.primaryReasons
                    .where((r) => r.id == e.primaryReason)
                    .toList();
                final primaryLabel = primaryMatches.isEmpty
                    ? (e.primaryReason ?? '—')
                    : primaryMatches.first.label;
                return DataRow(cells: [
                  DataCell(Text(when)),
                  DataCell(Text(e.planType ?? '—')),
                  DataCell(Text(e.facilityId ?? '—')),
                  DataCell(Text(primaryLabel)),
                  DataCell(Text(e.detailReason ?? '—')),
                  DataCell(Text(e.outcome ?? '—')),
                ]);
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _statCard(String label, String value) {
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              Text(value,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}
