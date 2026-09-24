import 'package:flutter/material.dart';

/// Record a payment on a stay (cash, check, card taken elsewhere, Venmo),
/// through staysRecordPayment with a requestId minted when the sheet opens.
///
/// A WP0 stub: the signature is final; WP4 replaces the body. Stays is behind
/// the shortTermRentals flag, so nothing opens it until then.
Future<void> showRecordPaymentSheet(BuildContext context, {required String facilityId, required String stayId}) async {}
