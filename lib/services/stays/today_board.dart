import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stay_task.dart';
import 'package:sfcapp/utils/local_date.dart';

/// The Today board (spec §1.1 A): what she opens each morning. Built by the
/// pure [buildTodayBoard] from stays, listings, tasks and channels, for one
/// facility-local date, so it can be tested for a fixed day.

/// How many of a group's listings are booked tonight.
class TonightGroup {
  const TonightGroup({required this.group, required this.booked, required this.total});

  final String group;
  final int booked;
  final int total;

  /// "RV park 5/9", or for a single listing "House booked" / "House vacant".
  String get label {
    if (total == 1) return booked == 1 ? '$group booked' : '$group vacant';
    return '$group $booked/$total';
  }
}

class TodayHeadline {
  const TodayHeadline({required this.groups, this.netThisMonthCents});

  final List<TonightGroup> groups;

  /// Owner/manager only; null for everyone else.
  final int? netThisMonthCents;

  /// e.g. "Airbnbs 2/2 booked · RV park 5/9 · House vacant · $2,340 net this month".
  String text({String Function(int cents)? formatMoney}) {
    final parts = <String>[];
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      var label = g.label;
      if (i == 0 && g.total > 1) label = '$label booked';
      parts.add(label);
    }
    final net = netThisMonthCents;
    if (net != null) {
      final money = formatMoney != null ? formatMoney(net) : _dollars(net);
      parts.add('$money net this month');
    }
    return parts.isEmpty ? 'No listings yet' : parts.join(' · ');
  }

  static String _dollars(int cents) {
    final negative = cents < 0;
    final whole = (cents.abs() / 100).round();
    final digits = whole.toString();
    final grouped = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
      grouped.write(digits[i]);
    }
    return '${negative ? '-' : ''}\$$grouped';
  }
}

enum AttentionKind {
  conflict,
  removedFromFeed,
  needsReview,
  feedFailing,
  feedSuspicious,
  feedStale,
  arrivalMissingName,
  balanceDue,
  unassignedSameDayTurn,
  cleanerIssue,
  overdueDeparture,
  timeZoneMismatch,
}

class AttentionItem {
  const AttentionItem({
    required this.kind,
    required this.title,
    this.detail,
    this.stayId,
    this.taskId,
    this.channelId,
    this.listingId,
    this.high = false,
  });

  final AttentionKind kind;
  final String title;
  final String? detail;
  final String? stayId;
  final String? taskId;
  final String? channelId;
  final String? listingId;

  /// Shown first, in red.
  final bool high;
}

/// Payment chip on an arrival: no amounts, and only for owners and managers.
enum PaymentChip { airbnbPaid, due, paid }

class TodayStayRow {
  const TodayStayRow({
    required this.stay,
    required this.guestLabel,
    required this.listingName,
    this.time,
    this.paymentChip,
    this.turnoverStatus,
  });

  final Stay stay;
  final String guestLabel;
  final String listingName;

  /// Arrival or checkout time, 'HH:mm'.
  final String? time;
  final PaymentChip? paymentChip;

  /// A departure's turnover task status, when there is one.
  final StayTaskStatus? turnoverStatus;
}

class TodayTurnoverRow {
  const TodayTurnoverRow({required this.task, required this.listingName});

  final StayTask task;
  final String listingName;

  bool get sameDayTurn => task.sameDayTurn;
}

class TomorrowPreview {
  const TomorrowPreview({this.arrivals = const [], this.departures = const [], this.turnovers = 0});

  final List<TodayStayRow> arrivals;
  final List<TodayStayRow> departures;
  final int turnovers;
}

/// Percent booked over the next 30, 60 and 90 nights for one group, and the
/// 1–2 night gaps between bookings that are hard to sell.
class ForecastGroup {
  const ForecastGroup({
    required this.group,
    required this.pct30,
    required this.pct60,
    required this.pct90,
    required this.orphanGapNights,
  });

  final String group;

  /// 0–100, whole numbers.
  final int pct30;
  final int pct60;
  final int pct90;
  final int orphanGapNights;
}

class TodayBoard {
  const TodayBoard({
    required this.today,
    required this.headline,
    this.needsAttention = const [],
    this.arrivals = const [],
    this.departures = const [],
    this.inHouse = const [],
    this.overdueDepartures = const [],
    this.turnoversDueToday = const [],
    this.tomorrow = const TomorrowPreview(),
    this.forecast = const [],
    this.showMoney = false,
  });

  final LocalDate today;
  final TodayHeadline headline;
  final List<AttentionItem> needsAttention;
  final List<TodayStayRow> arrivals;
  final List<TodayStayRow> departures;
  final List<TodayStayRow> inHouse;
  final List<TodayStayRow> overdueDepartures;
  final List<TodayTurnoverRow> turnoversDueToday;
  final TomorrowPreview tomorrow;
  final List<ForecastGroup> forecast;

  /// Owner/manager: money figures and payment chips are included.
  final bool showMoney;

  /// Arrivals today plus open conflicts: the sidebar badge.
  int get badgeCount => arrivals.length + needsAttention.where((a) => a.kind == AttentionKind.conflict).length;
}

TodayBoard buildTodayBoard({
  required LocalDate today,
  required List<StayListing> listings,
  required List<Stay> stays,
  List<StayTask> tasks = const [],
  List<StayChannel> channels = const [],
  DateTime? nowUtc,
  String? controlsTimeZone,
  String? facilityTimeZone,
  bool showMoney = false,
  int? netThisMonthCents,
}) {
  final todayYmd = today.toYmd();
  final tomorrowYmd = today.addDays(1).toYmd();
  final listingById = {for (final l in listings) l.id: l};
  final bookable = listings.where((l) => l.isBookable).toList();
  final active = stays.where((s) => s.isActive).toList();
  final reservations = active.where((s) => s.isReservation).toList();

  String listingName(String listingId, String fallback) =>
      listingById[listingId]?.name ?? (fallback.isEmpty ? 'Listing' : fallback);

  final turnoverByStay = <String, StayTask>{
    for (final t in tasks)
      if (t.isTurnover && t.stayId != null) t.stayId!: t,
  };

  PaymentChip? chipFor(Stay s) {
    if (!showMoney) return null;
    return switch (s.paymentStatus) {
      StayPaymentStatus.channelCollected => PaymentChip.airbnbPaid,
      StayPaymentStatus.due || StayPaymentStatus.partial => PaymentChip.due,
      StayPaymentStatus.paid => PaymentChip.paid,
      _ => null,
    };
  }

  TodayStayRow row(Stay s, {String? time}) => TodayStayRow(
        stay: s,
        guestLabel: s.guestLabel,
        listingName: listingName(s.listingId, s.listingName),
        time: time,
        paymentChip: chipFor(s),
        turnoverStatus: turnoverByStay[s.id]?.status,
      );

  int byTimeThenListing(TodayStayRow a, TodayStayRow b) {
    final t = (a.time ?? '').compareTo(b.time ?? '');
    return t != 0 ? t : a.listingName.compareTo(b.listingName);
  }

  final arrivals = [
    for (final s in reservations)
      if (s.checkIn == todayYmd && s.arrivalState == StayArrivalState.upcoming) row(s, time: s.checkInTime),
  ]..sort(byTimeThenListing);

  final departures = [
    for (final s in reservations)
      if (s.checkOut == todayYmd && s.arrivalState != StayArrivalState.noShow) row(s, time: s.checkOutTime),
  ]..sort(byTimeThenListing);

  final inHouse = [
    for (final s in reservations)
      if (s.arrivalState == StayArrivalState.checkedIn && s.checkOut.compareTo(todayYmd) > 0) row(s, time: s.checkOutTime),
  ]..sort((a, b) => a.listingName.compareTo(b.listingName));

  final overdue = [
    for (final s in reservations)
      if (s.arrivalState == StayArrivalState.checkedIn && s.checkOut.compareTo(todayYmd) < 0) row(s, time: s.checkOutTime),
  ]..sort((a, b) => a.stay.checkOut.compareTo(b.stay.checkOut));

  final turnoversToday = [
    for (final t in tasks)
      if (t.isTurnover && t.dueDate == todayYmd && t.status != StayTaskStatus.cancelled && t.status != StayTaskStatus.unknown)
        TodayTurnoverRow(task: t, listingName: listingName(t.listingId ?? '', '')),
  ]..sort((a, b) {
      if (a.sameDayTurn != b.sameDayTurn) return a.sameDayTurn ? -1 : 1;
      return a.task.dueStartLocal.compareTo(b.task.dueStartLocal);
    });

  final tomorrow = TomorrowPreview(
    arrivals: [
      for (final s in reservations)
        if (s.checkIn == tomorrowYmd) row(s, time: s.checkInTime),
    ]..sort(byTimeThenListing),
    departures: [
      for (final s in reservations)
        if (s.checkOut == tomorrowYmd) row(s, time: s.checkOutTime),
    ]..sort(byTimeThenListing),
    turnovers: tasks.where((t) => t.isTurnover && t.dueDate == tomorrowYmd && t.isOpen).length,
  );

  // --- Needs attention ------------------------------------------------------
  final attention = <AttentionItem>[];
  final horizonEnd = today.addDays(3).toYmd();

  if (controlsTimeZone != null && facilityTimeZone != null && controlsTimeZone != facilityTimeZone) {
    attention.add(AttentionItem(
      kind: AttentionKind.timeZoneMismatch,
      title: "Stays uses $controlsTimeZone but the facility's time zone is $facilityTimeZone",
      detail: 'Fix the facility time zone in facility settings so dates agree.',
      high: true,
    ));
  }
  for (final s in stays) {
    final relevant = s.checkOut.compareTo(todayYmd) >= 0;
    if (s.status == StayStatus.conflict && relevant) {
      attention.add(AttentionItem(
        kind: AttentionKind.conflict,
        title: 'Double booking: ${s.guestLabel} at ${listingName(s.listingId, s.listingName)}',
        detail: '${s.checkIn} to ${s.checkOut}',
        stayId: s.id,
        listingId: s.listingId,
        high: s.conflict?.isAcknowledged != true,
      ));
    }
    if (s.status == StayStatus.removedFromFeed && relevant) {
      attention.add(AttentionItem(
        kind: AttentionKind.removedFromFeed,
        title: 'Removed from the channel: ${s.guestLabel}',
        detail: '${listingName(s.listingId, s.listingName)} · ${s.checkIn} to ${s.checkOut}',
        stayId: s.id,
        listingId: s.listingId,
      ));
    }
    if (s.needsReview && s.isActive && relevant) {
      attention.add(AttentionItem(
        kind: AttentionKind.needsReview,
        title: 'Check this booking: ${s.guestLabel}',
        detail: 'It is no longer in the channel feed but is checked in or paid.',
        stayId: s.id,
        listingId: s.listingId,
        high: true,
      ));
    }
  }
  for (final s in reservations) {
    if (s.guestDisplayName.trim().isEmpty &&
        s.checkIn.compareTo(todayYmd) >= 0 &&
        s.checkIn.compareTo(horizonEnd) <= 0 &&
        s.arrivalState == StayArrivalState.upcoming) {
      attention.add(AttentionItem(
        kind: AttentionKind.arrivalMissingName,
        title: 'No guest name yet: ${s.guestLabel}',
        detail: '${listingName(s.listingId, s.listingName)} · arrives ${s.checkIn}',
        stayId: s.id,
        listingId: s.listingId,
      ));
    }
    if (showMoney && s.source.isSfcBooking && s.paymentStatus.hasBalance) {
      attention.add(AttentionItem(
        kind: AttentionKind.balanceDue,
        title: 'Balance due: ${s.guestLabel}',
        detail: '${listingName(s.listingId, s.listingName)} · ${s.checkIn} to ${s.checkOut}',
        stayId: s.id,
        listingId: s.listingId,
      ));
    }
  }
  for (final r in overdue) {
    attention.add(AttentionItem(
      kind: AttentionKind.overdueDeparture,
      title: 'Still checked in: ${r.guestLabel}',
      detail: '${r.listingName} · checkout was ${r.stay.checkOut}',
      stayId: r.stay.id,
      listingId: r.stay.listingId,
      high: true,
    ));
  }
  final weekAgo = today.addDays(-7).toYmd();
  for (final t in tasks) {
    if (t.sameDayTurn && t.assigneeUid == null && t.isOpen && t.dueDate.compareTo(todayYmd) >= 0) {
      attention.add(AttentionItem(
        kind: AttentionKind.unassignedSameDayTurn,
        title: 'Same-day turnover with nobody assigned',
        detail: '${listingName(t.listingId ?? '', '')} · ${t.dueDate}',
        taskId: t.id,
        listingId: t.listingId,
        high: t.dueDate == todayYmd,
      ));
    }
    if (t.hasIssue && t.status != StayTaskStatus.cancelled && t.dueDate.compareTo(weekAgo) >= 0) {
      attention.add(AttentionItem(
        kind: AttentionKind.cleanerIssue,
        title: 'Issue reported: ${listingName(t.listingId ?? '', '')}',
        detail: t.issueNote.trim(),
        taskId: t.id,
        listingId: t.listingId,
      ));
    }
  }
  final now = nowUtc;
  for (final c in channels.where((c) => c.active)) {
    final name = '${c.label.isEmpty ? c.provider.wire : c.label} (${listingName(c.listingId, '')})';
    if (c.sync.lastStatus == ChannelSyncStatus.suspicious || c.sync.suspiciousSince != null) {
      attention.add(AttentionItem(
        kind: AttentionKind.feedSuspicious,
        title: 'Calendar feed looks empty: $name',
        detail: 'Nothing was removed. Check the listing in the channel.',
        channelId: c.id,
        listingId: c.listingId,
        high: true,
      ));
    } else if (c.sync.consecutiveFailures >= 3 || c.sync.lastStatus == ChannelSyncStatus.gone) {
      attention.add(AttentionItem(
        kind: AttentionKind.feedFailing,
        title: 'Calendar feed is failing: $name',
        channelId: c.id,
        listingId: c.listingId,
        high: true,
      ));
    } else if (now != null && c.isStale(now)) {
      attention.add(AttentionItem(
        kind: AttentionKind.feedStale,
        title: 'Calendar feed not synced for over 6 hours: $name',
        channelId: c.id,
        listingId: c.listingId,
      ));
    }
  }
  attention.sort((a, b) {
    if (a.high != b.high) return a.high ? -1 : 1;
    return a.kind.index.compareTo(b.kind.index);
  });

  // --- Headline: tonight, per group ---------------------------------------------
  final groups = <String, List<StayListing>>{};
  for (final l in bookable) {
    groups.putIfAbsent(l.displayGroup, () => []).add(l);
  }
  final bookedTonight = {
    for (final s in reservations)
      if (s.coversNight(todayYmd)) s.listingId,
  };
  final tonight = [
    for (final entry in groups.entries)
      TonightGroup(
        group: entry.key,
        booked: entry.value.where((l) => bookedTonight.contains(l.id)).length,
        total: entry.value.length,
      ),
  ];

  // --- Forecast ------------------------------------------------------------------
  final forecast = <ForecastGroup>[];
  for (final entry in groups.entries) {
    final ids = {for (final l in entry.value) l.id};
    int pct(int days) {
      final end = today.addDays(days).toYmd();
      var booked = 0;
      var blocked = 0;
      for (final id in ids) {
        final nights = <String>{};
        final blockNights = <String>{};
        for (final s in active.where((s) => s.listingId == id)) {
          final from = s.checkIn.compareTo(todayYmd) > 0 ? s.checkIn : todayYmd;
          final to = s.checkOut.compareTo(end) < 0 ? s.checkOut : end;
          final fromDate = LocalDate.tryParse(from);
          final toDate = LocalDate.tryParse(to);
          if (fromDate == null || toDate == null) continue;
          for (final n in LocalDate.nights(fromDate, toDate)) {
            (s.isBlock ? blockNights : nights).add(n.toYmd());
          }
        }
        booked += nights.length;
        blocked += blockNights.difference(nights).length;
      }
      final available = ids.length * days - blocked;
      return available <= 0 ? 0 : (booked * 100 / available).round();
    }

    var orphans = 0;
    final end90 = today.addDays(90).toYmd();
    for (final id in ids) {
      final spans = active.where((s) => s.listingId == id && s.checkOut.compareTo(todayYmd) > 0 && s.checkIn.compareTo(end90) < 0).toList()
        ..sort((a, b) => a.checkIn.compareTo(b.checkIn));
      // Measure each gap from the latest checkout so far: with overlapping
      // stays (a conflict) a short stay inside a long one is not a gap.
      String? coveredUntil;
      for (final s in spans) {
        final gapStart = LocalDate.tryParse(coveredUntil);
        final gapEnd = LocalDate.tryParse(s.checkIn);
        if (gapStart != null && gapEnd != null) {
          final gap = gapStart.daysUntil(gapEnd);
          if (gap >= 1 && gap <= 2) orphans += gap;
        }
        if (coveredUntil == null || s.checkOut.compareTo(coveredUntil) > 0) coveredUntil = s.checkOut;
      }
    }
    forecast.add(ForecastGroup(group: entry.key, pct30: pct(30), pct60: pct(60), pct90: pct(90), orphanGapNights: orphans));
  }

  return TodayBoard(
    today: today,
    headline: TodayHeadline(groups: tonight, netThisMonthCents: showMoney ? netThisMonthCents : null),
    needsAttention: attention,
    arrivals: arrivals,
    departures: departures,
    inHouse: inHouse,
    overdueDepartures: overdue,
    turnoversDueToday: turnoversToday,
    tomorrow: tomorrow,
    forecast: forecast,
    showMoney: showMoney,
  );
}
