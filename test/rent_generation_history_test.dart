// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/rent_generation_history.dart';

// The Generation History panel read action == 'recurringcharge.generated'
// ordered by at, which only the old client writer used (and the rules refused
// its rows), with no index; the job and the callable wrote other shapes. It
// also showed each day's first amount, not the run's total. All names are
// made up.

/// Records the query chain instead of running it.
class _RecordingQuery extends Fake implements Query<Map<String, dynamic>> {
  final List<String> calls = [];

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) {
    if (whereIn != null) {
      calls.add('where $field in ${whereIn.join(',')}');
    } else {
      calls.add('where $field == $isEqualTo');
    }
    return this;
  }

  @override
  Query<Map<String, dynamic>> orderBy(Object field, {bool descending = false}) {
    calls.add('orderBy $field ${descending ? 'desc' : 'asc'}');
    return this;
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) {
    calls.add('limit $limit');
    return this;
  }
}

final _now = DateTime(2026, 10, 3, 9);
Timestamp _at(DateTime d) => Timestamp.fromDate(d);

/// A row as the job and the callable now write it (writeAuditLog).
Map<String, dynamic> _charge(
  String id, {
  required String runId,
  required double amount,
  required DateTime at,
  String source = 'scheduled',
  String actorUid = 'system',
  String? actorEmail = 'system@scheduled-job',
  int month = 10,
  int year = 2026,
}) =>
    {
      'id': id,
      'eventType': 'recurringCharge.generated',
      'actorUid': actorUid,
      if (actorEmail != null) 'actorEmail': actorEmail,
      'targetType': 'ledgerEntry',
      'targetId': 'le-$id',
      'timestamp': _at(at),
      'after': {'amount': amount, 'chargeType': 'monthlyRent', 'month': month, 'year': year},
      'metadata': {'runId': runId, 'source': source},
    };

Map<String, dynamic> _toCheck(String id, {required String runId, required DateTime at}) => {
      'id': id,
      'eventType': 'recurringCharge.needsReview',
      'actorUid': 'system',
      'actorEmail': 'system@scheduled-job',
      'targetType': 'tenant',
      'timestamp': _at(at),
      'metadata': {
        'runId': runId,
        'source': 'scheduled',
        'reason': 'check by hand',
        'chargeType': 'monthlyRent',
        'month': 10,
        'year': 2026,
      },
    };

/// The job's rows before this change: action/at/details.
Map<String, dynamic> _oldJobCharge(String id, {required double amount, required DateTime at, int month = 10}) => {
      'id': id,
      'action': 'recurringCharge.generated',
      'actorUid': 'system',
      'actorEmail': 'system@scheduled-job',
      'at': _at(at),
      'details': {'amount': amount, 'chargeType': 'monthlyRent', 'month': month, 'year': 2026, 'scheduled': true},
    };

/// The old client writer's rows: lowercase action, no month.
Map<String, dynamic> _clientCharge(String id, {required double amount, required DateTime? at, String email = 'owner@example.com'}) => {
      'id': id,
      'action': 'recurringcharge.generated',
      'actorUid': 'uid-${email.split('@').first}',
      'actorEmail': email,
      'at': at == null ? null : _at(at),
      'details': {'amount': amount, 'chargeType': 'monthlyRent'},
    };

void main() {
  group('queries', () {
    test('current rows: both events, newest first, by timestamp', () {
      final q = _RecordingQuery();
      RentGenerationHistory.rowsQuery(q);
      expect(q.calls, [
        'where eventType in recurringCharge.generated,recurringCharge.needsReview',
        'orderBy timestamp desc',
        'limit 500',
      ]);
    });

    test('old rows: both action spellings and the job\'s review rows, by at', () {
      final q = _RecordingQuery();
      RentGenerationHistory.legacyRowsQuery(q);
      expect(q.calls, [
        'where action in recurringcharge.generated,recurringCharge.generated,recurringCharge.needsReview',
        'orderBy at desc',
        'limit 500',
      ]);
    });

    test('firestore.indexes.json declares an index for each query', () {
      final indexes = (jsonDecode(File('firestore.indexes.json').readAsStringSync())
              as Map<String, dynamic>)['indexes'] as List<dynamic>;
      bool declared(String equalityField, String orderField) => indexes.any((raw) {
            final index = raw as Map<String, dynamic>;
            final fields = [
              for (final f in index['fields'] as List<dynamic>)
                '${(f as Map<String, dynamic>)['fieldPath']} ${f['order']}',
            ];
            return index['collectionGroup'] == 'auditLogs' &&
                index['queryScope'] == 'COLLECTION' &&
                fields.join(', ') == '$equalityField ASCENDING, $orderField DESCENDING';
          });

      for (final build in [RentGenerationHistory.rowsQuery, RentGenerationHistory.legacyRowsQuery]) {
        final q = _RecordingQuery();
        build(q);
        final equality = RegExp(r'^where (\w+) ').firstMatch(q.calls[0])!.group(1)!;
        final order = RegExp(r'^orderBy (\w+) desc$').firstMatch(q.calls[1])!.group(1)!;
        expect(declared(equality, order), isTrue, reason: 'auditLogs ($equality, $order desc)');
      }
    });
  });

  group('grouping', () {
    test('a job run and a Generate press are separate runs, each totalled', () {
      final job = DateTime(2026, 10, 1, 0, 0, 5);
      final press = DateTime(2026, 10, 2, 14, 30);
      final runs = RentGenerationHistory.group([
        _charge('m1', runId: 'manual_a', amount: 80, at: press, source: 'manual', actorUid: 'owner-1', actorEmail: 'owner@example.com'),
        _charge('m2', runId: 'manual_a', amount: 95.5, at: press.add(const Duration(seconds: 1)), source: 'manual', actorUid: 'owner-1', actorEmail: 'owner@example.com'),
        _charge('j1', runId: 'scheduled_2026_10', amount: 120, at: job),
        _charge('j2', runId: 'scheduled_2026_10', amount: 50, at: job.add(const Duration(seconds: 1))),
        _toCheck('j3', runId: 'scheduled_2026_10', at: job.add(const Duration(seconds: 2))),
        _charge('j4', runId: 'scheduled_2026_10', amount: 50, at: job.add(const Duration(seconds: 3))),
      ], const [], now: _now);

      expect(runs.map((r) => r.key), ['manual_a', 'scheduled_2026_10']);

      final manual = runs[0];
      expect(manual.chargeCount, 2);
      expect(manual.total, 175.5);
      expect(manual.actor, 'owner@example.com');
      expect(manual.generatedAt, press.add(const Duration(seconds: 1)));
      expect(manual.countLabel, '2 charges generated');

      final scheduled = runs[1];
      expect(scheduled.chargeCount, 3);
      expect(scheduled.toCheckCount, 1);
      expect(scheduled.total, 220);
      expect(scheduled.actor, 'Scheduled job');
      expect(scheduled.title, 'Monthly Rent Charges');
      expect(scheduled.monthLabel, 'October 2026');
      expect(scheduled.countLabel, '3 charges generated · 1 to check by hand');
      expect(scheduled.mayBeIncomplete, isFalse);
    });

    test('the job\'s old rows join its run for the month', () {
      final job = DateTime(2026, 10, 1, 0, 0, 5);
      final runs = RentGenerationHistory.group(
        [_charge('new1', runId: 'scheduled_2026_10', amount: 120, at: job.add(const Duration(minutes: 5)))],
        [
          _oldJobCharge('old1', amount: 50, at: job),
          _oldJobCharge('sep1', amount: 120, at: DateTime(2026, 9, 1, 0, 0, 3), month: 9),
        ],
        now: _now,
      );
      expect(runs.map((r) => (r.key, r.chargeCount, r.total)), [
        ('scheduled_2026_10', 2, 170.0),
        ('scheduled_2026_09', 1, 120.0),
      ]);
      expect(runs[1].monthLabel, 'September 2026');
      expect(runs[1].actor, 'Scheduled job');
    });

    test('old client rows group by day and actor, with no month', () {
      final runs = RentGenerationHistory.group(const [], [
        _clientCharge('c1', amount: 35.48, at: DateTime(2026, 9, 24, 10)),
        _clientCharge('c2', amount: 0.1, at: DateTime(2026, 9, 24, 10, 1)),
        _clientCharge('c3', amount: 0.2, at: DateTime(2026, 9, 24, 16)),
        _clientCharge('c4', amount: 40, at: DateTime(2026, 9, 24, 11), email: 'manager@example.com'),
        _clientCharge('c5', amount: 60, at: DateTime(2026, 9, 25, 10)),
      ], now: _now);

      expect(runs.map((r) => (r.actor, r.chargeCount, r.total)), [
        ('owner@example.com', 1, 60.0),
        ('owner@example.com', 3, 35.78),
        ('manager@example.com', 1, 40.0),
      ]);
      expect(runs[1].monthLabel, isNull);
      expect(runs[1].title, 'Monthly Rent Charges');
    });

    test('a row still waiting for its server timestamp counts as now', () {
      final runs = RentGenerationHistory.group(const [], [
        _clientCharge('c1', amount: 80, at: null),
      ], now: _now);
      expect(runs.single.generatedAt, _now);
      expect(runs.single.total, 80);
    });

    test('a row in both results counts once', () {
      final row = _charge('dup', runId: 'manual_a', amount: 80, at: DateTime(2026, 10, 2), source: 'manual', actorUid: 'owner-1');
      final runs = RentGenerationHistory.group([row], [
        {...row, 'action': 'recurringCharge.generated', 'at': row['timestamp']},
      ], now: _now);
      expect(runs.single.chargeCount, 1);
    });

    test('a full page marks the run holding its oldest row as maybe incomplete', () {
      final job = DateTime(2026, 10, 1, 0, 0, 5);
      final runs = RentGenerationHistory.group(
        [
          _charge('m1', runId: 'manual_a', amount: 80, at: DateTime(2026, 10, 2), source: 'manual', actorUid: 'owner-1'),
          _charge('j2', runId: 'scheduled_2026_10', amount: 50, at: job.add(const Duration(seconds: 1))),
          _charge('j1', runId: 'scheduled_2026_10', amount: 120, at: job),
        ],
        const [],
        now: _now,
        limit: 3,
      );
      expect(runs.map((r) => (r.key, r.mayBeIncomplete)), [
        ('manual_a', false),
        ('scheduled_2026_10', true),
      ]);
      expect(runs[1].countLabel, '2 charges generated (older rows not loaded)');

      final notFull = RentGenerationHistory.group(
        [_charge('j1', runId: 'scheduled_2026_10', amount: 120, at: job)],
        const [],
        now: _now,
        limit: 3,
      );
      expect(notFull.single.mayBeIncomplete, isFalse);
    });

    test('rows for other events are ignored', () {
      final runs = RentGenerationHistory.group([
        {'id': 'x', 'eventType': 'payment.created', 'timestamp': _at(DateTime(2026, 10, 2)), 'after': {'amount': 10}},
      ], [
        {'id': 'y', 'action': 'movein.completed', 'at': _at(DateTime(2026, 10, 2)), 'details': {'amount': 10}},
      ], now: _now);
      expect(runs, isEmpty);
    });
  });

  group('combine', () {
    Map<String, dynamic> row(String id) =>
        _charge(id, runId: 'scheduled_2026_10', amount: 100, at: DateTime(2026, 10, 1));

    test('waits for both, then updates on either', () async {
      final current = StreamController<List<Map<String, dynamic>>>();
      final legacy = StreamController<List<Map<String, dynamic>>>();
      final views = <RentGenerationHistoryView>[];
      final sub = RentGenerationHistory.combine(() => current.stream, () => legacy.stream, now: () => _now)
          .listen(views.add);

      current.add([row('a')]);
      await pumpEventQueue();
      expect(views, isEmpty);

      legacy.add(const []);
      await pumpEventQueue();
      expect(views.single.runs.single.chargeCount, 1);

      current.add([row('a'), row('b')]);
      await pumpEventQueue();
      expect(views.last.runs.single.chargeCount, 2);
      expect(views.last.olderHistoryUnavailable, isFalse);

      await sub.cancel();
      expect(current.hasListener, isFalse);
      expect(legacy.hasListener, isFalse);
    });

    test('an error on the old rows still shows the current runs, and says so', () async {
      final views = <RentGenerationHistoryView>[];
      final errors = <Object>[];
      final sub = RentGenerationHistory.combine(
        () => Stream.value([row('a')]),
        () => Stream.error(FirebaseException(plugin: 'cloud_firestore', code: 'failed-precondition')),
        now: () => _now,
      ).listen(views.add, onError: errors.add);
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect(views.single.runs.single.chargeCount, 1);
      expect(views.single.olderHistoryUnavailable, isTrue);
      await sub.cancel();
    });

    test('an error on the current rows is the stream\'s error', () async {
      final errors = <Object>[];
      final sub = RentGenerationHistory.combine(
        () => Stream.error(FirebaseException(plugin: 'cloud_firestore', code: 'failed-precondition')),
        () => Stream.value(const []),
        now: () => _now,
      ).listen((_) {}, onError: errors.add);
      await pumpEventQueue();

      expect(errors.single, isA<FirebaseException>());
      await sub.cancel();
    });

    test('each listener gets its own queries, so the stream can be kept', () async {
      var opened = 0;
      final stream = RentGenerationHistory.combine(
        () {
          opened++;
          return Stream.value([row('a')]);
        },
        () => Stream.value(const []),
        now: () => _now,
      );
      expect((await stream.first).runs, hasLength(1));
      expect((await stream.first).runs, hasLength(1));
      expect(opened, 2);
    });
  });
}
