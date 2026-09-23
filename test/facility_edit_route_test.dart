import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/router/facility_edit_route.dart';

FacilityModel _facility(String id, String name) => FacilityModel(
      id: id,
      name: name,
      ownerUid: 'owner',
      createdAt: DateTime(2026),
    );

/// Stands in for the router: rebuilds the route's widget on demand, the way
/// GoRouter re-runs a route builder when auth, locale or theme settle.
class _Host extends StatefulWidget {
  const _Host({required this.buildRoute});

  final Widget Function() buildRoute;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => widget.buildRoute();
}

FacilityEditRoute _route({
  required Future<FacilityModel?> Function(String id) load,
  String? uid,
}) {
  return FacilityEditRoute(
    key: const ValueKey('facility-edit-f1'),
    facilityId: 'f1',
    notFound: const Text('not found'),
    currentUid: () => uid,
    loadFacility: load,
    buildEditor: (f) => Text('editing ${f.name}'),
  );
}

void main() {
  testWidgets('router rebuilds do not refetch the facility or bring the spinner back',
      (tester) async {
    // The bug: the route builder created FutureBuilder(future: getFacility(id))
    // itself, so every router rebuild started a new read and a new spinner.
    var loads = 0;
    final gate = Completer<FacilityModel?>();
    Future<FacilityModel?> load(String id) {
      loads += 1;
      return gate.future;
    }

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: _Host(buildRoute: () => _route(load: load))),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    final host = tester.state<_HostState>(find.byType(_Host));
    for (var i = 0; i < 3; i++) {
      host.rebuild();
      await tester.pump();
    }
    expect(loads, 1);

    gate.complete(_facility('f1', 'Keepsake'));
    await tester.pump();
    expect(find.text('editing Keepsake'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      host.rebuild();
      await tester.pump();
    }
    expect(loads, 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('editing Keepsake'), findsOneWidget);
  });

  testWidgets('a facility the user cannot read shows not found', (tester) async {
    var loads = 0;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: _route(load: (_) async {
          loads += 1;
          return null;
        }),
      ),
    ));
    await tester.pump();
    expect(find.text('not found'), findsOneWidget);
    expect(loads, 1);
  });

  testWidgets('uses the facility list another screen already loaded, without a read',
      (tester) async {
    var loads = 0;
    final list = [_facility('f0', 'Other'), _facility('f1', 'Keepsake')];

    await tester.pumpWidget(ProviderScope(
      overrides: [
        userFacilitiesProvider.overrideWith((ref, uid) => Stream.value(list)),
      ],
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          // Something else (the sidebar, the facilities screen) holds the list.
          final facilities = ref.watch(userFacilitiesProvider('owner'));
          if (!facilities.hasValue) return const SizedBox();
          return _route(
            uid: 'owner',
            load: (_) async {
              loads += 1;
              return null;
            },
          );
        }),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('editing Keepsake'), findsOneWidget);
    expect(loads, 0);
  });

  testWidgets('does not open the facility list itself when nothing has loaded it',
      (tester) async {
    var streams = 0;
    var loads = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        userFacilitiesProvider.overrideWith((ref, uid) {
          streams += 1;
          return Stream.value([_facility('f1', 'Keepsake')]);
        }),
      ],
      child: MaterialApp(
        home: _route(
          uid: 'owner',
          load: (_) async {
            loads += 1;
            return _facility('f1', 'Keepsake');
          },
        ),
      ),
    ));
    await tester.pump();

    expect(streams, 0);
    expect(loads, 1);
    expect(find.text('editing Keepsake'), findsOneWidget);
  });
}
