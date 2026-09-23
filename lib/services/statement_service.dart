import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import 'pdf_letterhead.dart';
import 'package:intl/intl.dart';

/// Service for generating and sending account statements
class StatementService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Generate statement PDF from ledger entries
  static Future<Uint8List> generateStatementPDF({
    required List<LedgerEntry> entries,
    required TenantModel tenant,
    required FacilityModel facility,
    DateTime? startDate,
    DateTime? endDate,
    double? balanceForward,
  }) async {
    try {
      final pdf = pw.Document();
      final logo = await PdfLetterhead.loadLogo(facility);
      final remitTo = PdfLetterhead.remitAddress(facility);
      final customMessage = facility.statementMessage?.trim();
      final now = DateTime.now();
      final statementDate = endDate ?? now;
      
      // Calculate balances
      double runningBalance = balanceForward ?? 0.0;
      final transactions = <_TransactionRow>[];
      
      // Sort entries by date (oldest first for statement)
      final sortedEntries = List<LedgerEntry>.from(entries)
        ..sort((a, b) => a.entryDate.compareTo(b.entryDate));
      
      for (final entry in sortedEntries) {
        if (entry.status != LedgerEntryStatus.voided) {
          final reducesBalance = entry.type == LedgerEntryType.payment ||
              entry.type == LedgerEntryType.credit ||
              entry.type == LedgerEntryType.refund;
          if (reducesBalance) {
            runningBalance -= entry.amount.abs(); // Payments reduce balance
          } else {
            runningBalance += entry.amount; // Charges increase balance
          }

          // Columns follow the same rule as the balance, so a row can never
          // sit under Charges while lowering what is owed.
          transactions.add(_TransactionRow(
            date: entry.entryDate,
            description: entry.description ?? entry.typeDisplayName,
            charges: !reducesBalance && entry.amount > 0 ? entry.amount : 0.0,
            payments: reducesBalance || entry.amount < 0
                ? entry.amount.abs()
                : 0.0,
            balance: runningBalance,
            reference: entry.referenceId,
          ));
        }
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(72),
          build: (pw.Context context) {
            return [
              PdfLetterhead.build(
                facility: facility,
                title: 'Account Statement',
                titleDetails: ['Date: ${_formatDate(statementDate)}'],
                logo: logo,
              ),
              pw.SizedBox(height: 28),

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
                        pw.SizedBox(height: 8),
                        pw.Text(tenant.name, style: const pw.TextStyle(fontSize: 11)),
                        pw.Text(tenant.email, style: const pw.TextStyle(fontSize: 10)),
                        pw.Text(tenant.phone, style: const pw.TextStyle(fontSize: 10)),
                        if (tenant.unitNumber.isNotEmpty)
                          pw.Text(
                            'Unit: ${tenant.unitNumber}',
                            style: const pw.TextStyle(fontSize: 10),
                          ),
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
                            '${_formatDate(startDate)} - ${_formatDate(statementDate)}',
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                          pw.SizedBox(height: 8),
                        ],
                        pw.Text(
                          'Current Balance:',
                          style: pw.TextStyle(
                            fontSize: 12,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          _formatCurrency(runningBalance),
                          style: pw.TextStyle(
                            fontSize: 16,
                            fontWeight: pw.FontWeight.bold,
                            color: runningBalance > 0 ? PdfColors.red700 : PdfColors.green700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              
              if (balanceForward != null && balanceForward > 0) ...[
                pw.SizedBox(height: 16),
                pw.Container(
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(color: PdfColors.yellow100),
                  child: pw.Text(
                    'Balance Forward: ${_formatCurrency(balanceForward)}',
                    style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
                  ),
                ),
              ],

              pw.SizedBox(height: 30),

              // Transactions Table
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  // Header
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      _buildTableCell('Date', isHeader: true),
                      _buildTableCell('Description', isHeader: true),
                      _buildTableCell('Charges', isHeader: true, alignRight: true),
                      _buildTableCell('Payments', isHeader: true, alignRight: true),
                      _buildTableCell('Balance', isHeader: true, alignRight: true),
                    ],
                  ),
                  // Rows
                  ...transactions.map((transaction) => pw.TableRow(
                    children: [
                      _buildTableCell(_formatDate(transaction.date)),
                      _buildTableCell(transaction.description),
                      _buildTableCell(
                        transaction.charges > 0 ? _formatCurrency(transaction.charges) : '',
                        alignRight: true,
                      ),
                      _buildTableCell(
                        transaction.payments > 0 ? _formatCurrency(transaction.payments) : '',
                        alignRight: true,
                      ),
                      _buildTableCell(
                        _formatCurrency(transaction.balance),
                        alignRight: true,
                        isBold: true,
                      ),
                    ],
                  )),
                ],
              ),
              
              pw.SizedBox(height: 30),

              // Footer
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 20),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Thank you for your business!',
                      style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 8),
                    pw.Text(
                      customMessage != null && customMessage.isNotEmpty
                          ? customMessage
                          : 'Please make payment by the due date to avoid late fees.',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                    if (remitTo != null) ...[
                      pw.SizedBox(height: 8),
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
              ),
            ];
          },
        ),
      );

      return pdf.save();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Statement] Error generating PDF: $e');
      }
      rethrow;
    }
  }

  static pw.Widget _buildTableCell(String text, {bool isHeader = false, bool alignRight = false, bool isBold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
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

      // Calculate balance forward (balance before start date)
      double balanceForward = 0.0;
      if (startDate != null) {
        final earlierEntries = ledgerEntries.where((e) => e.entryDate.isBefore(startDate)).toList();
        balanceForward = 0.0;
        for (final entry in earlierEntries) {
          if (entry.status != LedgerEntryStatus.voided) {
            if (entry.type == LedgerEntryType.payment || 
                entry.type == LedgerEntryType.credit || 
                entry.type == LedgerEntryType.refund) {
              balanceForward -= entry.amount.abs();
            } else {
              balanceForward += entry.amount;
            }
          }
        }
      }

      // Filter entries by date range if specified
      List<LedgerEntry> filteredEntries = ledgerEntries;
      if (startDate != null) {
        filteredEntries = filteredEntries.where((e) => e.entryDate.isAfter(startDate.subtract(const Duration(seconds: 1))) || e.entryDate.isAtSameMomentAs(startDate)).toList();
      }
      if (endDate != null) {
        filteredEntries = filteredEntries.where((e) => e.entryDate.isBefore(endDate.add(const Duration(days: 1))) || e.entryDate.isAtSameMomentAs(endDate)).toList();
      }

      // Generate PDF
      final pdfData = await generateStatementPDF(
        entries: filteredEntries,
        tenant: tenant,
        facility: facility,
        startDate: startDate,
        endDate: endDate,
        balanceForward: balanceForward,
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

      final subject = 'Account Statement from ${facility.name}';
      final htmlBody = '''
<html>
<body style="font-family: Arial, sans-serif;">
  <h2>Account Statement</h2>
  <p>Dear ${tenant.name},</p>
  <p>Your account statement for ${periodText} is ready.</p>
  <p><a href="${pdfUrl}" style="background-color: #4CAF50; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px; display: inline-block;">Download Statement PDF</a></p>
  <p><strong>Current Balance:</strong> ${_formatCurrency(_calculateCurrentBalance(ledgerEntries))}</p>
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

Your account statement for ${periodText} is ready.

Download it here: ${pdfUrl}

Current Balance: ${_formatCurrency(_calculateCurrentBalance(ledgerEntries))}

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

  static double _calculateCurrentBalance(List<LedgerEntry> entries) {
    double balance = 0.0;
    for (final entry in entries) {
      if (entry.status != LedgerEntryStatus.voided) {
        if (entry.type == LedgerEntryType.payment || 
            entry.type == LedgerEntryType.credit || 
            entry.type == LedgerEntryType.refund) {
          balance -= entry.amount.abs();
        } else {
          balance += entry.amount;
        }
      }
    }
    return balance;
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

  static String _formatDate(DateTime date) {
    return DateFormat('MMM d, yyyy').format(date);
  }

  static String _formatCurrency(double amount) {
    final formatter = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    return formatter.format(amount);
  }
}

class _TransactionRow {
  final DateTime date;
  final String description;
  final double charges;
  final double payments;
  final double balance;
  final String? reference;

  _TransactionRow({
    required this.date,
    required this.description,
    required this.charges,
    required this.payments,
    required this.balance,
    this.reference,
  });
}

