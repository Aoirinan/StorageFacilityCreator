import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/bulk_statement_service.dart';
import 'package:sfcapp/services/statement_service.dart'
    show statementUnitLabels;
import 'package:sfcapp/utils/bulk_statements.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

const _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

/// The first ten of [names], then "and N more".
String _firstTen(List<String> names) =>
    names.take(10).join(', ') +
    (names.length > 10 ? ', and ${names.length - 10} more' : '');

String _nameOf(TenantModel t) => t.name.trim().isEmpty ? t.id : t.name.trim();

/// `<Facility> statements <Mon YYYY>.pdf`: the period's month, or the month
/// printed in for all history. Characters a file name cannot carry become
/// spaces.
String bulkStatementsFileName(
  String facilityName,
  StatementPeriod period,
  DateTime today,
) {
  final month = period.startDate ?? today;
  final name = facilityName
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return '${name.isEmpty ? 'Tenant' : name} statements '
      '${_shortMonths[month.month - 1]} ${month.year}.pdf';
}

/// Tenants List > Select Multiple > Print statements (N).
///
/// For an owner whose tenants mostly have no email, so monthly statements
/// are printed and mailed: one PDF with every selected tenant's statement,
/// instead of opening each tenant's ledger and printing from there. Reads
/// the selected tenants' ledgers with [reader], lets the owner pick the
/// period and what to skip, builds the PDF with progress and Cancel, then
/// prints or downloads it. Nothing is written.
///
/// [tenants] are the selected tenants in the list's order, which is the
/// order the statements print in. [units] are the facility's units, so a
/// record holding two units names both; [today] is the statement date.
Future<void> showBulkStatementsDialog(
  BuildContext context, {
  required List<TenantModel> tenants,
  required FacilityModel facility,
  required StatementLedgerReader reader,
  List<UnitModel> units = const [],
  DateTime? today,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _BulkStatementsDialog(
      tenants: tenants,
      facility: facility,
      reader: reader,
      units: units,
      today: today ?? DateTime.now(),
    ),
  );
}

enum _Step { loading, options, building, ready, failed }

class _BulkStatementsDialog extends StatefulWidget {
  final List<TenantModel> tenants;
  final FacilityModel facility;
  final StatementLedgerReader reader;
  final List<UnitModel> units;
  final DateTime today;

  const _BulkStatementsDialog({
    required this.tenants,
    required this.facility,
    required this.reader,
    required this.units,
    required this.today,
  });

  @override
  State<_BulkStatementsDialog> createState() => _BulkStatementsDialogState();
}

class _BulkStatementsDialogState extends State<_BulkStatementsDialog> {
  _Step step = _Step.loading;
  Map<String, List<LedgerEntry>> entries = const {};
  String? failure;

  bool thisMonth = true;
  late int year = widget.today.year;
  late int month = widget.today.month;
  bool combine = false;
  bool skipNothingOwed = false;
  // On before the first rent job has posted, when most ledgers are empty
  // and a statement would be a blank page at $0.00.
  bool skipNoActivity = true;
  bool duplex = false;

  int done = 0;
  int total = 0;
  bool cancelled = false;
  BulkStatementsPdf? pdf;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final read = await widget.reader
          .read(widget.facility.id, [for (final t in widget.tenants) t.id]);
      if (!mounted) return;
      setState(() {
        entries = read;
        step = _Step.options;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        failure = 'The ledgers could not be read: '
            '${ErrorMessageHelper.getUserFriendlyMessage(e)}';
        step = _Step.failed;
      });
    }
  }

  StatementPeriod get _period => thisMonth
      ? StatementPeriod.month(year, month)
      : const StatementPeriod.allHistory();

  List<String> _unitLabels(TenantModel tenant) => statementUnitLabels(
        tenant,
        widget.facility,
        units: widget.units.where((u) => u.tenantId == tenant.id),
      );

  /// The plan for the options as ticked, or with one skip forced on to
  /// count what ticking it would leave out.
  BulkStatementPlan _plan({bool? skipZero, bool? skipEmpty}) =>
      planBulkStatements(
        widget.tenants,
        entries,
        period: _period,
        combineSamePerson: combine,
        skipNothingOwed: skipZero ?? skipNothingOwed,
        skipNoActivity: skipEmpty ?? skipNoActivity,
        unitLabels: _unitLabels,
      );

  Future<void> _build() async {
    final plan = _plan();
    setState(() {
      step = _Step.building;
      done = 0;
      total = plan.statementCount;
      cancelled = false;
      pdf = null;
    });
    try {
      final result = await BulkStatementService.buildBulkStatementsPdf(
        plan,
        widget.facility,
        printedOn: widget.today,
        period: _period,
        duplex: duplex,
        onProgress: (d, t) {
          if (!mounted) return;
          setState(() {
            done = d;
            total = t;
          });
        },
        // Closing the dialog cancels too, so no build runs on unseen.
        isCancelled: () => cancelled || !mounted,
      );
      if (!mounted) return;
      setState(() {
        pdf = result;
        step = _Step.ready;
      });
    } on BulkStatementsCancelled {
      if (mounted) setState(() => step = _Step.options);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        failure = 'The statements could not be built: '
            '${ErrorMessageHelper.getUserFriendlyMessage(e)}';
        step = _Step.failed;
      });
    }
  }

  String get _fileName =>
      bulkStatementsFileName(widget.facility.name, _period, widget.today);

  /// Printing.layoutPdf runs in the click itself. On the web it opens the
  /// browser's print window, and a window opened after an await is what
  /// popup blockers stop, which is why the PDF is built first and printed
  /// from a button of its own rather than straight after the build.
  Future<void> _print() async {
    final bytes = pdf!.bytes;
    try {
      await Printing.layoutPdf(
        name: _fileName,
        onLayout: (_) async => bytes,
      );
    } catch (e) {
      _say('The print window could not be opened: '
          '${ErrorMessageHelper.getUserFriendlyMessage(e)}');
    }
  }

  /// On the web this downloads the file, for printing later or elsewhere.
  Future<void> _download() async {
    try {
      await Printing.sharePdf(bytes: pdf!.bytes, filename: _fileName);
    } catch (e) {
      _say('The PDF could not be saved: '
          '${ErrorMessageHelper.getUserFriendlyMessage(e)}');
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext ctx) {
    return AlertDialog(
      title: const Text('Print statements'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: switch (step) {
            _Step.loading => _loadingBody(),
            _Step.options => _optionsBody(),
            _Step.building => _buildingBody(),
            _Step.ready => _readyBody(),
            _Step.failed => Text(failure ?? 'Something went wrong.',
                key: const Key('bulk-statements-failed')),
          },
        ),
      ),
      actions: switch (step) {
        _Step.loading => [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        _Step.options => _optionsActions(ctx),
        _Step.building => [
            TextButton(
              key: const Key('bulk-statements-cancel'),
              onPressed: () => setState(() => cancelled = true),
              child: const Text('Cancel'),
            ),
          ],
        _Step.ready => [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            OutlinedButton.icon(
              key: const Key('bulk-statements-download'),
              onPressed: _download,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Download PDF'),
            ),
            FilledButton.icon(
              key: const Key('bulk-statements-print'),
              onPressed: _print,
              icon: const Icon(Icons.print_outlined),
              label: const Text('Print'),
            ),
          ],
        _Step.failed => [
            if (entries.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => step = _Step.options),
                child: const Text('Back'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
      },
    );
  }

  Widget _loadingBody() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            'Reading ${_count(widget.tenants.length, 'ledger', 'ledgers')}...',
            key: const Key('bulk-statements-loading'),
          ),
        ],
      );

  Widget _buildingBody() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: total == 0 ? null : done / total),
          const SizedBox(height: 12),
          Text(
            'Building $done of $total...',
            key: const Key('bulk-statements-progress'),
          ),
        ],
      );

  Widget _readyBody() {
    final result = pdf!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_count(result.statementCount, 'statement', 'statements')}, '
          '${_count(result.pageCount, 'page', 'pages')}',
          key: const Key('bulk-statements-ready'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text('Print opens your browser\'s print window. Download PDF saves '
            '"$_fileName" to print later.'),
      ],
    );
  }

  List<Widget> _optionsActions(BuildContext ctx) {
    final count = _plan().statementCount;
    return [
      TextButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('bulk-statements-build'),
        onPressed: count == 0 ? null : _build,
        child: Text('Build ${_count(count, 'statement', 'statements')}'),
      ),
    ];
  }

  /// The units [group]'s records hold between them, each counted once: a
  /// record can hold more than one.
  int _unitCount(List<TenantModel> group) =>
      {for (final t in group) ..._unitLabels(t)}.length;

  Widget _optionsBody() {
    final plan = _plan();
    final groups = sameCustomerGroups(widget.tenants);
    final people = groups.combinable.length;
    final unitsInGroups =
        groups.combinable.fold(0, (n, g) => n + _unitCount(g));
    // Who Combine would put on one statement, so the owner can check them
    // before building: a shared name and address is a guess, not proof.
    final combinedNames = [
      for (final g in groups.combinable)
        '${_nameOf(g.first)} (${_count(_unitCount(g), 'unit', 'units')})',
    ];
    final nothingOwed = _plan(skipZero: true).skippedNothingOwed.length;
    final noActivity = _plan(skipEmpty: true).skippedNoActivity.length;
    final thisYear = widget.today.year;
    final years = [for (var y = thisYear - 2; y <= thisYear + 1; y++) y];
    final noAddress = plan.noMailingAddress;
    final incomplete = plan.incompleteMailingAddress;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_count(widget.tenants.length, 'tenant', 'tenants')} selected. '
          'Statements print in the order the list shows them now.',
        ),
        const SizedBox(height: 16),
        const Text('Period', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: true,
              label: Text('This month', key: Key('bulk-statements-period-month')),
            ),
            ButtonSegment(
              value: false,
              label: Text('All history', key: Key('bulk-statements-period-all')),
            ),
          ],
          selected: {thisMonth},
          onSelectionChanged: (s) => setState(() => thisMonth = s.first),
        ),
        if (thisMonth) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: const Key('bulk-statements-month'),
                  initialValue: month,
                  decoration: const InputDecoration(
                    labelText: 'Month',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (var m = 1; m <= 12; m++)
                      DropdownMenuItem(value: m, child: Text(_shortMonths[m - 1])),
                  ],
                  onChanged: (m) {
                    if (m != null) setState(() => month = m);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: const Key('bulk-statements-year'),
                  initialValue: year,
                  decoration: const InputDecoration(
                    labelText: 'Year',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final y in years)
                      DropdownMenuItem(value: y, child: Text('$y')),
                  ],
                  onChanged: (y) {
                    if (y != null) setState(() => year = y);
                  },
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        CheckboxListTile(
          key: const Key('bulk-statements-combine'),
          value: combine,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          // Nobody to combine: the box says so and stays off.
          onChanged: people == 0
              ? null
              : (v) => setState(() => combine = v ?? false),
          title: Text('Combine units for the same person '
              '(${_count(people, 'person', 'people')}, '
              '${_count(unitsInGroups, 'unit', 'units')})'),
          subtitle: combinedNames.isEmpty
              ? null
              : Text(
                  _firstTen(combinedNames),
                  key: const Key('bulk-statements-combine-who'),
                ),
        ),
        CheckboxListTile(
          key: const Key('bulk-statements-skip-nothing-owed'),
          value: skipNothingOwed,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (v) => setState(() => skipNothingOwed = v ?? false),
          title: Text('Skip tenants who owe nothing ($nothingOwed)'),
        ),
        CheckboxListTile(
          key: const Key('bulk-statements-skip-no-activity'),
          value: skipNoActivity,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (v) => setState(() => skipNoActivity = v ?? false),
          title: Text('Skip tenants with no ledger entries ($noActivity)'),
        ),
        CheckboxListTile(
          key: const Key('bulk-statements-duplex'),
          value: duplex,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (v) => setState(() => duplex = v ?? false),
          title: const Text('Double-sided'),
          subtitle: const Text('Adds a blank page after any statement with '
              'an odd number of pages, so no statement starts on the back '
              'of another.'),
        ),
        if (noAddress.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'No mailing address on file: ${noAddress.length}',
            key: const Key('bulk-statements-no-address'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(_firstTen([for (final t in noAddress) _nameOf(t)])),
        ],
        if (incomplete.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Address missing city, state or ZIP: ${incomplete.length}',
            key: const Key('bulk-statements-incomplete-address'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(_firstTen([for (final t in incomplete) _nameOf(t)])),
        ],
        if (plan.notCombined.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final g in plan.notCombined)
            Text('Printed separately: ${_nameOf(g.tenants.first)} '
                '(${g.reason})'),
        ],
        if (plan.statementCount == 0) ...[
          const SizedBox(height: 12),
          const Text(
            'Nothing to print: every selected tenant is skipped.',
            key: Key('bulk-statements-none'),
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}
