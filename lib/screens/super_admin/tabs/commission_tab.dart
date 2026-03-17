import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/screens/super_admin/tabs/commission_csv_export_stub.dart'
    if (dart.library.html)
      'package:sfcapp/screens/super_admin/tabs/commission_csv_export_web.dart'
    as csv_export;

class CommissionTab extends ConsumerStatefulWidget {
  const CommissionTab({super.key});

  @override
  ConsumerState<CommissionTab> createState() => _CommissionTabState();
}

class _CommissionTabState extends ConsumerState<CommissionTab> {
  late DateTime _startDate;
  late DateTime _endDate;
  bool _commissionableOnly = true;
  double _minimumSaleAmount = 0;
  double _commissionRate = 10;
  _CommissionRateType _rateType = _CommissionRateType.percentOfSale;
  bool _savingSnapshot = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _endDate = DateTime(now.year, now.month, now.day, 23, 59, 59);
    _startDate = _endDate.subtract(const Duration(days: 29));
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        _startDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        _endDate = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
      });
    }
  }

  void _setQuickRange(int days) {
    final now = DateTime.now();
    setState(() {
      _endDate = DateTime(now.year, now.month, now.day, 23, 59, 59);
      _startDate = _endDate.subtract(Duration(days: days - 1));
    });
  }

  void _setThisMonth() {
    final now = DateTime.now();
    setState(() {
      _startDate = DateTime(now.year, now.month, 1);
      _endDate = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    });
  }

  void _setLastMonth() {
    final now = DateTime.now();
    final startOfThisMonth = DateTime(now.year, now.month, 1);
    final endOfLastMonth = startOfThisMonth.subtract(const Duration(days: 1));
    setState(() {
      _startDate = DateTime(endOfLastMonth.year, endOfLastMonth.month, 1);
      _endDate =
          DateTime(endOfLastMonth.year, endOfLastMonth.month + 1, 0, 23, 59, 59);
    });
  }

  List<_CommissionRow> _buildRows(List<MarketingLead> leads) {
    final inRange = leads.where((lead) {
      final created = lead.createdAt;
      if (created == null) return false;
      return !created.isBefore(_startDate) && !created.isAfter(_endDate);
    });

    final byRep = <String, _CommissionAccumulator>{};
    for (final lead in inRange) {
      final rep = _repForLead(lead);
      final acc = byRep.putIfAbsent(rep, () => _CommissionAccumulator());
      acc.totalLeads++;
      final isWon = lead.status == MarketingLeadStatus.won ||
          lead.saleStatus.toLowerCase() == 'won';
      final saleAmount = (lead.saleAmount ?? 0).toDouble();
      final hasRep = rep != 'Unassigned';
      final commissionable = isWon && hasRep && saleAmount >= _minimumSaleAmount;
      if (isWon) {
        acc.wonCount++;
        acc.saleTotal += saleAmount;
      }
      if (commissionable) {
        acc.commissionableWonCount++;
        acc.commissionableSaleTotal += saleAmount;
      }

      final firstContactedAt = lead.firstContactedAt;
      if (lead.createdAt != null && firstContactedAt != null) {
        final hours = firstContactedAt.difference(lead.createdAt!).inMinutes / 60.0;
        if (hours >= 0) {
          acc.firstContactHoursTotal += hours;
          acc.firstContactSamples++;
        }
      }
      final closedAt = lead.closedAt;
      if (lead.createdAt != null && closedAt != null) {
        final days = closedAt.difference(lead.createdAt!).inMinutes / 1440.0;
        if (days >= 0) {
          acc.closeDaysTotal += days;
          acc.closeSamples++;
        }
      }
    }

    final rows = byRep.entries
        .map((e) {
          final salesBasis =
              _commissionableOnly ? e.value.commissionableSaleTotal : e.value.saleTotal;
          final winsBasis =
              _commissionableOnly ? e.value.commissionableWonCount : e.value.wonCount;
          return _CommissionRow(
            rep: e.key,
            totalLeads: e.value.totalLeads,
            wonCount: e.value.wonCount,
            commissionableWonCount: e.value.commissionableWonCount,
            saleTotal: e.value.saleTotal,
            commissionableSaleTotal: e.value.commissionableSaleTotal,
            avgFirstContactHours: e.value.firstContactSamples == 0
                ? null
                : e.value.firstContactHoursTotal / e.value.firstContactSamples,
            avgCloseDays: e.value.closeSamples == 0
                ? null
                : e.value.closeDaysTotal / e.value.closeSamples,
            commissionAmount: _rateType == _CommissionRateType.percentOfSale
                ? salesBasis * (_commissionRate / 100)
                : winsBasis * _commissionRate,
          );
        })
        .toList();
    rows.sort((a, b) => b.commissionAmount.compareTo(a.commissionAmount));
    return rows;
  }

  String _repForLead(MarketingLead lead) {
    final workedBy = (lead.workedByName ?? '').trim();
    if (workedBy.isNotEmpty) return workedBy;
    final name = (lead.assignedToName ?? '').trim();
    if (name.isNotEmpty) return name;
    final email = (lead.assignedToEmail ?? '').trim();
    if (email.isNotEmpty) return email;
    return 'Unassigned';
  }

  _CommissionFunnelMetrics _buildFunnelMetrics(List<MarketingLead> leads) {
    final inRange = leads.where((lead) {
      final created = lead.createdAt;
      if (created == null) return false;
      return !created.isBefore(_startDate) && !created.isAfter(_endDate);
    }).toList();
    final total = inRange.length;
    final contacted = inRange
        .where((l) => l.status != MarketingLeadStatus.newLead || l.firstContactedAt != null)
        .length;
    final won = inRange.where((l) => l.status == MarketingLeadStatus.won).length;
    final lost = inRange.where((l) => l.status == MarketingLeadStatus.lost).length;

    double? avgFirstContactHours;
    final firstSamples = inRange
        .where((l) => l.createdAt != null && l.firstContactedAt != null)
        .map((l) => l.firstContactedAt!.difference(l.createdAt!).inMinutes / 60.0)
        .where((h) => h >= 0)
        .toList();
    if (firstSamples.isNotEmpty) {
      avgFirstContactHours = firstSamples.reduce((a, b) => a + b) / firstSamples.length;
    }

    double? avgCloseDays;
    final closeSamples = inRange
        .where((l) => l.createdAt != null && l.closedAt != null)
        .map((l) => l.closedAt!.difference(l.createdAt!).inMinutes / 1440.0)
        .where((d) => d >= 0)
        .toList();
    if (closeSamples.isNotEmpty) {
      avgCloseDays = closeSamples.reduce((a, b) => a + b) / closeSamples.length;
    }

    return _CommissionFunnelMetrics(
      totalLeads: total,
      contactedLeads: contacted,
      wonLeads: won,
      lostLeads: lost,
      avgFirstContactHours: avgFirstContactHours,
      avgCloseDays: avgCloseDays,
    );
  }

  String _csvCell(String value) => '"${value.replaceAll('"', '""')}"';

  String get _rateTypeValue => _rateType == _CommissionRateType.percentOfSale
      ? 'percent_of_sales'
      : 'fixed_per_won';

  List<_SourceConversionRow> _buildSourceRows(List<MarketingLead> leads) {
    final inRange = leads.where((lead) {
      final created = lead.createdAt;
      if (created == null) return false;
      return !created.isBefore(_startDate) && !created.isAfter(_endDate);
    });
    final bySource = <String, _SourceAccumulator>{};
    for (final lead in inRange) {
      final source = (lead.utmSource ?? lead.source).trim().isEmpty
          ? 'unknown'
          : (lead.utmSource ?? lead.source).trim().toLowerCase();
      final acc = bySource.putIfAbsent(source, () => _SourceAccumulator());
      acc.total++;
      if (lead.status != MarketingLeadStatus.newLead || lead.firstContactedAt != null) {
        acc.contacted++;
      }
      if (lead.status == MarketingLeadStatus.won ||
          lead.saleStatus.toLowerCase() == 'won') {
        acc.won++;
      }
    }
    final rows = bySource.entries
        .map((e) => _SourceConversionRow(
              source: e.key,
              leads: e.value.total,
              contacted: e.value.contacted,
              won: e.value.won,
            ))
        .toList();
    rows.sort((a, b) => b.leads.compareTo(a.leads));
    return rows;
  }

  String _toCsv(List<_CommissionRow> rows) {
    final b = StringBuffer();
    b.writeln(
        'Period Start,Period End,Rep,Leads In Range,Won Count,Commissionable Won Count,Sale Total,Commissionable Sales,Rate Type,Rate Value,Commission Amount');
    final periodStart = DateFormat('yyyy-MM-dd').format(_startDate);
    final periodEnd = DateFormat('yyyy-MM-dd').format(_endDate);
    final rateLabel = _rateType == _CommissionRateType.percentOfSale
        ? 'percent_of_sales'
        : 'fixed_per_won';
    for (final row in rows) {
      b.writeln(
          '${_csvCell(periodStart)},${_csvCell(periodEnd)},${_csvCell(row.rep)},${row.totalLeads},${row.wonCount},${row.commissionableWonCount},${row.saleTotal.toStringAsFixed(2)},${row.commissionableSaleTotal.toStringAsFixed(2)},${_csvCell(rateLabel)},${_commissionRate.toStringAsFixed(2)},${row.commissionAmount.toStringAsFixed(2)}');
    }
    return b.toString();
  }

  Future<void> _exportCsv(List<_CommissionRow> rows) async {
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No commission rows to export.')),
      );
      return;
    }
    final csv = _toCsv(rows);
    final filename =
        'commission_${DateFormat('yyyyMMdd').format(_startDate)}_${DateFormat('yyyyMMdd').format(_endDate)}.csv';
    if (kIsWeb) {
      csv_export.downloadCsv(csv, filename);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported $filename')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('CSV copied to clipboard (download supported on web).')),
    );
  }

  Future<void> _savePayoutSnapshot(List<_CommissionRow> rows) async {
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No commission rows to snapshot.')),
      );
      return;
    }
    final actor = FirebaseAuth.instance.currentUser;
    if (actor == null) return;
    setState(() => _savingSnapshot = true);
    try {
      final repRows = rows
          .map((row) => {
                'rep': row.rep,
                'totalLeads': row.totalLeads,
                'wonCount': row.wonCount,
                'commissionableWonCount': row.commissionableWonCount,
                'saleTotal': row.saleTotal,
                'commissionableSaleTotal': row.commissionableSaleTotal,
                'commissionAmount': row.commissionAmount,
              })
          .toList();
      final totalSales = rows.fold<double>(0, (sum, row) => sum + row.saleTotal);
      final totalCommission =
          rows.fold<double>(0, (sum, row) => sum + row.commissionAmount);
      final totalWon = rows.fold<int>(0, (sum, row) => sum + row.wonCount);
      await SuperAdminDataService.createCommissionPayoutPeriod(
        periodStart: _startDate,
        periodEnd: _endDate,
        commissionableOnly: _commissionableOnly,
        minimumSaleAmount: _minimumSaleAmount,
        rateType: _rateTypeValue,
        rateValue: _commissionRate,
        createdByUid: actor.uid,
        createdByEmail: actor.email ?? 'unknown',
        repRows: repRows,
        totalSales: totalSales,
        totalCommission: totalCommission,
        totalWon: totalWon,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payout snapshot saved.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save snapshot: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingSnapshot = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final leadsAsync = ref.watch(marketingLeadsProvider);
    final dateFmt = DateFormat('MMM d, yyyy');
    final currencyFmt = NumberFormat.currency(symbol: '\$');

    return leadsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (leads) {
        final rows = _buildRows(leads);
        final sourceRows = _buildSourceRows(leads);
        final funnel = _buildFunnelMetrics(leads);
        final totalWon = rows.fold<int>(0, (s, r) => s + r.wonCount);
        final totalLeads = rows.fold<int>(0, (s, r) => s + r.totalLeads);
        final totalSales = rows.fold<double>(0, (s, r) => s + r.saleTotal);
        final totalCommissionableWon =
            rows.fold<int>(0, (s, r) => s + r.commissionableWonCount);
        final totalCommission =
            rows.fold<double>(0, (s, r) => s + r.commissionAmount);

        return Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickStartDate,
                    icon: const Icon(Icons.date_range, size: 16),
                    label: Text('Start: ${dateFmt.format(_startDate)}'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickEndDate,
                    icon: const Icon(Icons.date_range, size: 16),
                    label: Text('End: ${dateFmt.format(_endDate)}'),
                  ),
                  TextButton(
                    onPressed: () => _setQuickRange(7),
                    child: const Text('Last 7 days'),
                  ),
                  TextButton(
                    onPressed: () => _setQuickRange(30),
                    child: const Text('Last 30 days'),
                  ),
                  TextButton(
                    onPressed: () => _setQuickRange(90),
                    child: const Text('Last 90 days'),
                  ),
                  TextButton(
                    onPressed: _setThisMonth,
                    child: const Text('This month'),
                  ),
                  TextButton(
                    onPressed: _setLastMonth,
                    child: const Text('Last month'),
                  ),
                  FilterChip(
                    label: const Text('Commissionable only'),
                    selected: _commissionableOnly,
                    onSelected: (v) => setState(() => _commissionableOnly = v),
                  ),
                  SizedBox(
                    width: 170,
                    child: TextFormField(
                      initialValue: _minimumSaleAmount == 0
                          ? ''
                          : _minimumSaleAmount.toStringAsFixed(0),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Min sale amount',
                        prefixText: '\$',
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() {
                        _minimumSaleAmount = double.tryParse(v.trim()) ?? 0;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: 170,
                    child: DropdownButtonFormField<_CommissionRateType>(
                      initialValue: _rateType,
                      decoration: const InputDecoration(
                        labelText: 'Commission model',
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: _CommissionRateType.percentOfSale,
                          child: Text('% of sales'),
                        ),
                        DropdownMenuItem(
                          value: _CommissionRateType.fixedPerWon,
                          child: Text('Fixed per won'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _rateType = v);
                        }
                      },
                    ),
                  ),
                  SizedBox(
                    width: 170,
                    child: TextFormField(
                      initialValue: _commissionRate.toStringAsFixed(0),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Rate value',
                        prefixText: _rateType == _CommissionRateType.percentOfSale
                            ? ''
                            : '\$',
                        suffixText: _rateType == _CommissionRateType.percentOfSale
                            ? '%'
                            : null,
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() {
                        _commissionRate = double.tryParse(v.trim()) ?? 0;
                      }),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => _exportCsv(rows),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Export CSV'),
                  ),
                  FilledButton.icon(
                    onPressed: _savingSnapshot ? null : () => _savePayoutSnapshot(rows),
                    icon: _savingSnapshot
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_clock, size: 16),
                    label: const Text('Lock Payout Period'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _summaryCard('Reps', '${rows.length}'),
                  const SizedBox(width: 8),
                  _summaryCard('Leads', '$totalLeads'),
                  const SizedBox(width: 8),
                  _summaryCard('Won', '$totalWon'),
                  const SizedBox(width: 8),
                  _summaryCard('Comm. Won', '$totalCommissionableWon'),
                  const SizedBox(width: 8),
                  _summaryCard('Sales', currencyFmt.format(totalSales)),
                  const SizedBox(width: 8),
                  _summaryCard(
                    'Commission',
                    currencyFmt.format(totalCommission),
                    emphasized: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _summaryCard('Contact Rate',
                      '${(funnel.contactRate * 100).toStringAsFixed(1)}%'),
                  const SizedBox(width: 8),
                  _summaryCard(
                      'Close Rate', '${(funnel.closeRate * 100).toStringAsFixed(1)}%'),
                  const SizedBox(width: 8),
                  _summaryCard('Avg First Call',
                      funnel.avgFirstContactHoursLabel),
                  const SizedBox(width: 8),
                  _summaryCard('Avg Time To Close', funnel.avgCloseDaysLabel),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (sourceRows.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.borderLight),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Conversion by source',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      ...sourceRows.take(6).map((row) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '${row.source}: ${row.leads} leads • '
                              'contact ${(row.contactRate * 100).toStringAsFixed(1)}% • '
                              'won ${(row.wonRate * 100).toStringAsFixed(1)}%',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: AppTheme.textSecondary),
                            ),
                          )),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (rows.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: Text('No commission activity in selected range.'),
                      ),
                    )
                  else
                    ...rows.map((row) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).cardColor,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.borderLight),
                            ),
                            child: ListTile(
                              title: Text(
                                row.rep,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                  'Leads: ${row.totalLeads} • Won: ${row.wonCount} • Comm. Won: ${row.commissionableWonCount}'
                                  '${row.avgFirstContactHours == null ? '' : ' • Avg first call: ${row.avgFirstContactHours!.toStringAsFixed(1)}h'}'
                                  '${row.avgCloseDays == null ? '' : ' • Avg close: ${row.avgCloseDays!.toStringAsFixed(1)}d'}'),
                              trailing: Text(
                                currencyFmt.format(row.commissionAmount),
                                style: const TextStyle(
                                    color: AppTheme.success,
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        )),
                  const SizedBox(height: 8),
                  Text(
                    'Locked payout periods',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  _PayoutPeriodsSection(currencyFmt: currencyFmt),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _summaryCard(String label, String value, {bool emphasized = false}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: emphasized ? AppTheme.success : AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommissionAccumulator {
  int totalLeads = 0;
  int wonCount = 0;
  int commissionableWonCount = 0;
  double saleTotal = 0;
  double commissionableSaleTotal = 0;
  double firstContactHoursTotal = 0;
  int firstContactSamples = 0;
  double closeDaysTotal = 0;
  int closeSamples = 0;
}

class _SourceAccumulator {
  int total = 0;
  int contacted = 0;
  int won = 0;
}

class _SourceConversionRow {
  final String source;
  final int leads;
  final int contacted;
  final int won;

  const _SourceConversionRow({
    required this.source,
    required this.leads,
    required this.contacted,
    required this.won,
  });

  double get contactRate => leads == 0 ? 0 : contacted / leads;
  double get wonRate => leads == 0 ? 0 : won / leads;
}

class _CommissionRow {
  final String rep;
  final int totalLeads;
  final int wonCount;
  final int commissionableWonCount;
  final double saleTotal;
  final double commissionableSaleTotal;
  final double commissionAmount;
  final double? avgFirstContactHours;
  final double? avgCloseDays;

  const _CommissionRow({
    required this.rep,
    required this.totalLeads,
    required this.wonCount,
    required this.commissionableWonCount,
    required this.saleTotal,
    required this.commissionableSaleTotal,
    required this.commissionAmount,
    required this.avgFirstContactHours,
    required this.avgCloseDays,
  });
}

enum _CommissionRateType { percentOfSale, fixedPerWon }

class _CommissionFunnelMetrics {
  final int totalLeads;
  final int contactedLeads;
  final int wonLeads;
  final int lostLeads;
  final double? avgFirstContactHours;
  final double? avgCloseDays;

  const _CommissionFunnelMetrics({
    required this.totalLeads,
    required this.contactedLeads,
    required this.wonLeads,
    required this.lostLeads,
    required this.avgFirstContactHours,
    required this.avgCloseDays,
  });

  double get contactRate => totalLeads == 0 ? 0 : contactedLeads / totalLeads;
  double get closeRate => totalLeads == 0 ? 0 : (wonLeads + lostLeads) / totalLeads;
  String get avgFirstContactHoursLabel =>
      avgFirstContactHours == null ? '—' : '${avgFirstContactHours!.toStringAsFixed(1)}h';
  String get avgCloseDaysLabel =>
      avgCloseDays == null ? '—' : '${avgCloseDays!.toStringAsFixed(1)}d';
}

class _PayoutPeriodsSection extends ConsumerWidget {
  const _PayoutPeriodsSection({required this.currencyFmt});

  final NumberFormat currencyFmt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periodsAsync = ref.watch(commissionPayoutPeriodsProvider);
    return periodsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (e, _) => Text('Error loading payout periods: $e'),
      data: (periods) {
        if (periods.isEmpty) {
          return const Text(
            'No locked payout periods yet. Use "Lock Payout Period" to create one.',
            style: TextStyle(color: AppTheme.textSecondary),
          );
        }
        return Column(
          children: periods.take(8).map((period) {
            final dateFmt = DateFormat('MMM d, yyyy');
            final statusColor =
                period.status == 'closed' ? AppTheme.error : AppTheme.success;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderLight),
              ),
              child: ExpansionTile(
                title: Text(
                  '${dateFmt.format(period.periodStart)} - ${dateFmt.format(period.periodEnd)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Won: ${period.totalWon} • Sales: ${currencyFmt.format(period.totalSales)} • '
                  'Commission: ${currencyFmt.format(period.totalCommission)}',
                ),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    period.status.toUpperCase(),
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            if (period.status == 'closed') {
                              await SuperAdminDataService.reopenCommissionPayoutPeriod(
                                  period.id);
                            } else {
                              await SuperAdminDataService.closeCommissionPayoutPeriod(
                                  period.id);
                            }
                          },
                          icon: Icon(period.status == 'closed'
                              ? Icons.lock_open
                              : Icons.lock),
                          label: Text(period.status == 'closed'
                              ? 'Reopen period'
                              : 'Close period'),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Created by ${period.createdByEmail}',
                            style: const TextStyle(color: AppTheme.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _PayoutPeriodRepRows(
                    periodId: period.id,
                    isClosed: period.status == 'closed',
                    currencyFmt: currencyFmt,
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _PayoutPeriodRepRows extends ConsumerWidget {
  const _PayoutPeriodRepRows({
    required this.periodId,
    required this.isClosed,
    required this.currencyFmt,
  });

  final String periodId;
  final bool isClosed;
  final NumberFormat currencyFmt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repsAsync = SuperAdminDataService.commissionPayoutPeriodReps(periodId);
    final actorEmail = FirebaseAuth.instance.currentUser?.email ?? 'unknown';
    return StreamBuilder<List<CommissionPayoutRepRow>>(
      stream: repsAsync,
      builder: (context, snapshot) {
        final reps = snapshot.data ?? const <CommissionPayoutRepRow>[];
        if (reps.isEmpty) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text('No rep payout rows found.'),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            children: reps.map((rep) {
              return CheckboxListTile(
                dense: true,
                value: rep.paid,
                onChanged: isClosed
                    ? null
                    : (value) async {
                        await SuperAdminDataService.setCommissionRepPaid(
                          periodId: periodId,
                          repDocId: rep.id,
                          paid: value == true,
                          actorEmail: actorEmail,
                        );
                      },
                title: Text(rep.rep),
                subtitle: Text(
                  'Won: ${rep.wonCount} • Comm. Won: ${rep.commissionableWonCount} • '
                  'Commission: ${currencyFmt.format(rep.commissionAmount)}',
                ),
                secondary: rep.paid
                    ? const Icon(Icons.check_circle, color: AppTheme.success, size: 18)
                    : const Icon(Icons.pending, color: AppTheme.warning, size: 18),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}
