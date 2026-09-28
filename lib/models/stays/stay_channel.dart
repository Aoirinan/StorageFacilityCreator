import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

class StayChannelSyncHealth {
  const StayChannelSyncHealth({
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.lastChangedAt,
    this.lastStatus = ChannelSyncStatus.unknown,
    this.lastHttpStatus,
    this.lastErrorCode,
    this.consecutiveFailures = 0,
    this.eventCount = 0,
    this.futureReservationCount = 0,
    this.blockCount = 0,
    this.firstSyncCompletedAt,
    this.suspiciousSince,
  });

  factory StayChannelSyncHealth.fromMap(Map<String, dynamic> d) => StayChannelSyncHealth(
        lastAttemptAt: stayTime(d['lastAttemptAt']),
        lastSuccessAt: stayTime(d['lastSuccessAt']),
        lastChangedAt: stayTime(d['lastChangedAt']),
        lastStatus: ChannelSyncStatus.fromWire(d['lastStatus']),
        lastHttpStatus: stayIntOrNull(d['lastHttpStatus']),
        lastErrorCode: stayStrOrNull(d['lastErrorCode']),
        consecutiveFailures: stayInt(d['consecutiveFailures']),
        eventCount: stayInt(d['eventCount']),
        futureReservationCount: stayInt(d['futureReservationCount']),
        blockCount: stayInt(d['blockCount']),
        firstSyncCompletedAt: stayTime(d['firstSyncCompletedAt']),
        suspiciousSince: stayTime(d['suspiciousSince']),
      );

  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final DateTime? lastChangedAt;
  final ChannelSyncStatus lastStatus;
  final int? lastHttpStatus;
  final String? lastErrorCode;
  final int consecutiveFailures;
  final int eventCount;
  final int futureReservationCount;
  final int blockCount;
  final DateTime? firstSyncCompletedAt;
  final DateTime? suspiciousSince;
}

/// facilities/{fid}/stayChannels/{channelId}: one imported calendar feed and
/// its sync health. Owners and managers read it. The feed URL itself is a
/// bearer secret kept in secret/current, which no client can read.
class StayChannel {
  const StayChannel({
    required this.id,
    required this.listingId,
    this.provider = ChannelProvider.unknown,
    this.label = '',
    this.active = false,
    this.importBlocks = true,
    this.urlHost = '',
    this.urlFingerprint = '',
    this.sync = const StayChannelSyncHealth(),
    this.createdAt,
  });

  factory StayChannel.fromFirestore(DocumentSnapshot<Object?> doc) => StayChannel.fromMap(doc.id, stayDocData(doc));

  factory StayChannel.fromMap(String id, Map<String, dynamic> d) => StayChannel(
        id: id,
        listingId: stayStr(d['listingId']),
        provider: ChannelProvider.fromWire(d['provider']),
        label: stayStr(d['label']),
        active: stayTrue(d['active']),
        importBlocks: d['importBlocks'] != false,
        urlHost: stayStr(d['urlHost']),
        urlFingerprint: stayStr(d['urlFingerprint']),
        sync: StayChannelSyncHealth.fromMap(stayMap(d['sync'])),
        createdAt: stayTime(d['createdAt']),
      );

  final String id;
  final String listingId;
  final ChannelProvider provider;
  final String label;
  final bool active;
  final bool importBlocks;
  final String urlHost;
  final String urlFingerprint;
  final StayChannelSyncHealth sync;
  final DateTime? createdAt;

  /// Not synced successfully for more than [maxAge] (default 6 hours) as of [now].
  bool isStale(DateTime now, {Duration maxAge = const Duration(hours: 6)}) {
    final last = sync.lastSuccessAt;
    return last == null || now.difference(last) > maxAge;
  }
}
