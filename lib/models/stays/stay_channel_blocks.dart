import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

class ChannelBlockRange {
  const ChannelBlockRange({required this.checkIn, required this.checkOut, this.echo = false});

  factory ChannelBlockRange.fromMap(Map<String, dynamic> d) => ChannelBlockRange(
        checkIn: stayStr(d['checkIn']),
        checkOut: stayStr(d['checkOut']),
        echo: stayTrue(d['echo']),
      );

  /// 'YYYY-MM-DD'.
  final String checkIn;

  /// 'YYYY-MM-DD', exclusive.
  final String checkOut;

  /// Our own export echoed back by the channel; drawn fainter.
  final bool echo;
}

/// facilities/{fid}/stayChannelBlocks/{channelId}: one feed's imported "Not
/// available" ranges, replaced as a set on every successful sync. Soft: they
/// fill free nights only and never conflict.
class StayChannelBlocks {
  const StayChannelBlocks({
    required this.channelId,
    required this.listingId,
    this.provider = ChannelProvider.unknown,
    this.ranges = const [],
    this.syncedAt,
  });

  factory StayChannelBlocks.fromFirestore(DocumentSnapshot<Object?> doc) =>
      StayChannelBlocks.fromMap(doc.id, stayDocData(doc));

  factory StayChannelBlocks.fromMap(String channelId, Map<String, dynamic> d) => StayChannelBlocks(
        channelId: channelId,
        listingId: stayStr(d['listingId']),
        provider: ChannelProvider.fromWire(d['provider']),
        ranges: stayMapList(d['ranges']).map(ChannelBlockRange.fromMap).toList(),
        syncedAt: stayTime(d['syncedAt']),
      );

  final String channelId;
  final String listingId;
  final ChannelProvider provider;
  final List<ChannelBlockRange> ranges;
  final DateTime? syncedAt;
}
