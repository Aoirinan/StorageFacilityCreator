import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/models/provider_params.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/tenant_navigation_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/theme/app_theme.dart';

// Previous / next tenant on the tenant's page and ledger: chevron buttons
// with a "12 of 77" label, and the Left / Right arrow keys. The order is the
// tenant list's (see tenantListOrderProvider), else the facility's active
// tenants by unit.

const previousTenantTooltip = 'Previous tenant (Left arrow key)';
const nextTenantTooltip = 'Next tenant (Right arrow key)';

/// Which of the tenant's pages previous / next stay on: the ledger's move to
/// the next tenant's ledger, so payments can be posted down the list.
enum TenantPage { detail, ledger }

String tenantPageLocation(TenantModel tenant, TenantPage page) {
  switch (page) {
    case TenantPage.detail:
      return AppRoute.tenantDetailFor(
        tenantId: tenant.id,
        facilityId: tenant.facilityId,
      );
    case TenantPage.ledger:
      return AppRoute.tenantLedgerFor(
        tenantId: tenant.id,
        facilityId: tenant.facilityId,
      );
  }
}

/// Swaps the page on top for [tenant]'s [page]. Replaces rather than pushes,
/// so Back leaves for wherever the owner came from instead of walking back
/// through every tenant visited. The routes key the page by tenant, so the
/// replaced page's state (filters, a DNR result, a running balance) is not
/// carried over to the next tenant.
void openTenantInPlace(
  BuildContext context,
  TenantModel tenant,
  TenantPage page,
) {
  _replaceWithoutHistory(
    GoRouter.of(context),
    tenantPageLocation(tenant, page),
    tenant,
  );
}

/// [GoRouter.replace], and the browser's current history entry replaced
/// too rather than a new one pushed.
///
/// go_router's replace still reports the new page to the browser as a new
/// entry (pushState), so the browser's Back button walked back through
/// every tenant stepped through. [Router.neglect] makes the report a
/// replaceState, but only for the report after the frame it is called in,
/// and the app's route guard is async: the navigation lands frames later
/// and is reported as a push again. So neglect when the router's
/// configuration actually changes, which is this replace landing.
void _replaceWithoutHistory(GoRouter router, String location, Object? extra) {
  final delegate = router.routerDelegate;
  void neglectThisChange() {
    delegate.removeListener(neglectThisChange);
    final routerContext = delegate.navigatorKey.currentContext;
    if (routerContext != null) Router.neglect(routerContext, () {});
  }

  delegate.addListener(neglectThisChange);
  unawaited(router.replace<Object?>(location, extra: extra));
}

/// Whether the keyboard is in a text field, where the arrow keys move the
/// caret. The focus node's context is the `Focus` inside [EditableText], so
/// look up for one rather than at the widget itself.
bool textInputHasFocus() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>() !=
    null;

class PreviousTenantIntent extends Intent {
  const PreviousTenantIntent();
}

class NextTenantIntent extends Intent {
  const NextTenantIntent();
}

class _OpenTenantAction<T extends Intent> extends Action<T> {
  _OpenTenantAction(this.neighbors, this.target, this.open);

  final TenantNeighbors? neighbors;
  final TenantModel? target;
  final void Function(TenantModel tenant) open;

  // Disabled, the key goes on to the rest of the app: to a text field's
  // caret, or anywhere when the tenant has no place in an order. At either
  // end the key is kept and does nothing: passed on, the app's arrow-key
  // focus moves took the focus off to another widget, a text field say, and
  // the arrows then stopped moving between tenants.
  @override
  bool isEnabled(T intent) => neighbors != null && !textInputHasFocus();

  @override
  Object? invoke(T intent) {
    final tenant = target;
    if (tenant != null) open(tenant);
    return null;
  }
}

/// Left / Right arrow for the previous / next tenant on [child], a tenant's
/// page or ledger. Not while a text field has focus, not with a modifier
/// (the browser's Alt+Left / Alt+Right are Back / Forward) and not while a
/// dialog is open over the page.
class TenantPrevNextShortcuts extends ConsumerWidget {
  const TenantPrevNextShortcuts({
    super.key,
    required this.tenant,
    required this.page,
    required this.child,
  });

  final TenantModel tenant;
  final TenantPage page;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final neighbors = ref.watch(tenantNeighborsProvider(FacilityTenantParams(
      facilityId: tenant.facilityId,
      tenantId: tenant.id,
    )));
    void open(TenantModel target) => openTenantInPlace(context, target, page);

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft, includeRepeats: false):
            PreviousTenantIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight, includeRepeats: false):
            NextTenantIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          PreviousTenantIntent: _OpenTenantAction<PreviousTenantIntent>(
              neighbors, neighbors?.previous, open),
          NextTenantIntent: _OpenTenantAction<NextTenantIntent>(
              neighbors, neighbors?.next, open),
        },
        // Keys go to the focused widget and up through its ancestors, so the
        // page needs focus for these to hear them. Its own scope, so that a
        // text field that lets go of focus leaves it here rather than on the
        // route above these shortcuts. The app shell's KeyboardScrollable
        // only takes focus back when it is outside the page.
        child: FocusScope(autofocus: true, child: child),
      ),
    );
  }
}

/// The previous / next buttons and "12 of 77". Nothing when the tenant has
/// no place in an order (see [tenantNeighbors]).
class TenantPrevNextControls extends ConsumerWidget {
  const TenantPrevNextControls({
    super.key,
    required this.tenant,
    required this.page,
  });

  final TenantModel tenant;
  final TenantPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final neighbors = ref.watch(tenantNeighborsProvider(FacilityTenantParams(
      facilityId: tenant.facilityId,
      tenantId: tenant.id,
    )));
    if (neighbors == null) return const SizedBox.shrink();
    final previous = neighbors.previous;
    final next = neighbors.next;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: previousTenantTooltip,
          onPressed: previous == null
              ? null
              : () => openTenantInPlace(context, previous, page),
        ),
        Text(
          neighbors.positionLabel,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: nextTenantTooltip,
          onPressed:
              next == null ? null : () => openTenantInPlace(context, next, page),
        ),
      ],
    );
  }
}

/// On leaving the ledger, puts [tenant]'s page underneath if another
/// tenant's is there.
///
/// The ledger opens over the tenant's page, and previous / next replace only
/// the ledger, so after moving along the list the page underneath is still
/// the first tenant's. Leaving (the ledger's back arrow, the top bar's or the
/// browser's) showed that tenant, not the one just worked on.
class TenantPageFollowsLedger extends StatelessWidget {
  const TenantPageFollowsLedger({
    super.key,
    required this.tenant,
    required this.child,
  });

  final TenantModel tenant;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop || router == null) return;
        // After the pop is done with the navigator.
        scheduleMicrotask(() => showTenantPageUnderLedger(router, tenant));
      },
      child: child,
    );
  }
}

/// With the ledger gone: when another tenant's page is on top, replaces it
/// with [tenant]'s.
void showTenantPageUnderLedger(GoRouter router, TenantModel tenant) {
  final state = router.state;
  if (state.uri.path != AppRoute.tenantDetail) return;
  final extra = state.extra;
  final shownId =
      extra is TenantModel ? extra.id : state.uri.queryParameters['tenantId'];
  if (shownId == tenant.id) return;
  _replaceWithoutHistory(
    router,
    tenantPageLocation(tenant, TenantPage.detail),
    tenant,
  );
}
