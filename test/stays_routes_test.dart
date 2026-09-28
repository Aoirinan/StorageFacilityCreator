import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/feature_flag_model.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_task.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/providers/feature_flag_provider.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/route_helpers.dart';
import 'package:sfcapp/router/stays_routes.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';
import 'package:sfcapp/widgets/stays/stays_module_gate.dart';

import 'support/fake_stays_callables.dart';
import 'support/fake_stays_repository.dart';

const _fid = 'f1';

enum _Flag { loading, off, on, error }

class _Harness {
  _Harness({
    this.flag = _Flag.on,
    this.moduleEnabled = true,
    Set<PermissionType>? permissions,
    this.controlsError = false,
  }) : permissions = permissions ?? PermissionType.values.toSet();

  final _Flag flag;
  final bool moduleEnabled;
  final Set<PermissionType> permissions;
  final bool controlsError;
  final repository = FakeStaysRepository();
  final callables = FakeStaysCallables();
  final loads = <String>[];

  Future<Stay?> loadStay(String facilityId, String stayId) async {
    loads.add('stay:$facilityId/$stayId');
    return stayId == 'missing' ? null : Stay(id: stayId, facilityId: facilityId, listingId: 'l1', checkIn: '2026-10-03', checkOut: '2026-10-05');
  }

  Future<StayTask?> loadTask(String facilityId, String taskId) async {
    loads.add('task:$facilityId/$taskId');
    return StayTask.fromMap(taskId, {'facilityId': facilityId, 'category': 'turnover', 'status': 'todo'});
  }

  Stream<List<FeatureFlagModel>> _flags() {
    FeatureFlagModel model(bool enabled) => FeatureFlagModel(
          key: staysFeatureFlagKey,
          label: 'Stays',
          description: '',
          enabled: enabled,
          riskLevel: FlagRiskLevel.high,
        );
    return switch (flag) {
      _Flag.loading => StreamController<List<FeatureFlagModel>>().stream,
      _Flag.off => Stream.value([model(false)]),
      _Flag.on => Stream.value([model(true)]),
      _Flag.error => Stream.error(StateError('flags unavailable')),
    };
  }

  Future<GoRouter> pump(WidgetTester tester, String location) async {
    if (moduleEnabled) {
      repository.seed(_fid, StaysCollections.controls, StaysCollections.currentDocId, {'moduleEnabled': true});
    }
    final router = GoRouter(
      initialLocation: location,
      errorBuilder: (context, state) => NotFoundPage(state: state),
      routes: [
        ShellRoute(
          builder: (context, state, child) => Scaffold(body: child),
          routes: [
            ...staysShellRoutes(loadStay: loadStay, loadTask: loadTask),
            GoRoute(path: '/dashboard', builder: (_, __) => const Text('DASHBOARD')),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      // A fresh scope per page, as on a reload.
      key: UniqueKey(),
      retry: (_, __) => null,
      overrides: [
        featureFlagsProvider.overrideWith((ref) => _flags()),
        staysRepositoryProvider.overrideWithValue(repository),
        staysCallablesProvider.overrideWithValue(callables),
        stayPermissionResolverProvider.overrideWithValue((facilityId, p) async => facilityId == _fid && permissions.contains(p)),
        if (controlsError) stayControlsProvider.overrideWith((ref, facilityId) => Stream.error(StateError('denied'))),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await _settle(tester);
    return router;
  }
}

/// Spinners never settle, so pump a fixed number of frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

final _notFound = find.text('Page not found');
final _spinner = find.byType(CircularProgressIndicator);

void main() {
  group('route builders', () {
    test('build the documented URLs and drop empty parameters', () {
      expect(AppRoute.staysWithTab(facilityId: 'f1'), '/stays?facilityId=f1&tab=today');
      expect(AppRoute.staysWithTab(facilityId: 'f1', tab: 'calendar'), '/stays?facilityId=f1&tab=calendar');
      expect(AppRoute.stayDetailFor(facilityId: 'f1', stayId: 'airbnb_HM1'), '/stays/booking?facilityId=f1&stayId=airbnb_HM1');
      expect(
        AppRoute.stayCreateFor(facilityId: 'f1', listingId: 'l1', checkIn: '2026-10-03', checkOut: '2026-10-05', kind: 'owner_block'),
        '/stays/booking/new?facilityId=f1&listingId=l1&checkIn=2026-10-03&checkOut=2026-10-05&kind=owner_block',
      );
      expect(AppRoute.stayCreateFor(facilityId: 'f1'), '/stays/booking/new?facilityId=f1');
      expect(AppRoute.stayEditFor(facilityId: 'f1', stayId: 's1'), '/stays/booking/edit?facilityId=f1&stayId=s1');
      expect(AppRoute.turnoverDetailFor(facilityId: 'f1', taskId: 't1'), '/stays/turnover?facilityId=f1&taskId=t1');
      expect(AppRoute.stayListingEditFor(facilityId: 'f1'), '/stays/listing/edit?facilityId=f1');
      expect(AppRoute.stayListingEditFor(facilityId: 'f1', listingId: ''), '/stays/listing/edit?facilityId=f1');
      expect(AppRoute.staysSetupFor('f1'), '/stays/setup?facilityId=f1');
      expect(AppRoute.staysChannelsFor(facilityId: 'f1', listingId: 'l1'), '/stays/channels?facilityId=f1&listingId=l1');
      expect(AppRoute.staysEarningsImportFor('f1'), '/stays/earnings/import?facilityId=f1');
      expect(AppRoute.staysGuestsFor('f1'), '/stays/guests?facilityId=f1');
      expect(AppRoute.staysTemplatesFor('f1'), '/stays/templates?facilityId=f1');
      expect(AppRoute.staysSettingsFor('f1'), '/settings/stays?facilityId=f1');
    });

    test('ids are encoded', () {
      expect(AppRoute.stayDetailFor(facilityId: 'f 1', stayId: 'a&b'), '/stays/booking?facilityId=f+1&stayId=a%26b');
    });
  });

  group('every Stays page needs a facilityId', () {
    for (final path in [
      AppRoute.stays,
      AppRoute.stayCreate,
      AppRoute.stayEdit,
      AppRoute.stayDetail,
      AppRoute.turnoverDetail,
      AppRoute.stayListingEdit,
      AppRoute.staysSetup,
      AppRoute.staysChannels,
      AppRoute.staysEarningsImport,
      AppRoute.staysGuests,
      AppRoute.staysTemplates,
      AppRoute.staysSettings,
    ]) {
      testWidgets('$path without one is Page not found', (tester) async {
        final h = _Harness();
        await h.pump(tester, path);
        expect(_notFound, findsOneWidget);
        expect(h.loads, isEmpty);
      });
    }
  });

  group('the shortTermRentals flag', () {
    testWidgets('off: every Stays URL is Page not found and nothing is loaded', (tester) async {
      final h = _Harness(flag: _Flag.off);
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(_notFound, findsOneWidget);
      expect(find.text('Stays Hub'), findsNothing);

      await h.pump(tester, AppRoute.stayDetailFor(facilityId: _fid, stayId: 's1'));
      expect(_notFound, findsOneWidget);
      expect(h.loads, isEmpty);
      expect(h.callables.calls, isEmpty);
    });

    testWidgets('failing to load: treated as off, never as on', (tester) async {
      final h = _Harness(flag: _Flag.error);
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(_notFound, findsOneWidget);
      expect(find.text('Stays Hub'), findsNothing);
    });

    testWidgets('still loading: a spinner, and no Stays content', (tester) async {
      final h = _Harness(flag: _Flag.loading);
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(_spinner, findsOneWidget);
      expect(find.text('Stays Hub'), findsNothing);
      expect(_notFound, findsNothing);
    });

    testWidgets('on, with the module on: the page', (tester) async {
      final h = _Harness();
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(find.text('Stays Hub'), findsOneWidget);
    });
  });

  group('permissions', () {
    testWidgets('without the page permission at this facility: no access', (tester) async {
      final h = _Harness(permissions: {PermissionType.viewStays});
      await h.pump(tester, AppRoute.staysSettingsFor(_fid));
      expect(find.text("You don't have access to this"), findsOneWidget);
      expect(find.text('Stays Settings'), findsNothing);
    });

    testWidgets('an employee reaches the hub and turnovers, not money or channels', (tester) async {
      final employee = {PermissionType.viewStays, PermissionType.workStayTasks};
      final h = _Harness(permissions: employee);
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(find.text('Stays Hub'), findsOneWidget);

      await h.pump(tester, AppRoute.turnoverDetailFor(facilityId: _fid, taskId: 't1'));
      expect(find.text('Turnover Detail'), findsOneWidget);

      for (final location in [
        AppRoute.staysEarningsImportFor(_fid),
        AppRoute.staysChannelsFor(facilityId: _fid),
        AppRoute.staysGuestsFor(_fid),
      ]) {
        await h.pump(tester, location);
        expect(find.text("You don't have access to this"), findsOneWidget, reason: location);
      }
    });

    testWidgets('another facility is checked as itself', (tester) async {
      final h = _Harness();
      await h.pump(tester, AppRoute.staysWithTab(facilityId: 'someone-elses'));
      expect(find.text("You don't have access to this"), findsOneWidget);
    });
  });

  group('StaysModuleGate', () {
    testWidgets('module off: the disabled page, with setup for an owner when available', (tester) async {
      final h = _Harness(moduleEnabled: false);
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(find.text('Stays Hub'), findsNothing);
      expect(find.text('Stays is not turned on'), findsOneWidget);
      expect(find.text('Set up Stays'), findsOneWidget);
      expect(h.callables.countOf(StaysCallableNames.getAvailability), 1);
    });

    testWidgets('module off and not available to the facility: no setup button', (tester) async {
      final h = _Harness(moduleEnabled: false);
      h.callables.availability = StaysAvailability.unavailable;
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(find.text('Stays is not turned on'), findsOneWidget);
      expect(find.text('Set up Stays'), findsNothing);
    });

    testWidgets('module off, for someone who cannot set it up: no setup button', (tester) async {
      final h = _Harness(moduleEnabled: false, permissions: {PermissionType.viewStays});
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(find.text('Stays is not turned on'), findsOneWidget);
      expect(find.text('Set up Stays'), findsNothing);
    });

    testWidgets('paused by the kill switch', (tester) async {
      final h = _Harness(moduleEnabled: false);
      h.callables.availability = const StaysAvailability(allowed: false, paused: true);
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(find.text('Stays is paused'), findsOneWidget);
    });

    testWidgets('setup and settings open while the module is off', (tester) async {
      final h = _Harness(moduleEnabled: false);
      await h.pump(tester, AppRoute.staysSetupFor(_fid));
      expect(find.text('Stays Setup Wizard'), findsOneWidget);
      await h.pump(tester, AppRoute.staysSettingsFor(_fid));
      expect(find.text('Stays Settings'), findsOneWidget);
    });

    testWidgets('controls that fail to load: an error with Retry, never the page', (tester) async {
      final h = _Harness(controlsError: true);
      await h.pump(tester, AppRoute.staysWithTab(facilityId: _fid));
      expect(find.text("Couldn't load Stays"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Stays Hub'), findsNothing);
    });

    testWidgets('hides its child while loading', (tester) async {
      await tester.pumpWidget(ProviderScope(
        retry: (_, __) => null,
        overrides: [
          featureFlagsProvider.overrideWith((ref) => Stream.value([
                const FeatureFlagModel(
                  key: staysFeatureFlagKey,
                  label: 'Stays',
                  description: '',
                  enabled: true,
                  riskLevel: FlagRiskLevel.high,
                ),
              ])),
          stayControlsProvider.overrideWith((ref, facilityId) => StreamController<Never>().stream),
        ],
        child: const MaterialApp(home: Scaffold(body: StaysModuleGate(facilityId: _fid, child: Text('SECRET')))),
      ));
      await _settle(tester);
      expect(_spinner, findsOneWidget);
      expect(find.text('SECRET'), findsNothing);
    });
  });

  group('pages opened by id', () {
    testWidgets('load the stay or task of this facility', (tester) async {
      final h = _Harness();
      await h.pump(tester, AppRoute.stayDetailFor(facilityId: _fid, stayId: 'airbnb_HM1'));
      expect(find.text('Stay Detail'), findsOneWidget);
      await h.pump(tester, AppRoute.stayEditFor(facilityId: _fid, stayId: 'man_1'));
      expect(find.text('Stay Edit'), findsOneWidget);
      await h.pump(tester, AppRoute.turnoverDetailFor(facilityId: _fid, taskId: 'turnover_man_1'));
      expect(find.text('Turnover Detail'), findsOneWidget);
      expect(h.loads, ['stay:f1/airbnb_HM1', 'stay:f1/man_1', 'task:f1/turnover_man_1']);
    });

    testWidgets('a stay that does not exist is Page not found', (tester) async {
      final h = _Harness();
      await h.pump(tester, AppRoute.stayDetailFor(facilityId: _fid, stayId: 'missing'));
      expect(_notFound, findsOneWidget);
    });
  });
}
