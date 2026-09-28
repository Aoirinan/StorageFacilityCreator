import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

class StayListingCapacity {
  const StayListingCapacity({
    this.maxGuests = 0,
    this.bedrooms = 0,
    this.beds = 0,
    this.bathrooms = 0,
    this.petsAllowed = false,
  });

  factory StayListingCapacity.fromMap(Map<String, dynamic> d) => StayListingCapacity(
        maxGuests: stayInt(d['maxGuests']),
        bedrooms: stayInt(d['bedrooms']),
        beds: stayInt(d['beds']),
        bathrooms: stayNum(d['bathrooms']),
        petsAllowed: stayTrue(d['petsAllowed']),
      );

  final int maxGuests;
  final int bedrooms;
  final int beds;
  final double bathrooms;
  final bool petsAllowed;

  Map<String, dynamic> toMap() => {
        'maxGuests': maxGuests,
        'bedrooms': bedrooms,
        'beds': beds,
        'bathrooms': bathrooms,
        'petsAllowed': petsAllowed,
      };
}

class StayListingRv {
  const StayListingRv({
    this.hookup = RvHookup.unknown,
    this.amps = const [],
    this.maxLengthFt,
    this.pullThrough = false,
    this.surface,
  });

  factory StayListingRv.fromMap(Map<String, dynamic> d) => StayListingRv(
        hookup: RvHookup.fromWire(d['hookup']),
        amps: d['amps'] is List ? (d['amps'] as List).map(stayIntOrNull).whereType<int>().toList() : const [],
        maxLengthFt: stayIntOrNull(d['maxLengthFt']),
        pullThrough: stayTrue(d['pullThrough']),
        surface: stayStrOrNull(d['surface']),
      );

  final RvHookup hookup;
  final List<int> amps;
  final int? maxLengthFt;
  final bool pullThrough;
  final String? surface;

  Map<String, dynamic> toMap() => {
        'hookup': hookup.wire,
        'amps': amps,
        'maxLengthFt': maxLengthFt,
        'pullThrough': pullThrough,
        'surface': surface,
      };
}

class StayListingRates {
  const StayListingRates({
    this.nightly = 0,
    this.weekendNightly,
    this.weeklyNightly,
    this.cleaningFee = 0,
    this.petFee = 0,
    this.extraGuestFee = 0,
    this.extraGuestAfter = 0,
  });

  factory StayListingRates.fromMap(Map<String, dynamic> d) => StayListingRates(
        nightly: stayInt(d['nightly']),
        weekendNightly: stayIntOrNull(d['weekendNightly']),
        weeklyNightly: stayIntOrNull(d['weeklyNightly']),
        cleaningFee: stayInt(d['cleaningFee']),
        petFee: stayInt(d['petFee']),
        extraGuestFee: stayInt(d['extraGuestFee']),
        extraGuestAfter: stayInt(d['extraGuestAfter']),
      );

  /// All in cents.
  final int nightly;
  final int? weekendNightly;
  final int? weeklyNightly;
  final int cleaningFee;
  final int petFee;
  final int extraGuestFee;
  final int extraGuestAfter;

  Map<String, dynamic> toMap() => {
        'nightly': nightly,
        'weekendNightly': weekendNightly,
        'weeklyNightly': weeklyNightly,
        'cleaningFee': cleaningFee,
        'petFee': petFee,
        'extraGuestFee': extraGuestFee,
        'extraGuestAfter': extraGuestAfter,
      };
}

class StaySeasonalRate {
  const StaySeasonalRate({
    required this.id,
    required this.name,
    required this.startMmdd,
    required this.endMmdd,
    required this.nightlyCents,
    this.weekendNightlyCents,
  });

  factory StaySeasonalRate.fromMap(Map<String, dynamic> d) => StaySeasonalRate(
        id: stayStr(d['id']),
        name: stayStr(d['name']),
        startMmdd: stayStr(d['startMmdd']),
        endMmdd: stayStr(d['endMmdd']),
        nightlyCents: stayInt(d['nightlyCents']),
        weekendNightlyCents: stayIntOrNull(d['weekendNightlyCents']),
      );

  final String id;
  final String name;

  /// 'MM-DD'; a season may wrap the year end.
  final String startMmdd;
  final String endMmdd;
  final int nightlyCents;
  final int? weekendNightlyCents;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'startMmdd': startMmdd,
        'endMmdd': endMmdd,
        'nightlyCents': nightlyCents,
        'weekendNightlyCents': weekendNightlyCents,
      };
}

class StayTaxLine {
  const StayTaxLine({
    required this.code,
    required this.label,
    required this.rateBps,
    this.appliesTo = const [],
  });

  factory StayTaxLine.fromMap(Map<String, dynamic> d) => StayTaxLine(
        code: stayStr(d['code']),
        label: stayStr(d['label']),
        rateBps: stayInt(d['rateBps']),
        appliesTo: stayStrList(d['appliesTo']),
      );

  final String code;
  final String label;

  /// Basis points, 0–3000. No rates are hardcoded anywhere; the owner enters them.
  final int rateBps;

  /// Some of [appliesToValues].
  final List<String> appliesTo;

  /// What a tax line can apply to (TAX_APPLIES_TO).
  static const List<String> appliesToValues = ['lodging', 'cleaning', 'pet', 'extra_guest'];

  Map<String, dynamic> toMap() => {
        'code': code,
        'label': label,
        'rateBps': rateBps,
        'appliesTo': appliesTo,
        'remittedBy': 'owner',
      };
}

class StayChecklistTemplateItem {
  const StayChecklistTemplateItem({required this.id, required this.label});

  factory StayChecklistTemplateItem.fromMap(Map<String, dynamic> d) =>
      StayChecklistTemplateItem(id: stayStr(d['id']), label: stayStr(d['label']));

  final String id;
  final String label;

  Map<String, dynamic> toMap() => {'id': id, 'label': label};
}

class StayListingTurnover {
  const StayListingTurnover({
    this.mode = TurnoverMode.none,
    this.afterOwnerBlocks = false,
    this.checklistTemplate = const [],
    this.defaultAssigneeUid,
    this.defaultAssigneeName,
  });

  factory StayListingTurnover.fromMap(Map<String, dynamic> d) => StayListingTurnover(
        mode: d['mode'] == null ? TurnoverMode.none : TurnoverMode.fromWire(d['mode']),
        afterOwnerBlocks: stayTrue(d['afterOwnerBlocks']),
        checklistTemplate: stayMapList(d['checklistTemplate']).map(StayChecklistTemplateItem.fromMap).toList(),
        defaultAssigneeUid: stayStrOrNull(d['defaultAssigneeUid']),
        defaultAssigneeName: stayStrOrNull(d['defaultAssigneeName']),
      );

  final TurnoverMode mode;
  final bool afterOwnerBlocks;
  final List<StayChecklistTemplateItem> checklistTemplate;
  final String? defaultAssigneeUid;
  final String? defaultAssigneeName;

  Map<String, dynamic> toMap() => {
        'mode': mode.wire,
        'afterOwnerBlocks': afterOwnerBlocks,
        'checklistTemplate': checklistTemplate.map((i) => i.toMap()).toList(),
        'defaultAssigneeUid': defaultAssigneeUid,
        'defaultAssigneeName': defaultAssigneeName,
      };
}

class StayListingAirbnb {
  const StayListingAirbnb({this.listingNameAliases = const [], this.listingUrl, this.calendarUrl});

  factory StayListingAirbnb.fromMap(Map<String, dynamic> d) => StayListingAirbnb(
        listingNameAliases: stayStrList(d['listingNameAliases']),
        listingUrl: stayStrOrNull(d['listingUrl']),
        calendarUrl: stayStrOrNull(d['calendarUrl']),
      );

  final List<String> listingNameAliases;
  final String? listingUrl;
  final String? calendarUrl;

  Map<String, dynamic> toMap() => {
        'listingNameAliases': listingNameAliases,
        'listingUrl': listingUrl,
        'calendarUrl': calendarUrl,
      };
}

/// facilities/{fid}/stayListings/{listingId}: one rentable nightly thing (an
/// Airbnb home, the house, a cabin, an RV site). Written only by callables,
/// which validate every list element; archived, never deleted.
class StayListing {
  const StayListing({
    required this.id,
    required this.facilityId,
    required this.name,
    this.shortCode = '',
    this.kind = StayListingKind.unknown,
    this.group = '',
    this.sortOrder = 0,
    this.active = false,
    this.archived = false,
    this.address,
    this.capacity = const StayListingCapacity(),
    this.rv,
    this.checkInTime,
    this.checkOutTime,
    this.minNights = 1,
    this.maxNights = 180,
    this.rates = const StayListingRates(),
    this.seasonalRates = const [],
    this.taxLines = const [],
    this.turnover = const StayListingTurnover(),
    this.accessCodeMode = AccessCodeMode.none,
    this.airbnb = const StayListingAirbnb(),
    this.notes = '',
    this.version = 0,
    this.updatedAt,
  });

  factory StayListing.fromFirestore(DocumentSnapshot<Object?> doc) => StayListing.fromMap(doc.id, stayDocData(doc));

  factory StayListing.fromMap(String id, Map<String, dynamic> d) {
    final times = stayMap(d['times']);
    final rules = stayMap(d['stayRules']);
    return StayListing(
      id: id,
      facilityId: stayStr(d['facilityId']),
      name: stayStr(d['name'], 'Listing'),
      shortCode: stayStr(d['shortCode']),
      kind: StayListingKind.fromWire(d['kind']),
      group: stayStr(d['group']),
      sortOrder: stayInt(d['sortOrder']),
      active: stayTrue(d['active']),
      archived: stayTrue(d['archived']),
      address: stayStrOrNull(d['address']),
      capacity: StayListingCapacity.fromMap(stayMap(d['capacity'])),
      rv: d['rv'] is Map ? StayListingRv.fromMap(stayMap(d['rv'])) : null,
      checkInTime: stayStrOrNull(times['checkIn']),
      checkOutTime: stayStrOrNull(times['checkOut']),
      minNights: stayInt(rules['minNights'], 1),
      maxNights: stayInt(rules['maxNights'], 180),
      rates: StayListingRates.fromMap(stayMap(d['ratesCents'])),
      seasonalRates: stayMapList(d['seasonalRates']).map(StaySeasonalRate.fromMap).toList(),
      taxLines: stayMapList(d['taxLines']).map(StayTaxLine.fromMap).toList(),
      turnover: StayListingTurnover.fromMap(stayMap(d['turnover'])),
      accessCodeMode: d['accessCodeMode'] == null ? AccessCodeMode.none : AccessCodeMode.fromWire(d['accessCodeMode']),
      airbnb: StayListingAirbnb.fromMap(stayMap(d['airbnb'])),
      notes: stayStr(d['notes']),
      version: stayInt(d['version']),
      updatedAt: stayTime(d['updatedAt']),
    );
  }

  final String id;
  final String facilityId;
  final String name;
  final String shortCode;
  final StayListingKind kind;

  /// e.g. 'Airbnbs', 'RV park'.
  final String group;
  final int sortOrder;
  final bool active;
  final bool archived;
  final String? address;
  final StayListingCapacity capacity;
  final StayListingRv? rv;

  /// null: the controls' default time.
  final String? checkInTime;
  final String? checkOutTime;
  final int minNights;
  final int maxNights;
  final StayListingRates rates;
  final List<StaySeasonalRate> seasonalRates;
  final List<StayTaxLine> taxLines;
  final StayListingTurnover turnover;
  final AccessCodeMode accessCodeMode;
  final StayListingAirbnb airbnb;
  final String notes;
  final int version;
  final DateTime? updatedAt;

  /// Rentable now: active and not archived.
  bool get isBookable => active && !archived;

  String get displayGroup => group.trim().isEmpty ? (kind.isSite ? 'RV park' : 'Listings') : group.trim();

  /// The fields staysSaveListing takes as `listing`.
  Map<String, dynamic> toInputMap() => {
        'name': name,
        'shortCode': shortCode,
        'kind': kind.wire,
        'group': group,
        'sortOrder': sortOrder,
        'active': active,
        'archived': archived,
        'address': address,
        'capacity': capacity.toMap(),
        'rv': rv?.toMap(),
        'times': {'checkIn': checkInTime, 'checkOut': checkOutTime},
        'stayRules': {'minNights': minNights, 'maxNights': maxNights},
        'ratesCents': rates.toMap(),
        'seasonalRates': seasonalRates.map((s) => s.toMap()).toList(),
        'taxLines': taxLines.map((t) => t.toMap()).toList(),
        'turnover': turnover.toMap(),
        'accessCodeMode': accessCodeMode.wire,
        'airbnb': airbnb.toMap(),
        'notes': notes,
      };
}
