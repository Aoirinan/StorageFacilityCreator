import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayPrivate/{stayId}: the guest's full name, phone last
/// 4, profile link and private notes. Owners and managers only.
class StayPrivate {
  const StayPrivate({
    required this.stayId,
    this.guestProfileId,
    this.fullName,
    this.phoneLast4,
    this.privateNotes = '',
    this.updatedAt,
  });

  factory StayPrivate.fromFirestore(DocumentSnapshot<Object?> doc) => StayPrivate.fromMap(doc.id, stayDocData(doc));

  factory StayPrivate.fromMap(String stayId, Map<String, dynamic> d) => StayPrivate(
        stayId: stayId,
        guestProfileId: stayStrOrNull(d['guestProfileId']),
        fullName: stayStrOrNull(d['fullName']),
        phoneLast4: stayStrOrNull(d['phoneLast4']),
        privateNotes: stayStr(d['privateNotes']),
        updatedAt: stayTime(d['updatedAt']),
      );

  final String stayId;
  final String? guestProfileId;
  final String? fullName;
  final String? phoneLast4;
  final String privateNotes;
  final DateTime? updatedAt;
}
