import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/invoice_model.dart';
import '../models/invoice_line_item_model.dart';
import '../models/ledger_entry_model.dart';
import '../models/tenant_model.dart';
import '../models/facility_model.dart';
import 'ledger_service.dart';
import 'tenant_service.dart';
import 'facility_service.dart';
import 'audit_service.dart';
import 'email_service.dart';

/// Service for managing invoices
class InvoiceService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Generate next invoice number for a facility
  /// Format: INV-YYYY-XXX (e.g., INV-2025-001)
  static Future<String> _generateInvoiceNumber(String facilityId) async {
    try {
      final year = DateTime.now().year;
      final prefix = 'INV-$year-';

      // Get the last invoice number for this year
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .where('invoiceNumber', isGreaterThanOrEqualTo: prefix)
          .where('invoiceNumber', isLessThan: 'INV-${year + 1}-')
          .orderBy('invoiceNumber', descending: true)
          .limit(1)
          .get();

      int nextNumber = 1;
      if (snapshot.docs.isNotEmpty) {
        final lastNumber = snapshot.docs.first.data()['invoiceNumber'] as String;
        final lastNumStr = lastNumber.split('-').last;
        nextNumber = (int.tryParse(lastNumStr) ?? 0) + 1;
      }

      return '$prefix${nextNumber.toString().padLeft(3, '0')}';
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error generating invoice number, using timestamp: $e');
      }
      // Fallback to timestamp-based number
      return 'INV-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// Generate invoice from unpaid ledger entries
  static Future<InvoiceModel> generateInvoiceFromLedger({
    required String tenantId,
    required String facilityId,
    List<String>? ledgerEntryIds, // If null, includes all unpaid charges
    DateTime? issueDate,
    DateTime? dueDate,
    double? taxRate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [Invoice] Generating invoice for tenant: $tenantId');
      }

      // Get tenant and facility
      final tenant = await TenantService.getTenantById(facilityId, tenantId);
      if (tenant == null) throw Exception('Tenant not found');

      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      // Get unpaid ledger entries
      final allEntries = await LedgerService.getLedgerEntries(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      List<LedgerEntry> entriesToInvoice;
      if (ledgerEntryIds != null && ledgerEntryIds.isNotEmpty) {
        entriesToInvoice = allEntries
            .where((e) =>
                ledgerEntryIds.contains(e.id) &&
                e.isCharge &&
                e.isActive &&
                (e.metadata?['allocatedAmount'] == null ||
                    (e.metadata?['allocatedAmount'] as num).toDouble() < e.amount))
            .toList();
      } else {
        // Get all unpaid charges
        entriesToInvoice = allEntries
            .where((e) =>
                e.isCharge &&
                e.isActive &&
                (e.metadata?['allocatedAmount'] == null ||
                    (e.metadata?['allocatedAmount'] as num).toDouble() < e.amount))
            .toList();
      }

      if (entriesToInvoice.isEmpty) {
        throw Exception('No unpaid charges to invoice');
      }

      // Convert ledger entries to invoice line items
      final lineItems = entriesToInvoice.map((entry) {
        return InvoiceLineItem(
          id: entry.id,
          type: _mapLedgerTypeToInvoiceType(entry.type),
          description: entry.description ?? entry.typeDisplayName,
          amount: entry.amount - ((entry.metadata?['allocatedAmount'] as num?)?.toDouble() ?? 0.0),
          dueDate: entry.dueDate,
          metadata: {
            'ledgerEntryId': entry.id,
            'entryDate': entry.entryDate.toIso8601String(),
          },
        );
      }).toList();

      // Calculate totals
      final subtotal = lineItems.fold(0.0, (sum, item) => sum + item.amount);
      final tax = taxRate != null ? subtotal * taxRate : null;
      final total = subtotal + (tax ?? 0.0);

      // Generate invoice number
      final invoiceNumber = await _generateInvoiceNumber(facilityId);

      // Create invoice
      final now = DateTime.now();
      final invoice = InvoiceModel(
        id: '', // Will be set by Firestore
        tenantId: tenantId,
        facilityId: facilityId,
        invoiceNumber: invoiceNumber,
        status: InvoiceStatus.draft,
        issueDate: issueDate ?? now,
        dueDate: dueDate ?? now.add(const Duration(days: 30)),
        subtotal: subtotal,
        tax: tax,
        total: total,
        balance: total,
        lineItems: lineItems,
        ledgerEntryIds: entriesToInvoice.map((e) => e.id).toList(),
        paymentIds: [],
        notes: null,
        createdAt: now,
        createdBy: user.uid,
        isActive: true,
      );

      // Save to Firestore
      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .doc();

      await ref.set(invoice.copyWith(id: ref.id).toFirestore());

      // Update ledger entries to reference this invoice
      final batch = _firestore.batch();
      for (final entry in entriesToInvoice) {
        final entryRef = _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('ledgers')
            .doc(entry.id);
        
        final updatedMetadata = Map<String, dynamic>.from(entry.metadata ?? {});
        updatedMetadata['invoiceId'] = ref.id;
        
        batch.update(entryRef, {'metadata': updatedMetadata});
      }
      await batch.commit();

      // Audit log
      await AuditService.logInvoiceCreated(
        facilityId: facilityId,
        tenantId: tenantId,
        invoiceId: ref.id,
        invoiceNumber: invoiceNumber,
        total: total,
      );

      if (kDebugMode) {
        print('✅ [Invoice] Created invoice: $invoiceNumber (${ref.id})');
      }

      return invoice.copyWith(id: ref.id);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error generating invoice: $e');
      }
      rethrow;
    }
  }

  /// Map ledger entry type to invoice line item type
  static InvoiceLineItemType _mapLedgerTypeToInvoiceType(LedgerEntryType type) {
    switch (type) {
      case LedgerEntryType.rentCharge:
        return InvoiceLineItemType.rent;
      case LedgerEntryType.insuranceCharge:
        return InvoiceLineItemType.insurance;
      case LedgerEntryType.lateFee:
        return InvoiceLineItemType.lateFee;
      case LedgerEntryType.adminFee:
        return InvoiceLineItemType.adminFee;
      case LedgerEntryType.moveInFee:
        return InvoiceLineItemType.moveInFee;
      case LedgerEntryType.moveOutFee:
        return InvoiceLineItemType.otherFee;
      case LedgerEntryType.lockCutFee:
        return InvoiceLineItemType.otherFee;
      case LedgerEntryType.transferFee:
        return InvoiceLineItemType.otherFee;
      case LedgerEntryType.otherCharge:
        return InvoiceLineItemType.otherFee;
      default:
        return InvoiceLineItemType.other;
    }
  }

  /// Generate invoice PDF
  static Future<Uint8List> generateInvoicePDF({
    required InvoiceModel invoice,
    required TenantModel tenant,
    required FacilityModel facility,
  }) async {
    try {
      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(72),
          build: (pw.Context context) {
            return [
              // Header
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          facility.name,
                          style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        if (facility.address != null)
                          pw.Text(
                            facility.address!,
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                        if (facility.phone != null)
                          pw.Text(
                            facility.phone!,
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'INVOICE',
                          style: pw.TextStyle(
                            fontSize: 32,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          invoice.invoiceNumber,
                          style: const pw.TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 40),

              // Bill To
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Bill To:',
                          style: pw.TextStyle(
                            fontSize: 12,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.SizedBox(height: 8),
                        pw.Text(tenant.name, style: const pw.TextStyle(fontSize: 11)),
                        pw.Text(tenant.email, style: const pw.TextStyle(fontSize: 10)),
                        pw.Text(tenant.phone, style: const pw.TextStyle(fontSize: 10)),
                        if (tenant.addresses.isNotEmpty)
                          pw.Text(
                            tenant.addresses.first.toString(),
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                      ],
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'Invoice Date:',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          _formatDate(invoice.issueDate),
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                        pw.SizedBox(height: 8),
                        pw.Text(
                          'Due Date:',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          _formatDate(invoice.dueDate),
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 30),

              // Line Items Table
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  // Header
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Description',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Amount',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  // Line items
                  ...invoice.lineItems.map((item) => pw.TableRow(
                        children: [
                          pw.Padding(
                            padding: const pw.EdgeInsets.all(8),
                            child: pw.Text(item.description),
                          ),
                          pw.Padding(
                            padding: const pw.EdgeInsets.all(8),
                            child: pw.Text(
                              item.formattedAmount,
                              textAlign: pw.TextAlign.right,
                            ),
                          ),
                        ],
                      )),
                ],
              ),
              pw.SizedBox(height: 20),

              // Totals
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.end,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Row(
                        mainAxisSize: pw.MainAxisSize.min,
                        children: [
                          pw.SizedBox(
                            width: 150,
                            child: pw.Text(
                              'Subtotal:',
                              textAlign: pw.TextAlign.right,
                            ),
                          ),
                          pw.SizedBox(
                            width: 100,
                            child: pw.Text(
                              invoice.formattedSubtotal,
                              textAlign: pw.TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                      if (invoice.tax != null)
                        pw.Row(
                          mainAxisSize: pw.MainAxisSize.min,
                          children: [
                            pw.SizedBox(
                              width: 150,
                              child: pw.Text(
                                'Tax:',
                                textAlign: pw.TextAlign.right,
                              ),
                            ),
                            pw.SizedBox(
                              width: 100,
                              child: pw.Text(
                                invoice.formattedTax!,
                                textAlign: pw.TextAlign.right,
                              ),
                            ),
                          ],
                        ),
                      pw.Divider(),
                      pw.Row(
                        mainAxisSize: pw.MainAxisSize.min,
                        children: [
                          pw.SizedBox(
                            width: 150,
                            child: pw.Text(
                              'Total:',
                              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                              textAlign: pw.TextAlign.right,
                            ),
                          ),
                          pw.SizedBox(
                            width: 100,
                            child: pw.Text(
                              invoice.formattedTotal,
                              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                              textAlign: pw.TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),

              if (invoice.notes != null && invoice.notes!.isNotEmpty) ...[
                pw.SizedBox(height: 30),
                pw.Text(
                  'Notes:',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
                pw.Text(invoice.notes!),
              ],
            ];
          },
        ),
      );

      return pdf.save();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error generating PDF: $e');
      }
      rethrow;
    }
  }

  /// Upload invoice PDF to Firebase Storage
  static Future<String> uploadInvoicePDF({
    required String facilityId,
    required String invoiceId,
    required Uint8List pdfData,
  }) async {
    try {
      final ref = _storage
          .ref()
          .child('facilities/$facilityId/invoices/$invoiceId/invoice.pdf');

      final uploadTask = ref.putData(pdfData);
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      if (kDebugMode) {
        print('✅ [Invoice] PDF uploaded: $downloadUrl');
      }

      return downloadUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error uploading PDF: $e');
      }
      rethrow;
    }
  }

  /// Generate and upload invoice PDF
  static Future<String> generateAndUploadInvoicePDF({
    required InvoiceModel invoice,
    required String facilityId,
    required String invoiceId,
  }) async {
    try {
      // Get tenant and facility
      final tenant = await TenantService.getTenantById(facilityId, invoice.tenantId);
      if (tenant == null) throw Exception('Tenant not found');

      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      final pdfData = await generateInvoicePDF(
        invoice: invoice,
        tenant: tenant,
        facility: facility,
      );

      final pdfUrl = await uploadInvoicePDF(
        facilityId: facilityId,
        invoiceId: invoiceId,
        pdfData: pdfData,
      );

      // Update invoice with PDF URL
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .doc(invoiceId)
          .update({'pdfUrl': pdfUrl});

      return pdfUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error generating and uploading PDF: $e');
      }
      rethrow;
    }
  }

  /// Get invoices for a tenant (real-time stream)
  static Stream<List<InvoiceModel>> getInvoicesForTenantStream({
    required String tenantId,
    required String facilityId,
  }) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      return _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .where('tenantId', isEqualTo: tenantId)
          .where('isActive', isEqualTo: true)
          .orderBy('issueDate', descending: true)
          .snapshots()
          .map((snapshot) {
        return snapshot.docs
            .map((doc) => InvoiceModel.fromFirestore(doc))
            .toList();
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error getting invoices stream: $e');
      }
      rethrow;
    }
  }

  /// Get invoices for a facility (real-time stream)
  /// Uses where('isActive') only and sorts in memory so the list works even if
  /// the composite index (isActive + issueDate) is missing or still building.
  static Stream<List<InvoiceModel>> getInvoicesForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      return _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .where('isActive', isEqualTo: true)
          .snapshots()
          .map((snapshot) {
        final list = snapshot.docs
            .map((doc) => InvoiceModel.fromFirestore(doc))
            .toList();
        list.sort((a, b) => b.issueDate.compareTo(a.issueDate));
        return list;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error getting invoices stream: $e');
      }
      rethrow;
    }
  }

  /// Get overdue invoices for a facility
  static Future<List<InvoiceModel>> getOverdueInvoices(String facilityId) async {
    try {
      final now = DateTime.now();
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .where('isActive', isEqualTo: true)
          .where('status', whereIn: ['sent', 'overdue'])
          .where('balance', isGreaterThan: 0)
          .get();

      final invoices = snapshot.docs
          .map((doc) => InvoiceModel.fromFirestore(doc))
          .where((invoice) => invoice.dueDate.isBefore(now) && invoice.balance > 0)
          .toList();

      return invoices;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error getting overdue invoices: $e');
      }
      rethrow;
    }
  }

  /// Apply payment to invoice
  static Future<void> applyPaymentToInvoice({
    required String facilityId,
    required String invoiceId,
    required String paymentId,
    required double paymentAmount,
  }) async {
    try {
      final invoiceRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .doc(invoiceId);

      final invoiceDoc = await invoiceRef.get();
      if (!invoiceDoc.exists) {
        throw Exception('Invoice not found');
      }

      final invoice = InvoiceModel.fromFirestore(invoiceDoc);
      final newBalance = (invoice.balance - paymentAmount).clamp(0.0, invoice.total);
      final newStatus = newBalance <= 0 ? InvoiceStatus.paid : invoice.status;

      // Update invoice
      await invoiceRef.update({
        'balance': newBalance,
        'status': newStatus.name,
        'paymentIds': FieldValue.arrayUnion([paymentId]),
        if (newBalance <= 0) 'paidDate': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [Invoice] Applied payment to invoice: $invoiceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error applying payment: $e');
      }
      rethrow;
    }
  }

  /// Send invoice (update status and send email)
  static Future<void> sendInvoice({
    required String facilityId,
    required String invoiceId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Get invoice and related data
      final invoiceDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .doc(invoiceId)
          .get();
      
      if (!invoiceDoc.exists) {
        throw Exception('Invoice not found');
      }

      final invoice = InvoiceModel.fromFirestore(invoiceDoc);
      final tenant = await TenantService.getTenantById(facilityId, invoice.tenantId);
      final facility = await FacilityService.getFacility(facilityId);

      if (tenant == null) {
        throw Exception('Tenant not found');
      }
      if (facility == null) {
        throw Exception('Facility not found');
      }

      // Update invoice status
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .doc(invoiceId)
          .update({
        'status': InvoiceStatus.sent.name,
        'sentAt': FieldValue.serverTimestamp(),
      });

      // Send email with invoice PDF
      if (invoice.pdfUrl != null && tenant.email.isNotEmpty) {
        try {
          final subject = 'Invoice ${invoice.invoiceNumber} from ${facility.name}';
          final body = '''
Dear ${tenant.name},

Please find attached your invoice ${invoice.invoiceNumber} for ${facility.name}.

Invoice Details:
- Invoice Number: ${invoice.invoiceNumber}
- Issue Date: ${_formatDate(invoice.issueDate)}
- Due Date: ${_formatDate(invoice.dueDate)}
- Total Amount: ${invoice.formattedTotal}
${invoice.balance > 0 ? '- Balance Due: ${invoice.formattedBalance}' : ''}

${invoice.notes != null && invoice.notes!.isNotEmpty ? '\nNotes:\n${invoice.notes}\n' : ''}

Please make payment by the due date to avoid late fees.

Thank you for your business!

${facility.name}
${facility.email != null ? '\nEmail: ${facility.email}' : ''}
${facility.phone != null ? 'Phone: ${facility.phone}' : ''}
''';

          // Send email with PDF link
          final htmlBody = '''
<html>
<body>
  <p>Dear ${tenant.name},</p>
  <p>Please find your invoice ${invoice.invoiceNumber} for ${facility.name}.</p>
  <h3>Invoice Details:</h3>
  <ul>
    <li>Invoice Number: ${invoice.invoiceNumber}</li>
    <li>Issue Date: ${_formatDate(invoice.issueDate)}</li>
    <li>Due Date: ${_formatDate(invoice.dueDate)}</li>
    <li>Total Amount: ${invoice.formattedTotal}</li>
    ${invoice.balance > 0 ? '<li>Balance Due: ${invoice.formattedBalance}</li>' : ''}
  </ul>
  ${invoice.notes != null && invoice.notes!.isNotEmpty ? '<p><strong>Notes:</strong><br>${invoice.notes}</p>' : ''}
  ${invoice.pdfUrl != null ? '<p><a href="${invoice.pdfUrl}" style="background-color: #4CAF50; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px; display: inline-block;">Download Invoice PDF</a></p>' : ''}
  <p>Please make payment by the due date to avoid late fees.</p>
  <p>Thank you for your business!</p>
  <p>
    <strong>${facility.name}</strong><br>
    ${facility.email != null ? 'Email: ${facility.email}<br>' : ''}
    ${facility.phone != null ? 'Phone: ${facility.phone}' : ''}
  </p>
</body>
</html>
''';

          await EmailService.sendEmail(
            to: tenant.email,
            subject: subject,
            html: htmlBody,
            text: body,
            facilityId: facilityId,
          );

          if (kDebugMode) {
            print('✅ [Invoice] Invoice email sent to ${tenant.email}');
          }
        } catch (emailError) {
          if (kDebugMode) {
            print('⚠️ [Invoice] Error sending email: $emailError');
          }
          // Don't fail the whole operation if email fails
          // Invoice status is already updated
        }
      } else {
        if (kDebugMode) {
          print('⚠️ [Invoice] Cannot send email: PDF URL or tenant email missing');
        }
      }

      if (kDebugMode) {
        print('✅ [Invoice] Invoice sent: $invoiceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error sending invoice: $e');
      }
      rethrow;
    }
  }

  /// Mark invoice as paid (manual payment)
  static Future<void> markInvoiceAsPaid({
    required String facilityId,
    required String invoiceId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final invoiceRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .doc(invoiceId);

      final invoiceDoc = await invoiceRef.get();
      if (!invoiceDoc.exists) {
        throw Exception('Invoice not found');
      }

      final invoice = InvoiceModel.fromFirestore(invoiceDoc);
      
      // Can only mark as paid if not already paid or voided
      if (invoice.status == InvoiceStatus.paid) {
        throw Exception('Invoice is already marked as paid');
      }
      if (invoice.status == InvoiceStatus.voided) {
        throw Exception('Cannot mark voided invoice as paid');
      }

      // Update invoice to paid status
      await invoiceRef.update({
        'status': InvoiceStatus.paid.name,
        'balance': 0.0,
        'paidDate': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': user.uid,
      });

      // Audit log
      await AuditService.logInvoiceAction(
        facilityId: facilityId,
        tenantId: invoice.tenantId,
        invoiceId: invoiceId,
        invoiceNumber: invoice.invoiceNumber,
        action: 'paid',
        details: {'amount': invoice.total},
      );

      if (kDebugMode) {
        print('✅ [Invoice] Marked as paid: $invoiceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error marking as paid: $e');
      }
      rethrow;
    }
  }

  /// Void invoice
  static Future<void> voidInvoice({
    required String facilityId,
    required String invoiceId,
    String? reason,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final invoiceRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('invoices')
          .doc(invoiceId);

      final invoiceDoc = await invoiceRef.get();
      if (!invoiceDoc.exists) {
        throw Exception('Invoice not found');
      }

      final invoice = InvoiceModel.fromFirestore(invoiceDoc);
      
      // Can only void if not already paid or voided
      if (invoice.status == InvoiceStatus.paid) {
        throw Exception('Cannot void a paid invoice');
      }
      if (invoice.status == InvoiceStatus.voided) {
        throw Exception('Invoice is already voided');
      }

      // Update invoice to voided status
      final updateData = <String, dynamic>{
        'status': InvoiceStatus.voided.name,
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': user.uid,
      };

      if (reason != null && reason.isNotEmpty) {
        updateData['voidReason'] = reason;
      }

      await invoiceRef.update(updateData);

      // Audit log
      await AuditService.logInvoiceAction(
        facilityId: facilityId,
        tenantId: invoice.tenantId,
        invoiceId: invoiceId,
        invoiceNumber: invoice.invoiceNumber,
        action: 'voided',
        details: reason != null ? {'reason': reason} : null,
      );

      if (kDebugMode) {
        print('✅ [Invoice] Voided: $invoiceId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Invoice] Error voiding invoice: $e');
      }
      rethrow;
    }
  }

  static String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}

