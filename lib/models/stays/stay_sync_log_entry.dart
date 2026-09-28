import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/staySyncLog/{runId}: one channel sync's result, kept 30 days.
class StaySyncLogEntry {
  const StaySyncLogEntry({
    required this.id,
    required this.channelId,
    this.listingId = '',
    this.trigger = SyncTrigger.unknown,
    this.status = ChannelSyncStatus.unknown,
    this.httpStatus,
    this.created = 0,
    this.dateChanged = 0,
    this.restored = 0,
    this.missesAdvanced = 0,
    this.removed = 0,
    this.needsReview = 0,
    this.conflicts = 0,
    this.blocks = 0,
    this.durationMs = 0,
    this.finishedAt,
  });

  factory StaySyncLogEntry.fromFirestore(DocumentSnapshot<Object?> doc) =>
      StaySyncLogEntry.fromMap(doc.id, stayDocData(doc));

  factory StaySyncLogEntry.fromMap(String id, Map<String, dynamic> d) => StaySyncLogEntry(
        id: id,
        channelId: stayStr(d['channelId']),
        listingId: stayStr(d['listingId']),
        trigger: SyncTrigger.fromWire(d['trigger']),
        status: ChannelSyncStatus.fromWire(d['status']),
        httpStatus: stayIntOrNull(d['httpStatus']),
        created: stayInt(d['created']),
        dateChanged: stayInt(d['dateChanged']),
        restored: stayInt(d['restored']),
        missesAdvanced: stayInt(d['missesAdvanced']),
        removed: stayInt(d['removed']),
        needsReview: stayInt(d['needsReview']),
        conflicts: stayInt(d['conflicts']),
        blocks: stayInt(d['blocks']),
        durationMs: stayInt(d['durationMs']),
        finishedAt: stayTime(d['finishedAt']),
      );

  final String id;
  final String channelId;
  final String listingId;
  final SyncTrigger trigger;
  final ChannelSyncStatus status;
  final int? httpStatus;
  final int created;
  final int dateChanged;
  final int restored;
  final int missesAdvanced;
  final int removed;
  final int needsReview;
  final int conflicts;
  final int blocks;
  final int durationMs;
  final DateTime? finishedAt;
}
