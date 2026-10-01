import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/utils/local_date.dart';

// Plain-text labels Stays screens share: dates written from 'YYYY-MM-DD'
// strings (never through a DateTime in the browser's zone), "6 min ago",
// and the names of listing kinds, channels and export scopes.

const List<String> _monthShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const List<String> _monthLong = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const List<String> _weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// 'Oct 3'.
String shortDateLabel(LocalDate date) => '${_monthShort[date.month - 1]} ${date.day}';

/// 'Sat, Oct 3'.
String weekdayDateLabel(LocalDate date) => '${_weekdayShort[date.weekday - 1]}, ${shortDateLabel(date)}';

/// 'October 2026'.
String monthTitle(LocalDate anyDayInMonth) => '${_monthLong[anyDayInMonth.month - 1]} ${anyDayInMonth.year}';

/// 'Oct 3' from '2026-10-03'; the text as-is when it is not a date.
String ymdLabel(String ymd) {
  final date = LocalDate.tryParse(ymd);
  return date == null ? ymd : shortDateLabel(date);
}

/// A stay's dates: 'Oct 3 – Oct 6 · 3 nights' (checkOut is the departure day).
String stayDatesLabel(String checkIn, String checkOut) {
  final a = LocalDate.tryParse(checkIn);
  final b = LocalDate.tryParse(checkOut);
  if (a == null || b == null) return '$checkIn – $checkOut';
  final nights = a.daysUntil(b);
  return '${shortDateLabel(a)} – ${shortDateLabel(b)} · $nights ${nights == 1 ? 'night' : 'nights'}';
}

/// Nights ('YYYY-MM-DD') as runs: 'Oct 3–5, Oct 9'. Runs of consecutive
/// nights are joined; unparseable values are left out.
String describeNights(Iterable<String> nights) {
  final dates = nights.map(LocalDate.tryParse).whereType<LocalDate>().toSet().toList()..sort();
  if (dates.isEmpty) return '';
  final runs = <String>[];
  var start = dates.first;
  var end = dates.first;
  void close() {
    if (start == end) {
      runs.add(shortDateLabel(start));
    } else if (start.month == end.month && start.year == end.year) {
      runs.add('${shortDateLabel(start)}–${end.day}');
    } else {
      runs.add('${shortDateLabel(start)} – ${shortDateLabel(end)}');
    }
  }

  for (final date in dates.skip(1)) {
    if (end.addDays(1) == date) {
      end = date;
      continue;
    }
    close();
    start = date;
    end = date;
  }
  close();
  return runs.join(', ');
}

/// 'just now', '6 min ago', '2 h ago', '3 days ago'; null → 'never'.
String agoLabel(DateTime? at, DateTime now) {
  if (at == null) return 'never';
  final d = now.difference(at);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}

/// The listing kinds the setup wizard offers, in order.
const List<StayListingKind> setupListingKinds = [
  StayListingKind.vacationRental,
  StayListingKind.house,
  StayListingKind.cabin,
  StayListingKind.rvSite,
];

String listingKindLabel(StayListingKind kind) => switch (kind) {
      StayListingKind.vacationRental => 'Home (Airbnb-style rental)',
      StayListingKind.house => 'House',
      StayListingKind.cabin => 'Cabin',
      StayListingKind.room => 'Room',
      StayListingKind.rvSite => 'RV site',
      StayListingKind.tentSite => 'Tent site',
      StayListingKind.garage => 'Garage',
      StayListingKind.other => 'Other',
      StayListingKind.unknown => 'Listing',
    };

/// The sites a calendar can be imported from, in the order they are offered.
const List<ChannelProvider> importProviders = [
  ChannelProvider.airbnb,
  ChannelProvider.vrbo,
  ChannelProvider.booking,
  ChannelProvider.google,
  ChannelProvider.hipcamp,
  ChannelProvider.other,
];

String channelProviderLabel(ChannelProvider provider) => switch (provider) {
      ChannelProvider.airbnb => 'Airbnb',
      ChannelProvider.vrbo => 'VRBO',
      ChannelProvider.booking => 'Booking.com',
      ChannelProvider.google => 'Google Calendar',
      ChannelProvider.hipcamp => 'Hipcamp',
      ChannelProvider.other => 'Other site',
      ChannelProvider.unknown => 'Calendar',
    };

/// The sites an SFC export link can be made for, in the order they are offered.
const List<ExportTargetProvider> exportTargets = [
  ExportTargetProvider.airbnb,
  ExportTargetProvider.vrbo,
  ExportTargetProvider.booking,
  ExportTargetProvider.google,
  ExportTargetProvider.hipcamp,
  ExportTargetProvider.other,
];

String exportTargetLabel(ExportTargetProvider target) => switch (target) {
      ExportTargetProvider.airbnb => 'Airbnb',
      ExportTargetProvider.vrbo => 'VRBO',
      ExportTargetProvider.booking => 'Booking.com',
      ExportTargetProvider.google => 'Google Calendar',
      ExportTargetProvider.hipcamp => 'Hipcamp',
      ExportTargetProvider.other => 'Another site',
      ExportTargetProvider.unknown => 'A calendar app',
    };

/// The export target that imports a channel's own calendar (Airbnb → Airbnb).
ExportTargetProvider exportTargetFor(ChannelProvider provider) => switch (provider) {
      ChannelProvider.airbnb => ExportTargetProvider.airbnb,
      ChannelProvider.vrbo => ExportTargetProvider.vrbo,
      ChannelProvider.booking => ExportTargetProvider.booking,
      ChannelProvider.google => ExportTargetProvider.google,
      ChannelProvider.hipcamp => ExportTargetProvider.hipcamp,
      ChannelProvider.other => ExportTargetProvider.other,
      ChannelProvider.unknown => ExportTargetProvider.unknown,
    };

String exportScopeLabel(ExportScope scope) => switch (scope) {
      ExportScope.blocksOnly => 'Owner and maintenance blocks only',
      ExportScope.sfc => 'Blocks, plus direct, phone and walk-up bookings',
      ExportScope.all => 'Blocks, SFC bookings and other channels’ bookings',
      ExportScope.unknown => 'Unknown',
    };

/// Dollars typed by a person ('125', '125.5', '$1,250.00') → cents. Blank
/// is null; anything else that is not a non-negative amount with at most two
/// decimals throws [FormatException] rather than guessing.
int? parseDollarsToCents(String text) {
  final cleaned = text.trim().replaceAll(r'$', '').replaceAll(',', '');
  if (cleaned.isEmpty) return null;
  final match = RegExp(r'^(\d{1,7})(?:\.(\d{1,2}))?$').firstMatch(cleaned);
  if (match == null) throw FormatException('Enter an amount like 125 or 125.50', text);
  final dollars = int.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  return dollars * 100 + int.parse(fraction);
}

/// '$125' or '$125.50'.
String centsLabel(int cents) {
  final dollars = cents ~/ 100;
  final rest = cents % 100;
  return rest == 0 ? '\$$dollars' : '\$$dollars.${rest.toString().padLeft(2, '0')}';
}

/// A short code for a new listing (1–8 characters, unique among [taken],
/// compared without case): 'Cabin 2' → 'C2', 'RV 3' → 'RV3', 'Blue House'
/// → 'BH', 'Loft' → 'LOF'. The server refuses a short code already in use.
String suggestShortCode(String name, Iterable<String> taken) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final buffer = StringBuffer();
  for (final raw in words) {
    final word = raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (word.isEmpty) continue;
    if (RegExp(r'^\d+$').hasMatch(word) || word.length <= 3) {
      buffer.write(word.toUpperCase());
    } else {
      buffer.write(word[0].toUpperCase());
    }
  }
  var base = buffer.toString();
  if (base.length < 2) {
    final letters = name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    base = letters.length >= 3 ? letters.substring(0, 3) : (letters.isEmpty ? 'L' : letters);
  }
  if (base.length > 8) base = base.substring(0, 8);
  final used = {for (final t in taken) t.trim().toUpperCase()};
  if (!used.contains(base)) return base;
  for (var n = 2; n < 1000; n++) {
    final suffix = '$n';
    final head = base.length + suffix.length > 8 ? base.substring(0, 8 - suffix.length) : base;
    final candidate = '$head$suffix';
    if (!used.contains(candidate)) return candidate;
  }
  return base;
}
