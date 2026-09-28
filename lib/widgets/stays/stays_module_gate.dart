import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Shows [child] only when Stays is on for [facilityId] (spec §7.1): a
/// spinner while the flag or controls load, an error with Retry when they
/// fail, and a disabled page (with "Set up Stays" for an owner or manager
/// when the platform allows the facility) when the module is off. Setup and
/// settings pass [allowWhenDisabled] so the module can be turned on.
class StaysModuleGate extends ConsumerWidget {
  const StaysModuleGate({
    super.key,
    required this.facilityId,
    this.allowWhenDisabled = false,
    required this.child,
  });

  final String facilityId;
  final bool allowWhenDisabled;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (ref.watch(staysUiStateProvider)) {
      case StaysUiState.loading:
        return const Center(child: CircularProgressIndicator());
      case StaysUiState.off:
        return const StaysEmptyState(
          icon: Icons.block,
          title: 'Stays is not available',
          subtitle: 'Short-term rentals are not switched on for this account.',
        );
      case StaysUiState.on:
        break;
    }
    return ref.watch(stayControlsProvider(facilityId)).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => StaysEmptyState.error(
            title: "Couldn't load Stays",
            onRetry: () => ref.invalidate(stayControlsProvider(facilityId)),
          ),
          data: (controls) {
            if (controls.moduleEnabled == true || allowWhenDisabled) return child;
            return StaysDisabledPage(facilityId: facilityId);
          },
        );
  }
}

/// Stays is off for this facility. Owners and managers of a facility the
/// platform allows get a way to set it up.
class StaysDisabledPage extends ConsumerWidget {
  const StaysDisabledPage({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final availability = ref.watch(staysAvailabilityProvider(facilityId)).value;
    final canSetUp = ref.watch(stayPermissionProvider((facilityId, PermissionType.manageStaySettings))).value ?? false;
    if (availability?.paused == true) {
      return const StaysEmptyState(
        icon: Icons.pause_circle_outline,
        title: 'Stays is paused',
        subtitle: 'Bookings, calendars and syncing are paused for maintenance. Nothing has been changed.',
      );
    }
    final offerSetup = canSetUp && availability?.allowed == true;
    return StaysEmptyState(
      icon: Icons.night_shelter_outlined,
      title: 'Stays is not turned on',
      subtitle: offerSetup
          ? 'Set up your Airbnbs, rentals and RV nights to start using Stays.'
          : 'Stays is not turned on for this facility.',
      actionLabel: offerSetup ? 'Set up Stays' : null,
      onAction: offerSetup ? () => context.go(AppRoute.staysSetupFor(facilityId)) : null,
    );
  }
}
