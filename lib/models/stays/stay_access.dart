import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayAccess/{stayId}: a per-stay door or gate code. Staff
/// read it; owners and managers (and the sync, in phone-last-4 mode) write it.
class StayAccess {
  const StayAccess({
    required this.stayId,
    this.doorCode,
    this.gateCode,
    this.accessNotes = '',
    this.source = StayAccessSource.manual,
    this.updatedAt,
  });

  factory StayAccess.fromFirestore(DocumentSnapshot<Object?> doc) => StayAccess.fromMap(doc.id, stayDocData(doc));

  factory StayAccess.fromMap(String stayId, Map<String, dynamic> d) => StayAccess(
        stayId: stayId,
        doorCode: stayStrOrNull(d['doorCode']),
        gateCode: stayStrOrNull(d['gateCode']),
        accessNotes: stayStr(d['accessNotes']),
        source: d['source'] == null ? StayAccessSource.manual : StayAccessSource.fromWire(d['source']),
        updatedAt: stayTime(d['updatedAt']),
      );

  final String stayId;
  final String? doorCode;
  final String? gateCode;
  final String accessNotes;
  final StayAccessSource source;
  final DateTime? updatedAt;
}
