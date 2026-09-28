import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayMessageTemplates/{templateId}: a copy-first message.
/// The owner copies, prints or opens her own mail or text app; nothing
/// sends it, and there is no auto-send setting in v1.
class StayMessageTemplate {
  const StayMessageTemplate({
    required this.id,
    required this.facilityId,
    required this.key,
    required this.name,
    required this.body,
    this.channelHint = TemplateChannelHint.unknown,
    this.listingIds = const [],
    this.seeded = false,
    this.updatedAt,
  });

  factory StayMessageTemplate.fromFirestore(DocumentSnapshot<Object?> doc) =>
      StayMessageTemplate.fromMap(doc.id, stayDocData(doc));

  factory StayMessageTemplate.fromMap(String id, Map<String, dynamic> d) => StayMessageTemplate(
        id: id,
        facilityId: stayStr(d['facilityId']),
        key: stayStr(d['key'], id),
        name: stayStr(d['name']),
        body: stayStr(d['body']),
        channelHint: TemplateChannelHint.fromWire(d['channelHint']),
        listingIds: stayStrList(d['listingIds']),
        seeded: stayTrue(d['seeded']),
        updatedAt: stayTime(d['updatedAt']),
      );

  final String id;
  final String facilityId;

  /// e.g. 'airbnb_check_in'; also the key in a stay's messageMarks.
  final String key;
  final String name;
  final String body;
  final TemplateChannelHint channelHint;

  /// Empty means every listing.
  final List<String> listingIds;
  final bool seeded;
  final DateTime? updatedAt;

  bool appliesTo(String listingId) => listingIds.isEmpty || listingIds.contains(listingId);
}
