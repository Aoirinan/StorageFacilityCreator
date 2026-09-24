import 'package:cloud_firestore/cloud_firestore.dart';

// Reads of one stored field that never throw on a value of the wrong type.
// UnitModel.fromFirestore cast and called methods on raw values, so one unit
// doc with, say, a numeric unitNumber from an import failed the whole
// facility's unit read: the Units list came back empty and the public map
// publish failed. The Cloud Functions read the same docs with String() and
// Number(); these follow them.

/// A string as stored; a number or bool as its text (101 reads '101', as
/// String() gives it on the server); anything else, such as a map, list or
/// timestamp, as missing.
String? textFromField(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

/// A finite number, or a string holding one (' 100 ' reads 100), as the
/// server's Number() reads it for rent (moveInCharges.ts) and the public
/// site's asNumber for display; anything else as missing.
double? numberFromField(Object? value) {
  final n = value is num
      ? value.toDouble()
      : value is String
          ? double.tryParse(value.trim())
          : null;
  return n != null && n.isFinite ? n : null;
}

/// A Timestamp, as Firestore returns dates, or a DateTime; anything else,
/// such as a date typed in as a string, as missing, as the app's other models
/// read dates.
DateTime? dateFromField(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

/// A map, with its keys as strings; anything else as missing.
Map<String, dynamic>? mapFromField(Object? value) {
  if (value is! Map) return null;
  return {for (final e in value.entries) e.key.toString(): e.value};
}

/// A list, each entry read by [textFromField] and the unreadable ones left
/// out; anything else as missing.
List<String>? textListFromField(Object? value) {
  if (value is! List) return null;
  return value.map(textFromField).whereType<String>().toList();
}
