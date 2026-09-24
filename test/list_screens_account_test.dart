import 'dart:io';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/screens/insurance_screen.dart';
import 'package:sfcapp/screens/rent_payments/past_due_hub_tab.dart';
import 'package:sfcapp/widgets/facilities_load_error.dart';

/// The ten money-adjacent list screens that made sure the user had an
/// account before loading their facilities, and returned early (a blank
/// screen) when that account read failed.
const _listScreens = [
  'lib/screens/deposit_list_screen.dart',
  'lib/screens/invoice_list_screen.dart',
  'lib/screens/payment_list_screen.dart',
  'lib/screens/lien_list_screen.dart',
  'lib/screens/recurring_charges_screen.dart',
  'lib/screens/financial_reports_screen.dart',
  'lib/screens/inventory_list_screen.dart',
  'lib/screens/reports_consolidated_screen.dart',
  'lib/screens/insurance_screen.dart',
  'lib/screens/rent_payments/past_due_hub_tab.dart',
];

/// What the app shell's facility switcher keeps listening to on every page:
/// the signed-in user and their facility list. Riverpod pauses a provider
/// nobody listens to, so without it a screen's one-off reads never finish.
class _ShellListeners extends ConsumerWidget {
  const _ShellListeners();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(authStateProvider).value?.uid;
    if (uid != null) ref.watch(userFacilitiesProvider(uid));
    return const SizedBox.shrink();
  }
}

Widget _host(List overrides, Widget child) => ProviderScope(
      overrides: [
        authStateProvider.overrideWith(
          (ref) => Stream.value(MockUser(uid: 'owner-1', isEmailVerified: true)),
        ),
        activeFacilityIdProvider.overrideWith(
          (ref) => ActiveFacilityNotifier(load: () async => null, save: (_) async {}),
        ),
        ...overrides.cast(),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [const _ShellListeners(), Expanded(child: child)]),
        ),
      ),
    );

void main() {
  test('no list screen waits on the account before loading its facilities', () {
    // Each awaited the account and returned before loading anything if it
    // threw. The account is only needed by creation flows; the shared helper
    // starts it without holding up or failing the screen.
    for (final path in _listScreens) {
      final source = File(path).readAsStringSync();
      expect(source, contains('FacilityCreatorAccountService.ensureAccountInBackground()'),
          reason: path);
      expect(source, isNot(contains('ensureAccountForCurrentUser')), reason: path);
      expect(source, isNot(contains('getOrCreateAccountForCurrentUser')), reason: path);
    }
  });

  group('screens that showed "no facilities" when the facilities failed to load', () {
    late bool failing;
    late int loads;

    Stream<List<FacilityModel>> facilities(Ref ref, String uid) {
      loads += 1;
      return failing
          ? Stream.error(StateError('facilities unavailable'))
          : Stream.value(const <FacilityModel>[]);
    }

    setUp(() {
      failing = true;
      loads = 0;
    });

    testWidgets('the past-due tab shows the error with a Retry', (tester) async {
      await tester.pumpWidget(_host([
        userFacilitiesProvider.overrideWith(facilities),
      ], const PastDueHubTab()));
      await tester.pumpAndSettle();

      // Before: the error was swallowed and the tab offered to create a
      // first facility.
      expect(find.byType(FacilitiesLoadError), findsOneWidget);
      expect(find.text('No Facilities Found'), findsNothing);

      failing = false;
      final before = loads;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(loads, greaterThan(before));
      expect(find.byType(FacilitiesLoadError), findsNothing);
      expect(find.text('No Facilities Found'), findsOneWidget);
    });

    testWidgets('the insurance screen shows the error with a Retry', (tester) async {
      await tester.pumpWidget(_host([
        userFacilitiesProvider.overrideWith(facilities),
      ], const InsuranceScreen()));
      await tester.pumpAndSettle();

      expect(find.byType(FacilitiesLoadError), findsOneWidget);
      expect(find.text('No Facilities Found'), findsNothing);

      failing = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(FacilitiesLoadError), findsNothing);
      expect(find.text('No Facilities Found'), findsOneWidget);
    });
  });
}
