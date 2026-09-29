import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/screens/public_move_in_screen.dart';
import 'package:sfcapp/services/public_rental_service.dart';

/// The move-in page finds a payment made for its reservation that no Stripe
/// redirect confirmed: a renter who paid and closed Stripe's tab, or came
/// back on the move-in link. Before, the page offered to take the payment
/// again, checkout refused that as already paid, and the renter could not
/// finish (public_move_in_screen.dart, _findRecordedPayment).
void main() {
  const token = 'move-in-token-0123456789';
  const reservationId = 'res-page';

  late List<MapEntry<String, Map<String, dynamic>>> calls;
  late List<Map<String, dynamic>> confirmAnswers;
  late List<Uri> opened;

  List<Map<String, dynamic>> callsTo(String name) =>
      calls.where((c) => c.key == name).map((c) => c.value).toList();

  setUp(() {
    calls = [];
    opened = [];
    confirmAnswers = [];
    PublicRentalService.callableForTesting = (name, data) async {
      calls.add(MapEntry(name, Map<String, dynamic>.from(data)));
      switch (name) {
        case 'getPublicReservationByToken':
          return <String, dynamic>{
            'found': true,
            'reservation': <String, dynamic>{
              'id': reservationId,
              'facilityId': 'fac-page',
              'unitId': 'unit-page',
              'unitNumber': 'P1',
              'email': 'renter@example.com',
              'phone': '5551234567',
              'name': 'Rita Renter',
              'status': 'pending',
              'reservedAt': DateTime(2026, 9, 24).toIso8601String(),
              'moveInDate': DateTime(2026, 9, 25).toIso8601String(),
              'moveInToken': token,
            },
          };
        case 'confirmPublicMoveInCheckout':
          // One answer per ask, the last repeated.
          return confirmAnswers.length > 1
              ? confirmAnswers.removeAt(0)
              : confirmAnswers.first;
        case 'createPublicMoveInCheckout':
          return <String, dynamic>{
            'checkoutUrl': 'https://checkout.example/cs_new',
            'sessionId': 'cs_new',
          };
        case 'completePublicMoveIn':
          return <String, dynamic>{'success': true, 'tenantId': 'tenant-new'};
      }
      throw StateError('unexpected callable $name');
    };
  });

  tearDown(() => PublicRentalService.callableForTesting = null);

  const notPaid = <String, dynamic>{'success': false, 'paid': false};
  const paid = <String, dynamic>{
    'success': true,
    'paid': true,
    'paymentIntentId': 'pi_recorded',
    'amountPaid': 25.0,
    'currency': 'usd',
    'sessionId': 'cs_recorded',
  };

  final sources = PublicMoveInScreenSources(
    getUnit: (facilityId, unitId) async => UnitModel(
      id: unitId,
      facilityId: facilityId,
      unitNumber: 'P1',
      unitType: 'standard',
      status: UnitStatus.reserved,
      monthlyRate: 100,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner',
    ),
    getFacility: (facilityId) async => FacilityModel(
      id: facilityId,
      name: 'Page Storage',
      ownerUid: 'owner',
      createdAt: DateTime(2026, 1, 1),
      stripeConnectAccountId: 'acct_page',
      stripeConnectOnboardingComplete: true,
    ),
    getPublicSettings: (_) async => null,
    openCheckout: (url) async {
      opened.add(url);
      return true;
    },
  );

  Future<void> openPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/public-move-in',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Text('home')),
        GoRoute(
          path: '/public-move-in',
          builder: (_, __) =>
              PublicMoveInScreen(token: token, sources: sources),
        ),
      ],
    );
    await tester.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
  }

  /// Fills in what the page requires before it pays or submits.
  Future<void> fillInForm(WidgetTester tester) async {
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Mailing Address *'), '1 Main St');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Emergency Contact Name *'),
        'Ed Emergency');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Emergency Contact Phone *'),
        '5559876543');
    await tester.tap(find.text('I agree to the terms and conditions'));
    await tester.pump();
    final pad = find.byType(ClipRRect).last;
    await tester.dragFrom(
        tester.getCenter(pad) - const Offset(60, 0), const Offset(120, 30));
    await tester.pump();
  }

  Future<void> pressSubmit(WidgetTester tester, String label) async {
    final button = find.widgetWithText(ElevatedButton, label);
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    // Real time: the signature is drawn to a PNG before the call is made.
    await tester.runAsync(() async {
      await tester.tap(button);
      for (var i = 0;
          i < 50 && callsTo('completePublicMoveIn').isEmpty && opened.isEmpty;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
  }

  /// After a move-in, the page shows its confirmation for two seconds and goes home.
  Future<void> leavesThePage(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2200)));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  }

  testWidgets(
      'on opening, the page asks for the payment recorded for the reservation, '
      'and finishes with it', (tester) async {
    confirmAnswers = [paid];
    await openPage(tester);

    // Asked about the recorded session: no session_id came back from Stripe.
    final confirms = callsTo('confirmPublicMoveInCheckout');
    expect(confirms, hasLength(1));
    expect(confirms.single, {'reservationId': reservationId, 'token': token});
    expect(find.text('We found your payment. You can now submit move-in.'),
        findsOneWidget);
    expect(find.text('Payment Received'), findsOneWidget);
    // Before: 'Pay and Submit Move-In', which went to a checkout that
    // refused the reservation as already paid.
    expect(find.widgetWithText(ElevatedButton, 'Submit Move-In Request'),
        findsOneWidget);

    await fillInForm(tester);
    await pressSubmit(tester, 'Submit Move-In Request');

    expect(callsTo('createPublicMoveInCheckout'), isEmpty);
    final completes = callsTo('completePublicMoveIn');
    expect(completes, hasLength(1));
    expect(completes.single['paymentIntentId'], 'pi_recorded');
    expect(completes.single['skipPayment'], false);
    await leavesThePage(tester);
  });

  testWidgets(
      'nothing paid on opening: paying first asks again, and finishes with a '
      'payment made meanwhile instead of starting a checkout', (tester) async {
    // Paid in another tab after the page opened.
    confirmAnswers = [notPaid, paid];
    await openPage(tester);
    expect(callsTo('confirmPublicMoveInCheckout'), hasLength(1));
    expect(find.text('We found your payment. You can now submit move-in.'),
        findsNothing);

    await fillInForm(tester);
    await pressSubmit(tester, 'Pay and Submit Move-In');

    final confirms = callsTo('confirmPublicMoveInCheckout');
    expect(confirms, hasLength(2));
    expect(confirms.last, {'reservationId': reservationId, 'token': token});
    // Before: a second checkout, refused as already paid.
    expect(callsTo('createPublicMoveInCheckout'), isEmpty);
    expect(opened, isEmpty);
    final completes = callsTo('completePublicMoveIn');
    expect(completes, hasLength(1));
    expect(completes.single['paymentIntentId'], 'pi_recorded');
    await leavesThePage(tester);
  });

  testWidgets('with nothing paid, paying starts a checkout and opens Stripe',
      (tester) async {
    confirmAnswers = [notPaid];
    await openPage(tester);

    await fillInForm(tester);
    await pressSubmit(tester, 'Pay and Submit Move-In');

    expect(callsTo('confirmPublicMoveInCheckout'), hasLength(2));
    expect(callsTo('createPublicMoveInCheckout'), hasLength(1));
    expect(opened, [Uri.parse('https://checkout.example/cs_new')]);
    expect(callsTo('completePublicMoveIn'), isEmpty);
  });
}
