import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_notification_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/services/autopay_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
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

/// What the banner did: the reviews it marked read, and the facilities
/// whose reviews it read.
typedef _Pumped = ({List<(String, String)> marked, List<String> readFor});

Future<_Pumped> _pumpBanner(
  WidgetTester tester, {
  required String? facilityId,
  required List<FacilityNotificationModel> reviews,
}) async {
  final marked = <(String, String)>[];
  final readFor = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        _activeFacility(facilityId),
        unreadOnlineMoveInReviewsProvider.overrideWith((ref, id) {
          readFor.add(id);
          return Stream.value(reviews);
        }),
        markFacilityNotificationReadProvider.overrideWithValue(
          (facility, notification) async =>
              marked.add((facility, notification)),
        ),
      ],
      child: _bannerApp,
    ),
  );
  await tester.pumpAndSettle();
  return (marked: marked, readFor: readFor);
}

Override _activeFacility(String? facilityId) =>
    activeFacilityIdProvider.overrideWith(
      (ref) => ActiveFacilityNotifier(
        load: () async => facilityId,
        save: (_) async {},
      ),
    );

const _bannerApp = MaterialApp(
  home: Scaffold(body: Column(children: [OnlineMoveInReviewBanner()])),
);

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
    final pumped = await _pumpBanner(
      tester,
      facilityId: 'fac1',
      reviews: unreadNewestFirst([_review('n1', message)]),
    );

    expect(pumped.readFor, ['fac1']);
    expect(find.text(message), findsOneWidget);
    await tester.tap(find.text('Mark reviewed'));
    await tester.pumpAndSettle();

    expect(pumped.marked, [('fac1', 'n1')]);
  });

  testWidgets('nothing is shown with no unread reviews', (tester) async {
    await _pumpBanner(tester, facilityId: 'fac1', reviews: const []);

    expect(find.text('Mark reviewed'), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  for (final facilityId in <String?>[null, '', 'all']) {
    testWidgets(
        'nothing is shown, and nothing is read, with facility "$facilityId" '
        '(none chosen, or all of them at once)', (tester) async {
      final pumped = await _pumpBanner(
        tester,
        facilityId: facilityId,
        // Reviews there would be if it read them: 'all' is not a facility
        // with Notifications of its own.
        reviews: unreadNewestFirst([_review('n1', 'a review')]),
      );

      expect(pumped.readFor, isEmpty);
      expect(find.text('Mark reviewed'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });
  }

  group("the banner's own Firestore query", () {
    late FakeQueryLog log;

    setUp(() {
      log = FakeQueryLog();
      final notifications = FakeCollection([
        // Read ones first, so a query that fetched them would serve them.
        for (var i = 0; i < 3; i++)
          _review('read-$i', 'reviewed $i', readAt: DateTime(2026, 9, 22)),
        for (var i = 0; i < 12; i++)
          _review('unread-${i.toString().padLeft(2, '0')}', 'unread review $i',
              createdAt: DateTime(2026, 9, 1 + i)),
        FakeDoc('other-type', {
          'type': 'AUTOPAY_REQUESTED',
          'facilityId': 'fac1',
          'createdAt': Timestamp.fromDate(DateTime(2026, 9, 23)),
          'readAt': null,
          'message': 'autopay requested',
        }),
      ], log: log);
      FacilitySubcollections.overrideForTesting((facilityId, name) {
        expect((facilityId, name), ('fac1', 'Notifications'));
        return notifications;
      });
    });
    tearDown(() => FacilitySubcollections.overrideForTesting(null));

    testWidgets('asks Firestore for a few unread reviews only, and marks one read',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [_activeFacility('fac1')],
        child: _bannerApp,
      ));
      await tester.pumpAndSettle();

      // Before: every review the facility ever had, read ones included, with
      // no limit, on every screen for every staff session; the read ones
      // were dropped only after they had been fetched.
      expect(log.equalityFilters, [
        ('type', 'ONLINE_MOVE_IN_REVIEW'),
        ('readAt', null),
      ]);
      expect(log.limits, [AutopayService.unreadNotificationsOfTypeLimit]);
      expect(find.text('Mark reviewed'),
          findsNWidgets(AutopayService.unreadNotificationsOfTypeLimit));
      // The newest ten of the twelve unread, not the first ten by document
      // id: before, with no ordering, a new alert past the limit was hidden
      // until older ones were marked reviewed.
      expect(log.orderedBy, ['createdAt']);
      expect(find.text('unread review 11'), findsOneWidget);
      expect(find.text('unread review 2'), findsOneWidget);
      expect(find.text('unread review 1'), findsNothing);
      expect(find.text('unread review 0'), findsNothing);
      expect(find.textContaining('reviewed '), findsNothing);
      expect(find.text('autopay requested'), findsNothing);

      await tester.tap(find.text('Mark reviewed').first);
      await tester.pumpAndSettle();

      // The one change the rules allow staff: readAt, and nothing else.
      final (op, id, data) = log.writes.single;
      expect(op, 'update');
      expect(id, startsWith('unread-'));
      expect(data.keys, ['readAt']);
      expect(data['readAt'], isA<FieldValue>());
    });
  });
}
