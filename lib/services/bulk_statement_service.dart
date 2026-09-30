import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/services/pdf_letterhead.dart';
import 'package:sfcapp/services/statement_service.dart';
import 'package:sfcapp/utils/bulk_statements.dart';

/// Reads whole ledgers for many tenants at once. A seam, like the bulk Paid
/// through reader, so tests can hand in ledgers without Firestore.
abstract class StatementLedgerReader {
  /// Every ledger entry of each of [tenantIds], keyed by tenant id. A tenant
  /// with no entries has an empty list.
  Future<Map<String, List<LedgerEntry>>> read(
      String facilityId, List<String> tenantIds);
}

/// facilities/{fid}/ledgers where tenantId in (up to 30 ids), one query per
/// chunk: three reads for eighty tenants instead of eighty, and no orderBy,
/// so no composite index is needed and the statement sorts in memory. No
/// row cap either (LedgerService.getLedgerEntries stops at 1000 newest
/// first), so the balances are exact.
class FirestoreStatementLedgerReader implements StatementLedgerReader {
  final FirebaseFirestore _db;
  FirestoreStatementLedgerReader([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;

  @override
  Future<Map<String, List<LedgerEntry>>> read(
      String facilityId, List<String> tenantIds) async {
    final ledgers =
        _db.collection('facilities').doc(facilityId).collection('ledgers');
    final out = <String, List<LedgerEntry>>{
      for (final id in tenantIds) id: <LedgerEntry>[],
    };
    for (final chunk in chunkIds(tenantIds, 30)) {
      final snap = await ledgers.where('tenantId', whereIn: chunk).get();
      for (final doc in snap.docs) {
        final entry = LedgerEntry.fromFirestore(doc);
        (out[entry.tenantId] ??= []).add(entry);
      }
    }
    return out;
  }
}

/// The owner pressed Cancel (or closed the dialog) part way through a build.
class BulkStatementsCancelled implements Exception {
  const BulkStatementsCancelled();

  @override
  String toString() => 'BulkStatementsCancelled';
}

/// A finished bulk build: one PDF holding every statement.
class BulkStatementsPdf {
  final Uint8List bytes;
  final int statementCount;

  /// Pages in the PDF, blank duplex pages included.
  final int pageCount;

  const BulkStatementsPdf({
    required this.bytes,
    required this.statementCount,
    required this.pageCount,
  });
}

class BulkStatementService {
  BulkStatementService._();

  /// Every statement in [plan] in one PDF, in plan order, each starting on
  /// a new page. The pdf package cannot merge documents, so one
  /// pw.Document takes a StatementService.buildStatementPage per job; the
  /// logo is fetched once ([PdfLetterhead.loadLogo], unless [logo] is
  /// given) and embedded once, since an ImageProvider caches its image per
  /// document.
  ///
  /// [printedOn] is the date line on every statement; [period] the span
  /// each covers (the same one the plan's lines were cut to). With
  /// [duplex], a statement with an odd number of pages gets a blank page
  /// after it, so on a printer printing both sides the next tenant's
  /// statement never starts on the back of this one.
  ///
  /// Laying out a page is synchronous, so the build yields to the event
  /// loop between statements: [onProgress] gets (done, total) after each
  /// one, and [isCancelled] is asked before each; a true answer throws
  /// [BulkStatementsCancelled] and nothing is returned.
  ///
  /// [compress] off writes the page text in the clear, for tests that read
  /// the bytes back.
  static Future<BulkStatementsPdf> buildBulkStatementsPdf(
    BulkStatementPlan plan,
    FacilityModel facility, {
    pw.ImageProvider? logo,
    required DateTime printedOn,
    required StatementPeriod period,
    bool duplex = false,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    bool compress = true,
  }) async {
    logo ??= await PdfLetterhead.loadLogo(facility);
    final doc = pw.Document(compress: compress);
    final pages = doc.document.pdfPageList.pages;
    final total = plan.jobs.length;
    var done = 0;
    for (final job in plan.jobs) {
      if (isCancelled?.call() ?? false) throw const BulkStatementsCancelled();
      final before = pages.length;
      doc.addPage(StatementService.buildStatementPage(
        lines: job.lines,
        tenant: job.holder,
        unitLabels: job.unitLabels,
        facility: facility,
        logo: logo,
        printedOn: printedOn,
        startDate: period.startDate,
        endDate: period.endDate,
        // Every record's, so a combined statement notes the deposits held
        // on all its units, summed.
        securityDeposits: [for (final t in job.tenants) t.securityDeposit],
      ));
      if (duplex && (pages.length - before).isOdd) {
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.letter,
          build: (_) => pw.Container(),
        ));
      }
      done++;
      onProgress?.call(done, total);
      // Let the frame paint the progress and the Cancel button register.
      await Future<void>.delayed(Duration.zero);
    }
    if (isCancelled?.call() ?? false) throw const BulkStatementsCancelled();
    final bytes = await doc.save();
    return BulkStatementsPdf(
      bytes: bytes,
      statementCount: total,
      pageCount: pages.length,
    );
  }
}
