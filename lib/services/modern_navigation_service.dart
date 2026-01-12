import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';

import '../services/facility_service.dart';
import '../screens/home_screen_modern_helper.dart';

/// Modern navigation service for sidebar routes
class ModernNavigationService {
  static void navigateToRoute(BuildContext context, String route) {
    final currentLocation =
        GoRouter.of(context).routeInformationProvider.value.location ?? '';

    // Normalize paths (ignore query) to avoid re-navigating to the same page
    final currentPath = Uri.tryParse(currentLocation)?.path ?? currentLocation;
    final targetPath = Uri.tryParse(route)?.path ?? route;
    final isSameOrChild = currentPath == targetPath || currentPath.startsWith(targetPath);
    if (isSameOrChild) {
      return;
    }

    void doNav() {
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
        case '/units/map':
          _navigateToMapWithFacilitySelection(context);
          break;
        case '/access':
          _navigateToAccessWithFacilitySelection(context);
          break;
        case '/billing':
          context.go('/billing');
          break;
        case '/payments':
          context.go('/payments');
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
        case '/reminders':
          context.go('/reminders');
          break;
        case '/settings':
          context.go('/settings');
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
  static Future<void> _navigateToMapWithFacilitySelection(BuildContext context) async {
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
  static Future<void> _navigateToAccessWithFacilitySelection(BuildContext context) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please sign in to access gate controls')),
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
        context.go('/access?facilityId=${facility.id}&facilityName=${Uri.encodeComponent(facility.name)}');
        return;
      }

      // Multiple facilities - show picker
      final selected = await showModalBottomSheet<FacilitySelectResult>(
        context: context,
        builder: (context) => FacilityPickerSheet(facilities: facilities),
      );

      if (selected != null) {
        context.go('/access?facilityId=${selected.id}&facilityName=${Uri.encodeComponent(selected.name)}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accessing gate access: $e')),
      );
    }
  }

  // Helper method to navigate to comms with facility selection
  static Future<void> _navigateToCommsWithFacilitySelection(BuildContext context) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please sign in to access messaging')),
        );
        return;
      }

      final facilities = await FacilityService.getUserFacilities();
      
      if (facilities.isEmpty) {
        _showNoFacilitiesDialog(context, featureName: 'messaging');
        return;
      }

      // If only one facility, use it directly
      if (facilities.length == 1) {
        context.go('/messaging?facilityId=${facilities.first.id}');
        return;
      }

      // Multiple facilities - show picker
      final selected = await showModalBottomSheet<FacilitySelectResult>(
        context: context,
        builder: (context) => FacilityPickerSheet(facilities: facilities),
      );

      if (selected != null) {
        context.go('/messaging?facilityId=${selected.id}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error accessing messaging: $e')),
      );
    }
  }

  // Helper to show no facilities dialog
  static void _showNoFacilitiesDialog(BuildContext context, {required String featureName}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No Facilities'),
        content: Text('You need to create a facility before using $featureName.'),
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

