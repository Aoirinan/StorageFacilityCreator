import 'dart:math';

final RegExp _requestIdPattern = RegExp(r'^[a-f0-9]{32}$');

/// A 128-bit random id as 32 lowercase hex characters, minted once per form
/// (e.g. in initState) so a retried save lands on the same server doc
/// (`man_{requestId}`) instead of booking or charging twice. There is no uuid
/// package in this app.
String newRequestId([Random? random]) {
  final r = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

bool isValidRequestId(String? value) => value != null && _requestIdPattern.hasMatch(value);
