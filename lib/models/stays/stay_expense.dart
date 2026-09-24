import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayExpenses/{exp_{requestId}}: a Stays expense
/// (cleaning pay, supplies, …), voided rather than deleted.
class StayExpense {
  const StayExpense({
    required this.id,
    required this.facilityId,
    this.listingId,
    this.category = StayExpenseCategory.unknown,
    this.amountCents = 0,
    this.spentDate = '',
    this.spentMonth = '',
    this.vendor = '',
    this.memo = '',
    this.receiptPath,
    this.status = StayMoneyEntryStatus.unknown,
    this.voidedAt,
    this.voidReason,
    this.createdAt,
    this.createdBy,
  });

  factory StayExpense.fromFirestore(DocumentSnapshot<Object?> doc) => StayExpense.fromMap(doc.id, stayDocData(doc));

  factory StayExpense.fromMap(String id, Map<String, dynamic> d) => StayExpense(
        id: id,
        facilityId: stayStr(d['facilityId']),
        listingId: stayStrOrNull(d['listingId']),
        category: StayExpenseCategory.fromWire(d['category']),
        amountCents: stayInt(d['amountCents']),
        spentDate: stayStr(d['spentDate']),
        spentMonth: stayStr(d['spentMonth']),
        vendor: stayStr(d['vendor']),
        memo: stayStr(d['memo']),
        receiptPath: stayStrOrNull(d['receiptPath']),
        status: StayMoneyEntryStatus.fromWire(d['status']),
        voidedAt: stayTime(d['voidedAt']),
        voidReason: stayStrOrNull(d['voidReason']),
        createdAt: stayTime(d['createdAt']),
        createdBy: stayStrOrNull(d['createdBy']),
      );

  final String id;
  final String facilityId;
  final String? listingId;
  final StayExpenseCategory category;
  final int amountCents;
  final String spentDate;
  final String spentMonth;
  final String vendor;
  final String memo;
  final String? receiptPath;
  final StayMoneyEntryStatus status;
  final DateTime? voidedAt;
  final String? voidReason;
  final DateTime? createdAt;
  final String? createdBy;

  bool get isPosted => status == StayMoneyEntryStatus.posted;
}
