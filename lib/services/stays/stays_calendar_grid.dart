import 'package:flutter/foundation.dart';

import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_channel_blocks.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/utils/local_date.dart';

// The month calendar of one listing, worked out from its stays and its
// channels' imported blocks (pure, so it is unit-tested without Firestore).
//
// Hard: bookings and owner/maintenance blocks (every active stay) hold
// nights. Soft: a channel's "Not available" ranges fill free nights only and
// never conflict. A stay the engine marked `conflict` lost the nights listed
// in conflict.nights to an earlier stay: that night is double booked.
// "Removed from feed" stays hold nothing but are shown, so the owner sees
// what disappeared from a channel instead of a silent gap.

/// One channel "Not available" range on a listing.
@immutable
class StaySoftBlock {
  const StaySoftBlock({
    required this.channelId,
    required this.provider,
    required this.checkIn,
    required this.checkOut,
    this.echo = false,
  });

  final String channelId;
  final ChannelProvider provider;

  /// 'YYYY-MM-DD'.
  final String checkIn;

  /// 'YYYY-MM-DD', exclusive.
  final String checkOut;

  /// Our own export shown back to us by the channel.
  final bool echo;

  bool coversNight(String night) => checkIn.compareTo(night) <= 0 && night.compareTo(checkOut) < 0;
}

/// How a night is drawn, strongest first.
enum StayNightStyle {
  /// Two hard stays claim it.
  conflict,

  /// A guest booking holds it.
  booking,

  /// An owner or maintenance block holds it.
  block,

  /// A booking the channel no longer lists (it holds nothing).
  removed,

  /// Only a channel's "Not available" block (soft).
  soft,

  /// Only our own block echoed back by a channel (fainter still).
  echo,

  /// Free.
  empty,
}

/// Whether [stay] lost [night] to an earlier stay (the engine's conflict data).
bool stayLostNight(Stay stay, String night) {
  if (stay.status != StayStatus.conflict) return false;
  final nights = stay.conflict?.nights ?? const <String>[];
  return nights.isEmpty ? stay.coversNight(night) : nights.contains(night);
}

@immutable
class StayNightCell {
  const StayNightCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isPast,
    this.hard = const [],
    this.removed = const [],
    this.soft = const [],
  });

  final LocalDate date;

  /// In the month shown (the grid pads whole weeks with the neighbours' days).
  final bool inMonth;
  final bool isToday;
  final bool isPast;

  /// Active stays on this night, the one holding it first.
  final List<Stay> hard;

  /// Stays removed from their channel's feed that covered this night.
  final List<Stay> removed;

  /// Channel "Not available" ranges over this night.
  final List<StaySoftBlock> soft;

  String get ymd => date.toYmd();

  Stay? get holder => hard.isEmpty ? null : hard.first;

  /// Two hard stays claim the night, or the engine says one lost it.
  bool get isConflict => hard.length > 1 || hard.any((s) => stayLostNight(s, ymd));

  StayNightStyle get style {
    if (isConflict) return StayNightStyle.conflict;
    final h = holder;
    if (h != null) return h.isBlock ? StayNightStyle.block : StayNightStyle.booking;
    if (removed.isNotEmpty) return StayNightStyle.removed;
    if (soft.isNotEmpty) return soft.every((b) => b.echo) ? StayNightStyle.echo : StayNightStyle.soft;
    return StayNightStyle.empty;
  }

  /// The holder arrives tonight, so its name is written here.
  bool get holderArrives => holder?.checkIn == ymd;

  bool get isFree => hard.isEmpty && removed.isEmpty && soft.isEmpty;
}

@immutable
class StayMonthGrid {
  const StayMonthGrid({required this.month, required this.from, required this.to, required this.weeks});

  /// The first of the month shown.
  final LocalDate month;

  /// The first day drawn (a Sunday) and the day after the last one.
  final LocalDate from;
  final LocalDate to;

  /// Sunday-first weeks of seven cells.
  final List<List<StayNightCell>> weeks;

  Iterable<StayNightCell> get cells => weeks.expand((w) => w);

  StayNightCell? cellFor(String ymd) {
    for (final cell in cells) {
      if (cell.ymd == ymd) return cell;
    }
    return null;
  }
}

/// The days drawn for the month holding [anyDay]: whole weeks, Sunday first.
(LocalDate from, LocalDate to) monthGridRange(LocalDate anyDay) {
  final first = anyDay.firstOfMonth;
  final from = first.addDays(-(first.weekday % 7));
  final lastNight = first.firstOfNextMonth.addDays(-1);
  final to = lastNight.addDays(7 - (lastNight.weekday % 7));
  return (from, to);
}

/// The soft blocks of [listingId] from every channel's block doc.
List<StaySoftBlock> softBlocksFor(String listingId, Iterable<StayChannelBlocks> channelBlocks) => [
      for (final doc in channelBlocks)
        if (doc.listingId == listingId)
          for (final r in doc.ranges)
            StaySoftBlock(
              channelId: doc.channelId,
              provider: doc.provider,
              checkIn: r.checkIn,
              checkOut: r.checkOut,
              echo: r.echo,
            ),
    ];

/// The engine's order for who holds a night: a stay that did not lose it
/// first, then the earlier writer (createdAtMs, then id).
int _holderOrder(Stay a, Stay b, String night) {
  final lostA = stayLostNight(a, night) ? 1 : 0;
  final lostB = stayLostNight(b, night) ? 1 : 0;
  if (lostA != lostB) return lostA - lostB;
  int ms(Stay s) => s.createdAtMs > 0 ? s.createdAtMs : 1 << 52;
  final byTime = ms(a).compareTo(ms(b));
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

/// The month holding [month] for one listing. [stays] may include other
/// listings' stays and cancelled ones; they are left out here.
StayMonthGrid buildStayMonthGrid({
  required String listingId,
  required LocalDate month,
  required LocalDate today,
  required Iterable<Stay> stays,
  required Iterable<StayChannelBlocks> channelBlocks,
}) {
  final (from, to) = monthGridRange(month);
  final mine = stays.where((s) => s.listingId == listingId).toList();
  final active = mine.where((s) => s.isActive).toList();
  final removed = mine.where((s) => s.status == StayStatus.removedFromFeed).toList();
  final soft = softBlocksFor(listingId, channelBlocks);
  final first = month.firstOfMonth;

  final weeks = <List<StayNightCell>>[];
  var week = <StayNightCell>[];
  for (var day = from; day.isBefore(to); day = day.addDays(1)) {
    final ymd = day.toYmd();
    final hard = active.where((s) => s.coversNight(ymd)).toList()..sort((a, b) => _holderOrder(a, b, ymd));
    week.add(StayNightCell(
      date: day,
      inMonth: day.month == first.month && day.year == first.year,
      isToday: day == today,
      isPast: day.isBefore(today),
      hard: hard,
      removed: removed.where((s) => s.coversNight(ymd)).toList(),
      soft: soft.where((b) => b.coversNight(ymd)).toList(),
    ));
    if (week.length == 7) {
      weeks.add(week);
      week = <StayNightCell>[];
    }
  }
  return StayMonthGrid(month: first, from: from, to: to, weeks: weeks);
}

/// A double booking as the owner sees it: [stay] lost [nights] to [holders].
@immutable
class StayConflictSummary {
  const StayConflictSummary({required this.stay, required this.nights, this.holders = const []});

  /// The stay the engine marked `conflict`.
  final Stay stay;

  /// The nights it lost ('YYYY-MM-DD').
  final List<String> nights;

  /// The stays holding those nights, as far as they are loaded.
  final List<Stay> holders;

  String get listingId => stay.listingId;

  bool get acknowledged => stay.conflict?.isAcknowledged == true;
}

/// The conflict stays still worth a banner: not acknowledged by the owner,
/// and with at least one lost night today or later ([today] is the
/// facility's date, never the browser's). With [today] unknown (no
/// confirmed zone) only acknowledged ones are dropped.
List<Stay> openConflictStays(Iterable<Stay> stays, {LocalDate? today}) {
  final todayYmd = today?.toYmd();
  return [
    for (final s in stays)
      if (s.status == StayStatus.conflict && s.conflict?.isAcknowledged != true)
        if (todayYmd == null || _hasNightFrom(s, todayYmd)) s,
  ];
}

bool _hasNightFrom(Stay stay, String todayYmd) {
  final nights = stay.conflict?.nights ?? const <String>[];
  // No nights listed: the stay's own last night (checkOut is exclusive).
  if (nights.isEmpty) return stay.checkOut.compareTo(todayYmd) > 0;
  return nights.any((n) => n.compareTo(todayYmd) >= 0);
}

/// One summary per stay in conflict, soonest first. [others] is where the
/// winners are looked up (any stays; their ids come from conflict.stayIds).
List<StayConflictSummary> summarizeConflicts(Iterable<Stay> stays, {Iterable<Stay> others = const []}) {
  final byId = <String, Stay>{for (final s in others) s.id: s, for (final s in stays) s.id: s};
  final out = <StayConflictSummary>[];
  for (final stay in stays) {
    if (stay.status != StayStatus.conflict) continue;
    final nights = List<String>.of(stay.conflict?.nights ?? const <String>[])..sort();
    final holders = <Stay>[
      for (final id in stay.conflict?.stayIds ?? const <String>[])
        if (id != stay.id && byId[id] != null) byId[id]!,
    ];
    out.add(StayConflictSummary(stay: stay, nights: nights, holders: holders));
  }
  out.sort((a, b) {
    final an = a.nights.isEmpty ? a.stay.checkIn : a.nights.first;
    final bn = b.nights.isEmpty ? b.stay.checkIn : b.nights.first;
    final byNight = an.compareTo(bn);
    return byNight != 0 ? byNight : a.stay.id.compareTo(b.stay.id);
  });
  return out;
}
