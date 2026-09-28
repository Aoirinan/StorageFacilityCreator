import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stay_task.dart';
import 'package:sfcapp/services/stays/today_board.dart';
import 'package:sfcapp/utils/local_date.dart';

// A fixed facility-local day: Saturday 3 October 2026.
final _today = LocalDate(2026, 10, 3);
final _now = DateTime.utc(2026, 10, 3, 16);

StayListing _listing(String id, String name, String group, {String kind = 'vacation_rental', bool active = true}) =>
    StayListing.fromMap(id, {
      'facilityId': 'f1',
      'name': name,
      'group': group,
      'kind': kind,
      'active': active,
      'archived': false,
    });

Stay _stay(
  String id,
  String listingId,
  String checkIn,
  String checkOut, {
  String kind = 'reservation',
  String source = 'direct',
  String status = 'confirmed',
  String arrival = 'upcoming',
  String name = 'Guest',
  String payment = 'none',
  String checkInTime = '15:00',
  String checkOutTime = '11:00',
  Map<String, dynamic>? sync,
  Map<String, dynamic>? external,
  Map<String, dynamic>? conflict,
}) =>
    Stay.fromMap(id, {
      'facilityId': 'f1',
      'listingId': listingId,
      'listingName': listingId,
      'kind': kind,
      'source': source,
      'status': status,
      'arrivalState': arrival,
      'checkIn': checkIn,
      'checkOut': checkOut,
      'checkInTime': checkInTime,
      'checkOutTime': checkOutTime,
      'guestDisplayName': name,
      'paymentStatus': payment,
      if (sync != null) 'sync': sync,
      if (external != null) 'external': external,
      if (conflict != null) 'conflict': conflict,
    });

StayTask _task(
  String id, {
  required String listingId,
  required String dueDate,
  String status = 'todo',
  bool sameDay = false,
  String? assignee,
  String issue = '',
  String? stayId,
  String dueStartLocal = '',
}) =>
    StayTask.fromMap(id, {
      'facilityId': 'f1',
      'category': 'turnover',
      'listingId': listingId,
      'stayId': stayId,
      'dueDate': dueDate,
      'dueStartLocal': dueStartLocal.isEmpty ? '$dueDate 11:00' : dueStartLocal,
      'status': status,
      'sameDayTurn': sameDay,
      'assigneeUid': assignee,
      'issueNote': issue,
    });

StayChannel _channel(String id, {Map<String, dynamic> sync = const {}, bool active = true, String label = 'Airbnb A1'}) =>
    StayChannel.fromMap(id, {
      'listingId': 'a1',
      'provider': 'airbnb',
      'label': label,
      'active': active,
      'sync': sync,
    });

final _listings = [
  _listing('a1', 'Airbnb 1', 'Airbnbs'),
  _listing('a2', 'Airbnb 2', 'Airbnbs'),
  _listing('rv1', 'RV 1', 'RV park', kind: 'rv_site'),
  _listing('rv2', 'RV 2', 'RV park', kind: 'rv_site'),
  _listing('rv3', 'RV 3', 'RV park', kind: 'rv_site'),
  _listing('h1', 'The House', 'House', kind: 'house'),
  _listing('old', 'Old cabin', 'Airbnbs', active: false),
];

void main() {
  group('headline', () {
    test('counts tonight per group, and the money only when it may be shown', () {
      final stays = [
        _stay('s1', 'a1', '2026-10-02', '2026-10-05', arrival: 'checked_in'),
        _stay('s2', 'a2', '2026-10-03', '2026-10-04'),
        _stay('s3', 'rv1', '2026-10-01', '2026-10-06', arrival: 'checked_in'),
        // Checks out this morning: not a night tonight.
        _stay('s4', 'rv2', '2026-10-01', '2026-10-03', arrival: 'checked_in'),
        // Cancelled and blocks do not count as booked.
        _stay('s5', 'h1', '2026-10-03', '2026-10-05', status: 'cancelled'),
        _stay('s6', 'rv3', '2026-10-03', '2026-10-05', kind: 'owner_block', name: ''),
      ];
      final owner = buildTodayBoard(
        today: _today,
        listings: _listings,
        stays: stays,
        showMoney: true,
        netThisMonthCents: 234000,
      );
      expect(owner.headline.groups.map((g) => g.label), ['Airbnbs 2/2', 'RV park 1/3', 'House vacant']);
      expect(owner.headline.text(), 'Airbnbs 2/2 booked · RV park 1/3 · House vacant · \$2,340 net this month');

      final employee = buildTodayBoard(
        today: _today,
        listings: _listings,
        stays: stays,
        showMoney: false,
        netThisMonthCents: 234000,
      );
      expect(employee.headline.netThisMonthCents, isNull);
      expect(employee.headline.text(), isNot(contains(r'$')));
    });

    test('no listings yet', () {
      expect(buildTodayBoard(today: _today, listings: const [], stays: const []).headline.text(), 'No listings yet');
    });
  });

  group('arrivals, departures and in-house', () {
    final stays = [
      _stay('late', 'a2', '2026-10-03', '2026-10-05', checkInTime: '16:00', name: 'Late L.'),
      _stay('early', 'rv1', '2026-10-03', '2026-10-04', checkInTime: '12:00', source: 'walk_up', name: 'Early E.'),
      _stay('arrived', 'rv2', '2026-10-03', '2026-10-04', arrival: 'checked_in', name: 'Here H.'),
      _stay('leaving', 'a1', '2026-09-30', '2026-10-03', arrival: 'checked_in', name: 'Going G.'),
      _stay('staying', 'h1', '2026-10-01', '2026-10-07', arrival: 'checked_in', name: 'Stay S.'),
      _stay('overdue', 'rv3', '2026-09-28', '2026-10-02', arrival: 'checked_in', name: 'Over O.'),
      _stay('gone', 'a1', '2026-10-03', '2026-10-06', status: 'cancelled', name: 'Cancel C.'),
      _stay('tomorrow', 'a1', '2026-10-04', '2026-10-06', name: 'Next N.'),
      _stay('noshow', 'rv3', '2026-10-01', '2026-10-03', arrival: 'no_show', name: 'Never N.'),
    ];
    final tasks = [_task('turnover_leaving', listingId: 'a1', dueDate: '2026-10-03', stayId: 'leaving', status: 'in_progress')];
    final board = buildTodayBoard(today: _today, listings: _listings, stays: stays, tasks: tasks);

    test('arrivals are today, not yet checked in, earliest first', () {
      expect(board.arrivals.map((r) => r.stay.id), ['early', 'late']);
      expect(board.arrivals.first.time, '12:00');
      expect(board.arrivals.first.listingName, 'RV 1');
    });

    test('departures carry their turnover status; no-shows are not departures', () {
      expect(board.departures.map((r) => r.stay.id), ['leaving']);
      expect(board.departures.single.turnoverStatus, StayTaskStatus.inProgress);
    });

    test('in-house guests are checked in and leave after today', () {
      expect(board.inHouse.map((r) => r.stay.id), ['arrived', 'staying']);
    });

    test('a guest still checked in after checkout day is overdue, and needs attention', () {
      expect(board.overdueDepartures.map((r) => r.stay.id), ['overdue']);
      final item = board.needsAttention.firstWhere((a) => a.kind == AttentionKind.overdueDeparture);
      expect(item.stayId, 'overdue');
      expect(item.high, isTrue);
    });

    test('tomorrow shows the next arrivals and departures', () {
      expect(board.tomorrow.arrivals.map((r) => r.stay.id), ['tomorrow']);
      // Both leave at 11:00, so by listing name.
      expect(board.tomorrow.departures.map((r) => r.stay.id), ['early', 'arrived']);
    });

    test('the badge is arrivals today plus open conflicts', () {
      expect(board.badgeCount, 2);
    });
  });

  group('payment chips and balances', () {
    final stays = [
      _stay('abnb', 'a1', '2026-10-03', '2026-10-05', source: 'airbnb', payment: 'channel_collected'),
      _stay('due', 'rv1', '2026-10-03', '2026-10-04', source: 'walk_up', payment: 'due'),
      _stay('paid', 'rv2', '2026-10-03', '2026-10-04', source: 'phone', payment: 'paid'),
      _stay('part', 'h1', '2026-10-05', '2026-10-08', source: 'direct', payment: 'partial'),
    ];

    test('owners and managers see chips and balances due', () {
      final board = buildTodayBoard(today: _today, listings: _listings, stays: stays, showMoney: true);
      final chips = {for (final r in board.arrivals) r.stay.id: r.paymentChip};
      expect(chips, {'abnb': PaymentChip.airbnbPaid, 'due': PaymentChip.due, 'paid': PaymentChip.paid});
      expect(
        board.needsAttention.where((a) => a.kind == AttentionKind.balanceDue).map((a) => a.stayId),
        unorderedEquals(['due', 'part']),
      );
    });

    test('an employee sees no chips and no balances', () {
      final board = buildTodayBoard(today: _today, listings: _listings, stays: stays, showMoney: false);
      expect(board.arrivals.every((r) => r.paymentChip == null), isTrue);
      expect(board.needsAttention.where((a) => a.kind == AttentionKind.balanceDue), isEmpty);
      expect(board.showMoney, isFalse);
    });
  });

  group('needs attention', () {
    test('conflicts, removals, reviews and unnamed arrivals', () {
      final board = buildTodayBoard(
        today: _today,
        listings: _listings,
        stays: [
          _stay('c1', 'a1', '2026-10-04', '2026-10-06', status: 'conflict', conflict: {
            'stayIds': ['x'],
            'nights': ['2026-10-04'],
          }),
          _stay('c2', 'a2', '2026-10-04', '2026-10-06', status: 'conflict', conflict: {
            'stayIds': ['y'],
            'nights': ['2026-10-04'],
            'acknowledgedAt': '2026-10-02T12:00:00.000Z',
          }),
          // A past conflict is history, not a to-do.
          _stay('c3', 'a2', '2026-09-01', '2026-09-03', status: 'conflict'),
          _stay('r1', 'a1', '2026-10-10', '2026-10-12', status: 'removed_from_feed', source: 'airbnb'),
          _stay('rev', 'rv1', '2026-10-01', '2026-10-05', arrival: 'checked_in', sync: {'needsReview': true, 'channelId': 'ch1'}),
          _stay('noname', 'a2', '2026-10-06', '2026-10-08', source: 'airbnb', name: '', external: {
            'provider': 'airbnb',
            'confirmationCode': 'HMXYZ98765',
          }),
          // Four days out: not yet.
          _stay('noname-later', 'a1', '2026-10-07', '2026-10-09', source: 'airbnb', name: ''),
        ],
      );
      List<String?> ids(AttentionKind kind) =>
          board.needsAttention.where((a) => a.kind == kind).map((a) => a.stayId).toList();
      expect(ids(AttentionKind.conflict), unorderedEquals(['c1', 'c2']));
      expect(board.needsAttention.firstWhere((a) => a.stayId == 'c1').high, isTrue);
      expect(board.needsAttention.firstWhere((a) => a.stayId == 'c2').high, isFalse);
      expect(ids(AttentionKind.removedFromFeed), ['r1']);
      expect(ids(AttentionKind.needsReview), ['rev']);
      expect(ids(AttentionKind.arrivalMissingName), ['noname']);
      expect(board.needsAttention.firstWhere((a) => a.stayId == 'noname').title, contains('Airbnb guest (…8765)'));
      // High items first.
      final highs = board.needsAttention.takeWhile((a) => a.high).length;
      expect(board.needsAttention.skip(highs).any((a) => a.high), isFalse);
    });

    test('turnovers: same-day turns first, unassigned ones and cleaner issues flagged', () {
      final board = buildTodayBoard(
        today: _today,
        listings: _listings,
        stays: const [],
        tasks: [
          _task('t-normal', listingId: 'rv1', dueDate: '2026-10-03', assignee: 'u1', dueStartLocal: '2026-10-03 10:00'),
          _task('t-same', listingId: 'a1', dueDate: '2026-10-03', sameDay: true, dueStartLocal: '2026-10-03 11:00'),
          _task('t-cancelled', listingId: 'a2', dueDate: '2026-10-03', status: 'cancelled'),
          _task('t-issue', listingId: 'h1', dueDate: '2026-10-02', status: 'done', assignee: 'u1', issue: 'Broken lamp'),
          _task('t-old-issue', listingId: 'h1', dueDate: '2026-09-01', status: 'done', issue: 'Long ago'),
          _task('t-tomorrow', listingId: 'a2', dueDate: '2026-10-04'),
        ],
      );
      expect(board.turnoversDueToday.map((r) => r.task.id), ['t-same', 't-normal']);
      final unassigned = board.needsAttention.where((a) => a.kind == AttentionKind.unassignedSameDayTurn).toList();
      expect(unassigned.map((a) => a.taskId), ['t-same']);
      expect(unassigned.single.high, isTrue);
      final issues = board.needsAttention.where((a) => a.kind == AttentionKind.cleanerIssue).toList();
      expect(issues.map((a) => a.taskId), ['t-issue']);
      expect(issues.single.detail, 'Broken lamp');
      expect(board.tomorrow.turnovers, 1);
    });

    test('feeds that fail, look empty or have not synced for 6 hours', () {
      final board = buildTodayBoard(
        today: _today,
        listings: _listings,
        stays: const [],
        nowUtc: _now,
        channels: [
          _channel('ok', sync: {'lastSuccessAt': _now.subtract(const Duration(minutes: 20)).toIso8601String()}),
          _channel('failing', sync: {
            'consecutiveFailures': 3,
            'lastSuccessAt': _now.subtract(const Duration(minutes: 20)).toIso8601String(),
          }),
          _channel('gone', sync: {'lastStatus': 'gone'}),
          _channel('empty', sync: {'lastStatus': 'suspicious'}),
          _channel('stale', sync: {'lastSuccessAt': _now.subtract(const Duration(hours: 7)).toIso8601String()}),
          _channel('off', active: false, sync: {'consecutiveFailures': 9}),
        ],
      );
      List<String?> ids(AttentionKind kind) =>
          board.needsAttention.where((a) => a.kind == kind).map((a) => a.channelId).toList();
      expect(ids(AttentionKind.feedFailing), unorderedEquals(['failing', 'gone']));
      expect(ids(AttentionKind.feedSuspicious), ['empty']);
      expect(ids(AttentionKind.feedStale), ['stale']);
      expect(board.needsAttention.any((a) => a.channelId == 'ok' || a.channelId == 'off'), isFalse);
    });

    test("a Stays zone that differs from the facility's is flagged", () {
      AttentionItem? mismatch(String? facilityZone) => buildTodayBoard(
            today: _today,
            listings: _listings,
            stays: const [],
            controlsTimeZone: 'America/Denver',
            facilityTimeZone: facilityZone,
          ).needsAttention.where((a) => a.kind == AttentionKind.timeZoneMismatch).firstOrNull;
      expect(mismatch('America/Chicago')?.high, isTrue);
      expect(mismatch('America/Denver'), isNull);
      expect(mismatch(null), isNull);
    });
  });

  group('forecast', () {
    test('percent booked over 30/60/90 nights, less blocked nights', () {
      final board = buildTodayBoard(
        today: _today,
        listings: [_listing('a1', 'Airbnb 1', 'Airbnbs'), _listing('a2', 'Airbnb 2', 'Airbnbs')],
        stays: [
          // 15 nights inside the next 30 (started yesterday: only from today counts).
          _stay('s1', 'a1', '2026-10-02', '2026-10-18'),
          // 10 blocked nights on a2: not sellable, so not available either.
          _stay('b1', 'a2', '2026-10-03', '2026-10-13', kind: 'owner_block', name: ''),
          // Cancelled: nothing.
          _stay('s2', 'a2', '2026-10-20', '2026-10-25', status: 'cancelled'),
        ],
      );
      final f = board.forecast.single;
      expect(f.group, 'Airbnbs');
      // 15 booked of 2×30 − 10 blocked = 50 available.
      expect(f.pct30, 30);
      // 15 of 2×60 − 10 = 110.
      expect(f.pct60, 14);
    });

    test('1–2 night gaps between bookings are orphan nights, measured from the latest checkout', () {
      final board = buildTodayBoard(
        today: _today,
        listings: [_listing('a1', 'Airbnb 1', 'Airbnbs')],
        stays: [
          _stay('s1', 'a1', '2026-10-05', '2026-10-08'),
          // Two-night gap.
          _stay('s2', 'a1', '2026-10-10', '2026-10-20'),
          // Inside s2 (a conflict): not a gap after s3.
          _stay('s3', 'a1', '2026-10-11', '2026-10-12', status: 'conflict'),
          // One night after s2.
          _stay('s4', 'a1', '2026-10-21', '2026-10-23'),
          // A week later: too long to be an orphan.
          _stay('s5', 'a1', '2026-10-30', '2026-11-02'),
        ],
      );
      expect(board.forecast.single.orphanGapNights, 3);
    });
  });
}
