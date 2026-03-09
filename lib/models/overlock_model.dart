import 'package:cloud_firestore/cloud_firestore.dart';

/// Last action taken on overlock (OVERLOCKED or REMOVED).
enum OverlockAction {
  overlocked,
  removed,
}

/// Overlock state stored on unit document: overlock: { ... }
class OverlockInfo {
  final bool isOverlocked;
  final DateTime? updatedAt;
  final String? updatedByUid;
  final String? updatedByName;
  final String? reasonNote;
  final OverlockAction? lastAction;

  const OverlockInfo({
    required this.isOverlocked,
    this.updatedAt,
    this.updatedByUid,
    this.updatedByName,
    this.reasonNote,
    this.lastAction,
  });

  factory OverlockInfo.fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return const OverlockInfo(isOverlocked: false);
    }
    OverlockAction? action;
    final last = data['lastAction'] as String?;
    if (last == 'OVERLOCKED') {
      action = OverlockAction.overlocked;
    } else if (last == 'REMOVED') {
      action = OverlockAction.removed;
    }
    return OverlockInfo(
      isOverlocked: data['isOverlocked'] == true,
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      updatedByUid: data['updatedByUid'] as String?,
      updatedByName: data['updatedByName'] as String?,
      reasonNote: data['reasonNote'] as String?,
      lastAction: action,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'isOverlocked': isOverlocked,
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'updatedByUid': updatedByUid,
      'updatedByName': updatedByName,
      'reasonNote': reasonNote,
      'lastAction': lastAction == OverlockAction.overlocked
          ? 'OVERLOCKED'
          : (lastAction == OverlockAction.removed ? 'REMOVED' : null),
    };
  }
}

/// Single event in facilities/{facilityId}/units/{unitId}/overlockEvents/{eventId}
class OverlockEventModel {
  final String id;
  final String action; // "OVERLOCKED" | "REMOVED"
  final DateTime at;
  final String byUid;
  final String? byName;
  final String? note;
  final String? tenantId;
  final String? tenantName;
  final String? bulkBatchId;

  const OverlockEventModel({
    required this.id,
    required this.action,
    required this.at,
    required this.byUid,
    this.byName,
    this.note,
    this.tenantId,
    this.tenantName,
    this.bulkBatchId,
  });

  factory OverlockEventModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return OverlockEventModel(
      id: doc.id,
      action: data['action'] as String? ?? '',
      at: (data['at'] as Timestamp?)?.toDate() ?? DateTime.now(),
      byUid: data['byUid'] as String? ?? '',
      byName: data['byName'] as String?,
      note: data['note'] as String?,
      tenantId: data['tenantId'] as String?,
      tenantName: data['tenantName'] as String?,
      bulkBatchId: data['bulkBatchId'] as String?,
    );
  }
}
