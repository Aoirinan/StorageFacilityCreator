import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_notification_model.dart';
import 'package:sfcapp/models/feature_flag_model.dart';
import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_access.dart';
import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_controls.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_folio.dart';
import 'package:sfcapp/models/stays/stay_guest_profile.dart';
import 'package:sfcapp/models/stays/stay_income_entry.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stay_night_lock_bucket.dart';
import 'package:sfcapp/models/stays/stay_private.dart';
import 'package:sfcapp/models/stays/stay_task.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/services/stays/stays_callables.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';
import 'package:sfcapp/services/stays/stays_repository.dart';

import 'support/fake_stays_repository.dart';

void main() {
  group('stay controls', () {
    test('a missing doc is all off, with no zone', () {
      final c = StayControls.fromMap(const {}, facilityId: 'f1');
      expect(c.moduleEnabled, isFalse);
      expect(c.timeZone, isNull);
      expect(c.confirmedTimeZone, isNull);
      expect(c.icalSyncEnabled, isFalse);
      expect(c.icalExportEnabled, isFalse);
      expect(c.employeesCanBook, isFalse);
      expect(c.employeesCanRecordCash, isFalse);
      expect(c.guestMessagingEnabled, isFalse);
      expect(c.directPaymentsEnabled, isFalse);
      expect(c.defaultCheckInTime, '15:00');
      expect(c.defaultCheckOutTime, '11:00');
      expect(c.dailyBriefLocalHour, 7);
      expect(c.paymentMethods, StayControls.defaultPaymentMethods);
    });

    test('switches count only when exactly true', () {
      final c = StayControls.fromMap(const {
        'moduleEnabled': 'true',
        'icalSyncEnabled': 1,
        'employeesCanBook': true,
        'dailyBriefLocalHour': 99,
      }, facilityId: 'f1');
      expect(c.moduleEnabled, isFalse);
      expect(c.icalSyncEnabled, isFalse);
      expect(c.employeesCanBook, isTrue);
      expect(c.dailyBriefLocalHour, 7);
    });

    test('a zone is usable only once confirmed', () {
      final unconfirmed = StayControls.fromMap(const {'timeZone': 'America/Denver'}, facilityId: 'f1');
      expect(unconfirmed.confirmedTimeZone, isNull);
      final confirmed = StayControls.fromMap(
        {'timeZone': 'America/Denver', 'timeZoneConfirmedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 1))},
        facilityId: 'f1',
      );
      expect(confirmed.confirmedTimeZone, 'America/Denver');
    });

    test('unknown payment methods are dropped', () {
      final c = StayControls.fromMap(const {
        'paymentMethods': ['cash', 'bitcoin', 'airbnb', 'venmo'],
      }, facilityId: 'f1');
      expect(c.paymentMethods, [StayIncomeMethod.cash, StayIncomeMethod.venmo]);
    });
  });

  group('enums', () {
    test('unknown strings read as unknown, never as a real value', () {
      expect(StayStatus.fromWire('exploded'), StayStatus.unknown);
      expect(StayStatus.fromWire(null), StayStatus.unknown);
      expect(StayKind.fromWire(42), StayKind.unknown);
      expect(StaySource.fromWire('walk_up'), StaySource.walkUp);
      expect(StayArrivalState.fromWire('checked_in'), StayArrivalState.checkedIn);
      expect(AccessCodeMode.fromWire('static'), AccessCodeMode.staticCode);
      expect(StaysErrorReason.fromWire('hard_conflict'), StaysErrorReason.hardConflict);
      expect(StaysErrorReason.fromWire('something_new'), StaysErrorReason.unknown);
    });

    test('only confirmed and conflict stays hold nights', () {
      expect(StayStatus.values.where((s) => s.isActive), [StayStatus.confirmed, StayStatus.conflict]);
    });

    test('every wire value round-trips', () {
      for (final values in <List<WireEnum>>[
        StayListingKind.values,
        StayKind.values,
        StaySource.values,
        StayStatus.values,
        StayArrivalState.values,
        StayPaymentStatus.values,
        StayTaskStatus.values,
        StayIncomeKind.values,
        StaysErrorReason.values,
      ]) {
        final wires = values.map((v) => v.wire).toList();
        expect(wires.toSet().length, wires.length, reason: 'duplicate wire value in $values');
      }
    });
  });

  group('stay', () {
    Map<String, dynamic> base() => {
          'facilityId': 'f1',
          'listingId': 'lst1',
          'checkIn': '2026-10-03',
          'checkOut': '2026-10-06',
          'kind': 'reservation',
          'source': 'airbnb',
          'status': 'confirmed',
        };

    test('reads a sparse doc with safe defaults', () {
      final s = Stay.fromMap('airbnb_HM12345678', base());
      expect(s.arrivalState, StayArrivalState.upcoming);
      expect(s.paymentStatus, StayPaymentStatus.none);
      expect(s.guestDisplayName, '');
      expect(s.tags, isEmpty);
      expect(s.messageMarks, isEmpty);
      expect(s.conflict, isNull);
      expect(s.isActive, isTrue);
      expect(s.checkInDate?.toYmd(), '2026-10-03');
    });

    test('nights are checkIn up to, not including, checkOut', () {
      final s = Stay.fromMap('s1', base());
      expect(s.coversNight('2026-10-03'), isTrue);
      expect(s.coversNight('2026-10-05'), isTrue);
      expect(s.coversNight('2026-10-06'), isFalse);
      expect(s.coversNight('2026-10-02'), isFalse);
    });

    test('an unnamed Airbnb guest shows the code, never a phone number', () {
      final s = Stay.fromMap('airbnb_HMABCD1234', {
        ...base(),
        'external': {'provider': 'airbnb', 'confirmationCode': 'HMABCD1234'},
      });
      expect(s.guestLabel, 'Airbnb guest (…1234)');
      expect(Stay.fromMap('s2', {...base(), 'guestDisplayName': 'Jane D.'}).guestLabel, 'Jane D.');
      expect(Stay.fromMap('s3', {...base(), 'kind': 'owner_block'}).guestLabel, 'Owner block');
    });

    test('message marks and timestamps read from Timestamps or ISO strings', () {
      final s = Stay.fromMap('s1', {
        ...base(),
        'messageMarks': {'airbnb_check_in': Timestamp.fromDate(DateTime.utc(2026, 10, 2, 22, 10)), 'bad': 'nope'},
        'checkedInAt': '2026-10-03T21:00:00.000Z',
      });
      expect(s.messageMarks.keys, ['airbnb_check_in']);
      expect(s.checkedInAt, DateTime.utc(2026, 10, 3, 21));
    });
  });

  group('other docs', () {
    test('a listing with nothing set is inactive and has no turnover', () {
      final l = StayListing.fromMap('lst1', const {'name': 'Airbnb 1'});
      expect(l.isBookable, isFalse);
      expect(l.turnover.mode, TurnoverMode.none);
      expect(l.accessCodeMode, AccessCodeMode.none);
      expect(l.minNights, 1);
      expect(l.maxNights, 180);
      expect(l.rv, isNull);
      expect(l.displayGroup, 'Listings');
      expect(StayListing.fromMap('rv1', const {'name': 'RV 1', 'kind': 'rv_site'}).displayGroup, 'RV park');
    });

    test('a listing round-trips its editable fields', () {
      final l = StayListing.fromMap('lst1', {
        'name': 'RV 3',
        'kind': 'rv_site',
        'active': true,
        'rv': {'hookup': 'full', 'amps': [30, 50], 'maxLengthFt': 40, 'pullThrough': true},
        'ratesCents': {'nightly': 4500, 'weeklyNightly': 4000},
        'taxLines': [
          {'code': 'lodging', 'label': 'Lodging tax', 'rateBps': 400, 'appliesTo': ['lodging']},
        ],
      });
      final again = StayListing.fromMap('lst1', l.toInputMap());
      expect(again.rv?.amps, [30, 50]);
      expect(again.rates.nightly, 4500);
      expect(again.rates.weeklyNightly, 4000);
      expect(again.taxLines.single.rateBps, 400);
      expect(again.taxLines.single.toMap()['remittedBy'], 'owner');
    });

    test('money reads whole numbers only', () {
      final e = StayIncomeEntry.fromMap('man_x', const {
        'grossCents': 4500.0,
        'netCents': 12.5,
        'status': 'posted',
        'countsAsIncome': true,
      });
      expect(e.grossCents, 4500);
      expect(e.netCents, 0);
      expect(e.isCountedIncome, isTrue);
      expect(StayIncomeEntry.fromMap('p', const {'status': 'posted', 'countsAsIncome': false}).isCountedIncome, isFalse);
      final folio = StayFolio.fromMap('s1', const {
        'totalCents': 45000,
        'adjustment': {'cents': -500, 'reason': 'Repeat guest'},
      });
      expect(folio.adjustmentCents, -500);
      expect(folio.balanceCents, 0);
    });

    test('a task reads its checklist progress', () {
      final t = StayTask.fromMap('turnover_s1', const {
        'category': 'turnover',
        'status': 'in_progress',
        'checklist': [
          {'id': 'a', 'label': 'Towels', 'done': true},
          {'id': 'b', 'label': 'Trash', 'done': false},
        ],
      });
      expect(t.isTurnover, isTrue);
      expect(t.progress, 0.5);
      expect(t.priority, StayTaskPriority.normal);
      expect(StayTask.fromMap('x', const {'status': 'weird'}).status, StayTaskStatus.unknown);
    });

    test('lock buckets, channels, private and access docs read defensively', () {
      final b = StayNightLockBucket.fromMap('lst1_2026-10', const {
        'nights': {
          '2026-10-03': {'s': 'man_x', 'h': true, 'src': 'direct', 'k': 'reservation'},
          '2026-10-04': {'s': 'blk:ch1', 'h': false, 'src': 'airbnb', 'k': 'channel_block', 'e': true},
          'junk': 5,
        },
      });
      expect(b.nights.keys, ['2026-10-03', '2026-10-04']);
      expect(b.nights['2026-10-04']!.channelId, 'ch1');
      expect(b.nights['2026-10-04']!.echo, isTrue);
      final c = StayChannel.fromMap('ch1', const {'active': true});
      expect(c.importBlocks, isTrue);
      expect(c.isStale(DateTime.utc(2026)), isTrue);
      expect(StayPrivate.fromMap('s1', const {}).fullName, isNull);
      expect(StayAccess.fromMap('s1', const {}).source, StayAccessSource.manual);
    });
  });

  group('notifications and flags', () {
    test('every Stays notification type is known, and unknown types read as other', () {
      for (final wire in StayNotificationTypes.all) {
        final type = FacilityNotificationTypeX.fromString(wire);
        expect(type.value, wire);
        expect(type.isStay, isTrue);
      }
      expect(FacilityNotificationTypeX.fromString('AUTOPAY_PAYMENT_FAILED'), FacilityNotificationType.other);
      expect(FacilityNotificationTypeX.fromString(null), FacilityNotificationType.other);
      expect(FacilityNotificationTypeX.fromString('AUTOPAY_ENABLED'), FacilityNotificationType.autopayEnabled);
    });

    test('the shortTermRentals flag ships off and high risk', () {
      final flag = kDefaultFeatureFlags.singleWhere((f) => f.key == 'shortTermRentals');
      expect(flag.enabled, isFalse);
      expect(flag.riskLevel, FlagRiskLevel.high);
    });
  });

  group('callable models', () {
    test('requests leave out what is not set', () {
      const req = StaysCreateStayRequest(
        facilityId: 'f1',
        requestId: '0123456789abcdef0123456789abcdef',
        listingId: 'lst1',
        checkIn: '2026-10-03',
        checkOut: '2026-10-04',
        kind: StayKind.reservation,
        source: StaySource.walkUp,
        guest: StayGuestInput(displayName: 'Rick R.', adults: 2),
        payment: StayPaymentInput(method: StayIncomeMethod.cash, amountCents: 4500, receivedDate: '2026-10-03'),
      );
      final json = req.toJson();
      expect(json['kind'], 'reservation');
      expect(json['source'], 'walk_up');
      expect(json['payment'], {'method': 'cash', 'amountCents': 4500, 'receivedDate': '2026-10-03'});
      expect(json.containsKey('adjustment'), isFalse);
      expect(json.containsKey('times'), isFalse);
      expect(const StayControlsChanges(moduleEnabled: true).toJson(), {'moduleEnabled': true});
    });

    test('a guest profile is a reference or a create, never both', () {
      expect(const StayGuestProfileRef.existing('gp_1').toJson(), {'profileId': 'gp_1'});
      expect(const StayGuestProfileRef.create(name: 'Rick Rover').toJson(), {
        'create': {'name': 'Rick Rover'},
      });
    });

    test('responses parse, with ISO timestamps', () {
      final result = StaysCreateStayResult.fromJson(const {
        'stayId': 'man_x',
        'created': false,
        'status': 'confirmed',
        'folio': {'totalCents': 9000, 'paidCents': 4500, 'balanceCents': 4500},
        'warnings': [
          {'code': 'short_lead', 'message': 'Block these dates in Airbnb too.'},
        ],
      });
      expect(result.created, isFalse);
      expect(result.folio?.balanceCents, 4500);
      expect(result.warnings.single.code, 'short_lead');
      final saved = StaysUpsertChannelResult.fromJson(const {
        'dryRun': false,
        'channelId': 'ch1',
        'urlHost': 'www.airbnb.com',
        'urlFingerprint': 'abc',
        'firstSync': {'channelId': 'ch1', 'status': 'ok', 'created': 6},
      });
      expect(saved, isA<StaysChannelSaved>());
      expect((saved as StaysChannelSaved).firstSync.created, 6);
      expect(StaysUpsertChannelResult.fromJson(const {'dryRun': true, 'status': 'ok', 'reservations': 6}), isA<StaysChannelPreview>());
    });

    test('a callable failure keeps its reason and details', () {
      final e = staysExceptionFrom(FirebaseFunctionsException(
        code: 'already-exists',
        message: 'Those nights are already booked.',
        details: {
          'reason': 'hard_conflict',
          'nights': [
            {'date': '2026-10-03', 'stayId': 'airbnb_HM1234567', 'label': 'Jane D. · 2026-10-03 to 2026-10-06'},
          ],
        },
      ));
      expect(e.reason, StaysErrorReason.hardConflict);
      expect(e.code, 'already-exists');
      expect(e.conflictNights.single.stayId, 'airbnb_HM1234567');
      final soft = staysExceptionFrom(FirebaseFunctionsException(
        code: 'failed-precondition',
        message: 'soft',
        details: {
          'reason': 'soft_block',
          'dates': ['2026-10-04'],
        },
      ));
      expect(soft.softBlockDates, ['2026-10-04']);
      final party = staysExceptionFrom(FirebaseFunctionsException(
        code: 'failed-precondition',
        message: 'The number of guests changed since this booking was priced.',
        details: {
          'reason': 'party_reprice_required',
          'pricedParty': {'adults': 2, 'children': 0, 'pets': 0},
          'party': {'adults': 3, 'children': 1, 'pets': 1},
        },
      ));
      expect(party.reason, StaysErrorReason.partyRepriceRequired);
      expect(staysExceptionFrom(Exception('offline')).reason, StaysErrorReason.unknown);
      expect(staysExceptionFrom(FirebaseFunctionsException(code: 'internal', message: 'x')).reason, StaysErrorReason.unknown);
    });

    test('a modify sends repriceParty only when a choice was made', () {
      const base = StaysModifyStayRequest(facilityId: 'f1', stayId: 'man_1', expectedVersion: 3, changes: StaysModifyStayChanges(checkOut: '2026-10-09'));
      expect(base.toJson().containsKey('repriceParty'), isFalse);
      const keep = StaysModifyStayRequest(
        facilityId: 'f1',
        stayId: 'man_1',
        expectedVersion: 3,
        changes: StaysModifyStayChanges(checkOut: '2026-10-09'),
        repriceParty: false,
      );
      expect(keep.toJson()['repriceParty'], isFalse);
    });

    test('a modify sends only the guest fields it changes, never a party it did not set', () {
      const rename = StaysModifyStayChanges(guest: StayGuestPatch(displayName: 'Ann B.'));
      expect(rename.toJson(), {
        'guest': {'displayName': 'Ann B.'},
      });
      expect(const StayGuestPatch(adults: 3).toJson(), {'adults': 3});
      expect(const StayGuestPatch(clearRvLength: true).toJson(), {'rvLengthFt': null});
      expect(const StayGuestPatch(rvLengthFt: 32, clearRvLength: true).toJson(), {'rvLengthFt': 32});
    });
  });
  group('guest consent', () {
    const draft = StayGuestProfileDraft(name: 'Rick Rover', consentEmail: true, consentSms: false, consentMethod: ConsentMethod.verbal);
    final recorded = StayGuestConsent(
      email: true,
      sms: false,
      method: ConsentMethod.verbal,
      recordedAt: DateTime.utc(2026, 9, 1),
      recordedBy: 'uid-owner',
    );

    test('only a change to the answers records new consent', () {
      expect(draft.changesConsent(null), isTrue);
      expect(draft.changesConsent(recorded), isFalse);
      const smsToo = StayGuestProfileDraft(name: 'Rick Rover', consentEmail: true, consentSms: true, consentMethod: ConsentMethod.verbal);
      expect(smsToo.changesConsent(recorded), isTrue);
      const written = StayGuestProfileDraft(name: 'Rick Rover', consentEmail: true, consentSms: false, consentMethod: ConsentMethod.written);
      expect(written.changesConsent(recorded), isTrue);
      expect(const StayGuestProfileDraft(name: 'Rick Rover').changesConsent(null), isFalse);
    });

    test('re-saving a profile keeps when and by whom consent was captured', () async {
      final repo = FakeStaysRepository(uid: 'uid-manager', now: () => DateTime.utc(2026, 10, 1));
      final id = await repo.createGuestProfile('f1', draft);
      expect(repo.writes.last.data['consent'], isA<Map<String, dynamic>>());

      await repo.updateGuestProfile(
        'f1',
        id,
        const StayGuestProfileDraft(name: 'Rick R. Rover', consentEmail: true, consentSms: false, consentMethod: ConsentMethod.verbal),
      );
      expect(repo.writes.last.data.containsKey('consent'), isFalse);
      expect(repo.read('f1', StaysCollections.guestProfiles, id)!['name'], 'Rick R. Rover');

      await repo.updateGuestProfile(
        'f1',
        id,
        const StayGuestProfileDraft(name: 'Rick R. Rover', consentEmail: true, consentSms: true, consentMethod: ConsentMethod.verbal),
      );
      expect((repo.writes.last.data['consent'] as Map)['sms'], isTrue);
    });
  });
}
