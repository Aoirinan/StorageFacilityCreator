import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/screens/permission_management_screen.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

void main() {
  /// What the team screen's invite dialog shows for [result].
  Future<SnackBar> shown(WidgetTester tester, InviteResult result) async {
    final bar =
        PermissionManagementScreen.inviteOutcomeSnackBar(result: result, email: 'new@example.com');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(bar),
            child: const Text('invite'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('invite'));
    await tester.pump();
    return bar;
  }

  testWidgets('a refused invite says it was not sent, and offers no resend', (tester) async {
    // A refusal (already on the team, not allowed to invite) read "Invite
    // created but email failed to send ... resend it from the pending
    // invites section", for an invite that did not exist.
    final bar = await shown(
      tester,
      InviteResult(success: false, errorMessage: 'new@example.com already has access.'),
    );
    expect(find.text('Invitation not sent. new@example.com already has access.'), findsOneWidget);
    expect(find.textContaining('resend'), findsNothing);
    expect(find.textContaining('Invite created'), findsNothing);
    expect(bar.backgroundColor, AppTheme.error);
  });

  testWidgets('a saved invite whose email failed says so, and points at the resend', (tester) async {
    final bar = await shown(
      tester,
      InviteResult(success: false, errorMessage: 'SMTP down', inviteSaved: true),
    );
    expect(find.text('Invite created but email failed to send.'), findsOneWidget);
    expect(find.text('Error: SMTP down'), findsOneWidget);
    expect(find.text('You can resend it from the pending invites section.'), findsOneWidget);
    expect(bar.backgroundColor, AppTheme.warning);
  });

  testWidgets('a sent invite says so', (tester) async {
    final bar = await shown(tester, InviteResult(success: true, inviteSaved: true));
    expect(
      find.text('Invitation sent to new@example.com. They will receive an email with '
          'instructions to join.'),
      findsOneWidget,
    );
    expect(bar.backgroundColor, AppTheme.success);
  });
}
