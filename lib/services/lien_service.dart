import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/lien_model.dart';
import '../models/tenant_model.dart';
import '../models/facility_model.dart';
import '../models/unit_model.dart';
import '../models/contract_model.dart';
import '../models/ledger_entry_model.dart';
import 'tenant_service.dart';
import 'facility_service.dart';
import 'unit_service.dart';
import 'contract_service.dart';
import 'ledger_service.dart';
import 'audit_service.dart';
import 'email_service.dart';

/// Service for managing liens and auction workflows
class LienService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Create a new lien from delinquency
  static Future<LienModel> createLien({
    required String facilityId,
    required String tenantId,
    required String unitId,
    required String contractId,
    double? lienFilingFee,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [Lien] Creating lien for tenant: $tenantId');
      }

      // Get current balance
      final balance = await LedgerService.getLedgerBalance(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      // Get ledger entries to calculate breakdown
      final entries = await LedgerService.getLedgerEntries(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      final principalAmount = entries
          .where((e) => e.type == LedgerEntryType.rentCharge && e.isActive)
          .fold(0.0, (sum, e) => sum + e.amount);

      final lateFees = entries
          .where((e) => e.type == LedgerEntryType.lateFee && e.isActive)
          .fold(0.0, (sum, e) => sum + e.amount);

      final totalAmount = balance + (lienFilingFee ?? 0.0);

      final lien = LienModel(
        id: '',
        facilityId: facilityId,
        tenantId: tenantId,
        unitId: unitId,
        contractId: contractId,
        currentStage: LienStage.notStarted,
        status: LienStatus.active,
        totalAmount: totalAmount,
        principalAmount: principalAmount,
        lateFees: lateFees,
        lienFilingFee: lienFilingFee ?? 0.0,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('liens')
          .add(lien.toFirestore());

      // Audit log
      await AuditService.logLienCreated(
        facilityId: facilityId,
        tenantId: tenantId,
        lienId: docRef.id,
        unitId: unitId,
      );

      if (kDebugMode) {
        print('✅ [Lien] Lien created: ${docRef.id}');
      }

      return lien.copyWith(id: docRef.id);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Lien] Error creating lien: $e');
      }
      rethrow;
    }
  }

  /// Update lien stage
  static Future<void> updateLienStage({
    required String facilityId,
    required String lienId,
    required LienStage newStage,
    String? lienNumber,
    String? county,
    String? auctionCompany,
    String? auctionReference,
    DateTime? auctionScheduledDate,
    double? auctionFee,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final updates = <String, dynamic>{
        'currentStage': newStage.name,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Set stage-specific dates and fields
      switch (newStage) {
        case LienStage.noticeSent:
          updates['noticeSentDate'] = FieldValue.serverTimestamp();
          break;
        case LienStage.lienFiled:
          updates['lienFiledDate'] = FieldValue.serverTimestamp();
          if (lienNumber != null) updates['lienNumber'] = lienNumber;
          if (county != null) updates['county'] = county;
          break;
        case LienStage.auctionScheduled:
          updates['auctionScheduledDate'] = auctionScheduledDate != null
              ? Timestamp.fromDate(auctionScheduledDate)
              : FieldValue.serverTimestamp();
          if (auctionCompany != null) updates['auctionCompany'] = auctionCompany;
          if (auctionReference != null) updates['auctionReference'] = auctionReference;
          if (auctionFee != null) updates['auctionFee'] = auctionFee;
          break;
        case LienStage.auctionComplete:
          updates['auctionCompleteDate'] = FieldValue.serverTimestamp();
          break;
        case LienStage.resolved:
          updates['resolvedDate'] = FieldValue.serverTimestamp();
          updates['status'] = LienStatus.resolved.name;
          break;
        case LienStage.cancelled:
          updates['cancelledDate'] = FieldValue.serverTimestamp();
          updates['status'] = LienStatus.cancelled.name;
          break;
        default:
          break;
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('liens')
          .doc(lienId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [Lien] Updated lien stage: $lienId -> ${newStage.name}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Lien] Error updating lien stage: $e');
      }
      rethrow;
    }
  }

  /// Generate and upload lien notice PDF
  static Future<String> generateAndUploadLienNoticePDF({
    required LienModel lien,
    required String facilityId,
    required String lienId,
  }) async {
    try {
      final tenant = await TenantService.getTenantById(facilityId, lien.tenantId);
      if (tenant == null) throw Exception('Tenant not found');

      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      final unit = await UnitService.getUnit(facilityId, lien.unitId);
      if (unit == null) throw Exception('Unit not found');

      final pdfData = await _generateLienNoticePDF(
        lien: lien,
        tenant: tenant,
        facility: facility,
        unit: unit,
      );

      final pdfUrl = await _uploadLienPDF(
        facilityId: facilityId,
        lienId: lienId,
        pdfData: pdfData,
        type: 'notice',
      );

      // Update lien with PDF URL
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('liens')
          .doc(lienId)
          .update({'noticePdfUrl': pdfUrl});

      return pdfUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Lien] Error generating notice PDF: $e');
      }
      rethrow;
    }
  }

  /// Generate lien notice PDF
  static Future<Uint8List> _generateLienNoticePDF({
    required LienModel lien,
    required TenantModel tenant,
    required FacilityModel facility,
    required UnitModel unit,
  }) async {
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
                  pw.Text(
                    facility.name,
                    style: pw.TextStyle(
                      fontSize: 24,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'LIEN NOTICE',
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.red700,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),

            // Date
            pw.Text(
              'Date: ${_formatDate(DateTime.now())}',
              style: const pw.TextStyle(fontSize: 12),
            ),
            pw.SizedBox(height: 20),

            // Tenant Information
            pw.Text(
              'To: ${tenant.name}',
              style: pw.TextStyle(
                fontSize: 14,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            if (tenant.addresses.isNotEmpty) ...[
              pw.SizedBox(height: 8),
              ...tenant.addresses.map((addr) => pw.Text(
                    addr.toString(),
                    style: const pw.TextStyle(fontSize: 12),
                  )),
            ],
            pw.SizedBox(height: 20),

            // Notice Content
            pw.Text(
              'NOTICE OF INTENT TO FILE LIEN',
              style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 12),
            pw.Text(
              'This is a formal notice that your storage unit account is delinquent and we intend to file a lien against your property.',
              style: const pw.TextStyle(fontSize: 12),
            ),
            pw.SizedBox(height: 12),

            // Unit Information
            pw.Text(
              'Unit Information:',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text('Unit Number: ${unit.unitNumber}', style: const pw.TextStyle(fontSize: 12)),
            pw.SizedBox(height: 12),

            // Amount Owed
            pw.Text(
              'Amount Owed:',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Principal: \$${lien.principalAmount.toStringAsFixed(2)}',
              style: const pw.TextStyle(fontSize: 12),
            ),
            pw.Text(
              'Late Fees: \$${lien.lateFees.toStringAsFixed(2)}',
              style: const pw.TextStyle(fontSize: 12),
            ),
            pw.Text(
              'Total Amount: \$${lien.totalAmount.toStringAsFixed(2)}',
              style: pw.TextStyle(
                fontSize: 14,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 20),

            // Warning
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.red50,
                border: pw.Border.all(color: PdfColors.red700, width: 2),
              ),
              child: pw.Text(
                'If payment is not received within the time period specified by your state\'s lien laws, we will proceed with filing a lien and may schedule your unit for auction.',
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.red700,
                ),
              ),
            ),
            pw.SizedBox(height: 20),

            // Contact Information
            pw.Text(
              'Contact Information:',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            if (facility.phone != null)
              pw.Text('Phone: ${facility.phone}', style: const pw.TextStyle(fontSize: 12)),
            if (facility.email != null)
              pw.Text('Email: ${facility.email}', style: const pw.TextStyle(fontSize: 12)),
            if (facility.address != null)
              pw.Text('Address: ${facility.address}', style: const pw.TextStyle(fontSize: 12)),
          ];
        },
      ),
    );

    return pdf.save();
  }

  /// Upload lien PDF to Firebase Storage
  static Future<String> _uploadLienPDF({
    required String facilityId,
    required String lienId,
    required Uint8List pdfData,
    required String type, // 'notice', 'filing', 'auction'
  }) async {
    try {
      final ref = _storage
          .ref()
          .child('facilities/$facilityId/liens/$lienId/${type}_notice.pdf');

      final uploadTask = ref.putData(pdfData);
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      if (kDebugMode) {
        print('✅ [Lien] PDF uploaded: $downloadUrl');
      }

      return downloadUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Lien] Error uploading PDF: $e');
      }
      rethrow;
    }
  }

  /// Get liens for a facility
  static Stream<List<LienModel>> getLiensForFacilityStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('liens')
        .where('isActive', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => LienModel.fromFirestore(doc))
            .toList());
  }

  /// Get lien by ID
  static Future<LienModel?> getLien({
    required String facilityId,
    required String lienId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('liens')
          .doc(lienId)
          .get();

      if (!doc.exists) return null;

      return LienModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Lien] Error getting lien: $e');
      }
      rethrow;
    }
  }

  /// Export liens for auction company (CSV format)
  static Future<String> exportLiensForAuction({
    required String facilityId,
    required List<String> lienIds,
  }) async {
    try {
      final liens = <LienModel>[];
      for (final lienId in lienIds) {
        final lien = await getLien(facilityId: facilityId, lienId: lienId);
        if (lien != null) {
          liens.add(lien);
        }
      }

      // Build CSV
      final csv = StringBuffer();
      csv.writeln('Lien ID,Unit Number,Tenant Name,Total Amount,Principal,Late Fees,Lien Number,County');

      for (final lien in liens) {
        final tenant = await TenantService.getTenantById(facilityId, lien.tenantId);
        final unit = await UnitService.getUnit(facilityId, lien.unitId);

        csv.writeln([
          lien.id,
          unit?.unitNumber ?? 'N/A',
          tenant?.name ?? 'N/A',
          lien.totalAmount.toStringAsFixed(2),
          lien.principalAmount.toStringAsFixed(2),
          lien.lateFees.toStringAsFixed(2),
          lien.lienNumber ?? '',
          lien.county ?? '',
        ].join(','));
      }

      return csv.toString();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Lien] Error exporting liens: $e');
      }
      rethrow;
    }
  }

  static String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}

/// Audit logging for liens
extension LienAuditService on AuditService {
  static Future<void> logLienCreated({
    required String facilityId,
    required String tenantId,
    required String lienId,
    required double amount,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await FirebaseFirestore.instance
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'lien.created',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': lienId,
        'entityType': 'lien',
        'entityId': lienId,
        'tenantId': tenantId,
        'details': {
          'amount': amount,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging lien creation: $e');
      }
    }
  }
}

