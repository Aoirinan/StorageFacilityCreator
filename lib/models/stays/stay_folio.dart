import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

class StayFolioLine {
  const StayFolioLine({
    required this.code,
    required this.label,
    this.qty = 1,
    this.unitCents = 0,
    this.amountCents = 0,
  });

  factory StayFolioLine.fromMap(Map<String, dynamic> d) => StayFolioLine(
        code: FolioLineCode.fromWire(d['code']),
        label: stayStr(d['label']),
        qty: stayInt(d['qty'], 1),
        unitCents: stayInt(d['unitCents']),
        amountCents: stayInt(d['amountCents']),
      );

  final FolioLineCode code;
  final String label;
  final int qty;
  final int unitCents;
  final int amountCents;
}

class StayFolioTaxLine {
  const StayFolioTaxLine({required this.code, required this.label, this.rateBps = 0, this.amountCents = 0});

  factory StayFolioTaxLine.fromMap(Map<String, dynamic> d) => StayFolioTaxLine(
        code: stayStr(d['code']),
        label: stayStr(d['label']),
        rateBps: stayInt(d['rateBps']),
        amountCents: stayInt(d['amountCents']),
      );

  final String code;
  final String label;
  final int rateBps;
  final int amountCents;
}

/// Amounts matched from the Airbnb CSV, summed.
class StayFolioAirbnb {
  const StayFolioAirbnb({
    this.grossCents = 0,
    this.hostFeeCents = 0,
    this.cleaningFeeCents = 0,
    this.taxRemittedCents = 0,
    this.netCents = 0,
    this.rowCount = 0,
    this.expectedOnly = false,
  });

  factory StayFolioAirbnb.fromMap(Map<String, dynamic> d) => StayFolioAirbnb(
        grossCents: stayInt(d['grossCents']),
        hostFeeCents: stayInt(d['hostFeeCents']),
        cleaningFeeCents: stayInt(d['cleaningFeeCents']),
        taxRemittedCents: stayInt(d['taxRemittedCents']),
        netCents: stayInt(d['netCents']),
        rowCount: stayInt(d['rowCount']),
        expectedOnly: stayTrue(d['expectedOnly']),
      );

  final int grossCents;
  final int hostFeeCents;
  final int cleaningFeeCents;
  final int taxRemittedCents;
  final int netCents;
  final int rowCount;

  /// Only the Reservations CSV's expected earnings are known so far.
  final bool expectedOnly;
}

/// facilities/{fid}/stayFolios/{stayId}: what a direct guest owes, in
/// integer cents. Owners and managers read it; callables write it.
class StayFolio {
  const StayFolio({
    required this.stayId,
    this.lines = const [],
    this.taxLines = const [],
    this.subtotalCents = 0,
    this.taxCents = 0,
    this.totalCents = 0,
    this.paidCents = 0,
    this.balanceCents = 0,
    this.quoteVersion = 0,
    this.quotedAt,
    this.adjustmentCents,
    this.adjustmentReason,
    this.airbnb,
    this.updatedAt,
  });

  factory StayFolio.fromFirestore(DocumentSnapshot<Object?> doc) => StayFolio.fromMap(doc.id, stayDocData(doc));

  factory StayFolio.fromMap(String stayId, Map<String, dynamic> d) {
    final adjustment = d['adjustment'] is Map ? stayMap(d['adjustment']) : null;
    return StayFolio(
      stayId: stayStr(d['stayId'], stayId),
      lines: stayMapList(d['lines']).map(StayFolioLine.fromMap).toList(),
      taxLines: stayMapList(d['taxLines']).map(StayFolioTaxLine.fromMap).toList(),
      subtotalCents: stayInt(d['subtotalCents']),
      taxCents: stayInt(d['taxCents']),
      totalCents: stayInt(d['totalCents']),
      paidCents: stayInt(d['paidCents']),
      balanceCents: stayInt(d['balanceCents']),
      quoteVersion: stayInt(d['quoteVersion']),
      quotedAt: stayTime(d['quotedAt']),
      adjustmentCents: adjustment == null ? null : stayIntOrNull(adjustment['cents']),
      adjustmentReason: adjustment == null ? null : stayStrOrNull(adjustment['reason']),
      airbnb: d['airbnb'] is Map ? StayFolioAirbnb.fromMap(stayMap(d['airbnb'])) : null,
      updatedAt: stayTime(d['updatedAt']),
    );
  }

  final String stayId;
  final List<StayFolioLine> lines;
  final List<StayFolioTaxLine> taxLines;
  final int subtotalCents;
  final int taxCents;
  final int totalCents;
  final int paidCents;
  final int balanceCents;
  final int quoteVersion;
  final DateTime? quotedAt;
  final int? adjustmentCents;
  final String? adjustmentReason;
  final StayFolioAirbnb? airbnb;
  final DateTime? updatedAt;
}
