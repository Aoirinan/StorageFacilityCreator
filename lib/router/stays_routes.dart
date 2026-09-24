import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_task.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/load_by_id.dart';
import 'package:sfcapp/router/route_helpers.dart';
import 'package:sfcapp/screens/stays/stay_detail_screen.dart';
import 'package:sfcapp/screens/stays/stay_edit_screen.dart';
import 'package:sfcapp/screens/stays/stay_listing_edit_screen.dart';
import 'package:sfcapp/screens/stays/stay_message_templates_screen.dart';
import 'package:sfcapp/screens/stays/stays_channels_screen.dart';
import 'package:sfcapp/screens/stays/stays_earnings_import_screen.dart';
import 'package:sfcapp/screens/stays/stays_guests_screen.dart';
import 'package:sfcapp/screens/stays/stays_hub_screen.dart';
import 'package:sfcapp/screens/stays/stays_settings_screen.dart';
import 'package:sfcapp/screens/stays/stays_setup_wizard_screen.dart';
import 'package:sfcapp/screens/stays/turnover_detail_screen.dart';
import 'package:sfcapp/services/stays/stays_repository.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';
import 'package:sfcapp/widgets/stays/stays_module_gate.dart';

// Every Stays page (spec §7.2), spread into app_router's ShellRoute with
// `...staysShellRoutes()`. Each page takes ?facilityId= and is "Page not
// found" without one. While the shortTermRentals flag is off every Stays
// URL is "Page not found", exactly as before these routes existed; with it
// on, StaysModuleGate decides whether the module is on for the facility.

Future<Stay?> _loadStay(String facilityId, String stayId) => FirestoreStaysRepository().getStay(facilityId, stayId);

Future<StayTask?> _loadTask(String facilityId, String taskId) => FirestoreStaysRepository().getTask(facilityId, taskId);

/// [loadStay] and [loadTask] are seams for tests; the app uses Firestore.
List<RouteBase> staysShellRoutes({
  LoadInFacility<Stay> loadStay = _loadStay,
  LoadInFacility<StayTask> loadTask = _loadTask,
}) {
  GoRoute page(
    String path,
    String name, {
    PermissionType permission = PermissionType.viewStays,
    bool allowWhenDisabled = false,
    required Widget Function(GoRouterState state, String facilityId) build,
  }) {
    return GoRoute(
      path: path,
      name: name,
      builder: (context, state) {
        final facilityId = state.uri.queryParameters['facilityId'] ?? '';
        if (facilityId.isEmpty) return NotFoundPage(state: state);
        return StaysRoutePage(
          state: state,
          facilityId: facilityId,
          permission: permission,
          allowWhenDisabled: allowWhenDisabled,
          child: build(state, facilityId),
        );
      },
    );
  }

  String? q(GoRouterState state, String key) {
    final value = state.uri.queryParameters[key];
    return value == null || value.isEmpty ? null : value;
  }

  return [
    page(
      AppRoute.stays,
      'stays',
      build: (state, facilityId) => StaysHubScreen(facilityId: facilityId, initialTab: q(state, 'tab') ?? 'today'),
    ),
    page(
      AppRoute.stayCreate,
      'stay-create',
      build: (state, facilityId) => StayEditScreen(
        facilityId: facilityId,
        listingId: q(state, 'listingId'),
        checkIn: q(state, 'checkIn'),
        checkOut: q(state, 'checkOut'),
        kind: q(state, 'kind') == null ? null : StayKind.fromWire(q(state, 'kind')),
      ),
    ),
    page(
      AppRoute.stayEdit,
      'stay-edit',
      build: (state, facilityId) => loadByIdPage<Stay>(
        state,
        idParam: 'stayId',
        load: loadStay,
        page: (stay, facilityId) => StayEditScreen(facilityId: facilityId, stay: stay),
      ),
    ),
    page(
      AppRoute.stayDetail,
      'stay-detail',
      build: (state, facilityId) => loadByIdPage<Stay>(
        state,
        idParam: 'stayId',
        load: loadStay,
        page: (stay, facilityId) => StayDetailScreen(facilityId: facilityId, stay: stay),
      ),
    ),
    page(
      AppRoute.turnoverDetail,
      'stay-turnover-detail',
      build: (state, facilityId) => loadByIdPage<StayTask>(
        state,
        idParam: 'taskId',
        load: loadTask,
        page: (task, facilityId) => TurnoverDetailScreen(facilityId: facilityId, task: task),
      ),
    ),
    page(
      AppRoute.stayListingEdit,
      'stay-listing-edit',
      permission: PermissionType.manageStays,
      build: (state, facilityId) => StayListingEditScreen(facilityId: facilityId, listingId: q(state, 'listingId')),
    ),
    page(
      AppRoute.staysSetup,
      'stays-setup',
      permission: PermissionType.manageStaySettings,
      allowWhenDisabled: true,
      build: (state, facilityId) => StaysSetupWizardScreen(facilityId: facilityId),
    ),
    page(
      AppRoute.staysChannels,
      'stays-channels',
      permission: PermissionType.manageStayChannels,
      build: (state, facilityId) => StaysChannelsScreen(facilityId: facilityId, listingId: q(state, 'listingId')),
    ),
    page(
      AppRoute.staysEarningsImport,
      'stays-earnings-import',
      permission: PermissionType.manageStayMoney,
      build: (state, facilityId) => StaysEarningsImportScreen(facilityId: facilityId),
    ),
    page(
      AppRoute.staysGuests,
      'stays-guests',
      permission: PermissionType.manageStays,
      build: (state, facilityId) => StaysGuestsScreen(facilityId: facilityId),
    ),
    page(
      AppRoute.staysTemplates,
      'stays-templates',
      permission: PermissionType.manageStays,
      build: (state, facilityId) => StayMessageTemplatesScreen(facilityId: facilityId),
    ),
    page(
      AppRoute.staysSettings,
      'stays-settings',
      permission: PermissionType.manageStaySettings,
      allowWhenDisabled: true,
      build: (state, facilityId) => StaysSettingsScreen(facilityId: facilityId),
    ),
  ];
}

/// A Stays page behind the flag, the caller's permission here, and the
/// module switch.
class StaysRoutePage extends ConsumerWidget {
  const StaysRoutePage({
    super.key,
    required this.state,
    required this.facilityId,
    required this.permission,
    required this.allowWhenDisabled,
    required this.child,
  });

  final GoRouterState state;
  final String facilityId;
  final PermissionType permission;
  final bool allowWhenDisabled;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (ref.watch(staysUiStateProvider)) {
      case StaysUiState.loading:
        return const Center(child: CircularProgressIndicator());
      case StaysUiState.off:
        // As if the route did not exist: the flag hides Stays completely.
        return NotFoundPage(state: state);
      case StaysUiState.on:
        break;
    }
    final allowed = ref.watch(stayPermissionProvider((facilityId, permission)));
    return allowed.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => StaysEmptyState.error(
        onRetry: () => ref.invalidate(stayPermissionProvider((facilityId, permission))),
      ),
      data: (ok) => ok
          ? StaysModuleGate(facilityId: facilityId, allowWhenDisabled: allowWhenDisabled, child: child)
          : const StaysEmptyState(
              icon: Icons.lock_outline,
              title: "You don't have access to this",
              subtitle: 'Ask the facility owner if you need it.',
            ),
    );
  }
}
