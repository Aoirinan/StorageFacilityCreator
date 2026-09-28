import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_controls.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';
import 'package:sfcapp/models/stays/stay_folio.dart';
import 'package:sfcapp/models/stays/stay_guest_profile.dart';

// The Stays callable contract, mirrored from
// functions-shared/src/stays/contracts.ts. test/stays_contract_parity_test.dart
// fails when the callable names, error reasons or notification types here
// and there drift apart. Callables return timestamps as ISO-8601 strings.

/// Callable names (STAYS_CALLABLES).
abstract final class StaysCallableNames {
  static const getAvailability = 'staysGetAvailability';
  static const setControls = 'staysSetControls';
  static const saveListing = 'staysSaveListing';
  static const bulkCreateRvSites = 'staysBulkCreateRvSites';
  static const quote = 'staysQuote';
  static const createStay = 'staysCreateStay';
  static const modifyStay = 'staysModifyStay';
  static const cancelStay = 'staysCancelStay';
  static const reviewStay = 'staysReviewStay';
  static const recordPayment = 'staysRecordPayment';
  static const voidIncome = 'staysVoidIncome';
  static const searchGuests = 'staysSearchGuests';
  static const upsertChannel = 'staysUpsertChannel';
  static const removeChannel = 'staysRemoveChannel';
  static const syncNow = 'staysSyncNow';
  static const createExportLink = 'staysCreateExportLink';
  static const getExportUrl = 'staysGetExportUrl';
  static const updateExportLink = 'staysUpdateExportLink';
  static const revokeExportLink = 'staysRevokeExportLink';
  static const importAirbnbCsv = 'staysImportAirbnbCsv';
  static const recordExpense = 'staysRecordExpense';
  static const voidExpense = 'staysVoidExpense';

  static const List<String> all = [
    getAvailability,
    setControls,
    saveListing,
    bulkCreateRvSites,
    quote,
    createStay,
    modifyStay,
    cancelStay,
    reviewStay,
    recordPayment,
    voidIncome,
    searchGuests,
    upsertChannel,
    removeChannel,
    syncNow,
    createExportLink,
    getExportUrl,
    updateExportLink,
    revokeExportLink,
    importAirbnbCsv,
    recordExpense,
    voidExpense,
  ];
}

/// A caller's role in Stays (STAY_ROLES); role_not_allowed errors name one in details.role.
abstract final class StayRoles {
  static const String owner = 'owner';
  static const String manager = 'manager';
  static const String employee = 'employee';
  static const String viewer = 'viewer';
  static const List<String> all = [owner, manager, employee, viewer];
}

/// StaysWarning.code values (STAYS_WARNING_CODES). A code the app does not
/// know is shown by its message alone.
abstract final class StaysWarningCodes {
  static const String facilityTimezoneMismatch = 'facility_timezone_mismatch';
  static const String shortLead = 'short_lead';
  static const String softNights = 'soft_nights';
  static const String freshSyncFailed = 'fresh_sync_failed';
  static const String freshSyncSkipped = 'fresh_sync_skipped';
  static const String overCapacity = 'over_capacity';
  static const String petsNotAllowed = 'pets_not_allowed';
  static const String rvTooLong = 'rv_too_long';
  static const String doNotRent = 'do_not_rent';
  static const String orphanGap = 'orphan_gap';
  static const String feedEmpty = 'feed_empty';
  static const String feedSuspicious = 'feed_suspicious';
  static const String eventsSkipped = 'events_skipped';
  static const String recurringEventsSkipped = 'recurring_events_skipped';
  static const String farFutureClamped = 'far_future_clamped';
  static const String repasteRequired = 'repaste_required';

  static const List<String> all = [
    facilityTimezoneMismatch,
    shortLead,
    softNights,
    freshSyncFailed,
    freshSyncSkipped,
    overCapacity,
    petsNotAllowed,
    rvTooLong,
    doNotRent,
    orphanGap,
    feedEmpty,
    feedSuspicious,
    eventsSkipped,
    recurringEventsSkipped,
    farFutureClamped,
    repasteRequired,
  ];
}

/// In-app notification types Stays writes (STAY_NOTIFICATION_TYPES).
abstract final class StayNotificationTypes {
  static const List<String> all = [
    'STAY_BOOKING_IMPORTED',
    'STAY_BOOKING_CHANGED',
    'STAY_BOOKING_REMOVED',
    'STAY_BOOKING_NEEDS_REVIEW',
    'STAY_CONFLICT',
    'STAY_FEED_FIRST_SYNC',
    'STAY_FEED_FAILING',
    'STAY_FEED_SUSPICIOUS',
    'STAY_TURNOVER_DONE',
    'STAY_TURNOVER_ISSUE',
    'STAY_TURNOVER_UNASSIGNED',
    'STAY_DAILY_BRIEF',
  ];
}

/// details.reason of a Stays callable error (STAYS_ERROR_REASONS).
enum StaysErrorReason implements WireEnum {
  staysPaused('stays_paused'),
  moduleNotAvailable('module_not_available'),
  moduleDisabled('module_disabled'),
  roleNotAllowed('role_not_allowed'),
  employeeSettingOff('employee_setting_off'),
  invalidDates('invalid_dates'),
  minNights('min_nights'),
  maxNights('max_nights'),
  listingInactive('listing_inactive'),
  hardConflict('hard_conflict'),
  softBlock('soft_block'),
  shortLeadAckRequired('short_lead_ack_required'),
  doNotRent('do_not_rent'),
  partyRepriceRequired('party_reprice_required'),
  feedOwnedDates('feed_owned_dates'),
  versionMismatch('version_mismatch'),
  contention('contention'),
  duplicateReservation('duplicate_reservation'),
  timezoneUnconfirmed('timezone_unconfirmed'),
  notAvailableYet('not_available_yet'),
  feedHostNotAllowed('feed_host_not_allowed'),
  feedFetchFailed('feed_fetch_failed'),
  feedInvalid('feed_invalid'),
  feedTooLarge('feed_too_large'),
  csvInvalid('csv_invalid'),
  csvTooLarge('csv_too_large'),
  rateLimited('rate_limited'),
  unauthenticated('unauthenticated'),
  appCheckRequired('app_check_required'),
  invalidArgument('invalid_argument'),
  notFound('not_found'),
  limitReached('limit_reached'),
  internal('internal'),

  /// Not a Stays error (a network failure, an old server): shown generically.
  unknown('unknown');

  const StaysErrorReason(this.wire);
  @override
  final String wire;
  static StaysErrorReason fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

/// A Stays callable that failed, with the server's reason and details (e.g.
/// the conflicting nights of a `hard_conflict`, the dates of a `soft_block`).
class StaysCallableException implements Exception {
  const StaysCallableException(this.reason, {this.details = const {}, this.message, this.code});

  final StaysErrorReason reason;
  final Map<String, dynamic> details;
  final String? message;

  /// The HttpsError code, e.g. 'already-exists'.
  final String? code;

  /// hard_conflict details: the nights and who holds them.
  List<HardConflictNight> get conflictNights =>
      stayMapList(details['nights']).map(HardConflictNight.fromJson).toList(growable: false);

  /// soft_block details: the channel-blocked dates.
  List<String> get softBlockDates => stayStrList(details['dates']);

  @override
  String toString() => 'StaysCallableException(${reason.wire}): ${message ?? ''}';
}

class HardConflictNight {
  const HardConflictNight({required this.date, required this.stayId, required this.label});

  factory HardConflictNight.fromJson(Map<String, dynamic> j) =>
      HardConflictNight(date: stayStr(j['date']), stayId: stayStr(j['stayId']), label: stayStr(j['label']));

  final String date;
  final String stayId;
  final String label;
}

class StaysWarning {
  const StaysWarning({required this.code, required this.message, this.details = const {}});

  factory StaysWarning.fromJson(Map<String, dynamic> j) =>
      StaysWarning(code: stayStr(j['code']), message: stayStr(j['message']), details: stayMap(j['details']));

  static List<StaysWarning> listFrom(Object? value) => stayMapList(value).map(StaysWarning.fromJson).toList();

  /// One of StaysWarningCodes, e.g. 'facility_timezone_mismatch'.
  final String code;
  final String message;
  final Map<String, dynamic> details;

  /// Whether [code] is one this app knows.
  bool get isKnown => StaysWarningCodes.all.contains(code);
}

Map<String, dynamic> _withoutNulls(Map<String, dynamic> map) => {
      for (final entry in map.entries)
        if (entry.value != null) entry.key: entry.value,
    };

// --- staysGetAvailability ----------------------------------------------------

class StaysAvailability {
  const StaysAvailability({required this.allowed, required this.paused});

  factory StaysAvailability.fromJson(Map<String, dynamic> j) =>
      StaysAvailability(allowed: stayTrue(j['allowed']), paused: stayTrue(j['paused']));

  static const unavailable = StaysAvailability(allowed: false, paused: false);

  final bool allowed;
  final bool paused;
}

// --- staysSetControls ------------------------------------------------------------

/// The controls to change; only the fields that are set are sent.
class StayControlsChanges {
  const StayControlsChanges({
    this.moduleEnabled,
    this.timeZone,
    this.icalSyncEnabled,
    this.icalExportEnabled,
    this.turnoverTasksEnabled,
    this.dailyBriefEnabled,
    this.dailyBriefLocalHour,
    this.lodgingTaxEnabled,
    this.employeesCanBook,
    this.employeesCanRecordCash,
    this.defaultCheckInTime,
    this.defaultCheckOutTime,
    this.shortLeadWarningHours,
    this.paymentMethods,
    this.parkRules,
    this.quietHours,
  });

  final bool? moduleEnabled;
  final String? timeZone;
  final bool? icalSyncEnabled;
  final bool? icalExportEnabled;
  final bool? turnoverTasksEnabled;
  final bool? dailyBriefEnabled;
  final int? dailyBriefLocalHour;
  final bool? lodgingTaxEnabled;
  final bool? employeesCanBook;
  final bool? employeesCanRecordCash;
  final String? defaultCheckInTime;
  final String? defaultCheckOutTime;
  final int? shortLeadWarningHours;
  final List<StayIncomeMethod>? paymentMethods;
  final String? parkRules;
  final String? quietHours;

  Map<String, dynamic> toJson() => _withoutNulls({
        'moduleEnabled': moduleEnabled,
        'timeZone': timeZone,
        'icalSyncEnabled': icalSyncEnabled,
        'icalExportEnabled': icalExportEnabled,
        'turnoverTasksEnabled': turnoverTasksEnabled,
        'dailyBriefEnabled': dailyBriefEnabled,
        'dailyBriefLocalHour': dailyBriefLocalHour,
        'lodgingTaxEnabled': lodgingTaxEnabled,
        'employeesCanBook': employeesCanBook,
        'employeesCanRecordCash': employeesCanRecordCash,
        'defaultCheckInTime': defaultCheckInTime,
        'defaultCheckOutTime': defaultCheckOutTime,
        'shortLeadWarningHours': shortLeadWarningHours,
        'paymentMethods': paymentMethods?.map((m) => m.wire).toList(),
        'parkRules': parkRules,
        'quietHours': quietHours,
      });
}

class StaysSetControlsRequest {
  const StaysSetControlsRequest({
    required this.facilityId,
    required this.changes,
    this.confirmTimeZone,
    this.expectedVersion,
  });

  final String facilityId;
  final StayControlsChanges changes;

  /// Confirms the zone; turning the module on needs a confirmed zone.
  final bool? confirmTimeZone;
  final int? expectedVersion;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'changes': changes.toJson(),
        'confirmTimeZone': confirmTimeZone,
        'expectedVersion': expectedVersion,
      });
}

class StaysSetControlsResult {
  const StaysSetControlsResult({required this.controls, this.warnings = const []});

  factory StaysSetControlsResult.fromJson(Map<String, dynamic> j, {required String facilityId}) =>
      StaysSetControlsResult(
        controls: StayControls.fromMap(stayMap(j['controls']), facilityId: facilityId),
        warnings: StaysWarning.listFrom(j['warnings']),
      );

  final StayControls controls;
  final List<StaysWarning> warnings;
}

// --- Listings ----------------------------------------------------------------------

class StaysSaveListingRequest {
  const StaysSaveListingRequest({
    required this.facilityId,
    required this.requestId,
    required this.listing,
    this.listingId,
    this.expectedVersion,
  });

  final String facilityId;
  final String requestId;

  /// The editable listing fields (StayListing.toInputMap()).
  final Map<String, dynamic> listing;

  /// null creates a listing.
  final String? listingId;
  final int? expectedVersion;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'requestId': requestId,
        'listingId': listingId,
        'expectedVersion': expectedVersion,
        'listing': listing,
      });
}

class StaysSaveListingResult {
  const StaysSaveListingResult({required this.listingId, required this.version});

  factory StaysSaveListingResult.fromJson(Map<String, dynamic> j) =>
      StaysSaveListingResult(listingId: stayStr(j['listingId']), version: stayInt(j['version']));

  final String listingId;
  final int version;
}

class StaysBulkRvSite {
  const StaysBulkRvSite({
    required this.n,
    required this.hookup,
    this.amps = const [],
    this.maxLengthFt,
    this.pullThrough = false,
  });

  final int n;
  final RvHookup hookup;
  final List<int> amps;
  final int? maxLengthFt;
  final bool pullThrough;

  Map<String, dynamic> toJson() => {
        'n': n,
        'hookup': hookup.wire,
        'amps': amps,
        'maxLengthFt': maxLengthFt,
        'pullThrough': pullThrough,
      };
}

class StaysBulkCreateRvSitesRequest {
  const StaysBulkCreateRvSitesRequest({
    required this.facilityId,
    required this.requestId,
    required this.prefix,
    required this.from,
    required this.to,
    required this.group,
    this.defaults = const {},
    this.perSite = const [],
  });

  final String facilityId;
  final String requestId;

  /// e.g. 'RV ' → 'RV 1' … 'RV N'.
  final String prefix;
  final int from;
  final int to;
  final String group;
  final Map<String, dynamic> defaults;
  final List<StaysBulkRvSite> perSite;

  Map<String, dynamic> toJson() => {
        'facilityId': facilityId,
        'requestId': requestId,
        'prefix': prefix,
        'from': from,
        'to': to,
        'group': group,
        'defaults': defaults,
        'perSite': perSite.map((s) => s.toJson()).toList(),
      };
}

// --- Quote and stays -------------------------------------------------------------

class StayQuote {
  const StayQuote({
    this.nights = 0,
    this.lines = const [],
    this.taxLines = const [],
    this.subtotalCents = 0,
    this.taxCents = 0,
    this.totalCents = 0,
  });

  factory StayQuote.fromJson(Map<String, dynamic> j) => StayQuote(
        nights: stayInt(j['nights']),
        lines: stayMapList(j['lines']).map(StayFolioLine.fromMap).toList(),
        taxLines: stayMapList(j['taxLines']).map(StayFolioTaxLine.fromMap).toList(),
        subtotalCents: stayInt(j['subtotalCents']),
        taxCents: stayInt(j['taxCents']),
        totalCents: stayInt(j['totalCents']),
      );

  final int nights;
  final List<StayFolioLine> lines;
  final List<StayFolioTaxLine> taxLines;
  final int subtotalCents;
  final int taxCents;
  final int totalCents;
}

class StaysQuoteRequest {
  const StaysQuoteRequest({
    required this.facilityId,
    required this.listingId,
    required this.checkIn,
    required this.checkOut,
    this.adults = 1,
    this.children = 0,
    this.pets = 0,
    this.excludeStayId,
    this.adjustmentCents,
  });

  final String facilityId;
  final String listingId;
  final String checkIn;
  final String checkOut;
  final int adults;
  final int children;
  final int pets;
  final String? excludeStayId;
  final int? adjustmentCents;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'listingId': listingId,
        'checkIn': checkIn,
        'checkOut': checkOut,
        'adults': adults,
        'children': children,
        'pets': pets,
        'excludeStayId': excludeStayId,
        'adjustmentCents': adjustmentCents,
      });
}

class StaysQuoteResult {
  const StaysQuoteResult({
    required this.available,
    this.hardConflicts = const [],
    this.softNights = const [],
    this.shortLead = false,
    this.quote = const StayQuote(),
    this.warnings = const [],
  });

  factory StaysQuoteResult.fromJson(Map<String, dynamic> j) => StaysQuoteResult(
        available: stayTrue(j['available']),
        hardConflicts: stayMapList(j['hardConflicts']).map(HardConflictNight.fromJson).toList(),
        softNights: stayStrList(j['softNights']),
        shortLead: stayTrue(j['shortLead']),
        quote: StayQuote.fromJson(stayMap(j['quote'])),
        warnings: StaysWarning.listFrom(j['warnings']),
      );

  final bool available;
  final List<HardConflictNight> hardConflicts;
  final List<String> softNights;
  final bool shortLead;
  final StayQuote quote;
  final List<StaysWarning> warnings;
}

class StayGuestInput {
  const StayGuestInput({
    this.displayName = '',
    this.adults = 1,
    this.children = 0,
    this.pets = 0,
    this.rvLengthFt,
  });

  final String displayName;
  final int adults;
  final int children;
  final int pets;
  final int? rvLengthFt;

  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        'adults': adults,
        'children': children,
        'pets': pets,
        'rvLengthFt': rvLengthFt,
      };
}

/// An existing returning guest, or one to create with this booking.
class StayGuestProfileRef {
  const StayGuestProfileRef.existing(String this.profileId)
      : name = null,
        phone = null,
        email = null,
        vehicle = null,
        notes = null;

  const StayGuestProfileRef.create({
    required String this.name,
    this.phone,
    this.email,
    this.vehicle,
    this.notes,
  }) : profileId = null;

  final String? profileId;
  final String? name;
  final String? phone;
  final String? email;
  final StayGuestVehicle? vehicle;
  final String? notes;

  Map<String, dynamic> toJson() => profileId != null
      ? {'profileId': profileId}
      : {
          'create': _withoutNulls({
            'name': name,
            'phone': phone,
            'email': email,
            'vehicle': vehicle?.toMap(),
            'notes': notes,
          }),
        };
}

class StayPaymentInput {
  const StayPaymentInput({required this.method, required this.amountCents, required this.receivedDate});

  final StayIncomeMethod method;
  final int amountCents;

  /// 'YYYY-MM-DD', facility-local.
  final String receivedDate;

  Map<String, dynamic> toJson() => {'method': method.wire, 'amountCents': amountCents, 'receivedDate': receivedDate};
}

class StayAdjustmentInput {
  const StayAdjustmentInput({required this.cents, required this.reason});

  final int cents;
  final String reason;

  Map<String, dynamic> toJson() => {'cents': cents, 'reason': reason};
}

class StaysCreateStayRequest {
  const StaysCreateStayRequest({
    required this.facilityId,
    required this.requestId,
    required this.listingId,
    required this.checkIn,
    required this.checkOut,
    required this.kind,
    required this.source,
    this.guest = const StayGuestInput(),
    this.confirmationCode,
    this.guestProfile,
    this.checkInNow,
    this.checkInTime,
    this.checkOutTime,
    this.payment,
    this.adjustment,
    this.overrideSoftBlocks,
    this.acknowledgeShortLead,
    this.acknowledgeDoNotRent,
    this.notes,
  });

  final String facilityId;

  /// Minted once per form; a retry returns created:false instead of booking twice.
  final String requestId;
  final String listingId;
  final String checkIn;
  final String checkOut;
  final StayKind kind;
  final StaySource source;
  final StayGuestInput guest;
  final String? confirmationCode;
  final StayGuestProfileRef? guestProfile;
  final bool? checkInNow;
  final String? checkInTime;
  final String? checkOutTime;
  final StayPaymentInput? payment;
  final StayAdjustmentInput? adjustment;
  final bool? overrideSoftBlocks;
  final bool? acknowledgeShortLead;
  final bool? acknowledgeDoNotRent;
  final String? notes;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'requestId': requestId,
        'listingId': listingId,
        'checkIn': checkIn,
        'checkOut': checkOut,
        'kind': kind.wire,
        'source': source.wire,
        'confirmationCode': confirmationCode,
        'guest': guest.toJson(),
        'guestProfile': guestProfile?.toJson(),
        'checkInNow': checkInNow,
        'times': checkInTime == null && checkOutTime == null
            ? null
            : _withoutNulls({'checkIn': checkInTime, 'checkOut': checkOutTime}),
        'payment': payment?.toJson(),
        'adjustment': adjustment?.toJson(),
        'overrideSoftBlocks': overrideSoftBlocks,
        'acknowledgeShortLead': acknowledgeShortLead,
        'acknowledgeDoNotRent': acknowledgeDoNotRent,
        'notes': notes,
      });
}

class StaysCreateStayResult {
  const StaysCreateStayResult({
    required this.stayId,
    required this.created,
    required this.status,
    this.folio,
    this.incomeEntryId,
    this.warnings = const [],
  });

  factory StaysCreateStayResult.fromJson(Map<String, dynamic> j) {
    final stayId = stayStr(j['stayId']);
    return StaysCreateStayResult(
      stayId: stayId,
      created: stayTrue(j['created']),
      status: StayStatus.fromWire(j['status']),
      folio: j['folio'] is Map ? StayFolio.fromMap(stayId, stayMap(j['folio'])) : null,
      incomeEntryId: stayStrOrNull(j['incomeEntryId']),
      warnings: StaysWarning.listFrom(j['warnings']),
    );
  }

  final String stayId;
  final bool created;
  final StayStatus status;
  final StayFolio? folio;
  final String? incomeEntryId;
  final List<StaysWarning> warnings;
}

/// The guest fields a staysModifyStay changes; only what is set is sent.
/// Not [StayGuestInput]: its create-form defaults (1 adult, no children or
/// pets) would turn a rename into a party change, which an owner's or
/// manager's edit prices.
class StayGuestPatch {
  const StayGuestPatch({
    this.displayName,
    this.adults,
    this.children,
    this.pets,
    this.rvLengthFt,
    this.clearRvLength = false,
  });

  final String? displayName;
  final int? adults;
  final int? children;
  final int? pets;
  final int? rvLengthFt;

  /// Sends `rvLengthFt: null`, clearing the rig length ([rvLengthFt] unset).
  final bool clearRvLength;

  Map<String, dynamic> toJson() => {
        ..._withoutNulls({
          'displayName': displayName,
          'adults': adults,
          'children': children,
          'pets': pets,
          'rvLengthFt': rvLengthFt,
        }),
        if (clearRvLength && rvLengthFt == null) 'rvLengthFt': null,
      };
}

class StaysModifyStayChanges {
  const StaysModifyStayChanges({
    this.checkIn,
    this.checkOut,
    this.listingId,
    this.checkInTime,
    this.checkOutTime,
    this.guest,
  });

  final String? checkIn;
  final String? checkOut;
  final String? listingId;
  final String? checkInTime;
  final String? checkOutTime;
  final StayGuestPatch? guest;

  Map<String, dynamic> toJson() => _withoutNulls({
        'checkIn': checkIn,
        'checkOut': checkOut,
        'listingId': listingId,
        'checkInTime': checkInTime,
        'checkOutTime': checkOutTime,
        'guest': guest?.toJson(),
      });
}

class StaysModifyStayRequest {
  const StaysModifyStayRequest({
    required this.facilityId,
    required this.stayId,
    required this.expectedVersion,
    required this.changes,
    this.overrideSoftBlocks,
    this.acknowledgeShortLead,
    this.payment,
    this.requestId,
    this.repriceParty,
  });

  final String facilityId;
  final String stayId;
  final int expectedVersion;
  final StaysModifyStayChanges changes;
  final bool? overrideSoftBlocks;
  final bool? acknowledgeShortLead;
  final StayPaymentInput? payment;

  /// Required with [payment]: the income row is man_{requestId}.
  final String? requestId;

  /// Owner or manager, when the stay's party differs from the folio's: true
  /// prices the party now on the stay, false keeps the price for the party
  /// it was priced for. Unset, new dates fail with
  /// [StaysErrorReason.partyRepriceRequired] unless [changes] sets a new
  /// count, which is priced.
  final bool? repriceParty;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'stayId': stayId,
        'expectedVersion': expectedVersion,
        'changes': changes.toJson(),
        'overrideSoftBlocks': overrideSoftBlocks,
        'acknowledgeShortLead': acknowledgeShortLead,
        'payment': payment?.toJson(),
        'requestId': requestId,
        'repriceParty': repriceParty,
      });
}

/// staysModifyStay, staysCancelStay and staysReviewStay return the stay as written.
class StaysStayResult {
  const StaysStayResult({required this.stay, this.folio});

  factory StaysStayResult.fromJson(Map<String, dynamic> j, {required String stayId}) => StaysStayResult(
        stay: Stay.fromMap(stayId, stayMap(j['stay'])),
        folio: j['folio'] is Map ? StayFolio.fromMap(stayId, stayMap(j['folio'])) : null,
      );

  final Stay stay;
  final StayFolio? folio;
}

class StaysCancelStayRequest {
  const StaysCancelStayRequest({
    required this.facilityId,
    required this.stayId,
    required this.expectedVersion,
    required this.reason,
    this.noShow,
  });

  final String facilityId;
  final String stayId;
  final int expectedVersion;
  final String reason;
  final bool? noShow;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'stayId': stayId,
        'expectedVersion': expectedVersion,
        'reason': reason,
        'noShow': noShow,
      });
}

class StaysReviewStayRequest {
  const StaysReviewStayRequest({
    required this.facilityId,
    required this.stayId,
    required this.action,
    this.note = '',
    this.expectedVersion,
  });

  final String facilityId;
  final String stayId;
  final StayReviewAction action;
  final String note;
  final int? expectedVersion;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'stayId': stayId,
        'action': action.wire,
        'note': note,
        'expectedVersion': expectedVersion,
      });
}

// --- Money ---------------------------------------------------------------------------

class StaysRecordPaymentRequest {
  const StaysRecordPaymentRequest({
    required this.facilityId,
    required this.requestId,
    required this.stayId,
    required this.method,
    required this.amountCents,
    required this.receivedDate,
    this.memo,
  });

  final String facilityId;
  final String requestId;
  final String stayId;
  final StayIncomeMethod method;

  /// Negative for a refund given back (owner/manager only).
  final int amountCents;
  final String receivedDate;
  final String? memo;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'requestId': requestId,
        'stayId': stayId,
        'method': method.wire,
        'amountCents': amountCents,
        'receivedDate': receivedDate,
        'memo': memo,
      });
}

class StaysRecordPaymentResult {
  const StaysRecordPaymentResult({
    required this.entryId,
    required this.created,
    required this.paymentStatus,
    this.folio,
  });

  factory StaysRecordPaymentResult.fromJson(Map<String, dynamic> j, {required String stayId}) =>
      StaysRecordPaymentResult(
        entryId: stayStr(j['entryId']),
        created: stayTrue(j['created']),
        paymentStatus: StayPaymentStatus.fromWire(j['paymentStatus']),
        folio: j['folio'] is Map ? StayFolio.fromMap(stayId, stayMap(j['folio'])) : null,
      );

  final String entryId;
  final bool created;
  final StayPaymentStatus paymentStatus;
  final StayFolio? folio;
}

class StaysVoidIncomeResult {
  const StaysVoidIncomeResult({required this.entryId, this.folio});

  factory StaysVoidIncomeResult.fromJson(Map<String, dynamic> j) {
    final folio = stayMap(j['folio']);
    return StaysVoidIncomeResult(
      entryId: stayStr(j['entryId']),
      folio: j['folio'] is Map ? StayFolio.fromMap(stayStr(folio['stayId']), folio) : null,
    );
  }

  final String entryId;
  final StayFolio? folio;
}

class StaysRecordExpenseRequest {
  const StaysRecordExpenseRequest({
    required this.facilityId,
    required this.requestId,
    required this.category,
    required this.amountCents,
    required this.spentDate,
    this.listingId,
    this.vendor,
    this.memo,
    this.receiptPath,
  });

  final String facilityId;
  final String requestId;
  final StayExpenseCategory category;
  final int amountCents;
  final String spentDate;
  final String? listingId;
  final String? vendor;
  final String? memo;
  final String? receiptPath;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'requestId': requestId,
        'listingId': listingId,
        'category': category.wire,
        'amountCents': amountCents,
        'spentDate': spentDate,
        'vendor': vendor,
        'memo': memo,
        'receiptPath': receiptPath,
      });
}

class StaysRecordExpenseResult {
  const StaysRecordExpenseResult({required this.expenseId, required this.created});

  factory StaysRecordExpenseResult.fromJson(Map<String, dynamic> j) =>
      StaysRecordExpenseResult(expenseId: stayStr(j['expenseId']), created: stayTrue(j['created']));

  final String expenseId;
  final bool created;
}

// --- Guests ----------------------------------------------------------------------------

class StayGuestSearchResult {
  const StayGuestSearchResult({
    required this.profileId,
    required this.name,
    this.rvLengthFt,
    this.lastStayAt,
    this.stayCount = 0,
    this.doNotRent = false,
    this.phoneE164,
    this.email,
  });

  factory StayGuestSearchResult.fromJson(Map<String, dynamic> j) => StayGuestSearchResult(
        profileId: stayStr(j['profileId']),
        name: stayStr(j['name']),
        rvLengthFt: stayIntOrNull(j['rvLengthFt']),
        lastStayAt: stayTime(j['lastStayAt']),
        stayCount: stayInt(j['stayCount']),
        doNotRent: stayTrue(j['doNotRent']),
        phoneE164: stayStrOrNull(j['phoneE164']),
        email: stayStrOrNull(j['email']),
      );

  final String profileId;
  final String name;
  final int? rvLengthFt;
  final DateTime? lastStayAt;
  final int stayCount;
  final bool doNotRent;

  /// Owner/manager only; the server leaves these out for employees.
  final String? phoneE164;
  final String? email;
}

// --- Channels and export links -----------------------------------------------------------

class StaysChannelSyncResult {
  const StaysChannelSyncResult({
    required this.channelId,
    required this.status,
    this.httpStatus,
    this.created = 0,
    this.dateChanged = 0,
    this.restored = 0,
    this.missesAdvanced = 0,
    this.removed = 0,
    this.needsReview = 0,
    this.conflicts = 0,
    this.blocks = 0,
    this.durationMs = 0,
    this.skipped = false,
  });

  factory StaysChannelSyncResult.fromJson(Map<String, dynamic> j) => StaysChannelSyncResult(
        channelId: stayStr(j['channelId']),
        status: ChannelSyncStatus.fromWire(j['status']),
        httpStatus: stayIntOrNull(j['httpStatus']),
        created: stayInt(j['created']),
        dateChanged: stayInt(j['dateChanged']),
        restored: stayInt(j['restored']),
        missesAdvanced: stayInt(j['missesAdvanced']),
        removed: stayInt(j['removed']),
        needsReview: stayInt(j['needsReview']),
        conflicts: stayInt(j['conflicts']),
        blocks: stayInt(j['blocks']),
        durationMs: stayInt(j['durationMs']),
        skipped: stayTrue(j['skipped']),
      );

  final String channelId;
  final ChannelSyncStatus status;
  final int? httpStatus;
  final int created;
  final int dateChanged;
  final int restored;
  final int missesAdvanced;
  final int removed;
  final int needsReview;
  final int conflicts;
  final int blocks;
  final int durationMs;
  final bool skipped;
}

class StaysUpsertChannelRequest {
  const StaysUpsertChannelRequest({
    required this.facilityId,
    required this.listingId,
    required this.provider,
    required this.label,
    required this.url,
    required this.dryRun,
    this.importBlocks = true,
    this.channelId,
  });

  final String facilityId;
  final String listingId;
  final ChannelProvider provider;
  final String label;

  /// The channel's export link; sent once, stored server-side as a secret.
  final String url;
  final bool dryRun;
  final bool importBlocks;
  final String? channelId;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'listingId': listingId,
        'provider': provider.wire,
        'label': label,
        'url': url,
        'importBlocks': importBlocks,
        'dryRun': dryRun,
        'channelId': channelId,
      });
}

/// A dry run's preview, or the saved channel with its first sync.
sealed class StaysUpsertChannelResult {
  const StaysUpsertChannelResult();

  factory StaysUpsertChannelResult.fromJson(Map<String, dynamic> j) {
    if (j['dryRun'] == false) {
      return StaysChannelSaved(
        channelId: stayStr(j['channelId']),
        urlHost: stayStr(j['urlHost']),
        urlFingerprint: stayStr(j['urlFingerprint']),
        firstSync: StaysChannelSyncResult.fromJson(stayMap(j['firstSync'])),
      );
    }
    return StaysChannelPreview(
      status: ChannelSyncStatus.fromWire(j['status']),
      reservations: stayInt(j['reservations']),
      blocks: stayInt(j['blocks']),
      firstDate: stayStrOrNull(j['firstDate']),
      lastDate: stayStrOrNull(j['lastDate']),
      nextArrival: stayStrOrNull(j['nextArrival']),
      warnings: StaysWarning.listFrom(j['warnings']),
    );
  }
}

class StaysChannelPreview extends StaysUpsertChannelResult {
  const StaysChannelPreview({
    required this.status,
    this.reservations = 0,
    this.blocks = 0,
    this.firstDate,
    this.lastDate,
    this.nextArrival,
    this.warnings = const [],
  });

  final ChannelSyncStatus status;
  final int reservations;
  final int blocks;
  final String? firstDate;
  final String? lastDate;
  final String? nextArrival;
  final List<StaysWarning> warnings;
}

class StaysChannelSaved extends StaysUpsertChannelResult {
  const StaysChannelSaved({
    required this.channelId,
    required this.urlHost,
    required this.urlFingerprint,
    required this.firstSync,
  });

  final String channelId;
  final String urlHost;
  final String urlFingerprint;
  final StaysChannelSyncResult firstSync;
}

class StaysExportLinkUrl {
  const StaysExportLinkUrl({required this.linkId, required this.url});

  factory StaysExportLinkUrl.fromJson(Map<String, dynamic> j, {String? linkId}) =>
      StaysExportLinkUrl(linkId: stayStr(j['linkId'], linkId ?? ''), url: stayStr(j['url']));

  final String linkId;

  /// `https://{app}/api/ical/{token}.ics`: treat it as a secret.
  final String url;
}

class StaysRevokeExportLinkResult {
  const StaysRevokeExportLinkResult({required this.linkId, this.rotated, this.warnings = const []});

  factory StaysRevokeExportLinkResult.fromJson(Map<String, dynamic> j) => StaysRevokeExportLinkResult(
        linkId: stayStr(j['linkId']),
        rotated: j['rotated'] is Map ? StaysExportLinkUrl.fromJson(stayMap(j['rotated'])) : null,
        warnings: StaysWarning.listFrom(j['warnings']),
      );

  final String linkId;

  /// The new link when rotating; it must be re-pasted into the channel.
  final StaysExportLinkUrl? rotated;
  final List<StaysWarning> warnings;
}

// --- Airbnb CSV import ------------------------------------------------------------------------

class StaysImportAirbnbCsvRequest {
  const StaysImportAirbnbCsvRequest({
    required this.facilityId,
    required this.kind,
    required this.fileName,
    required this.csvText,
    required this.dryRun,
    this.mappingOverrides,
    this.listingAliasMap,
  });

  final String facilityId;

  /// 'earnings' | 'reservations'.
  final String kind;
  final String fileName;
  final String csvText;
  final bool dryRun;
  final Map<String, String>? mappingOverrides;
  final Map<String, String>? listingAliasMap;

  Map<String, dynamic> toJson() => _withoutNulls({
        'facilityId': facilityId,
        'kind': kind,
        'fileName': fileName,
        'csvText': csvText,
        'dryRun': dryRun,
        'mappingOverrides': mappingOverrides,
        'listingAliasMap': listingAliasMap,
      });
}

class StaysImportSample {
  const StaysImportSample({required this.row, required this.reason});

  factory StaysImportSample.fromJson(Map<String, dynamic> j) =>
      StaysImportSample(row: stayInt(j['row']), reason: stayStr(j['reason']));

  final int row;
  final String reason;
}

class StaysImportAirbnbCsvResult {
  const StaysImportAirbnbCsvResult({
    required this.batchId,
    required this.dryRun,
    this.kind = '',
    this.alreadyImportedAt,
    this.detectedMapping = const {},
    this.missingRequired = const [],
    this.rowCount = 0,
    this.created = 0,
    this.skippedDuplicate = 0,
    this.needsReview = 0,
    this.rejected = 0,
    this.samples = const [],
    this.grossCents = 0,
    this.channelFeeCents = 0,
    this.netCents = 0,
    this.taxCents = 0,
    this.payoutCents = 0,
    this.dateFrom,
    this.dateTo,
    this.matchedListings = const {},
    this.unmatchedListings = const [],
    this.matchedStays = 0,
    this.createdStays = 0,
  });

  factory StaysImportAirbnbCsvResult.fromJson(Map<String, dynamic> j) {
    final mapping = stayMap(j['mapping']);
    final totals = stayMap(j['totals']);
    final range = stayMap(j['dateRange']);
    return StaysImportAirbnbCsvResult(
      batchId: stayStr(j['batchId']),
      kind: stayStr(j['kind']),
      dryRun: stayTrue(j['dryRun']),
      alreadyImportedAt: stayTime(j['alreadyImportedAt']),
      detectedMapping: stayMap(mapping['detected']).map((k, v) => MapEntry(k, stayStr(v))),
      missingRequired: stayStrList(mapping['missingRequired']),
      rowCount: stayInt(j['rowCount']),
      created: stayInt(j['created']),
      skippedDuplicate: stayInt(j['skippedDuplicate']),
      needsReview: stayInt(j['needsReview']),
      rejected: stayInt(j['rejected']),
      samples: stayMapList(j['samples']).map(StaysImportSample.fromJson).toList(),
      grossCents: stayInt(totals['grossCents']),
      channelFeeCents: stayInt(totals['channelFeeCents']),
      netCents: stayInt(totals['netCents']),
      taxCents: stayInt(totals['taxCents']),
      payoutCents: stayInt(totals['payoutCents']),
      dateFrom: stayStrOrNull(range['from']),
      dateTo: stayStrOrNull(range['to']),
      matchedListings: {
        for (final m in stayMapList(j['matchedListings'])) stayStr(m['name']): stayStr(m['listingId']),
      },
      unmatchedListings: stayStrList(j['unmatchedListings']),
      matchedStays: stayInt(j['matchedStays']),
      createdStays: stayInt(j['createdStays']),
    );
  }

  final String batchId;
  final String kind;
  final bool dryRun;
  final DateTime? alreadyImportedAt;
  final Map<String, String> detectedMapping;
  final List<String> missingRequired;
  final int rowCount;
  final int created;
  final int skippedDuplicate;
  final int needsReview;
  final int rejected;
  final List<StaysImportSample> samples;
  final int grossCents;
  final int channelFeeCents;
  final int netCents;
  final int taxCents;
  final int payoutCents;
  final String? dateFrom;
  final String? dateTo;

  /// Airbnb listing name → listingId.
  final Map<String, String> matchedListings;
  final List<String> unmatchedListings;
  final int matchedStays;
  final int createdStays;

  /// A commit needs every required column mapped.
  bool get canCommit => missingRequired.isEmpty;
}
