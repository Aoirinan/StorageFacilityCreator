import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/load_by_id.dart';

/// Stands in for a lien, payment or contract.
class _Doc {
  const _Doc(this.id, this.facilityId);

  final String id;
  final String facilityId;
}

/// Reads by id, as LienService.getLien and PaymentService.getPayment.
final _loads = <String>[];

Future<_Doc?> _load(String facilityId, String id) async {
  _loads.add('$facilityId/$id');
  if (id == 'boom') throw StateError('read failed');
  return id == 'missing' ? null : _Doc(id, facilityId);
}

/// Times a detail page was built from scratch.
int _pageInits = 0;

class _DetailPage extends StatefulWidget {
  const _DetailPage(this.doc, this.facilityId);

  final _Doc doc;
  final String facilityId;

  @override
  State<_DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<_DetailPage> {
  @override
  void initState() {
    super.initState();
    _pageInits++;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('DOC ${widget.doc.id} IN ${widget.facilityId}'),
        TextButton(
          onPressed: () => context.push('/other'),
          child: const Text('Open other'),
        ),
      ],
    );
  }
}

GoRouter _router(String initialLocation) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(body: child),
        routes: [
          // As app_router.dart's lien-detail route: the lien as `extra` from
          // the lien list, or by id from a calendar event.
          GoRoute(
            path: AppRoute.lienDetail,
            builder: (_, state) {
              final extra = state.extra;
              if (extra is Map<String, dynamic>) {
                final lien = extra['lien'];
                final facilityId = extra['facilityId'];
                if (lien is _Doc && facilityId is String) {
                  return _DetailPage(lien, facilityId);
                }
              }
              return loadByIdPage<_Doc>(
                state,
                idParam: 'lienId',
                load: _load,
                page: (lien, facilityId) => _DetailPage(lien, facilityId),
              );
            },
          ),
          GoRoute(
            path: '/other',
            builder: (_, __) => const Text('OTHER'),
          ),
        ],
      ),
    ],
  );
}

void main() {
  setUp(() {
    _loads.clear();
    _pageInits = 0;
  });

  Future<GoRouter> pumpApp(WidgetTester tester, String location) async {
    final router = _router(location);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return router;
  }

  String lienAt(String lienId, [String facilityId = 'f1']) => Uri(
        path: AppRoute.lienDetail,
        queryParameters: {'lienId': lienId, 'facilityId': facilityId},
      ).toString();

  // The calendar links lien, auction and contract events by id; these
  // routes needed `extra` and showed "Page not found".
  testWidgets('a link by id opens the page', (tester) async {
    await pumpApp(tester, lienAt('l1'));
    expect(find.text('DOC l1 IN f1'), findsOneWidget);
    expect(_loads, ['f1/l1']);
  });

  testWidgets('the page opened with extra is not loaded again',
      (tester) async {
    final router = await pumpApp(tester, '/other');
    router.go(
      AppRoute.lienDetail,
      extra: <String, dynamic>{'lien': const _Doc('l1', 'f1'), 'facilityId': 'f1'},
    );
    await tester.pumpAndSettle();
    expect(find.text('DOC l1 IN f1'), findsOneWidget);
    expect(_loads, isEmpty);
  });

  testWidgets('is loaded and built once while pages come and go over it',
      (tester) async {
    final router = await pumpApp(tester, lienAt('l1'));
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Open other'));
      await tester.pumpAndSettle();
      expect(find.text('OTHER'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('DOC l1 IN f1'), findsOneWidget);
    }
    // go_router re-runs the route builder on every navigation; a load
    // started there ran again each time and rebuilt the page.
    expect(_loads, ['f1/l1']);
    expect(_pageInits, 1);
  });

  testWidgets('loads again when the same page is reused for other ids',
      (tester) async {
    final router = await pumpApp(tester, lienAt('l1'));
    // Only the query string differs, so go_router keeps the same page.
    router.go(lienAt('l2'));
    await tester.pumpAndSettle();
    expect(find.text('DOC l2 IN f1'), findsOneWidget);
    expect(find.text('DOC l1 IN f1'), findsNothing);
    expect(_loads, ['f1/l1', 'f1/l2']);
    expect(_pageInits, 2);
  });

  testWidgets('shows Page not found without the facility', (tester) async {
    await pumpApp(tester, '${AppRoute.lienDetail}?lienId=l1');
    expect(find.text('Page not found'), findsOneWidget);
    expect(_loads, isEmpty);
  });

  testWidgets('shows Page not found when nothing is there', (tester) async {
    await pumpApp(tester, lienAt('missing'));
    expect(find.text('Page not found'), findsOneWidget);
  });

  testWidgets('shows Page not found when the read fails', (tester) async {
    await pumpApp(tester, lienAt('boom'));
    expect(find.text('Page not found'), findsOneWidget);
  });
}
