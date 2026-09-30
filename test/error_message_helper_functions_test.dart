import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

void main() {
  test("a suspended account's billing refusal is shown as the server wrote it", () {
    // The billing callables refuse a suspended account with
    // details.reason 'account_suspended'. It was shown as "Operation cannot
    // be completed at this time. Please try again.", which invites a retry
    // that can never work.
    final refusal = FirebaseFunctionsException(
      code: 'failed-precondition',
      message: 'This account is suspended, and subscribing or paying does not restore access. '
          'Contact support@storagefacilitycreator.com to restore it.',
      details: {'reason': 'account_suspended'},
    );
    expect(ErrorMessageHelper.getUserFriendlyMessage(refusal), refusal.message);
  });

  test("a callable's error gets the callable wording, not the database's", () {
    // FirebaseFunctionsException is a FirebaseException, and the Firestore
    // branch came first.
    final denied = FirebaseFunctionsException(code: 'permission-denied', message: 'Access denied');
    expect(ErrorMessageHelper.getUserFriendlyMessage(denied),
        "You don't have permission to perform this action.");
    final other = FirebaseFunctionsException(
      code: 'failed-precondition',
      message: 'Facility must be linked to this account first',
      details: {'reason': 'something_else'},
    );
    expect(ErrorMessageHelper.getUserFriendlyMessage(other),
        'Operation cannot be completed. Please try again.');

    // A Firestore error still reads as one.
    final firestore = FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    expect(ErrorMessageHelper.getUserFriendlyMessage(firestore),
        "You don't have permission to access this data. Please contact your administrator.");
  });
}
