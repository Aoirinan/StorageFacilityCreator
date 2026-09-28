import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayImportBatches/{sha256(csvText)}: one Airbnb CSV
/// import. Re-importing the same file finds this doc and adds nothing.
class StayImportBatch {
  const StayImportBatch({
    required this.id,
    this.kind = StayImportBatchKind.unknown,
    this.fileName = '',
    this.rowCount = 0,
    this.created = 0,
    this.skippedDuplicate = 0,
    this.needsReview = 0,
    this.rejected = 0,
    this.matchedStays = 0,
    this.createdStays = 0,
    this.unmatchedListings = const [],
    this.grossCents = 0,
    this.channelFeeCents = 0,
    this.netCents = 0,
    this.taxCents = 0,
    this.payoutCents = 0,
    this.dateFrom,
    this.dateTo,
    this.status = StayImportBatchStatus.unknown,
    this.committedAt,
  });

  factory StayImportBatch.fromFirestore(DocumentSnapshot<Object?> doc) =>
      StayImportBatch.fromMap(doc.id, stayDocData(doc));

  factory StayImportBatch.fromMap(String id, Map<String, dynamic> d) {
    final totals = stayMap(d['totals']);
    final range = stayMap(d['dateRange']);
    return StayImportBatch(
      id: id,
      kind: StayImportBatchKind.fromWire(d['kind']),
      fileName: stayStr(d['fileName']),
      rowCount: stayInt(d['rowCount']),
      created: stayInt(d['created']),
      skippedDuplicate: stayInt(d['skippedDuplicate']),
      needsReview: stayInt(d['needsReview']),
      rejected: stayInt(d['rejected']),
      matchedStays: stayInt(d['matchedStays']),
      createdStays: stayInt(d['createdStays']),
      unmatchedListings: stayStrList(d['unmatchedListings']),
      grossCents: stayInt(totals['grossCents']),
      channelFeeCents: stayInt(totals['channelFeeCents']),
      netCents: stayInt(totals['netCents']),
      taxCents: stayInt(totals['taxCents']),
      payoutCents: stayInt(totals['payoutCents']),
      dateFrom: stayStrOrNull(range['from']),
      dateTo: stayStrOrNull(range['to']),
      status: StayImportBatchStatus.fromWire(d['status']),
      committedAt: stayTime(d['committedAt']),
    );
  }

  final String id;
  final StayImportBatchKind kind;
  final String fileName;
  final int rowCount;
  final int created;
  final int skippedDuplicate;
  final int needsReview;
  final int rejected;
  final int matchedStays;
  final int createdStays;
  final List<String> unmatchedListings;
  final int grossCents;
  final int channelFeeCents;
  final int netCents;
  final int taxCents;
  final int payoutCents;
  final String? dateFrom;
  final String? dateTo;
  final StayImportBatchStatus status;
  final DateTime? committedAt;
}
