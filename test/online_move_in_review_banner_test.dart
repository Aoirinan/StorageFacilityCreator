import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_notification_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/widgets/online_move_in_review_banner.dart';

import 'support/fake_facility_collection.dart';

/// A notification doc as completePublicMoveIn writes it
/// (functions-public-website onlineMoveInReview.ts).
FakeDoc _review(String id, String message,
        {DateTime? createdAt, DateTime? readAt}) =>
    FakeDoc(id, {
      'type': 'ONLINE_MOVE_IN_REVIEW',
      'facilityId': 'fac1',
      'tenantId': 't-$id',
      'tenantName': 'Rita Renter',
      'createdAt': Timestamp.fromDate(createdAt ?? DateTime(2026, 9, 23, 12)),
      'readAt': readAt == null ? null : Timestamp.fromDate(readAt),
      'message': message,
      'metadata': {'reason': 'internal-use', 'unitId': 'u1'},
    });

Future<List<(String, String)>> _pumpBanner(
  WidgetTester tester, {
  required String? facilityId,
  required List<FacilityNotificationModel> reviews,
}) async {
  final marked = <(String, String)>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeFacilityIdProvider.overrideWith(
          (ref) => ActiveFacilityNotifier(
            load: () async => facilityId,
            save: (_) async {},
          ),
        ),
        unreadOnlineMoveInReviewsProvider.overrideWith((ref, id) {
          expect(id, facilityId);
          return Stream.value(reviews);
        }),
        markFacilityNotificationReadProvider.overrideWithValue(
          (facility, notification) async =>
              marked.add((facility, notification)),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Column(children: [OnlineMoveInReviewBanner()])),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return marked;
}

void main() {
  test('the server writes a type the app reads as an online move-in review',
      () {
    final model = FacilityNotificationModel.fromFirestore(_review('n1', 'x'));
    // Before: an unknown type read as autopayRequested.
    expect(model.type, FacilityNotificationType.onlineMoveInReview);
    expect(FacilityNotificationType.onlineMoveInReview.value,
        'ONLINE_MOVE_IN_REVIEW');
  });

  test('only unread reviews are shown, newest first', () {
    final reviews = unreadNewestFirst([
      _review('old', 'older', createdAt: DateTime(2026, 9, 20)),
      _review('done', 'reviewed', readAt: DateTime(2026, 9, 22)),
      _review('new', 'newer', createdAt: DateTime(2026, 9, 23)),
    ]);
    expect([for (final r in reviews) r.id], ['new', 'old']);
  });

  testWidgets('an unread review is shown and can be marked reviewed',
      (tester) async {
    const message = 'Rita Renter paid online and was moved into unit L1, '
        'which was set to internal use after they reserved it. '
        'Check the unit and the new tenancy.';
    final marked = await _pumpBanner(
      tester,
      facilityId: 'fac1',
      reviews: unreadNewestFirst([_review('n1', message)]),
    );

    expect(find.text(message), findsOneWidget);
    await tester.tap(find.text('Mark reviewed'));
    await tester.pumpAndSettle();

    expect(marked, [('fac1', 'n1')]);
  });

  testWidgets('nothing is shown with no unread reviews', (tester) async {
    await _pumpBanner(tester, facilityId: 'fac1', reviews: const []);

    expect(find.text('Mark reviewed'), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('nothing is shown, and nothing is read, with no facility chosen',
      (tester) async {
    await _pumpBanner(tester, facilityId: null, reviews: const []);

    expect(find.text('Mark reviewed'), findsNothing);
  });
}
