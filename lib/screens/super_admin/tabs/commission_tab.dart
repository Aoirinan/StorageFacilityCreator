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
      if (isWon) {
        acc.wonCount++;
        acc.saleTotal += (lead.saleAmount ?? 0).toDouble();
      }
    }

    final rows = byRep.entries
        .map((e) => _CommissionRow(
              rep: e.key,
              totalLeads: e.value.totalLeads,
              wonCount: e.value.wonCount,
              saleTotal: e.value.saleTotal,
            ))
        .toList();
    rows.sort((a, b) => b.saleTotal.compareTo(a.saleTotal));
    return rows;
  }

  String _repForLead(MarketingLead lead) {
    final name = (lead.assignedToName ?? '').trim();
    if (name.isNotEmpty) return name;
    final email = (lead.assignedToEmail ?? '').trim();
    if (email.isNotEmpty) return email;
    return 'Unassigned';
  }

  String _toCsv(List<_CommissionRow> rows) {
    final b = StringBuffer();
    b.writeln('Rep,Leads In Range,Won Count,Sale Total');
    for (final row in rows) {
      b.writeln(
          '"${row.rep.replaceAll('"', '""')}",${row.totalLeads},${row.wonCount},${row.saleTotal.toStringAsFixed(2)}');
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
        final totalWon = rows.fold<int>(0, (s, r) => s + r.wonCount);
        final totalLeads = rows.fold<int>(0, (s, r) => s + r.totalLeads);
        final totalSales = rows.fold<double>(0, (s, r) => s + r.saleTotal);

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
                  FilledButton.icon(
                    onPressed: () => _exportCsv(rows),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Export CSV'),
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
                  _summaryCard('Sales',
                      currencyFmt.format(totalSales), emphasized: true),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? const Center(
                      child: Text('No commission activity in selected range.'),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final row = rows[i];
                        return Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).cardColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.borderLight),
                          ),
                          child: ListTile(
                            title: Text(
                              row.rep,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                                'Leads: ${row.totalLeads} • Won: ${row.wonCount}'),
                            trailing: Text(
                              currencyFmt.format(row.saleTotal),
                              style: const TextStyle(
                                  color: AppTheme.success,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                        );
                      },
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
  double saleTotal = 0;
}

class _CommissionRow {
  final String rep;
  final int totalLeads;
  final int wonCount;
  final double saleTotal;

  const _CommissionRow({
    required this.rep,
    required this.totalLeads,
    required this.wonCount,
    required this.saleTotal,
  });
}
