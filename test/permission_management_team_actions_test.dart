import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/screens/permission_management_screen.dart';

void main() {
  const owner = TeamPowers(isOwner: true);
  const coOwner = TeamPowers(isCoOwner: true);
  const manager = TeamPowers(isManager: true);
  const employee = TeamPowers();

  group('TeamPowers.of', () {
    TeamPowers of({String? uid = 'me', bool superAdmin = false, String? ownerUid = 'boss', RoleType? role}) =>
        TeamPowers.of(userId: uid, isSuperAdmin: superAdmin, facilityOwnerUid: ownerUid, role: role);

    test("the facility's owner, and support (a super admin), are its owner here", () {
      expect(of(uid: 'boss', role: RoleType.owner).isOwner, isTrue);
      expect(of(superAdmin: true, role: RoleType.manager).isOwner, isTrue);
      expect(of(superAdmin: true, role: RoleType.manager).isManager, isFalse);
    });

    test('a co-owner, a manager and everyone else', () {
      expect(of(role: RoleType.owner).isCoOwner, isTrue);
      expect(of(role: RoleType.owner).isOwner, isFalse);
      expect(of(role: RoleType.manager).isManager, isTrue);
      for (final role in [RoleType.employee, RoleType.viewer, null]) {
        final powers = of(role: role);
        expect([powers.isOwner, powers.isCoOwner, powers.isManager], [false, false, false],
            reason: '$role');
      }
      expect(of(uid: null, ownerUid: null).isOwner, isFalse);
      expect(of(uid: '', ownerUid: '').isOwner, isFalse);
    });

    test('what each may do, as the rules allow it', () {
      expect([owner.canChangeRoles, owner.canInvite, owner.canCancelInvites], [true, true, true]);
      expect([coOwner.canChangeRoles, coOwner.canInvite, coOwner.canCancelInvites], [false, true, true]);
      expect([manager.canChangeRoles, manager.canInvite, manager.canCancelInvites], [false, false, true]);
      expect([employee.canChangeRoles, employee.canInvite, employee.canCancelInvites, employee.canRemoveAnyone],
          [false, false, false, false]);

      bool removes(TeamPowers p, RoleType member, {bool facilityOwner = false, bool you = false}) =>
          p.canRemove(memberRole: member, memberIsFacilityOwner: facilityOwner, memberIsYou: you);
      expect(removes(owner, RoleType.owner), isTrue, reason: 'the owner removes a co-owner');
      expect(removes(owner, RoleType.owner, facilityOwner: true, you: true), isFalse);
      expect(removes(manager, RoleType.employee), isTrue);
      expect(removes(manager, RoleType.manager), isTrue);
      expect(removes(manager, RoleType.owner), isFalse, reason: 'a co-owner is the owner\'s to remove');
      expect(removes(coOwner, RoleType.owner), isFalse);
      expect(removes(manager, RoleType.employee, you: true), isFalse);
      expect(removes(employee, RoleType.viewer), isFalse);
    });
  });

  group("a team member's row", () {
    /// Opens the row's menu for someone with [powers] and returns what it
    /// offers, or null when there is no menu at all.
    Future<List<String>?> menuFor(
      WidgetTester tester,
      TeamPowers powers, {
      RoleType member = RoleType.employee,
      bool memberIsFacilityOwner = false,
      bool memberIsYou = false,
    }) async {
      final entries = PermissionManagementScreen.memberMenuEntries(
        powers: powers,
        memberRole: member,
        memberIsFacilityOwner: memberIsFacilityOwner,
        memberIsYou: memberIsYou,
      );
      if (entries.isEmpty) return null;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: PopupMenuButton<String>(
              key: const Key('menu'),
              itemBuilder: (_) => entries,
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('menu')));
      await tester.pumpAndSettle();
      final offered = [
        for (final label in ['Change Role', 'Remove Access'])
          if (find.text(label).evaluate().isNotEmpty) label,
      ];
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      return offered;
    }

    bool enabled(WidgetTester tester, String value) => tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .singleWhere((item) => item.value == value)
        .enabled;

    testWidgets('a manager is offered Remove Access, never Change Role', (tester) async {
      // The rules refuse a manager's role change; the menu offered it and it
      // failed with "Failed to change role".
      expect(await menuFor(tester, manager), ['Remove Access']);
      expect(await menuFor(tester, manager, member: RoleType.manager), ['Remove Access']);
    });

    testWidgets('a co-owner is offered Remove Access, not Change Role', (tester) async {
      expect(await menuFor(tester, coOwner), ['Remove Access']);
    });

    testWidgets('the owner is offered both', (tester) async {
      expect(await menuFor(tester, owner), ['Change Role', 'Remove Access']);
    });

    testWidgets('an employee or viewer gets no menu at all', (tester) async {
      expect(await menuFor(tester, employee), isNull);
    });

    testWidgets('what they may not do to this member is greyed out, with the reason', (tester) async {
      Future<void> open(TeamPowers powers, RoleType member, {bool facilityOwner = false}) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Center(
              child: PopupMenuButton<String>(
                key: const Key('menu'),
                itemBuilder: (_) => PermissionManagementScreen.memberMenuEntries(
                  powers: powers,
                  memberRole: member,
                  memberIsFacilityOwner: facilityOwner,
                  memberIsYou: false,
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.byKey(const Key('menu')));
        await tester.pumpAndSettle();
      }

      await open(manager, RoleType.owner);
      expect(enabled(tester, 'remove'), isFalse);
      expect(find.text('Only the facility owner can remove an owner'), findsOneWidget);

      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await open(owner, RoleType.owner, facilityOwner: true);
      expect(enabled(tester, 'change_role'), isFalse);
      expect(enabled(tester, 'remove'), isFalse);
      expect(find.text('Owner cannot be removed'), findsOneWidget);

      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await open(owner, RoleType.owner);
      expect(enabled(tester, 'change_role'), isTrue);
      expect(enabled(tester, 'remove'), isTrue);
    });
  });

  group('a pending invitation', () {
    Future<List<String>> buttonsFor(WidgetTester tester, TeamPowers powers) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Wrap(
            children: PermissionManagementScreen.pendingInviteActions(
              powers: powers,
              onResend: () {},
              onCancel: () {},
            ),
          ),
        ),
      ));
      return [
        for (final label in ['Resend', 'Cancel'])
          if (find.text(label).evaluate().isNotEmpty) label,
      ];
    }

    testWidgets('the owner and a co-owner resend and cancel it', (tester) async {
      expect(await buttonsFor(tester, owner), ['Resend', 'Cancel']);
      expect(await buttonsFor(tester, coOwner), ['Resend', 'Cancel']);
    });

    testWidgets('a manager may only cancel it', (tester) async {
      // Resending is the owner's: the rules refuse a manager's.
      expect(await buttonsFor(tester, manager), ['Cancel']);
    });

    testWidgets('anyone else sees no buttons', (tester) async {
      expect(await buttonsFor(tester, employee), isEmpty);
    });
  });
}
