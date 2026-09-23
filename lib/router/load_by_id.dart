import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/router/route_helpers.dart';

/// Loads one document of a facility by id, e.g. `TenantService.getTenantById`.
typedef LoadInFacility<T> = Future<T?> Function(String facilityId, String id);

/// A detail page opened by id rather than with its model as `extra`: a
/// reload, a link, a calendar event, the Dashboard.
///
/// Reads `facilityId` and [idParam] from the query string ([id] overrides the
/// latter, for ids in the path), loads the model with [load] and shows
/// [page]. Shows "Page not found" when an id is missing or the load finds
/// nothing, and [LoadByIdError] with Retry when the load fails.
Widget loadByIdPage<T extends Object>(
  GoRouterState state, {
  required String idParam,
  String? id,
  required LoadInFacility<T> load,
  required Widget Function(T model, String facilityId) page,
}) {
  final facilityId = state.uri.queryParameters['facilityId'] ?? '';
  final modelId = id ?? state.uri.queryParameters[idParam] ?? '';
  if (facilityId.isEmpty || modelId.isEmpty) {
    return NotFoundPage(state: state);
  }
  return LoadById<T>(
    ids: [facilityId, modelId],
    load: () => load(facilityId, modelId),
    builder: (context, model) => page(model, facilityId),
    notFound: (context) => NotFoundPage(state: state),
  );
}

/// Shows [builder]'s page once [load] has found its model.
///
/// Loads once, and again only when [ids] change. The route builders used to
/// start the load inline, `FutureBuilder(future: load())`. go_router re-runs
/// page builders on every navigation, so each push over the page and each
/// pop back to it started a new load, swapped the page for a spinner and
/// built it again from scratch: the tenant page re-ran its DNR check (the
/// alert again and, on Override, another audit record) on every ledger round
/// trip.
class LoadById<T extends Object> extends StatefulWidget {
  const LoadById({
    super.key,
    required this.ids,
    required this.load,
    required this.builder,
    required this.notFound,
  });

  /// What [load] fetches. A page reused for other ids (go_router keeps the
  /// page when only the query string changes) loads again.
  final List<String> ids;
  final Future<T?> Function() load;
  final Widget Function(BuildContext context, T model) builder;

  /// Shown when the load finds nothing. A failed load shows [LoadByIdError].
  final WidgetBuilder notFound;

  @override
  State<LoadById<T>> createState() => _LoadByIdState<T>();
}

class _LoadByIdState<T extends Object> extends State<LoadById<T>> {
  late Future<T?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  @override
  void didUpdateWidget(LoadById<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.ids, widget.ids)) {
      _future = widget.load();
    }
  }

  void _retry() {
    setState(() {
      _future = widget.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T?>(
      future: _future,
      builder: (context, snapshot) {
        // Not just `waiting`: after the ids change the snapshot still holds
        // the previous model until the new load is done.
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        // A failed read (offline, a permission blip) is not a missing page:
        // "Page not found" told the owner a real payment or tenant was gone,
        // with no way to try again but reloading the app.
        if (snapshot.hasError) {
          debugPrint('LoadById(${widget.ids.join('/')}): ${snapshot.error}');
          return LoadByIdError(onRetry: _retry);
        }
        final model = snapshot.data;
        if (model == null) return widget.notFound(context);
        return widget.builder(context, model);
      },
    );
  }
}

/// Shown when a page opened by id could not be loaded.
class LoadByIdError extends StatelessWidget {
  const LoadByIdError({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 72, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                "Couldn't load this page",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Check your connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
