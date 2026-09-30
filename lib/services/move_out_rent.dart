import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

/// A calendar day as a count of days since 1970-01-01.
typedef Day = int;

/// Days a posted rent charge covers, first and last inclusive, and what it
/// cost ([amount], after this contract's move-in discounts; null when the
/// entry has no amount).
typedef RentPeriod = ({Day start, Day end, double? amount});

/// The rent line of a move-out.
class MoveOutRentLine {
  /// Used days no posted rent covers, and their rent.
  final int chargeDays;
  final double chargeAmount;

  /// Unused days after the move-out that posted rent covers, and their rent.
  final int creditDays;
  final double creditAmount;

  /// The tenancy's first day, when known, as YYYY-MM-DD.
  final String? moveInDate;

  const MoveOutRentLine({
    required this.chargeDays,
    required this.chargeAmount,
    required this.creditDays,
    required this.creditAmount,
    required this.moveInDate,
  });
}

/// The rent line of a move-out: what the tenant still owes for days they
/// used that no rent charge covers, and what comes back to them for days
/// after the move-out that rent already posted covers.
///
/// The move-out screen counted days 1 to the move-out date of the move-out
/// month as used and charged them unless the scheduled job had posted that
/// month: a tenant whose tenancy starts 1 Oct, moved out on 24 Sep, was
/// charged "Prorated Rent (24 days) $0.80" for days before their tenancy,
/// and October, paid at move-in, stayed charged.
///
/// Decided rule, and the processMoveOut callable works the line out again
/// by it before posting:
/// * Used days run from the move-in date (or the 1st, when later or
///   unknown) to the move-out date, in the move-out month only. Those no
///   posted rent covers are charged at that month's daily rate.
/// * Days after the move-out date that posted rent covers are unused
///   prepaid rent: they come back as a credit on the ledger, each day once
///   however many charges cover it, at the month's daily rate but never
///   more than the charge covering it cost per day (its amount over its
///   days; this contract's move-in discounts come off its move-in rent).
///   At the rate alone it gave back rent never paid: $200 for a free-month
///   coupon left on the 10th. Paying the credit out is the owner's separate
///   refund choice.
/// * Posted rent: the monthly rent charge (metadata.chargeType
///   'monthlyRent', with its month) covers its month; this contract's
///   move-in rent covers the move-in date to the end of that month
///   (prorated), the whole move-in month (a full month charged at the app's
///   move-in), or the month after (the online move-in's "Next Month Rent").
///   Another contract's move-in rent is another unit's.
/// * The move-in date is this contract's move-in rent's date, else the
///   vacated unit's moveInDate.
///
/// The app's move-in rows record the date picked as metadata.moveInDate, a
/// wall date read as written: their entryDate keeps the wizard's time of
/// day, so an evening move-in on the 30th fell on the next UTC day and its
/// one prorated day read as the whole next month. Otherwise a stored
/// instant (a Timestamp) is read as its UTC date, as the online move-in
/// stores UTC midnight. The move-out date is the wall date picked.
///
/// PARITY: functions-tenant-lifecycle/src/moveOutRent.ts. Both test suites
/// run functions-tenant-lifecycle/src/test/fixtures/moveOutRent.json. The
/// rent job's moveInRentCoversForMonth
/// (functions-automation/src/rentChargeHelpers.ts) copies the move-in row
/// mapping ([_isMoveInRent], [_moveInRowDay], [_moveInRentPeriod]) too.
class MoveOutRent {
  MoveOutRent._();

  static const _msPerDay = 86400000;

  static Day _day(int year, int month, int day) =>
      DateTime.utc(year, month, day).millisecondsSinceEpoch ~/ _msPerDay;

  static DateTime _date(Day day) =>
      DateTime.fromMillisecondsSinceEpoch(day * _msPerDay, isUtc: true);

  static int _daysInMonthOf(Day day) {
    final d = _date(day);
    return DateTime.utc(d.year, d.month + 1, 0).day;
  }

  static Day _firstOfMonth(Day day) {
    final d = _date(day);
    return _day(d.year, d.month, 1);
  }

  static Day _lastOfMonth(Day day) {
    final d = _date(day);
    return _day(d.year, d.month + 1, 0);
  }

  /// YYYY-MM-DD.
  static String isoDay(Day day) {
    final d = _date(day);
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  /// The date the owner picked, as a day: its own year, month and day,
  /// whatever its zone.
  static Day wallDay(DateTime date) => _day(date.year, date.month, date.day);

  /// The wall date at the start of [value] ("2026-09-24", or
  /// "2026-09-24T00:00:00.000" as the app sends it), or null.
  static Day? wallDayOf(String value) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(value.trim());
    if (m == null) return null;
    final year = int.parse(m[1]!);
    final month = int.parse(m[2]!);
    final day = int.parse(m[3]!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final result = _day(year, month, day);
    return _date(result).day == day ? result : null;
  }

  /// The UTC calendar day of an instant (a DateTime or a Timestamp), or null.
  static Day? instantDay(Object? value) {
    final date = value is Timestamp
        ? value.toDate()
        : value is DateTime
            ? value
            : null;
    if (date == null) return null;
    final utc = date.toUtc();
    return _day(utc.year, utc.month, utc.day);
  }

  /// [x] rounded to the cent, as cents() in moveOutRent.ts.
  static double cents(double x) => (x * 100).round() / 100;

  static String _text(Object? value) => value is String ? value.trim() : '';

  static Map<String, dynamic> _metadataOf(Map<String, dynamic> row) {
    final metadata = row['metadata'];
    return metadata is Map ? Map<String, dynamic>.from(metadata) : const {};
  }

  static bool _isMoveInRent(Map<String, dynamic> row) {
    final type = _text(row['type']);
    final lineItemType = _text(_metadataOf(row)['lineItemType']);
    return type == 'proratedRent' ||
        type == 'rent' ||
        (type == 'rentCharge' &&
            (lineItemType == 'proratedRent' || lineItemType == 'rent'));
  }

  /// The row's amount, when it has one; a negative one as 0.
  static double? _amountOf(Map<String, dynamic> row) {
    final amount = row['amount'];
    return amount is num && amount.isFinite
        ? (amount < 0 ? 0.0 : amount.toDouble())
        : null;
  }

  /// The days this contract's move-in rent [row], dated [entry], covers.
  static RentPeriod _moveInRentPeriod(Map<String, dynamic> row, Day entry) {
    final type = _text(row['type']);
    final lineItemType = _text(_metadataOf(row)['lineItemType']);
    final amount = _amountOf(row);
    if (type == 'rent') {
      // The online move-in's "Next Month Rent".
      final next = _lastOfMonth(entry) + 1;
      return (start: next, end: _lastOfMonth(next), amount: amount);
    }
    if (type == 'rentCharge' && lineItemType == 'rent') {
      // A full month charged at the app's move-in, for the move-in month.
      return (
        start: _firstOfMonth(entry),
        end: _lastOfMonth(entry),
        amount: amount,
      );
    }
    return (start: entry, end: _lastOfMonth(entry), amount: amount);
  }

  /// A move-in row's date: the app's metadata.moveInDate as written, else
  /// its entryDate's UTC date.
  static Day? _moveInRowDay(Map<String, dynamic> row) {
    final written = _metadataOf(row)['moveInDate'];
    return (written is String ? wallDayOf(written) : null) ??
        instantDay(row['entryDate']);
  }

  /// A discount posted at the app's move-in (a negative line, lineItemType
  /// 'discount').
  static bool _isMoveInDiscount(Map<String, dynamic> row) =>
      _text(_metadataOf(row)['lineItemType']) == 'discount' ||
      _text(row['type']) == 'discount';

  /// The days rent posted to this tenant covers, and what it cost, for
  /// [contractId]'s move-out, and the tenancy's first day from its move-in
  /// rent. [rows] are ledger documents' data; only posted ones count. This
  /// contract's move-in discounts come off its move-in rent, earliest first.
  static ({List<RentPeriod> periods, Day? moveInDay}) coverage(
    Iterable<Map<String, dynamic>> rows,
    String contractId,
  ) {
    final periods = <RentPeriod>[];
    final moveInPeriods = <RentPeriod>[];
    var discount = 0.0;
    Day? moveInDay;
    for (final row in rows) {
      if (_text(row['status']) != 'posted') continue;
      final metadata = _metadataOf(row);
      if (metadata['chargeType'] == 'monthlyRent') {
        // A whole number however it was stored (Number.isInteger in the
        // callable).
        final month = metadata['month'];
        final year = metadata['year'];
        if (month is num &&
            year is num &&
            month == month.truncate() &&
            year == year.truncate() &&
            month >= 1 &&
            month <= 12) {
          final start = _day(year.toInt(), month.toInt(), 1);
          periods.add(
              (start: start, end: _lastOfMonth(start), amount: _amountOf(row)));
        }
        continue;
      }
      if (contractId.isEmpty || _text(row['referenceId']) != contractId) {
        continue;
      }
      if (_isMoveInDiscount(row)) {
        final amount = row['amount'];
        if (amount is num && amount.isFinite && amount < 0) discount -= amount;
        continue;
      }
      if (!_isMoveInRent(row)) continue;
      final entry = _moveInRowDay(row);
      if (entry == null) continue;
      moveInPeriods.add(_moveInRentPeriod(row, entry));
      if (moveInDay == null || entry < moveInDay) moveInDay = entry;
    }
    moveInPeriods.sort((a, b) => a.start.compareTo(b.start));
    for (final p in moveInPeriods) {
      final amount = p.amount;
      if (discount > 0 && amount != null) {
        final off = amount < discount ? amount : discount;
        discount -= off;
        periods.add((start: p.start, end: p.end, amount: amount - off));
      } else {
        periods.add(p);
      }
    }
    return (periods: periods, moveInDay: moveInDay);
  }

  /// The rent line for a move-out on [moveOutDay] at [monthlyRate] a month,
  /// given the days posted rent covers and the tenancy's first day
  /// ([moveInDay], null when unknown).
  static ({int chargeDays, double chargeAmount, int creditDays, double creditAmount})
      rent({
    required double monthlyRate,
    required Day moveOutDay,
    required Day? moveInDay,
    required List<RentPeriod> periods,
  }) {
    final rate = monthlyRate.isFinite && monthlyRate > 0 ? monthlyRate : 0.0;
    bool covered(Day day) => periods.any((p) => p.start <= day && day <= p.end);

    // Used and not billed: the move-out month, from the move-in date.
    final monthStart = _firstOfMonth(moveOutDay);
    final from =
        moveInDay != null && moveInDay > monthStart ? moveInDay : monthStart;
    var chargeDays = 0;
    for (var day = from; day <= moveOutDay; day++) {
      if (!covered(day)) chargeDays++;
    }

    // Billed and not used: every covered day after the move-out, once, at
    // the month's daily rate or what the charge covering it cost per day,
    // whichever is less (the dearest charge, when several cover it).
    final perDay = <Day, double>{};
    for (final p in periods) {
      for (var day = p.start > moveOutDay + 1 ? p.start : moveOutDay + 1;
          day <= p.end;
          day++) {
        final daily = rate / _daysInMonthOf(day);
        final amount = p.amount;
        final paid = amount == null ? daily : amount / (p.end - p.start + 1);
        final price = paid < daily ? paid : daily;
        final before = perDay[day] ?? 0.0;
        perDay[day] = price > before ? price : before;
      }
    }
    var credit = 0.0;
    for (final day in perDay.keys.toList()..sort()) {
      credit += perDay[day]!;
    }

    return (
      chargeDays: chargeDays,
      chargeAmount: cents((chargeDays * rate) / _daysInMonthOf(moveOutDay)),
      creditDays: perDay.length,
      creditAmount: cents(credit),
    );
  }

  /// [rent] from the tenant's ledger: [rows] are their ledger documents'
  /// data, [unitMoveInDate] the vacated unit's moveInDate, used when this
  /// contract has no move-in rent to date it.
  static MoveOutRentLine line({
    required double monthlyRate,
    required Day moveOutDay,
    required String contractId,
    required Iterable<Map<String, dynamic>> rows,
    Object? unitMoveInDate,
  }) {
    final found = coverage(rows, contractId);
    final moveInDay = found.moveInDay ?? instantDay(unitMoveInDate);
    final r = rent(
      monthlyRate: monthlyRate,
      moveOutDay: moveOutDay,
      moveInDay: moveInDay,
      periods: found.periods,
    );
    return MoveOutRentLine(
      chargeDays: r.chargeDays,
      chargeAmount: r.chargeAmount,
      creditDays: r.creditDays,
      creditAmount: r.creditAmount,
      moveInDate: moveInDay == null ? null : isoDay(moveInDay),
    );
  }
}
