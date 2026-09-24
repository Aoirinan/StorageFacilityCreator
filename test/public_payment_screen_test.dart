import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/screens/public_payment_screen.dart';
import 'package:sfcapp/services/public_payment_link_service.dart';

const _token = 'tok_0123456789abcdef0123456789';
const _sessionId = 'cs_test_abc123';

PublicPaymentLink _link(String status) => PublicPaymentLink.fromMap(_token, {
      'token': _token,
      'amount': 125.5,
      'description': 'September rent',
      'status': status,
      'createdAt': '2026-09-01T00:00:00.000Z',
      'expiresAt': '2099-01-01T00:00:00.000Z',
    });

/// The server, as far as the payment page talks to it.
class _FakeApi extends PublicPaymentApi {
  _FakeApi({
    required this.links,
    String confirmStatus = 'paid',
    Object? confirmError,
    List<Object>? confirmAnswers,
    this.start,
  }) : confirmAnswers = confirmAnswers ?? [confirmError ?? confirmStatus];

  /// Successive getLink answers; the last one repeats.
  final List<PublicPaymentLink?> links;

  /// Successive confirmCheckout answers, a status or an error to throw; the
  /// last one repeats.
  final List<Object> confirmAnswers;
  final PublicCheckoutStart? start;

  int getCalls = 0;
  int startCalls = 0;
  final confirmCalls = <List<String>>[];

  @override
  Future<PublicPaymentLink?> getLink(String token) async {
    final answer = links[getCalls < links.length ? getCalls : links.length - 1];
    getCalls++;
    return answer;
  }

  @override
  Future<PublicCheckoutStart> startCheckout(String token) async {
    startCalls++;
    return start!;
  }

  @override
  Future<String> confirmCheckout(String token, String sessionId) async {
    final n = confirmCalls.length;
    confirmCalls.add([token, sessionId]);
    final answer = confirmAnswers[n < confirmAnswers.length ? n : confirmAnswers.length - 1];
    if (answer is String) return answer;
    throw answer;
  }
}

Future<void> _pump(
  WidgetTester tester,
  _FakeApi api, {
  PublicCheckoutReturn? checkoutReturn,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: PublicPaymentScreen(
      token: _token,
      api: api,
      checkoutReturn: checkoutReturn,
      pollInterval: const Duration(milliseconds: 100),
      maxPolls: 3,
    ),
  ));
  await tester.pump();
  await tester.pump();
}

const _successReturn = PublicCheckoutReturn(status: 'success', sessionId: _sessionId);

void main() {
  testWidgets('back from Stripe: confirms the session and shows paid, never Pay Now', (tester) async {
    final api = _FakeApi(links: [_link('pending'), _link('paid')]);

    await _pump(tester, api, checkoutReturn: _successReturn);

    expect(api.confirmCalls, [
      [_token, _sessionId],
    ]);
    expect(find.text('Payment Successful!'), findsOneWidget);
    expect(find.text('Pay Now'), findsNothing);
    // The page cannot know Stripe sent a receipt, so it no longer says so.
    expect(find.textContaining('receipt'), findsNothing);
  });

  testWidgets('a paid link shows the paid page, not "no longer active"', (tester) async {
    final api = _FakeApi(links: [_link('paid')]);

    await _pump(tester, api);

    expect(find.text('Payment Successful!'), findsOneWidget);
    expect(find.textContaining('no longer active'), findsNothing);
    expect(find.text('Pay Now'), findsNothing);
  });

  testWidgets('a payment still settling shows confirming, then paid once the link is', (tester) async {
    // First poll: webhook not in yet. Second: paid.
    final api = _FakeApi(
      links: [_link('pending'), _link('paid')],
      confirmStatus: 'processing',
    );

    await _pump(tester, api, checkoutReturn: _successReturn);
    expect(find.text('Confirming your payment…'), findsOneWidget);
    expect(find.text('Pay Now'), findsNothing);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('Pay Now'), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.text('Payment Successful!'), findsOneWidget);
  });

  testWidgets('polling re-confirms the session, so paid shows even when the webhook never marks the link',
      (tester) async {
    // checkout.session.completed is not delivered: the link itself stays pending.
    final api = _FakeApi(
      links: [_link('pending')],
      confirmAnswers: ['processing', 'processing', 'paid'],
    );

    await _pump(tester, api, checkoutReturn: _successReturn);
    expect(find.text('Confirming your payment…'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    expect(api.confirmCalls, List.filled(3, [_token, _sessionId]));
    expect(find.text('Payment Successful!'), findsOneWidget);
    expect(find.text('Pay Now'), findsNothing);
  });

  testWidgets('a poll that cannot confirm keeps checking and never offers Pay Now', (tester) async {
    final api = _FakeApi(
      links: [_link('pending')],
      confirmAnswers: [
        'processing',
        FirebaseFunctionsException(code: 'unavailable', message: 'Stripe timed out'),
        FirebaseFunctionsException(code: 'not-found', message: 'gone'),
      ],
    );

    await _pump(tester, api, checkoutReturn: _successReturn);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    expect(api.confirmCalls.length, 4);
    expect(find.text('Payment Processing'), findsOneWidget);
    expect(find.text('Pay Now'), findsNothing);
  });

  testWidgets('if confirming fails the tenant is told not to pay again, with no Pay Now', (tester) async {
    final api = _FakeApi(
      links: [_link('pending')],
      confirmError: FirebaseFunctionsException(code: 'unavailable', message: 'offline'),
    );

    await _pump(tester, api, checkoutReturn: _successReturn);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    expect(find.text('Payment Processing'), findsOneWidget);
    expect(find.text("You don't need to pay again."), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
    expect(find.text('Pay Now'), findsNothing);
  });

  testWidgets('a return URL for some other session falls back to the link itself', (tester) async {
    final api = _FakeApi(
      links: [_link('pending')],
      confirmError: FirebaseFunctionsException(code: 'permission-denied', message: 'not this link'),
    );

    await _pump(tester, api, checkoutReturn: _successReturn);

    expect(find.text('Pay Now'), findsOneWidget);
  });

  testWidgets('a payment the link could not take is shown as received', (tester) async {
    final api = _FakeApi(links: [_link('revoked')], confirmStatus: 'received');

    await _pump(tester, api, checkoutReturn: _successReturn);

    expect(find.text('Payment Received'), findsOneWidget);
    expect(find.text('Pay Now'), findsNothing);
  });

  testWidgets('Pay Now on a link that was paid in another tab shows paid and opens no checkout', (tester) async {
    final api = _FakeApi(
      links: [_link('pending'), _link('paid')],
      start: const PublicCheckoutStart.alreadyPaid(),
    );

    await _pump(tester, api);
    await tester.tap(find.text('Pay Now'));
    await tester.pump();
    await tester.pump();

    expect(api.startCalls, 1);
    expect(find.text('Payment Successful!'), findsOneWidget);
  });

  test('the return is read from the query before the hash route', () {
    final fromStripe = PublicCheckoutReturn.fromUri(Uri.parse(
      'https://app.example.test/?status=success&session_id=cs_live_a1B2#/pay?token=$_token',
    ));
    expect(fromStripe?.isSuccess, isTrue);
    expect(fromStripe?.sessionId, 'cs_live_a1B2');

    final cancelled = PublicCheckoutReturn.fromUri(Uri.parse('https://app.example.test/?status=cancel#/pay?token=x'));
    expect(cancelled?.status, 'cancel');
    expect(cancelled?.isSuccess, isFalse);

    // Stripe's placeholder, unfilled, is not a session.
    final template = PublicCheckoutReturn.fromUri(Uri.parse(
      'https://app.example.test/?status=success&session_id={CHECKOUT_SESSION_ID}#/pay?token=x',
    ));
    expect(template?.isSuccess, isFalse);

    expect(PublicCheckoutReturn.fromUri(Uri.parse('https://app.example.test/#/pay?token=x')), isNull);
  });
}
