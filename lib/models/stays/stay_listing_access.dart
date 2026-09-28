import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayListingAccess/{listingId}: wifi, codes, directions
/// and house rules. Staff read it (cleaners need the codes); owners and
/// managers write it; viewers and the public never see it, and it is never
/// in an export feed.
class StayListingAccess {
  const StayListingAccess({
    required this.facilityId,
    required this.listingId,
    this.wifiName = '',
    this.wifiPassword = '',
    this.staticDoorCode = '',
    this.lockboxCode = '',
    this.gateCode = '',
    this.parkingNotes = '',
    this.trashNotes = '',
    this.checkoutInstructions = '',
    this.directionsUrl = '',
    this.houseRules = '',
    this.updatedAt,
    this.updatedBy,
  });

  factory StayListingAccess.empty(String facilityId, String listingId) =>
      StayListingAccess(facilityId: facilityId, listingId: listingId);

  factory StayListingAccess.fromFirestore(DocumentSnapshot<Object?> doc, {required String facilityId}) => doc.exists
      ? StayListingAccess.fromMap(stayDocData(doc), facilityId: facilityId, listingId: doc.id)
      : StayListingAccess.empty(facilityId, doc.id);

  factory StayListingAccess.fromMap(Map<String, dynamic> d, {required String facilityId, required String listingId}) =>
      StayListingAccess(
        facilityId: stayStr(d['facilityId'], facilityId),
        listingId: stayStr(d['listingId'], listingId),
        wifiName: stayStr(d['wifiName']),
        wifiPassword: stayStr(d['wifiPassword']),
        staticDoorCode: stayStr(d['staticDoorCode']),
        lockboxCode: stayStr(d['lockboxCode']),
        gateCode: stayStr(d['gateCode']),
        parkingNotes: stayStr(d['parkingNotes']),
        trashNotes: stayStr(d['trashNotes']),
        checkoutInstructions: stayStr(d['checkoutInstructions']),
        directionsUrl: stayStr(d['directionsUrl']),
        houseRules: stayStr(d['houseRules']),
        updatedAt: stayTime(d['updatedAt']),
        updatedBy: stayStrOrNull(d['updatedBy']),
      );

  final String facilityId;
  final String listingId;
  final String wifiName;
  final String wifiPassword;
  final String staticDoorCode;
  final String lockboxCode;
  final String gateCode;
  final String parkingNotes;
  final String trashNotes;
  final String checkoutInstructions;
  final String directionsUrl;
  final String houseRules;
  final DateTime? updatedAt;
  final String? updatedBy;

  /// The whitelisted string fields the rules accept (updatedAt/By are added by the repository).
  Map<String, String> toEditableMap() => {
        'wifiName': wifiName,
        'wifiPassword': wifiPassword,
        'staticDoorCode': staticDoorCode,
        'lockboxCode': lockboxCode,
        'gateCode': gateCode,
        'parkingNotes': parkingNotes,
        'trashNotes': trashNotes,
        'checkoutInstructions': checkoutInstructions,
        'directionsUrl': directionsUrl,
        'houseRules': houseRules,
      };
}
