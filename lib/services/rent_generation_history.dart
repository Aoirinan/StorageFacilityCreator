import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// One run of monthly rent generation, as the Recurring Charges screen's
/// Generation History shows it: every tenant charged (and left to check) by
/// one scheduled job run or one press of Generate.
class RentGenerationRun {
  final String key;

  /// When the run's newest row was written.
  final DateTime generatedAt;
  final int? month;
  final int? year;
  final String? chargeType;

  /// 'Scheduled job', or the email of whoever pressed Generate.
  final String actor;
  final int chargeCount;
  final int totalCents;

  /// Tenants the run left uncharged for the owner to check by hand.
  final int toCheckCount;

  /// The run holds the oldest row loaded, so it may have more rows than
  /// were loaded.
  final bool mayBeIncomplete;

  const RentGenerationRun({
    required this.key,
    required this.generatedAt,
    required this.month,
    required this.year,
    required this.chargeType,
    required this.actor,
    required this.chargeCount,
    required this.totalCents,
    required this.toCheckCount,
    required this.mayBeIncomplete,
  });

  double get total => totalCents / 100;

  String get title => switch (chargeType) {
        'monthlyRent' => 'Monthly Rent Charges',
        'insurance' => 'Insurance Charges',
        _ => 'Recurring Charges',
      };

  /// 'October 2026', or null for rows that never recorded the month.
  String? get monthLabel {
    final m = month;
    final y = year;
    if (m == null || y == null || m < 1 || m > 12) return null;
    return DateFormat('MMMM yyyy').format(DateTime(y, m));
  }

  String get countLabel {
    final charges = '$chargeCount charge${chargeCount == 1 ? '' : 's'} generated';
    final toCheck = toCheckCount > 0 ? ' · $toCheckCount to check by hand' : '';
    final partial = mayBeIncomplete ? ' (older rows not loaded)' : '';
    return '$charges$toCheck$partial';
  }
}

class RentGenerationHistoryView {
  final List<RentGenerationRun> runs;

  /// The query for rows in the old shape failed, so runs from before the
  /// current shape may be missing.
  final bool olderHistoryUnavailable;

  const RentGenerationHistoryView({
    required this.runs,
    this.olderHistoryUnavailable = false,
  });
}

/// Reads the audit rows monthly rent generation writes and groups them into
/// runs.
///
/// The scheduled job and the generateMonthlyRentCharges callable write one
/// row per tenant in writeAuditLog's shape (functions-automation/src/
/// rentChargeAudit.ts): eventType, timestamp, after.amount/month/year,
/// metadata.runId/source. Rows from before that are read too: the job's
/// action/at/details under the same event names, and the old client-side
/// writer's action 'recurringcharge.generated' (no month, no run id).
///
/// Each query needs a composite index in firestore.indexes.json:
/// auditLogs (eventType, timestamp desc) and (action, at desc).
class RentGenerationHistory {
  RentGenerationHistory._();

  static const generatedEvent = 'recurringCharge.generated';
  static const needsReviewEvent = 'recurringCharge.needsReview';
  static const legacyActions = [
    'recurringcharge.generated',
    generatedEvent,
    needsReviewEvent,
  ];

  /// Rows per query. A run is one row per tenant, so a big facility's
  /// oldest loaded run may be cut short; it is marked as such.
  static const rowLimit = 500;

  static Query<Map<String, dynamic>> rowsQuery(Query<Map<String, dynamic>> auditLogs) =>
      auditLogs
          .where('eventType', whereIn: const [generatedEvent, needsReviewEvent])
          .orderBy('timestamp', descending: true)
          .limit(rowLimit);

  static Query<Map<String, dynamic>> legacyRowsQuery(Query<Map<String, dynamic>> auditLogs) =>
      auditLogs
          .where('action', whereIn: legacyActions)
          .orderBy('at', descending: true)
          .limit(rowLimit);

  static Stream<RentGenerationHistoryView> watch(String facilityId) {
    final auditLogs = FirebaseFirestore.instance
        .collection('facilities')
        .doc(facilityId)
        .collection('auditLogs');
    return combine(
      () => rowsQuery(auditLogs).snapshots().map(_rows),
      () => legacyRowsQuery(auditLogs).snapshots().map(_rows),
    );
  }

  static List<Map<String, dynamic>> _rows(QuerySnapshot<Map<String, dynamic>> snapshot) => [
        for (final doc in snapshot.docs) {...doc.data(), 'id': doc.id},
      ];

  /// The runs in [current] and [legacy] rows, once both have arrived.
  ///
  /// Each listener gets its own queries, so the stream can be kept across
  /// rebuilds. An error from [current] is the stream's error. One from
  /// [legacy] (its index not built yet, say) leaves the older rows out and
  /// says so, rather than hiding the current runs behind an error.
  static Stream<RentGenerationHistoryView> combine(
    Stream<List<Map<String, dynamic>>> Function() current,
    Stream<List<Map<String, dynamic>>> Function() legacy, {
    DateTime Function() now = DateTime.now,
    int limit = rowLimit,
  }) {
    return Stream.multi((out) {
      List<Map<String, dynamic>>? currentRows;
      List<Map<String, dynamic>>? legacyRows;
      var legacyFailed = false;

      void emit() {
        final rows = currentRows;
        if (rows == null || (legacyRows == null && !legacyFailed)) return;
        out.add(RentGenerationHistoryView(
          runs: group(rows, legacyRows ?? const [], now: now(), limit: limit),
          olderHistoryUnavailable: legacyFailed,
        ));
      }

      final currentSub = current().listen(
        (rows) {
          currentRows = rows;
          emit();
        },
        onError: out.addError,
      );
      final legacySub = legacy().listen(
        (rows) {
          legacyRows = rows;
          legacyFailed = false;
          emit();
        },
        onError: (Object error) {
          debugPrint('Generation History: older rows not loaded: $error');
          legacyRows = null;
          legacyFailed = true;
          emit();
        },
      );
      out.onCancel = () async {
        await currentSub.cancel();
        await legacySub.cancel();
      };
    });
  }

  /// Groups rows into runs, newest first.
  ///
  /// A row with a run id joins its run. The job's old rows join the run id
  /// its new rows use (one per facility per month). The old client rows,
  /// which had neither, group by day, actor and charge type. A query that
  /// returned [limit] rows may have stopped inside a run, so the run holding
  /// its oldest row is marked [RentGenerationRun.mayBeIncomplete].
  static List<RentGenerationRun> group(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> legacy, {
    required DateTime now,
    int limit = rowLimit,
  }) {
    final seen = <String>{};
    final rows = <_Row>[];
    _Row? oldestCurrent;
    _Row? oldestLegacy;

    void read(List<Map<String, dynamic>> source, bool isLegacy) {
      for (final data in source) {
        final id = data['id'];
        if (id is String && !seen.add(id)) continue;
        final row = _Row.parse(data, legacy: isLegacy, now: now);
        if (row == null) continue;
        rows.add(row);
        if (isLegacy) {
          if (oldestLegacy == null || row.at.isBefore(oldestLegacy!.at)) oldestLegacy = row;
        } else {
          if (oldestCurrent == null || row.at.isBefore(oldestCurrent!.at)) oldestCurrent = row;
        }
      }
    }

    read(current, false);
    read(legacy, true);

    final incomplete = <String>{
      if (current.length >= limit && oldestCurrent != null) oldestCurrent!.runKey,
      if (legacy.length >= limit && oldestLegacy != null) oldestLegacy!.runKey,
    };

    final byRun = <String, List<_Row>>{};
    for (final row in rows) {
      byRun.putIfAbsent(row.runKey, () => []).add(row);
    }

    final runs = [
      for (final entry in byRun.entries) _toRun(entry.key, entry.value, incomplete.contains(entry.key)),
    ]..sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
    return runs;
  }

  static RentGenerationRun _toRun(String key, List<_Row> rows, bool mayBeIncomplete) {
    rows.sort((a, b) => b.at.compareTo(a.at));
    final newest = rows.first;
    final dated = rows.where((r) => r.month != null && r.year != null).firstOrNull;
    return RentGenerationRun(
      key: key,
      generatedAt: newest.at,
      month: dated?.month,
      year: dated?.year,
      chargeType: rows.map((r) => r.chargeType).nonNulls.firstOrNull,
      actor: newest.actor,
      chargeCount: rows.where((r) => !r.toCheck).length,
      totalCents: rows.fold(0, (cents, r) => cents + r.cents),
      toCheckCount: rows.where((r) => r.toCheck).length,
      mayBeIncomplete: mayBeIncomplete,
    );
  }
}

class _Row {
  final DateTime at;
  final bool toCheck;
  final int? month;
  final int? year;
  final String? chargeType;
  final int cents;
  final String actor;
  final String runKey;

  _Row({
    required this.at,
    required this.toCheck,
    required this.month,
    required this.year,
    required this.chargeType,
    required this.cents,
    required this.actor,
    required this.runKey,
  });

  static const _scheduledEmail = 'system@scheduled-job';

  static _Row? parse(Map<String, dynamic> data, {required bool legacy, required DateTime now}) {
    final event = data[legacy ? 'action' : 'eventType'];
    if (event is! String) return null;
    final toCheck = event == RentGenerationHistory.needsReviewEvent;
    if (!toCheck && event.toLowerCase() != RentGenerationHistory.generatedEvent.toLowerCase()) {
      return null;
    }

    final metadata = _map(data['metadata']);
    // Old rows keep everything in details; a charge keeps its amount and
    // month in after, a tenant to check keeps its month in metadata.
    final details = legacy ? _map(data['details']) : (toCheck ? metadata : _map(data['after']));

    // A pending server timestamp reads as null until the write lands.
    final stamp = data[legacy ? 'at' : 'timestamp'];
    final at = stamp is Timestamp ? stamp.toDate() : now;

    final month = (details['month'] as num?)?.toInt();
    final year = (details['year'] as num?)?.toInt();
    final chargeType = details['chargeType'] as String?;
    final amount = toCheck ? 0 : (details['amount'] as num?) ?? 0;

    final actorUid = data['actorUid'] as String?;
    final actorEmail = data['actorEmail'] as String?;
    final scheduled = metadata['source'] == 'scheduled' ||
        details['scheduled'] == true ||
        actorUid == 'system' ||
        actorEmail == _scheduledEmail;

    String? runId = metadata['runId'] as String?;
    if (runId == null && scheduled && month != null && year != null) {
      // The job's run id (rentChargeAudit.ts, scheduledRentChargeRunId).
      runId = 'scheduled_${year}_${month.toString().padLeft(2, '0')}';
    }
    final actor = scheduled ? 'Scheduled job' : (actorEmail ?? 'Unknown');
    final runKey = runId ??
        [
          'day:${DateFormat('yyyy-MM-dd').format(at)}',
          'by:${actorUid ?? actorEmail ?? ''}',
          'type:${chargeType ?? ''}',
          'for:${year ?? ''}-${month ?? ''}',
        ].join('|');

    return _Row(
      at: at,
      toCheck: toCheck,
      month: month,
      year: year,
      chargeType: chargeType,
      cents: (amount * 100).round(),
      actor: actor,
      runKey: runKey,
    );
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};
}
