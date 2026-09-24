import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

class StayGuestVehicle {
  const StayGuestVehicle({this.plate, this.state, this.make, this.rvType, this.rvLengthFt});

  factory StayGuestVehicle.fromMap(Map<String, dynamic> d) => StayGuestVehicle(
        plate: stayStrOrNull(d['plate']),
        state: stayStrOrNull(d['state']),
        make: stayStrOrNull(d['make']),
        rvType: stayStrOrNull(d['rvType']),
        rvLengthFt: stayIntOrNull(d['rvLengthFt']),
      );

  final String? plate;
  final String? state;
  final String? make;
  final String? rvType;
  final int? rvLengthFt;

  Map<String, dynamic> toMap() => {
        'plate': plate,
        'state': state,
        'make': make,
        'rvType': rvType,
        'rvLengthFt': rvLengthFt,
      };
}

/// Captured now, used by nothing in v1 (no guest messaging).
class StayGuestConsent {
  const StayGuestConsent({this.email = false, this.sms = false, this.method = ConsentMethod.unknown, this.recordedAt, this.recordedBy});

  factory StayGuestConsent.fromMap(Map<String, dynamic> d) => StayGuestConsent(
        email: stayTrue(d['email']),
        sms: stayTrue(d['sms']),
        method: ConsentMethod.fromWire(d['method']),
        recordedAt: stayTime(d['recordedAt']),
        recordedBy: stayStrOrNull(d['recordedBy']),
      );

  final bool email;
  final bool sms;
  final ConsentMethod method;
  final DateTime? recordedAt;
  final String? recordedBy;
}

/// facilities/{fid}/stayGuestProfiles/{profileId}: a returning guest.
/// Personal data, so owners and managers only; deletable on request.
class StayGuestProfile {
  const StayGuestProfile({
    required this.id,
    required this.facilityId,
    required this.name,
    this.phoneE164,
    this.email,
    this.vehicle,
    this.notes = '',
    this.doNotRent = false,
    this.doNotRentReason,
    this.consent,
    this.stayCount = 0,
    this.lastStayAt,
    this.updatedAt,
  });

  factory StayGuestProfile.fromFirestore(DocumentSnapshot<Object?> doc) =>
      StayGuestProfile.fromMap(doc.id, stayDocData(doc));

  factory StayGuestProfile.fromMap(String id, Map<String, dynamic> d) => StayGuestProfile(
        id: id,
        facilityId: stayStr(d['facilityId']),
        name: stayStr(d['name']),
        phoneE164: stayStrOrNull(d['phoneE164']),
        email: stayStrOrNull(d['email']),
        vehicle: d['vehicle'] is Map ? StayGuestVehicle.fromMap(stayMap(d['vehicle'])) : null,
        notes: stayStr(d['notes']),
        doNotRent: stayTrue(d['doNotRent']),
        doNotRentReason: stayStrOrNull(d['doNotRentReason']),
        consent: d['consent'] is Map ? StayGuestConsent.fromMap(stayMap(d['consent'])) : null,
        stayCount: stayInt(d['stayCount']),
        lastStayAt: stayTime(d['lastStayAt']),
        updatedAt: stayTime(d['updatedAt']),
      );

  final String id;
  final String facilityId;
  final String name;
  final String? phoneE164;
  final String? email;
  final StayGuestVehicle? vehicle;
  final String notes;

  /// Facility-local do-not-rent flag; booking such a guest needs an explicit acknowledgment.
  final bool doNotRent;
  final String? doNotRentReason;
  final StayGuestConsent? consent;
  final int stayCount;
  final DateTime? lastStayAt;
  final DateTime? updatedAt;
}
