import 'package:flutter/material.dart';

/// The walk-up RV check-in sheet (spec §1.1 C): tonight's site grid, nights,
/// guest, payment and one "Check in & record $X" call.
///
/// A WP0 stub: the signature is final; WP4 replaces the body. Stays is behind
/// the shortTermRentals flag, so nothing opens it until then.
Future<void> showWalkUpSheet(BuildContext context, {required String facilityId, String? listingId}) async {}
