import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// The browser's Intl.DateTimeFormat, which knows every IANA zone; the Dart
// SDK has no zone database of its own. 'en-CA' gives numeric parts.

final Map<String, JSObject> _formatters = {};

JSObject _formatterFor(String timeZone) {
  final cached = _formatters[timeZone];
  if (cached != null) return cached;
  final intl = globalContext['Intl'] as JSObject;
  final ctor = intl['DateTimeFormat'] as JSFunction;
  final options = {
    'timeZone': timeZone,
    'year': 'numeric',
    'month': '2-digit',
    'day': '2-digit',
    'hour': '2-digit',
    'minute': '2-digit',
    'hourCycle': 'h23',
  }.jsify();
  // Throws a RangeError for a zone the browser does not know.
  final formatter = ctor.callAsConstructor<JSObject>('en-CA'.toJS, options);
  _formatters[timeZone] = formatter;
  return formatter;
}

/// Year, month, day, hour and minute of [instantUtc] in [timeZone], or null
/// when the browser does not know the zone.
Map<String, String>? wallClockParts(DateTime instantUtc, String timeZone) {
  try {
    final parts = _formatterFor(timeZone).callMethod<JSArray<JSObject>>(
      'formatToParts'.toJS,
      instantUtc.millisecondsSinceEpoch.toJS,
    );
    final result = <String, String>{};
    for (final part in parts.toDart) {
      final type = (part['type'] as JSString?)?.toDart;
      final value = (part['value'] as JSString?)?.toDart;
      if (type != null && value != null) result[type] = value;
    }
    return result;
  } catch (_) {
    return null;
  }
}
