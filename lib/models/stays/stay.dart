import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';
import 'package:sfcapp/utils/local_date.dart';

class StayExternalRef {
  const StayExternalRef({
    this.provider = ChannelProvider.unknown,
    this.uid,
    this.uidHistory = const [],
    this.confirmationCode,
    this.reservationUrl,
    this.summary,
  });

  factory StayExternalRef.fromMap(Map<String, dynamic> d) => StayExternalRef(
        provider: ChannelProvider.fromWire(d['provider']),
        uid: stayStrOrNull(d['uid']),
        uidHistory: stayStrList(d['uidHistory']),
        confirmationCode: stayStrOrNull(d['confirmationCode']),
        reservationUrl: stayStrOrNull(d['reservationUrl']),
        summary: stayStrOrNull(d['summary']),
      );

  final ChannelProvider provider;
  final String? uid;
  final List<String> uidHistory;
  final String? confirmationCode;

  /// Only ever an https Airbnb reservation link (the server drops anything else).
  final String? reservationUrl;
  final String? summary;
}

class StaySyncState {
  const StaySyncState({
    required this.channelId,
    this.firstSeenAt,
    this.lastSeenAt,
    this.missCount = 0,
    this.firstMissAt,
    this.lastMissAt,
    this.needsReview = false,
    this.agedOutAt,
    this.detached = false,
  });

  factory StaySyncState.fromMap(Map<String, dynamic> d) => StaySyncState(
        channelId: stayStr(d['channelId']),
        firstSeenAt: stayTime(d['firstSeenAt']),
        lastSeenAt: stayTime(d['lastSeenAt']),
        missCount: stayInt(d['missCount']),
        firstMissAt: stayTime(d['firstMissAt']),
        lastMissAt: stayTime(d['lastMissAt']),
        needsReview: stayTrue(d['needsReview']),
        agedOutAt: stayTime(d['agedOutAt']),
        detached: stayTrue(d['detached']),
      );

  final String channelId;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;
  final int missCount;
  final DateTime? firstMissAt;
  final DateTime? lastMissAt;
  final bool needsReview;
  final DateTime? agedOutAt;
  final bool detached;
}

class StayConflict {
  const StayConflict({
    this.stayIds = const [],
    this.nights = const [],
    this.detectedAt,
    this.acknowledgedAt,
    this.acknowledgedBy,
    this.note,
  });

  factory StayConflict.fromMap(Map<String, dynamic> d) => StayConflict(
        stayIds: stayStrList(d['stayIds']),
        nights: stayStrList(d['nights']),
        detectedAt: stayTime(d['detectedAt']),
        acknowledgedAt: stayTime(d['acknowledgedAt']),
        acknowledgedBy: stayStrOrNull(d['acknowledgedBy']),
        note: stayStrOrNull(d['note']),
      );

  /// The stays holding the nights this one lost.
  final List<String> stayIds;
  final List<String> nights;
  final DateTime? detectedAt;
  final DateTime? acknowledgedAt;
  final String? acknowledgedBy;
  final String? note;

  bool get isAcknowledged => acknowledgedAt != null;
}

/// facilities/{fid}/stays/{stayId}: one booking or block on a listing. No
/// personal data (a display name and party size only) and no money amounts.
/// Nights are facility-local 'YYYY-MM-DD' strings; checkOut is exclusive.
class Stay {
  const Stay({
    required this.id,
    required this.facilityId,
    required this.listingId,
    this.listingName = '',
    this.listingGroup = '',
    this.listingKind = StayListingKind.unknown,
    this.kind = StayKind.unknown,
    this.source = StaySource.unknown,
    this.origin = StayOrigin.unknown,
    this.status = StayStatus.unknown,
    this.arrivalState = StayArrivalState.upcoming,
    required this.checkIn,
    required this.checkOut,
    this.nights = 0,
    this.checkInTime = '',
    this.checkOutTime = '',
    this.guestDisplayName = '',
    this.adults = 0,
    this.children = 0,
    this.pets = 0,
    this.rvLengthFt,
    this.paymentStatus = StayPaymentStatus.none,
    this.external,
    this.sync,
    this.conflict,
    this.staffNotes = '',
    this.cleanerNotes = '',
    this.tags = const [],
    this.messageMarks = const {},
    this.turnoverTaskId,
    this.checkedInAt,
    this.checkedOutAt,
    this.cancelledAt,
    this.cancelledBy,
    this.cancelReason,
    this.requestId,
    this.version = 0,
    this.createdAtMs = 0,
    this.createdAt,
    this.updatedAt,
  });

  factory Stay.fromFirestore(DocumentSnapshot<Object?> doc) => Stay.fromMap(doc.id, stayDocData(doc));

  factory Stay.fromMap(String id, Map<String, dynamic> d) {
    final marks = <String, DateTime>{};
    stayMap(d['messageMarks']).forEach((key, value) {
      final at = stayTime(value);
      if (at != null) marks[key] = at;
    });
    return Stay(
      id: id,
      facilityId: stayStr(d['facilityId']),
      listingId: stayStr(d['listingId']),
      listingName: stayStr(d['listingName']),
      listingGroup: stayStr(d['listingGroup']),
      listingKind: StayListingKind.fromWire(d['listingKind']),
      kind: StayKind.fromWire(d['kind']),
      source: StaySource.fromWire(d['source']),
      origin: StayOrigin.fromWire(d['origin']),
      status: StayStatus.fromWire(d['status']),
      arrivalState: d['arrivalState'] == null
          ? StayArrivalState.upcoming
          : StayArrivalState.fromWire(d['arrivalState']),
      checkIn: stayStr(d['checkIn']),
      checkOut: stayStr(d['checkOut']),
      nights: stayInt(d['nights']),
      checkInTime: stayStr(d['checkInTime']),
      checkOutTime: stayStr(d['checkOutTime']),
      guestDisplayName: stayStr(d['guestDisplayName']),
      adults: stayInt(d['adults']),
      children: stayInt(d['children']),
      pets: stayInt(d['pets']),
      rvLengthFt: stayIntOrNull(d['rvLengthFt']),
      paymentStatus: d['paymentStatus'] == null
          ? StayPaymentStatus.none
          : StayPaymentStatus.fromWire(d['paymentStatus']),
      external: d['external'] is Map ? StayExternalRef.fromMap(stayMap(d['external'])) : null,
      sync: d['sync'] is Map ? StaySyncState.fromMap(stayMap(d['sync'])) : null,
      conflict: d['conflict'] is Map ? StayConflict.fromMap(stayMap(d['conflict'])) : null,
      staffNotes: stayStr(d['staffNotes']),
      cleanerNotes: stayStr(d['cleanerNotes']),
      tags: stayStrList(d['tags']),
      messageMarks: marks,
      turnoverTaskId: stayStrOrNull(d['turnoverTaskId']),
      checkedInAt: stayTime(d['checkedInAt']),
      checkedOutAt: stayTime(d['checkedOutAt']),
      cancelledAt: stayTime(d['cancelledAt']),
      cancelledBy: stayStrOrNull(d['cancelledBy']),
      cancelReason: stayStrOrNull(d['cancelReason']),
      requestId: stayStrOrNull(d['requestId']),
      version: stayInt(d['version']),
      createdAtMs: stayInt(d['createdAtMs']),
      createdAt: stayTime(d['createdAt']),
      updatedAt: stayTime(d['updatedAt']),
    );
  }

  final String id;
  final String facilityId;
  final String listingId;
  final String listingName;
  final String listingGroup;
  final StayListingKind listingKind;
  final StayKind kind;
  final StaySource source;
  final StayOrigin origin;
  final StayStatus status;
  final StayArrivalState arrivalState;

  /// 'YYYY-MM-DD', facility-local.
  final String checkIn;

  /// 'YYYY-MM-DD', exclusive.
  final String checkOut;
  final int nights;

  /// 'HH:mm'.
  final String checkInTime;
  final String checkOutTime;

  /// ≤60, e.g. 'Jane D.'; empty until a name is known.
  final String guestDisplayName;
  final int adults;
  final int children;
  final int pets;
  final int? rvLengthFt;
  final StayPaymentStatus paymentStatus;
  final StayExternalRef? external;
  final StaySyncState? sync;
  final StayConflict? conflict;
  final String staffNotes;
  final String cleanerNotes;
  final List<String> tags;

  /// templateKey → when it was copied or opened.
  final Map<String, DateTime> messageMarks;
  final String? turnoverTaskId;
  final DateTime? checkedInAt;
  final DateTime? checkedOutAt;
  final DateTime? cancelledAt;
  final String? cancelledBy;
  final String? cancelReason;
  final String? requestId;
  final int version;
  final int createdAtMs;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  LocalDate? get checkInDate => LocalDate.tryParse(checkIn);

  LocalDate? get checkOutDate => LocalDate.tryParse(checkOut);

  /// Holds its nights (confirmed or in conflict).
  bool get isActive => status.isActive;

  bool get isReservation => kind == StayKind.reservation;

  bool get isBlock => kind.isBlock;

  /// Dates are the channel's: changed in Airbnb, not in SFC.
  bool get isFeedOwned => origin == StayOrigin.feed;

  bool get needsReview => sync?.needsReview == true;

  /// Whether this stay holds [night] ('YYYY-MM-DD'): checkIn ≤ night < checkOut.
  bool coversNight(String night) => checkIn.compareTo(night) <= 0 && night.compareTo(checkOut) < 0;

  /// The name to show: the display name, else "Airbnb guest (…X4B2)" from the
  /// confirmation code (never a phone number: that is owner/manager-only).
  String get guestLabel {
    final name = guestDisplayName.trim();
    if (name.isNotEmpty) return name;
    if (kind == StayKind.ownerBlock) return 'Owner block';
    if (kind == StayKind.maintenanceBlock) return 'Maintenance block';
    final code = external?.confirmationCode;
    final channel = switch (source) {
      StaySource.airbnb => 'Airbnb guest',
      StaySource.vrbo => 'VRBO guest',
      StaySource.booking => 'Booking.com guest',
      StaySource.hipcamp => 'Hipcamp guest',
      _ => 'Guest',
    };
    if (code != null && code.length >= 4) return '$channel (…${code.substring(code.length - 4)})';
    return channel;
  }
}
