import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/reminder_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/reminder_detail_screen.dart';

ReminderModel _reminderOn(List<ReminderChannel> channels) => ReminderModel(
  id: 'r1',
  tenantId: 't1',
  facilityId: 'f1',
  tenantEmail: 'pat@example.com',
  type: ReminderType.rentOverdue,
  status: ReminderStatus.pending,
  channels: channels,
  title: 'Rent overdue',
  message: 'Your rent is overdue.',
  scheduledFor: DateTime(2026, 9, 1),
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 1),
  // Empty, so the page does not look up who made it.
  createdBy: '',
);

final _reminder = _reminderOn(const [ReminderChannel.email]);

Future<PermissionCheck> _allowed({
  required PermissionType permission,
  String? facilityId,
}) async =>
    const PermissionCheck(hasPermission: true);

// The page runs the app's real ReminderOperationsNotifier and
// ReminderService. With no Firebase app in tests the send reaches no channel
// and the other actions' writes fail, as they do offline or when refused.
void main() {
  Future<void> pumpDetail(
    WidgetTester tester, {
    ReminderModel? reminder,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: AppRoute.reminders,
      routes: [
        GoRoute(
          path: AppRoute.reminders,
          builder: (_, __) => const Text('REMINDERS'),
        ),
        GoRoute(
          path: AppRoute.reminderDetail,
          builder: (_, __) => ReminderDetailScreen(
            reminder: reminder ?? _reminder,
            checkPermission: _allowed,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => Scaffold(body: child),
        ),
      ),
    );
    unawaited(router.push(AppRoute.reminderDetail));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(
    WidgetTester tester,
    String menuItem,
    String button,
  ) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(menuItem));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, button));
    // Real services: let their failures come back.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  // It said "Reminder sent successfully" and left, so the operator took an
  // overdue notice as sent when nothing had gone to the tenant.
  testWidgets('a send that reached no one is not reported as sent',
      (tester) async {
    await pumpDetail(tester);
    await confirm(tester, 'Send now', 'Send');

    expect(find.text('Reminder sent successfully'), findsNothing);
    expect(find.textContaining('The reminder was not sent'), findsOneWidget);
    // Still on the reminder, so it can be sent again.
    expect(find.text('REMINDERS'), findsNothing);
    expect(find.text('Rent overdue'), findsOneWidget);
  });

  // In-app was a mock that counted as delivered: "Reminder sent
  // successfully", and the reminder was marked sent via in-app.
  testWidgets('an in-app reminder is not sent, and it says why',
      (tester) async {
    await pumpDetail(
      tester,
      reminder: _reminderOn(const [ReminderChannel.inApp]),
    );
    await confirm(tester, 'Send now', 'Send');

    expect(find.textContaining('Reminder sent'), findsNothing);
    expect(
      find.text('In-App reminders are not available yet, so nothing was '
          'sent. Send it by email or SMS instead.'),
      findsOneWidget,
    );
    expect(find.text('REMINDERS'), findsNothing);
  });

  testWidgets('a failed Cancel is not reported as cancelled', (tester) async {
    await pumpDetail(tester);
    await confirm(tester, 'Cancel reminder', 'Yes');

    expect(find.text('Reminder cancelled'), findsNothing);
    expect(find.textContaining('Something went wrong'), findsOneWidget);
    expect(find.text('REMINDERS'), findsNothing);
  });

  testWidgets('a failed Delete is not reported as deleted', (tester) async {
    await pumpDetail(tester);
    await confirm(tester, 'Delete', 'Delete');

    expect(find.text('Reminder deleted'), findsNothing);
    expect(find.textContaining('Something went wrong'), findsOneWidget);
    expect(find.text('REMINDERS'), findsNothing);
  });
}
