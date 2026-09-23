import 'dart:async';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/dashboard_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/onboarding_progress_provider.dart';
import 'package:sfcapp/screens/settings_screen.dart';

void main() {
  testWidgets('the onboarding checklist does not run the dashboard load', (tester) async {
    var dashboardLoads = 0;
    final facility = FacilityModel(
      id: 'fac1',
      name: 'Fac',
      ownerUid: 'owner-1',
      createdAt: DateTime(2026, 1, 1),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authStateProvider.overrideWith(
            (ref) => Stream.value(MockUser(uid: 'owner-1', isEmailVerified: true)),
          ),
          userFacilitiesProvider('owner-1')
              .overrideWith((ref) => Stream.value([facility])),
          onboardingProgressProvider('owner-1').overrideWith(
            (ref) async => (hasUnits: true, hasTenants: false),
          ),
          dashboardStatsProvider.overrideWith((ref) {
            dashboardLoads++;
            return Completer<DashboardStats>().future;
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsOnboardingTab())),
      ),
    );
    await tester.pumpAndSettle();

    // Before: the tab watched dashboardStatsProvider, which is autoDispose,
    // so every visit ran every tenant, unit, lead, overdue and ledger read
    // for each facility to answer two yes-or-no questions.
    expect(dashboardLoads, 0);
    // Facility created and units added are ticked; a tenant is not.
    expect(find.byIcon(Icons.check), findsNWidgets(2));
  });

  group('onboardingProgress', () {
    test('any facility with a unit or an active tenant counts', () async {
      final progress = await onboardingProgress(
        ['a', 'b'],
        hasUnit: (id) async => id == 'b',
        hasActiveTenant: (id) async => false,
      );
      expect(progress, (hasUnits: true, hasTenants: false));
    });

    test('no facilities means nothing is done', () async {
      final progress = await onboardingProgress(
        const [],
        hasUnit: (_) async => true,
        hasActiveTenant: (_) async => true,
      );
      expect(progress, (hasUnits: false, hasTenants: false));
    });
  });
}
