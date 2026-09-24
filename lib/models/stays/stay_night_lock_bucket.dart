import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_fields.dart';

/// One night in a lock bucket: who holds it.
class NightClaim {
  const NightClaim({required this.holder, required this.hard, this.source = '', this.kind = '', this.echo = false});

  factory NightClaim.fromMap(Map<String, dynamic> d) => NightClaim(
        holder: stayStr(d['s']),
        hard: stayTrue(d['h']),
        source: stayStr(d['src']),
        kind: stayStr(d['k']),
        echo: stayTrue(d['e']),
      );

  /// A stayId, or 'blk:{channelId}' for a channel's soft block.
  final String holder;

  /// A booking or owner/maintenance block (hard), or a channel's "Not
  /// available" block (soft, which never conflicts).
  final bool hard;

  /// The stay's source, or the channel's provider.
  final String source;

  /// The stay's kind, or 'channel_block'.
  final String kind;

  /// A channel block that is only our own export echoed back.
  final bool echo;

  bool get isChannelBlock => holder.startsWith('blk:');

  String? get channelId => isChannelBlock ? holder.substring(4) : null;
}

/// facilities/{fid}/stayNightLocks/{listingId}_{YYYY-MM}: a cache of who
/// holds each night of one listing in one month, rebuilt by the server in
/// every stay write. Read-only for the app.
class StayNightLockBucket {
  const StayNightLockBucket({
    required this.id,
    required this.listingId,
    required this.month,
    this.nights = const {},
    this.digest = '',
    this.rebuiltAt,
  });

  factory StayNightLockBucket.fromFirestore(DocumentSnapshot<Object?> doc) =>
      StayNightLockBucket.fromMap(doc.id, stayDocData(doc));

  factory StayNightLockBucket.fromMap(String id, Map<String, dynamic> d) {
    final nights = <String, NightClaim>{};
    stayMap(d['nights']).forEach((date, value) {
      if (value is Map) nights[date] = NightClaim.fromMap(stayMap(value));
    });
    return StayNightLockBucket(
      id: id,
      listingId: stayStr(d['listingId']),
      month: stayStr(d['month']),
      nights: nights,
      digest: stayStr(d['digest']),
      rebuiltAt: stayTime(d['rebuiltAt']),
    );
  }

  final String id;
  final String listingId;

  /// 'YYYY-MM'.
  final String month;

  /// 'YYYY-MM-DD' → claim.
  final Map<String, NightClaim> nights;
  final String digest;
  final DateTime? rebuiltAt;
}
