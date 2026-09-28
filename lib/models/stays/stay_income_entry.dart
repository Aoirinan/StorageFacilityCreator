import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayIncome/{entryId}: the append-only stay money journal
/// (integer cents, signed). Owners and managers read it; only callables
/// write it. It is combined with storage income only in reports, never in
/// the rent roll. netCents = gross − channel fee − pass-through tax.
class StayIncomeEntry {
  const StayIncomeEntry({
    required this.id,
    required this.facilityId,
    this.listingId,
    this.stayId,
    this.guestName,
    this.source = StayIncomeSource.unknown,
    this.method = StayIncomeMethod.unknown,
    this.kind = StayIncomeKind.unknown,
    this.countsAsIncome = false,
    this.grossCents = 0,
    this.channelFeeCents = 0,
    this.cleaningFeeCents = 0,
    this.taxPassThroughCents = 0,
    this.taxRemittedByChannelCents = 0,
    this.netCents = 0,
    this.receivedDate = '',
    this.receivedMonth = '',
    this.receivedAt,
    this.stayStart,
    this.stayEnd,
    this.nights,
    this.confirmationCode,
    this.referenceCode,
    this.memo = '',
    this.importBatchId,
    this.status = StayMoneyEntryStatus.unknown,
    this.voidedAt,
    this.voidReason,
    this.createdAt,
    this.createdBy,
  });

  factory StayIncomeEntry.fromFirestore(DocumentSnapshot<Object?> doc) =>
      StayIncomeEntry.fromMap(doc.id, stayDocData(doc));

  factory StayIncomeEntry.fromMap(String id, Map<String, dynamic> d) {
    final ref = stayMap(d['externalRef']);
    return StayIncomeEntry(
      id: id,
      facilityId: stayStr(d['facilityId']),
      listingId: stayStrOrNull(d['listingId']),
      stayId: stayStrOrNull(d['stayId']),
      guestName: stayStrOrNull(d['guestName']),
      source: StayIncomeSource.fromWire(d['source']),
      method: StayIncomeMethod.fromWire(d['method']),
      kind: StayIncomeKind.fromWire(d['kind']),
      countsAsIncome: stayTrue(d['countsAsIncome']),
      grossCents: stayInt(d['grossCents']),
      channelFeeCents: stayInt(d['channelFeeCents']),
      cleaningFeeCents: stayInt(d['cleaningFeeCents']),
      taxPassThroughCents: stayInt(d['taxPassThroughCents']),
      taxRemittedByChannelCents: stayInt(d['taxRemittedByChannelCents']),
      netCents: stayInt(d['netCents']),
      receivedDate: stayStr(d['receivedDate']),
      receivedMonth: stayStr(d['receivedMonth']),
      receivedAt: stayTime(d['receivedAt']),
      stayStart: stayStrOrNull(d['stayStart']),
      stayEnd: stayStrOrNull(d['stayEnd']),
      nights: stayIntOrNull(d['nights']),
      confirmationCode: stayStrOrNull(ref['confirmationCode']),
      referenceCode: stayStrOrNull(ref['referenceCode']),
      memo: stayStr(d['memo']),
      importBatchId: stayStrOrNull(d['importBatchId']),
      status: StayMoneyEntryStatus.fromWire(d['status']),
      voidedAt: stayTime(d['voidedAt']),
      voidReason: stayStrOrNull(d['voidReason']),
      createdAt: stayTime(d['createdAt']),
      createdBy: stayStrOrNull(d['createdBy']),
    );
  }

  final String id;
  final String facilityId;
  final String? listingId;
  final String? stayId;
  final String? guestName;
  final StayIncomeSource source;
  final StayIncomeMethod method;
  final StayIncomeKind kind;

  /// False for payout and channel-tax rows, which are never income.
  final bool countsAsIncome;
  final int grossCents;
  final int channelFeeCents;
  final int cleaningFeeCents;
  final int taxPassThroughCents;
  final int taxRemittedByChannelCents;
  final int netCents;
  final String receivedDate;
  final String receivedMonth;
  final DateTime? receivedAt;
  final String? stayStart;
  final String? stayEnd;
  final int? nights;
  final String? confirmationCode;
  final String? referenceCode;
  final String memo;
  final String? importBatchId;
  final StayMoneyEntryStatus status;
  final DateTime? voidedAt;
  final String? voidReason;
  final DateTime? createdAt;
  final String? createdBy;

  /// Counts in income totals: posted and marked as income.
  bool get isCountedIncome => status == StayMoneyEntryStatus.posted && countsAsIncome;
}
