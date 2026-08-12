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

    // Normalize paths (ignore query) to avoid re-navigating to the same page.
    // Use exact path equality only: `/units/map` must not be treated as `/units`
    // (prefix matching would block sidebar navigation from map to unit list).
    String normalizePath(String p) {
      if (p.length > 1 && p.endsWith('/')) {
        return p.substring(0, p.length - 1);
      }
      return p;
    }

    final currentPath = normalizePath(
        Uri.tryParse(currentLocation)?.path ?? currentLocation);
    final targetPath =
        normalizePath(Uri.tryParse(route)?.path ?? route);
    final isSameLocation = currentPath == targetPath;

    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H2',
      location: 'modern_navigation_service.dart:navigateToRoute',
      message: 'Path comparison',
      data: {
        'currentPath': currentPath,
        'targetPath': targetPath,
        'isSameLocation': isSameLocation
      },
    );
    // #endregion

    // Special handling for messaging/access/units - these need facility selection even if already on the route
    final needsFacilitySelection = route == '/messaging' ||
        route == '/access' ||
        route == '/units/map' ||
        route == '/online-rentals' ||
        route == AppRoute.websiteSetup;

    if (isSameLocation && !needsFacilitySelection) {
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
          context.go(AppRoute.paymentsInvoices);
          break;
        case '/stripe-connect':
          context.go('/stripe-connect');
          break;
        case '/payments':
          context.go('/payments');
          break;
        case '/online-rentals':
          _navigateToWebsiteSetupWithFacilitySelection(context);
          break;
        case AppRoute.websiteSetup:
          _navigateToWebsiteSetupWithFacilitySelection(context);
          break;
        case '/contracts':
          context.go('/contracts');
          break;
        case '/insurance':
          context.go('/insurance');
          break;
        case '/delinquency':
          context.go(AppRoute.paymentsPastDue);
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
          context.go(AppRoute.paymentsReminders);
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

  /// Resolves which facility to use for a sidebar destination that needs one:
  /// prefer the already-active facility (so switching screens doesn't force a
  /// re-pick), fall back to the single facility, else prompt with the picker.
  ///
  /// Whenever the resolved facility differs from what's already active, it's
  /// written back to [activeFacilityIdProvider] so the top-bar facility
  /// selector stays in sync with what the destination screen is showing.
  static Future<String?> _resolveFacilityId(
      BuildContext context, List<dynamic> facilities) async {
    final facilityIds = facilities.map((f) => f.id as String).toSet();

    String? activeId;
    ProviderContainer? container;
    try {
      container = ProviderScope.containerOf(context, listen: false);
      activeId =
          container.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
      if (activeId != null &&
          activeId.isNotEmpty &&
          facilityIds.contains(activeId)) {
        return activeId;
      }
    } catch (_) {
      // No ProviderScope in context — fall through to picker / single facility
    }

    String? resolvedId;
    if (facilities.length == 1) {
      resolvedId = facilities.first.id as String;
    } else {
      if (!context.mounted) return null;
      final selected = await showModalBottomSheet<FacilitySelectResult>(
        context: context,
        builder: (context) => FacilityPickerSheet(facilities: facilities.cast()),
      );
      resolvedId = selected?.id;
    }

    if (resolvedId != null && resolvedId != activeId && container != null) {
      try {
        await container
            .read(activeFacilityIdProvider.notifier)
            .setActiveFacilityId(resolvedId);
      } catch (_) {
        // Best-effort sync — navigation should proceed either way.
      }
    }

    return resolvedId;
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

      if (!context.mounted) return;
      final facilityId = await _resolveFacilityId(context, facilities);
      if (facilityId != null && context.mounted) {
        context.go('/units/map?facilityId=$facilityId');
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

      if (!context.mounted) return;
      final facilityId = await _resolveFacilityId(context, facilities);
      if (facilityId != null && context.mounted) {
        final facility = facilities.firstWhere((f) => f.id == facilityId);
        context.go(
            '/access?facilityId=${facility.id}&facilityName=${Uri.encodeComponent(facility.name)}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accessing gate access: $e')),
      );
    }
  }

  // Helper method to navigate to website setup with facility selection.
  // Also used as compatibility path for old online-rentals links.
  static Future<void> _navigateToWebsiteSetupWithFacilitySelection(
      BuildContext context) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please sign in to access website setup')),
        );
        return;
      }

      final facilities = await FacilityService.getUserFacilities();

      if (facilities.isEmpty) {
        _showNoFacilitiesDialog(context, featureName: 'website setup');
        return;
      }

      if (!context.mounted) return;
      final facilityId = await _resolveFacilityId(context, facilities);
      if (facilityId != null && context.mounted) {
        context.go('${AppRoute.websiteSetup}?facilityId=$facilityId');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accessing website setup: $e')),
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

      if (!context.mounted) return;
      final facilityId = await _resolveFacilityId(context, facilities);

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H1',
        location:
            'modern_navigation_service.dart:_navigateToCommsWithFacilitySelection',
        message: 'Facility resolved',
        data: {'facilityId': facilityId},
      );
      // #endregion

      if (facilityId != null && context.mounted) {
        context.go('/messaging?facilityId=$facilityId');
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

      if (!context.mounted) return;
      final chosenId = await _resolveFacilityId(context, facilities);

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
