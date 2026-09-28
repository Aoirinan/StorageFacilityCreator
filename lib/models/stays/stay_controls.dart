import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayControls/current: the module and automation switches
/// and the confirmed zone. Only the staysSetControls callable writes it.
class StayControls {
  const StayControls({
    required this.facilityId,
    this.moduleEnabled = false,
    this.timeZone,
    this.timeZoneConfirmedAt,
    this.timeZoneConfirmedBy,
    this.icalSyncEnabled = false,
    this.icalExportEnabled = false,
    this.turnoverTasksEnabled = false,
    this.dailyBriefEnabled = false,
    this.dailyBriefLocalHour = 7,
    this.lodgingTaxEnabled = false,
    this.employeesCanBook = false,
    this.employeesCanRecordCash = false,
    this.defaultCheckInTime = '15:00',
    this.defaultCheckOutTime = '11:00',
    this.shortLeadWarningHours = 72,
    this.paymentMethods = defaultPaymentMethods,
    this.parkRules = '',
    this.quietHours = '',
    this.guestMessagingEnabled = false,
    this.directPaymentsEnabled = false,
    this.templatesSeededAt,
    this.updatedAt,
    this.updatedBy,
    this.version = 0,
  });

  static const List<StayIncomeMethod> defaultPaymentMethods = [
    StayIncomeMethod.cash,
    StayIncomeMethod.check,
    StayIncomeMethod.cardExternal,
    StayIncomeMethod.venmo,
    StayIncomeMethod.other,
  ];

  /// No doc yet: everything off.
  factory StayControls.defaults(String facilityId) => StayControls(facilityId: facilityId);

  factory StayControls.fromFirestore(DocumentSnapshot<Object?> doc, {required String facilityId}) =>
      doc.exists ? StayControls.fromMap(stayDocData(doc), facilityId: facilityId) : StayControls.defaults(facilityId);

  factory StayControls.fromMap(Map<String, dynamic> d, {required String facilityId}) {
    final hour = stayIntOrNull(d['dailyBriefLocalHour']);
    final methods = d['paymentMethods'] is List
        ? stayStrList(d['paymentMethods'])
            .map(StayIncomeMethod.fromWire)
            .where((m) => StayIncomeMethod.manual.contains(m))
            .toList(growable: false)
        : defaultPaymentMethods;
    final tz = stayStrOrNull(d['timeZone']);
    return StayControls(
      facilityId: stayStr(d['facilityId'], facilityId),
      moduleEnabled: stayTrue(d['moduleEnabled']),
      timeZone: tz == null || tz.isEmpty ? null : tz,
      timeZoneConfirmedAt: stayTime(d['timeZoneConfirmedAt']),
      timeZoneConfirmedBy: stayStrOrNull(d['timeZoneConfirmedBy']),
      icalSyncEnabled: stayTrue(d['icalSyncEnabled']),
      icalExportEnabled: stayTrue(d['icalExportEnabled']),
      turnoverTasksEnabled: stayTrue(d['turnoverTasksEnabled']),
      dailyBriefEnabled: stayTrue(d['dailyBriefEnabled']),
      dailyBriefLocalHour: hour != null && hour >= 0 && hour <= 23 ? hour : 7,
      lodgingTaxEnabled: stayTrue(d['lodgingTaxEnabled']),
      employeesCanBook: stayTrue(d['employeesCanBook']),
      employeesCanRecordCash: stayTrue(d['employeesCanRecordCash']),
      defaultCheckInTime: stayStr(d['defaultCheckInTime'], '15:00'),
      defaultCheckOutTime: stayStr(d['defaultCheckOutTime'], '11:00'),
      shortLeadWarningHours: stayInt(d['shortLeadWarningHours'], 72),
      paymentMethods: methods,
      parkRules: stayStr(d['parkRules']),
      quietHours: stayStr(d['quietHours']),
      guestMessagingEnabled: stayTrue(d['guestMessagingEnabled']),
      directPaymentsEnabled: stayTrue(d['directPaymentsEnabled']),
      templatesSeededAt: stayTime(d['templatesSeededAt']),
      updatedAt: stayTime(d['updatedAt']),
      updatedBy: stayStrOrNull(d['updatedBy']),
      version: stayInt(d['version']),
    );
  }

  final String facilityId;
  final bool moduleEnabled;
  final String? timeZone;
  final DateTime? timeZoneConfirmedAt;
  final String? timeZoneConfirmedBy;
  final bool icalSyncEnabled;
  final bool icalExportEnabled;
  final bool turnoverTasksEnabled;
  final bool dailyBriefEnabled;
  final int dailyBriefLocalHour;
  final bool lodgingTaxEnabled;
  final bool employeesCanBook;
  final bool employeesCanRecordCash;
  final String defaultCheckInTime;
  final String defaultCheckOutTime;
  final int shortLeadWarningHours;
  final List<StayIncomeMethod> paymentMethods;
  final String parkRules;
  final String quietHours;

  /// Reserved for later automation; v1 never turns these on.
  final bool guestMessagingEnabled;
  final bool directPaymentsEnabled;
  final DateTime? templatesSeededAt;
  final DateTime? updatedAt;
  final String? updatedBy;
  final int version;

  /// The zone to use for facility dates, or null until the owner confirms one.
  String? get confirmedTimeZone => timeZoneConfirmedAt != null && timeZone != null ? timeZone : null;

  bool get isTimeZoneConfirmed => confirmedTimeZone != null;
}
