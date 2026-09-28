import 'package:flutter/material.dart';

/// Block dates on a listing (owner use or maintenance), prefilled from the
/// tape chart ([checkIn]/[checkOut] are 'YYYY-MM-DD', checkOut exclusive).
///
/// A WP0 stub: the signature is final; WP4 replaces the body. Stays is behind
/// the shortTermRentals flag, so nothing opens it until then.
Future<void> showQuickBlockSheet(
  BuildContext context, {
  required String facilityId,
  String? listingId,
  String? checkIn,
  String? checkOut,
}) async {}
