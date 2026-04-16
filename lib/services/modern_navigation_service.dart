import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/active_facility_provider.dart';
import '../router/app_route.dart';
import '../services/facility_service.dart';
import '../screens/home_screen_modern_helper.dart';
import 'debug_logger.dart';

/// Modern navigation service for sidebar routes
class ModernNavigationService {
  static void navigateToRoute(BuildContext context, String route) {
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H2',
      location: 'modern_navigation_service.dart:navigateToRoute',
      message: 'navigateToRoute called',
      data: {'route': route},
    );
    // #endregion

    final currentLocation =
        GoRouter.of(context).routeInformationProvider.value.uri.toString();

    // Normalize paths (ignore query) to avoid re-navigating to the same page
    final currentPath = Uri.tryParse(currentLocation)?.path ?? currentLocation;
    final targetPath = Uri.tryParse(route)?.path ?? route;
    final isSameOrChild =
        currentPath == targetPath || currentPath.startsWith(targetPath);

    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H2',
      location: 'modern_navigation_service.dart:navigateToRoute',
      message: 'Path comparison',
      data: {
        'currentPath': currentPath,
        'targetPath': targetPath,
        'isSameOrChild': isSameOrChild
      },
    );
    // #endregion

    // Special handling for messaging/access/units - these need facility selection even if already on the route
    final needsFacilitySelection = route == '/messaging' ||
        route == '/access' ||
        route == '/units/map' ||
        route == '/online-rentals';

    if (isSameOrChild && !needsFacilitySelection) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H2',
        location: 'modern_navigation_service.dart:navigateToRoute',
        message: 'Early return - same path and no facility selection needed',
        data: {},
      );
      // #endregion
      return;
    }

    void doNav() {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H2',
        location: 'modern_navigation_service.dart:doNav',
        message: 'Executing navigation',
        data: {'route': route},
      );
      // #endregion

      switch (route) {
        case '/dashboard':
          context.go('/dashboard');
          break;
        case '/facilities':
          context.go('/facilities');
          break;
        case '/tenants':
          context.go('/tenants');
          break;
        case '/units':
          context.go('/units');
          break;
        case '/units/map':
          _navigateToMapWithFacilitySelection(context);
          break;
        case '/access':
          _navigateToAccessWithFacilitySelection(context);
          break;
        case '/billing':
          context.go('/billing');
          break;
        case '/stripe-connect':
          context.go('/stripe-connect');
          break;
        case '/payments':
          context.go('/payments');
          break;
        case '/online-rentals':
          _navigateToOnlineRentalsWithFacilitySelection(context);
          break;
        case '/contracts':
          context.go('/contracts');
          break;
        case '/insurance':
          context.go('/insurance');
          break;
        case '/delinquency':
          context.go('/delinquency');
          break;
        case '/dnr':
          context.go('/dnr');
          break;
        case '/reports':
          context.go('/reports');
          break;
        case '/yield':
          context.go('/yield');
          break;
        case '/messaging':
          _navigateToCommsWithFacilitySelection(context);
          break;
        case AppRoute.retail:
          _navigateToRetailPosWithFacilitySelection(context);
          break;
        case '/reminders':
          context.go('/reminders');
          break;
        case '/settings':
          context.go('/settings');
          break;
        case '/calendar':
          context.go('/calendar');
          break;
        case AppRoute.managerOverlock:
          context.go(AppRoute.managerOverlock);
          break;
        case '/ai-assistant':
          context.go('/ai-assistant');
          break;
        case '/security':
          context.go('/security');
          break;
        default:
          break;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) doNav();
    });
  }

  // Helper method to navigate to map with facility selection
  static Future<void> _navigateToMapWithFacilitySelection(
      BuildContext context) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please sign in to access the map')),
        );
        return;
      }

      final facilities = await FacilityService.getUserFacilities();

      if (facilities.isEmpty) {
        _showNoFacilitiesDialog(context, featureName: 'unit map');
        return;
      }

      // If only one facility, use it directly
      if (facilities.length == 1) {
        context.go('/units/map?facilityId=${facilities.first.id}');
        return;
      }

      // Multiple facilities - show picker
      final selected = await showModalBottomSheet<FacilitySelectResult>(
        context: context,
        builder: (context) => FacilityPickerSheet(facilities: facilities),
      );

      if (selected != null) {
        context.go('/units/map?facilityId=${selected.id}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accessing map: $e')),
      );
    }
  }

  // Helper method to navigate to access with facility selection
  static Future<void> _navigateToAccessWithFacilitySelection(
      BuildContext context) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please sign in to access gate controls')),
        );
        return;
      }

      final facilities = await FacilityService.getUserFacilities();

      if (facilities.isEmpty) {
        _showNoFacilitiesDialog(context, featureName: 'gate access management');
        return;
      }

      // If only one facility, use it directly
      if (facilities.length == 1) {
        final facility = facilities.first;
        context.go(
            '/access?facilityId=${facility.id}&facilityName=${Uri.encodeComponent(facility.name)}');
        return;
      }

      // Multiple facilities - show picker
      final selected = await showModalBottomSheet<FacilitySelectResult>(
        context: context,
        builder: (context) => FacilityPickerSheet(facilities: facilities),
      );

      if (selected != null) {
        context.go(
            '/access?facilityId=${selected.id}&facilityName=${Uri.encodeComponent(selected.name)}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accessing gate access: $e')),
      );
    }
  }

  // Helper method to navigate to online rentals with facility selection
  static Future<void> _navigateToOnlineRentalsWithFacilitySelection(
      BuildContext context) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please sign in to access online rentals')),
        );
        return;
      }

      final facilities = await FacilityService.getUserFacilities();

      if (facilities.isEmpty) {
        _showNoFacilitiesDialog(context, featureName: 'online rentals');
        return;
      }

      if (facilities.length == 1) {
        context.go('/online-rentals?facilityId=${facilities.first.id}');
        return;
      }

      final selected = await showModalBottomSheet<FacilitySelectResult>(
        context: context,
        builder: (context) => FacilityPickerSheet(facilities: facilities),
      );

      if (selected != null) {
        context.go('/online-rentals?facilityId=${selected.id}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accessing online rentals: $e')),
      );
    }
  }

  // Helper method to navigate to comms with facility selection
  static Future<void> _navigateToCommsWithFacilitySelection(
      BuildContext context) async {
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H1',
      location:
          'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
      message: 'Facility selection started',
      data: {},
    );
    // #endregion
    try {
      final user = FirebaseAuth.instance.currentUser;
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H1',
        location:
            'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
        message: 'User check',
        data: {'hasUser': user != null, 'userId': user?.uid},
      );
      // #endregion
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please sign in to access messaging')),
        );
        return;
      }

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H1',
        location:
            'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
        message: 'Loading facilities',
        data: {},
      );
      // #endregion
      final facilities = await FacilityService.getUserFacilities();

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H1',
        location:
            'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
        message: 'Facilities loaded',
        data: {
          'facilityCount': facilities.length,
          'facilityIds': facilities.map((f) => f.id).toList()
        },
      );
      // #endregion

      if (facilities.isEmpty) {
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H1',
          location:
              'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
          message: 'No facilities found, showing dialog',
          data: {},
        );
        // #endregion
        _showNoFacilitiesDialog(context, featureName: 'messaging');
        return;
      }

      // If only one facility, use it directly
      if (facilities.length == 1) {
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H1',
          location:
              'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
          message: 'Single facility found, navigating directly',
          data: {'facilityId': facilities.first.id},
        );
        // #endregion
        context.go('/messaging?facilityId=${facilities.first.id}');
        return;
      }

      // Multiple facilities - show picker
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H1',
        location:
            'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
        message: 'Multiple facilities found, showing picker',
        data: {'facilityCount': facilities.length},
      );
      // #endregion
      final selected = await showModalBottomSheet<FacilitySelectResult>(
        context: context,
        builder: (context) => FacilityPickerSheet(facilities: facilities),
      );

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H1',
        location:
            'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
        message: 'Facility picker closed',
        data: {'selected': selected != null, 'selectedId': selected?.id},
      );
      // #endregion

      if (selected != null) {
        context.go('/messaging?facilityId=${selected.id}');
      }
    } catch (e, stackTrace) {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H1',
        location:
            'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
        message: 'Error during facility selection',
        data: {'error': e.toString(), 'stackTrace': stackTrace.toString()},
      );
      // #endregion
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accessing messaging: $e')),
      );
    }
  }

  /// Opens POS: uses active facility when valid, else single facility, else picker.
  static Future<void> _navigateToRetailPosWithFacilitySelection(
      BuildContext context) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please sign in to use retail / POS')),
        );
        return;
      }

      final facilities = await FacilityService.getUserFacilities();
      if (facilities.isEmpty) {
        _showNoFacilitiesDialog(context, featureName: 'retail / point of sale');
        return;
      }

      final facilityIds = facilities.map((f) => f.id).toSet();
      String? chosenId;

      try {
        final container = ProviderScope.containerOf(context, listen: false);
        final activeId =
            container.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
        if (activeId != null &&
            activeId.isNotEmpty &&
            facilityIds.contains(activeId)) {
          chosenId = activeId;
        }
      } catch (_) {
        // No ProviderScope in context — fall through to picker / single facility
      }

      chosenId ??= facilities.length == 1 ? facilities.first.id : null;

      if (chosenId == null) {
        final selected = await showModalBottomSheet<FacilitySelectResult>(
          context: context,
          builder: (context) => FacilityPickerSheet(facilities: facilities),
        );
        chosenId = selected?.id;
      }

      if (chosenId != null &&
          chosenId.isNotEmpty &&
          context.mounted) {
        context.go(
          Uri(
            path: AppRoute.pos,
            queryParameters: {'facilityId': chosenId},
          ).toString(),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error opening retail / POS: $e')),
      );
    }
  }

  // Helper to show no facilities dialog
  static void _showNoFacilitiesDialog(BuildContext context,
      {required String featureName}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No Facilities'),
        content:
            Text('You need to create a facility before using $featureName.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              context.go('/facilities/new');
            },
            child: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }
}
