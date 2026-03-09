import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/permission_model.dart';
import '../services/permission_service.dart';
import '../providers/active_facility_provider.dart';

/// Widget that gates content based on permissions
/// If user doesn't have permission, shows nothing or a placeholder
class PermissionGate extends ConsumerWidget {
  final PermissionType permission;
  final Widget child;
  final Widget? fallback; // Shown if permission is denied
  final bool hideIfDenied; // If true, shows nothing; if false, shows fallback

  const PermissionGate({
    super.key,
    required this.permission,
    required this.child,
    this.fallback,
    this.hideIfDenied = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facilityId = ref.watch(activeFacilityIdProvider).value;

    return FutureBuilder<PermissionCheck>(
      future: PermissionService.hasPermission(
        facilityId: facilityId,
        permission: permission,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink(); // Or loading indicator
        }

        final hasPermission = snapshot.data?.hasPermission ?? false;

        if (hasPermission) {
          return child;
        }

        if (hideIfDenied) {
          return const SizedBox.shrink();
        }

        return fallback ?? const SizedBox.shrink();
      },
    );
  }
}

/// Widget that gates a button/action based on permissions
/// Disables the button if permission is denied
class PermissionButton extends ConsumerWidget {
  final PermissionType permission;
  final Widget child;
  final VoidCallback? onPressed;
  final bool Function(bool hasPermission)? onPressedOverride; // Custom handler

  const PermissionButton({
    super.key,
    required this.permission,
    required this.child,
    this.onPressed,
    this.onPressedOverride,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facilityId = ref.watch(activeFacilityIdProvider).value;

    return FutureBuilder<PermissionCheck>(
      future: PermissionService.hasPermission(
        facilityId: facilityId,
        permission: permission,
      ),
      builder: (context, snapshot) {
        final hasPermission = snapshot.data?.hasPermission ?? false;
        final isEnabled = hasPermission && onPressed != null;

        if (onPressedOverride != null) {
          return child; // Let parent handle the logic
        }

        return Opacity(
          opacity: isEnabled ? 1.0 : 0.5,
          child: IgnorePointer(
            ignoring: !isEnabled,
            child: child,
          ),
        );
      },
    );
  }
}

/// Provider for checking if fine-grained RBAC is enabled
final fineGrainedRBACEnabledProvider = FutureProvider.family<bool, String?>((ref, facilityId) async {
  // This would check the feature flag
  // For now, we'll assume it's enabled if the permission check works
  // In production, this would check appConfig/fineGrainedRBAC
  return true; // Placeholder - will be implemented with feature flag
});

/// Helper function to check permission (for use in widgets)
Future<bool> checkPermission({
  required PermissionType permission,
  String? facilityId,
}) async {
  final check = await PermissionService.hasPermission(
    facilityId: facilityId,
    permission: permission,
  );
  return check.hasPermission;
}
