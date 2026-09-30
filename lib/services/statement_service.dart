import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/ledger_entry_model.dart';
import '../models/tenant_model.dart';
import '../models/facility_model.dart';
import 'ledger_service.dart';
import 'tenant_service.dart';
import 'facility_service.dart';
import 'email_service.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/pdf_letterhead.dart';
import 'package:sfcapp/utils/print_documents.dart' show tenantPrintAddress;
import 'package:sfcapp/utils/statement_lines.dart';
import 'package:sfcapp/utils/unit_label.dart';
import 'package:sfcapp/utils/unit_number_sort.dart';
import 'package:intl/intl.dart';

/// The labels of the units [tenant] holds, for the statement's unit line, in
/// unit-number order: one per unit in [units] (the units linked to the tenant
/// by `units.tenantId`, as TenantService.recordsFor(...).linkedUnits reads
/// them; one still marked available is not held, as in
/// TenantService.unitsHeldByTenant), or the tenant's own unit number when
/// the caller has no unit list. Each label carries its area when [facility]
/// names units with their area.
///
/// A tenant renting two units has one ledger, under one tenant record, and
/// the statement named only that record's unit; the owner could not tell
/// from the page that the rent charged covered both.
List<String> statementUnitLabels(
  TenantModel tenant,
  FacilityModel facility, {
  Iterable<UnitModel> units = const [],
}) {
  final includeArea = unitLabelsIncludeArea(facility);
  final held = [
    for (final u in units)
      if (u.status != UnitStatus.available && u.unitNumber.trim().isNotEmpty) u,
  ]..sort((a, b) => compareUnitNumbersNatural(a.unitNumber, b.unitNumber));
  if (held.isEmpty) {
    if (tenant.unitNumber.isEmpty) return const [];
    return [tenantUnitLabel(tenant, includeArea: includeArea)];
  }
  final labels = <String>[];
  for (final u in held) {
    final label = formatUnitLabel(
      number: u.unitNumber,
      area: u.area,
      includeArea: includeArea,
    );
    if (label.isNotEmpty && !labels.contains(label)) labels.add(label);
  }
  return labels;
}

/// "Unit: 12" for one label, "Units: 12, 14" for more. Labels that all end
/// in the same area, "B-14 (Building B)" and "B-15 (Building B)", name it
/// once: "Units: B-14, B-15 (Building B)". Null when there are none.
String? statementUnitsLine(List<String> labels) {
  if (labels.isEmpty) return null;
  if (labels.length == 1) return 'Unit: ${labels.single}';
  final suffix = _sharedAreaSuffix(labels);
  final numbers = suffix == null
      ? labels
      : [for (final l in labels) l.substring(0, l.length - suffix.length)];
  return 'Units: ${numbers.join(', ')}${suffix ?? ''}';
}

final RegExp _areaSuffix = RegExp(r' \([^()]*\)$');

String? _sharedAreaSuffix(List<String> labels) {
  final suffix = _areaSuffix.firstMatch(labels.first)?.group(0);
  if (suffix == null) return null;
  return labels.every((l) => l.endsWith(suffix)) ? suffix : null;
}

/// The statement's unit line under the account holder: "Unit: 12", or
/// "Unit: 12 (Building B)" when [facility] names units with their area. Null
/// for a tenant with no unit number.
String? statementUnitLine(TenantModel tenant, FacilityModel facility) =>
    statementUnitsLine(statementUnitLabels(tenant, facility));

/// The lines under the account holder's name, in print order: their mailing
/// address ([tenantPrintAddress]) first, so the name and address sit
/// together where a window envelope shows them; then phone and email, each
/// only when they have one (an empty one printed as a blank line before, and
/// most paper-statement tenants have no email); then the unit line.
List<String> statementHolderDetails(
  TenantModel tenant,
  List<String> unitLabels,
) {
  final address = tenantPrintAddress(tenant.addresses);
  final phone = tenant.phone.trim();
  final email = tenant.email.trim();
  return [
    if (address != null) ...address.split('\n'),
    if (phone.isNotEmpty) phone,
    if (email.isNotEmpty) email,
    if (statementUnitsLine(unitLabels) case final unitLine?) unitLine,
  ];
}

/// "Current Balance" when the statement runs to today, "Balance as of
/// Sep 23, 2026" when an end date was chosen: the figure is then the balance
/// on that day, which "Current" misdescribed.
String statementBalanceLabel(DateTime? endDate) => endDate == null
    ? 'Current Balance'
    : 'Balance as of ${_formatDate(endDate)}';

String _formatDate(DateTime date) => DateFormat('MMM d, yyyy').format(date);

String _formatCurrency(double amount) =>
    NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(amount);

/// Service for generating and sending account statements
class StatementService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  /// The unit labels for [tenant]'s statement ([statementUnitLabels]) from
  /// the units linked to them in Firestore. A failed read falls back to the
  /// tenant's own unit number: a statement naming one unit beats no
  /// statement, and the ledger it prints is the same either way.
  static Future<List<String>> unitLabelsFor(
    TenantModel tenant,
    FacilityModel facility,
  ) async {
    var units = const <UnitModel>[];
    try {
      units = await TenantService.recordsFor(facility.id).linkedUnits(tenant.id);
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [Statement] Linked units not read, using the tenant\'s unit: $e');
      }
    }
    return statementUnitLabels(tenant, facility, units: units);
  }

  /// One tenant's statement as PDF bytes. [entries] are their ledger, whole
  /// or already cut to the period; [buildStatementLines] cuts and sums them.
  /// [unitLabels] lists every unit they hold ([unitLabelsFor]); left null,
  /// the unit line shows the tenant's own unit number.
  static Future<Uint8List> generateStatementPDF({
    required List<LedgerEntry> entries,
    required TenantModel tenant,
    required FacilityModel facility,
    DateTime? startDate,
    DateTime? endDate,
    List<String>? unitLabels,
  }) async {
    try {
      final logo = await PdfLetterhead.loadLogo(facility);
      final pdf = pw.Document();
      pdf.addPage(buildStatementPage(
        lines: buildStatementLines(entries,
            startDate: startDate, endDate: endDate),
        tenant: tenant,
        unitLabels: unitLabels ?? statementUnitLabels(tenant, facility),
        facility: facility,
        logo: logo,
        printedOn: DateTime.now(),
        startDate: startDate,
        endDate: endDate,
      ));
      return pdf.save();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Statement] Error generating PDF: $e');
      }
      rethrow;
    }
  }

  /// One statement as pages for any pw.Document. The single print adds it
  /// to a fresh document ([generateStatementPDF]); a bulk print can add one
  /// per tenant to the same document, sharing one preloaded [logo], because
  /// the pdf package cannot merge documents afterwards.
  ///
  /// [lines] come from [buildStatementLines] over the tenant's ledger for
  /// the same [startDate] and [endDate]; [unitLabels] from
  /// [statementUnitLabels]. [printedOn] is the statement's date line.
  static pw.MultiPage buildStatementPage({
    required StatementLines lines,
    required TenantModel tenant,
    required List<String> unitLabels,
    required FacilityModel facility,
    pw.ImageProvider? logo,
    required DateTime printedOn,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    final remitTo = PdfLetterhead.remitAddress(facility);
    // The letterhead already says where to mail payments when the facility
    // has a separate mailing address; the footer saying it again put "Mail
    // payments to" on the page twice. A facility with one address has only
    // the footer to say it.
    final remitInFooter =
        remitTo != null && !PdfLetterhead.printsMailingLine(facility);
    final customMessage = facility.statementMessage?.trim();
    final balance = lines.closingBalance;
    final balanceLabel = statementBalanceLabel(endDate);
    final balanceColor = balance > 0 ? PdfColors.red700 : PdfColors.green700;
    final holderDetails = statementHolderDetails(tenant, unitLabels);
    // The date of the balance-forward row, or null for no row. With no start
    // date there is nothing before the period, so the row only ever appears
    // on a period statement; a credit carried forward shows too, where the
    // old yellow box showed a debit alone.
    final balanceForwardDate =
        startDate != null && lines.balanceForward != 0 ? startDate : null;

    final dataRows = <pw.TableRow>[
      if (balanceForwardDate != null)
        pw.TableRow(
          children: [
            _buildTableCell(_formatDate(balanceForwardDate)),
            _buildTableCell('Balance forward'),
            _buildTableCell('', alignRight: true),
            _buildTableCell('', alignRight: true),
            _buildTableCell(
              _formatCurrency(lines.balanceForward),
              alignRight: true,
              isBold: true,
            ),
          ],
        ),
      for (final row in lines.rows)
        pw.TableRow(
          children: [
            _buildTableCell(_formatDate(row.date)),
            _buildTableCell(row.description),
            _buildTableCell(
              row.charge > 0 ? _formatCurrency(row.charge) : '',
              alignRight: true,
            ),
            _buildTableCell(
              row.payment > 0 ? _formatCurrency(row.payment) : '',
              alignRight: true,
            ),
            _buildTableCell(
              _formatCurrency(row.runningBalance),
              alignRight: true,
              isBold: true,
            ),
          ],
        ),
    ];
    // The last few rows travel with the closing block (see below); the rest
    // form a table that may run over as many pages as it needs. With so few
    // rows that none are left over, the header travels with them too.
    final tailCount = dataRows.length < _rowsKeptWithClosing
        ? dataRows.length
        : _rowsKeptWithClosing;
    final leadingRows = dataRows.sublist(0, dataRows.length - tailCount);
    final tailRows = dataRows.sublist(dataRows.length - tailCount);
    // This statement's first page. In a bulk print it is not the document's
    // first page, so the page header compares pages, not page numbers.
    PdfPage? firstPage;

    return pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      margin: _pageMargin,
      // The column headings again at the top of every page after the first,
      // over whichever rows continue there: the rest of the table, or the
      // last rows the closing block took with it.
      header: (pw.Context context) {
        firstPage ??= context.page;
        return identical(context.page, firstPage)
            ? pw.SizedBox(height: 0)
            : _statementTable([_headerRow()]);
      },
      build: (pw.Context context) {
        return [
          PdfLetterhead.build(
            facility: facility,
            title: 'Account Statement',
            titleDetails: ['Date: ${_formatDate(printedOn)}'],
            logo: logo,
          ),
          pw.SizedBox(height: 14),

          // Account Information
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Account Holder:',
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(tenant.name, style: const pw.TextStyle(fontSize: 11)),
                    for (final line in holderDetails)
                      pw.Text(line, style: const pw.TextStyle(fontSize: 10)),
                  ],
                ),
              ),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    if (startDate != null) ...[
                      pw.Text(
                        'Statement Period:',
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        '${_formatDate(startDate)} - ${_formatDate(endDate ?? printedOn)}',
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                      pw.SizedBox(height: 6),
                    ],
                    pw.Text(
                      '$balanceLabel:',
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      _formatCurrency(balance),
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                        color: balanceColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          pw.SizedBox(height: 14),

          // Transactions Table
          if (leadingRows.isNotEmpty)
            _statementTable([_headerRow(), ...leadingRows]),

          // The last rows, the balance again and the closing lines, kept on
          // one page: a statement a little too long for its page used to
          // put the bottom balance and "Thank you" on a page of their own.
          // Moved over whole, they take a few rows with them, so the last
          // page always shows where the ledger ends. This table has no
          // header of its own (the page header gives it one on a new page);
          // under the leading one the two read as one table.
          pw.Inseparable(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                _statementTable([
                  if (leadingRows.isEmpty) _headerRow(),
                  ...tailRows,
                ]),

                // The balance again under the table: the owner reads the
                // page top to bottom and the figure that matters is where
                // the ledger ends, not back at the top.
                pw.SizedBox(height: 8),
                pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(
                    '$balanceLabel: ${_formatCurrency(balance)}',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                      color: balanceColor,
                    ),
                  ),
                ),

                pw.SizedBox(height: 12),

                // Footer
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Thank you for your business!',
                      style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      customMessage != null && customMessage.isNotEmpty
                          ? customMessage
                          : 'Please make payment by the due date to avoid late fees.',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                    if (remitInFooter) ...[
                      pw.SizedBox(height: 6),
                      pw.Text(
                        'Mail payments to:',
                        style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        '${facility.name}\n$remitTo',
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                    ],
                    pw.SizedBox(height: 4),
                    if (facility.email != null)
                      pw.Text(
                        'Questions? Email us at ${facility.email}',
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ];
      },
    );
  }

  /// Half an inch top and bottom, two thirds of an inch at the sides. With
  /// the inch all round these replaced and roomier table rows, a statement
  /// under a three-line address held about nine rows with its closing lines
  /// on one page; now a year of monthly rent and payments fits.
  static const _pageMargin =
      pw.EdgeInsets.symmetric(horizontal: 48, vertical: 36);

  /// Table rows moved to the next page with the closing block when it does
  /// not fit under the table ([buildStatementPage]).
  static const _rowsKeptWithClosing = 3;

  /// Fixed widths for every column but Description, so the table the
  /// closing block carries lines up with the one above it.
  static const Map<int, pw.TableColumnWidth> _columnWidths = {
    0: pw.FixedColumnWidth(70),
    1: pw.FlexColumnWidth(),
    2: pw.FixedColumnWidth(64),
    3: pw.FixedColumnWidth(64),
    4: pw.FixedColumnWidth(68),
  };

  static pw.Table _statementTable(List<pw.TableRow> rows) => pw.Table(
        border: pw.TableBorder.all(width: 0.5),
        columnWidths: _columnWidths,
        children: rows,
      );

  static pw.TableRow _headerRow() => pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          _buildTableCell('Date', isHeader: true),
          _buildTableCell('Description', isHeader: true),
          _buildTableCell('Charges', isHeader: true, alignRight: true),
          _buildTableCell('Payments', isHeader: true, alignRight: true),
          _buildTableCell('Balance', isHeader: true, alignRight: true),
        ],
      );

  static pw.Widget _buildTableCell(String text, {bool isHeader = false, bool alignRight = false, bool isBold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontWeight: isHeader || isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontSize: isHeader ? 10 : 9,
        ),
        textAlign: alignRight ? pw.TextAlign.right : pw.TextAlign.left,
      ),
    );
  }

  /// Send statement via email
  static Future<void> sendStatement({
    required String tenantId,
    required String facilityId,
    List<LedgerEntry>? entries,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Get tenant and facility
      final tenant = await TenantService.getTenantById(facilityId, tenantId);
      if (tenant == null) throw Exception('Tenant not found');

      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      if (tenant.email.isEmpty) {
        throw Exception('Tenant email not available');
      }

      // Get ledger entries if not provided
      final ledgerEntries = entries ?? await LedgerService.getLedgerEntries(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      // Generate PDF: the whole ledger goes in, and the period and balance
      // forward are cut from it by the same rule the printed statement uses.
      final pdfData = await generateStatementPDF(
        entries: ledgerEntries,
        tenant: tenant,
        facility: facility,
        startDate: startDate,
        endDate: endDate,
        unitLabels: await unitLabelsFor(tenant, facility),
      );

      // Upload PDF to Storage
      final pdfUrl = await _uploadStatementPDF(
        facilityId: facilityId,
        tenantId: tenantId,
        pdfData: pdfData,
        statementDate: endDate ?? DateTime.now(),
      );

      // Generate email content
      final periodText = startDate != null && endDate != null
          ? '${_formatDate(startDate)} to ${_formatDate(endDate)}'
          : 'your account';

      // Today's balance over the whole ledger, whatever period the PDF
      // covers: the email says "Current".
      final currentBalance =
          _formatCurrency(buildStatementLines(ledgerEntries).closingBalance);

      final subject = 'Account Statement from ${facility.name}';
      final htmlBody = '''
<html>
<body style="font-family: Arial, sans-serif;">
  <h2>Account Statement</h2>
  <p>Dear ${tenant.name},</p>
  <p>Your account statement for $periodText is ready.</p>
  <p><a href="$pdfUrl" style="background-color: #4CAF50; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px; display: inline-block;">Download Statement PDF</a></p>
  <p><strong>Current Balance:</strong> $currentBalance</p>
  <p>Please review the statement and contact us if you have any questions.</p>
  <p>Thank you for your business!</p>
  <br>
  <p>${facility.name}<br>
  ${facility.email != null ? 'Email: ${facility.email}<br>' : ''}
  ${facility.phone != null ? 'Phone: ${facility.phone}' : ''}
  </p>
</body>
</html>
      ''';

      final textBody = '''
Account Statement

Dear ${tenant.name},

Your account statement for $periodText is ready.

Download it here: $pdfUrl

Current Balance: $currentBalance

Please review the statement and contact us if you have any questions.

Thank you for your business!

${facility.name}
${facility.email != null ? 'Email: ${facility.email}' : ''}
${facility.phone != null ? 'Phone: ${facility.phone}' : ''}
      ''';

      // Send email with PDF link
      final emailResult = await EmailService.sendEmail(
        to: tenant.email,
        subject: subject,
        html: htmlBody,
        text: textBody,
        facilityId: facilityId,
        tenantId: tenantId,
      );

      if (!emailResult.success) {
        throw Exception(EmailService.staffEmailFailureHint(emailResult));
      }

      if (kDebugMode) {
        print('✅ [Statement] Statement sent successfully to ${tenant.email}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Statement] Error sending statement: $e');
      }
      rethrow;
    }
  }

  static Future<String> _uploadStatementPDF({
    required String facilityId,
    required String tenantId,
    required Uint8List pdfData,
    required DateTime statementDate,
  }) async {
    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(statementDate);
      final ref = _storage
          .ref()
          .child('facilities/$facilityId/statements/$tenantId/statement_$dateStr.pdf');

      final uploadTask = ref.putData(pdfData);
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      if (kDebugMode) {
        print('✅ [Statement] PDF uploaded: $downloadUrl');
      }

      return downloadUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Statement] Error uploading PDF: $e');
      }
      rethrow;
    }
  }
}
