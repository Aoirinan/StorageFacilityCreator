import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/reminder_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/reminder_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/screens/reminder_creation_screen.dart';
import 'package:sfcapp/screens/reminder_list_screen.dart';
import 'package:sfcapp/services/reminder_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

/// Runs ReminderService's real order of work with channels that send as
/// [outcomes] says: a label (delivered), null (did not go out) or an
/// error (thrown). [record] fails when [recordFails].
Future<(ReminderSendResult, List<ReminderChannel>, List<List<String>>)> _send(
  List<ReminderChannel> channels, {
  Map<ReminderChannel, Object?> outcomes = const {},
  bool recordFails = false,
}) async {
  final tried = <ReminderChannel>[];
  final recorded = <List<String>>[];
  final result = await ReminderService.deliverAndRecord(
    channels: channels,
    deliver: (channel) async {
      tried.add(channel);
      final outcome = outcomes[channel];
      if (outcome is Exception) throw outcome;
      return outcome as String?;
    },
    record: (delivered) async {
      recorded.add(delivered);
      if (recordFails) throw Exception('permission-denied');
    },
  );
  return (result, tried, recorded);
}

ReminderModel _reminder(List<ReminderChannel> channels) => ReminderModel(
      id: 'r1',
      tenantId: 't1',
      facilityId: 'f1',
      tenantEmail: 'pat@example.com',
      type: ReminderType.custom,
      status: ReminderStatus.pending,
      channels: channels,
      title: 'Rent due',
      message: 'Rent is due',
      scheduledFor: DateTime(2026, 9, 1),
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
      createdBy: 'owner-1',
    );

/// Sends every reminder by email.
class _EmailingOperations extends ReminderOperationsNotifier {
  @override
  Future<ReminderSendResult> sendReminder({
    required String facilityId,
    required String reminderId,
    required String tenantEmail,
    required String tenantPhone,
    required String message,
    required List<ReminderChannel> channels,
  }) async =>
      const ReminderSendResult(delivered: ['email']);
}

/// The Reminders list with one pending [reminder], and Send now on it
/// tapped and confirmed.
Future<void> _sendFromList(
  WidgetTester tester,
  ReminderModel reminder, {
  ReminderOperationsNotifier? operations,
}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final facility = FacilityModel(
    id: 'f1',
    name: 'Oak Storage',
    ownerUid: 'owner-1',
    createdAt: DateTime(2026, 1, 1),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(
          (ref) => Stream.value(MockUser(uid: 'owner-1')),
        ),
        userFacilitiesProvider('owner-1').overrideWith(
          (ref) => Stream.value([facility]),
        ),
        activeFacilityIdProvider.overrideWith(
          (ref) => ActiveFacilityNotifier.idle(const AsyncValue.data('f1')),
        ),
        reminderStatsProvider('f1').overrideWith(
          (ref) async => {'total': 1, 'sent': 0, 'pending': 1, 'overdue': 0},
        ),
        reminderListProvider('f1').overrideWith(
          (ref) => Stream.value([reminder]),
        ),
        if (operations != null)
          reminderOperationsProvider.overrideWith((ref) => operations),
      ],
      child: const MaterialApp(home: Scaffold(body: ReminderListScreen())),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Send now'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Send'));
  await tester.pumpAndSettle();
}

void main() {
  group('push and in-app', () {
    // They were mocks that counted as delivered: a reminder made with the
    // creation page's default (in-app) and sent said "Reminder sent
    // successfully" and was marked sent via in-app, with nothing sent.
    test('are never tried and never count as delivered', () async {
      final (result, tried, recorded) = await _send(
        const [ReminderChannel.inApp, ReminderChannel.push],
      );
      expect(tried, isEmpty);
      expect(recorded, isEmpty);
      expect(result.sent, isFalse);
      expect(result.unavailable, [ReminderChannel.inApp, ReminderChannel.push]);
    });

    // The real notifier and ReminderService, as the reminder pages call
    // them. Nothing is tried, so no Firebase is needed.
    test('a send on them alone is refused and says why', () async {
      final notifier = ReminderOperationsNotifier();
      addTearDown(notifier.dispose);
      Object? error;
      try {
        await notifier.sendReminder(
          facilityId: 'f1',
          reminderId: 'r1',
          tenantEmail: 'pat@example.com',
          tenantPhone: '',
          message: 'Rent is due',
          channels: const [ReminderChannel.inApp],
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<ReminderChannelNotAvailable>());
      expect(
        ErrorMessageHelper.getUserFriendlyMessage(error),
        'In-App reminders are not available yet, so nothing was sent. '
        'Send it by email or SMS instead.',
      );
      expect(notifier.state, isA<AsyncError<void>>());
    });

    test('alongside email, only the email counts and is recorded', () async {
      final (result, tried, recorded) = await _send(
        const [ReminderChannel.email, ReminderChannel.inApp],
        outcomes: {ReminderChannel.email: 'email'},
      );
      expect(tried, [ReminderChannel.email]);
      // The reminder's sentVia; it said "email, in-app".
      expect(recorded, [
        ['email'],
      ]);
      expect(() => throwUnlessReminderSent(result), returnsNormally);
      expect(
        reminderSentMessage(result),
        'Reminder sent (email). In-App reminders are not available yet, so '
        'it did not go out that way.',
      );
    });

    test('are the only channels that cannot send', () {
      expect(
        [for (final c in ReminderChannel.values) if (c.canSend) c],
        [ReminderChannel.email, ReminderChannel.sms],
      );
    });
  });

  group('a send that went out', () {
    // sendReminder caught the failed record and returned false, and the
    // page said no channel went through: a resend emailed or texted the
    // tenant again.
    test('is not reported as not sent when recording it failed', () async {
      final (result, _, recorded) = await _send(
        const [ReminderChannel.email],
        outcomes: {ReminderChannel.email: 'email'},
        recordFails: true,
      );
      expect(recorded, hasLength(1));
      expect(result.sent, isTrue);
      expect(result.recordError, isNotNull);

      Object? error;
      try {
        throwUnlessReminderSent(result);
      } catch (e) {
        error = e;
      }
      expect(error, isA<ReminderNotRecordedException>());
      expect(error, isNot(isA<ReminderNotSentException>()));
      expect(
        ErrorMessageHelper.getUserFriendlyMessage(error),
        'The reminder went out (email), but saving it as sent failed, so it '
        "may still show as not sent. Check the reminder's status before "
        'sending it again.',
      );
    });

    // One channel throwing stopped the rest and reported nothing sent.
    test('goes on to the next channel when one fails', () async {
      final (result, tried, recorded) = await _send(
        const [ReminderChannel.email, ReminderChannel.sms],
        outcomes: {
          ReminderChannel.email: Exception('digest queue failed'),
          ReminderChannel.sms: 'sms',
        },
      );
      expect(tried, [ReminderChannel.email, ReminderChannel.sms]);
      expect(recorded, [
        ['sms'],
      ]);
      expect(result.failed, [ReminderChannel.email]);
      expect(
        reminderSentMessage(result),
        'Reminder sent (sms). Email did not go through.',
      );
    });
  });

  test('nothing went out: not recorded, and reported as not sent', () async {
    final (result, _, recorded) = await _send(
      const [ReminderChannel.email, ReminderChannel.sms],
    );
    expect(recorded, isEmpty);
    expect(
      () => throwUnlessReminderSent(result),
      throwsA(isA<ReminderNotSentException>()),
    );
    expect(
      ErrorMessageHelper.getUserFriendlyMessage(
        const ReminderNotSentException(),
      ),
      'The reminder was not sent: no channel (email, SMS) went through.',
    );
  });

  // The creation page defaulted to in-app and offered push and in-app.
  testWidgets('a new reminder defaults to email; push and in-app are off',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          facilityTenantsProvider('f1').overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ReminderCreationScreen(facilityId: 'f1')),
        ),
      ),
    );
    await tester.pump();

    FilterChip chip(ReminderChannel channel) => tester.widget(
          find.widgetWithText(FilterChip, channel.displayName),
        );
    expect(chip(ReminderChannel.email).selected, isTrue);
    expect(chip(ReminderChannel.email).onSelected, isNotNull);
    expect(chip(ReminderChannel.sms).onSelected, isNotNull);
    for (final channel in [ReminderChannel.push, ReminderChannel.inApp]) {
      expect(chip(channel).selected, isFalse, reason: channel.name);
      expect(chip(channel).onSelected, isNull, reason: channel.name);
    }
  });

  group('Send now on the Reminders list', () {
    // With the real notifier and service. It read "Reminder not sent: The
    // reminder was not sent: ...", and a Firestore error as raw text.
    testWidgets('a refused send says why, once', (tester) async {
      await _sendFromList(tester, _reminder(const [ReminderChannel.inApp]));
      expect(
        find.text('In-App reminders are not available yet, so nothing was '
            'sent. Send it by email or SMS instead.'),
        findsOneWidget,
      );
      expect(find.textContaining('Reminder not sent'), findsNothing);
    });

    // A send that went out said nothing at all.
    testWidgets('a send that went out says how', (tester) async {
      await _sendFromList(
        tester,
        _reminder(const [ReminderChannel.email]),
        operations: _EmailingOperations(),
      );
      expect(find.text('Reminder sent (email).'), findsOneWidget);
    });
  });
}
