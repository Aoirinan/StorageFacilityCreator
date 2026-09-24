import 'package:cloud_firestore/cloud_firestore.dart';

// Defensive readers for Stays documents (spec §3.1): every optional field
// has a safe default, the way UnitModel.publicListingEnabled reads a doc
// written before the field existed. Automation switches count only when
// they are exactly `true`.

/// A Firestore Timestamp, a DateTime, or an ISO-8601 string (callables
/// return timestamps as strings) → DateTime, else null.
DateTime? stayTime(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

String stayStr(Object? value, [String fallback = '']) => value is String ? value : fallback;

String? stayStrOrNull(Object? value) => value is String ? value : null;

/// An integer, accepting whole doubles (web JSON has no int/double split).
int stayInt(Object? value, [int fallback = 0]) => stayIntOrNull(value) ?? fallback;

int? stayIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.roundToDouble()) return value.toInt();
  return null;
}

double stayNum(Object? value, [double fallback = 0]) => value is num ? value.toDouble() : fallback;

bool stayTrue(Object? value) => value == true;

List<String> stayStrList(Object? value) =>
    value is List ? value.whereType<String>().toList(growable: false) : const [];

Map<String, dynamic> stayMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
  return const {};
}

List<Map<String, dynamic>> stayMapList(Object? value) =>
    value is List ? value.whereType<Map>().map(stayMap).toList(growable: false) : const [];

/// The data of a document snapshot, or an empty map.
Map<String, dynamic> stayDocData(DocumentSnapshot<Object?> doc) => stayMap(doc.data());
