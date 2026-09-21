import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/support_access_provider.dart';
import 'package:sfcapp/services/support_access_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Shown across the top of every screen while a super admin is working inside
/// a facility they do not own.
///
/// It is deliberately loud and always present. Support access is easy to start
/// and easy to forget, and forgetting it means later edits look like the owner
/// made them.
class SupportSessionBanner extends ConsumerStatefulWidget {
  const SupportSessionBanner({super.key});

  @override
  ConsumerState<SupportSessionBanner> createState() =>
      _SupportSessionBannerState();
}

class _SupportSessionBannerState extends ConsumerState<SupportSessionBanner> {
  bool _ending = false;

  Future<void> _end(FacilityModel facility) async {
    setState(() => _ending = true);
    try {
      await SupportAccessService.end(
        facilityId: facility.id,
        facilityName: facility.name,
      );
      ref.invalidate(supportSessionFacilityProvider);
      ref.invalidate(activeFacilityIdProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Support access to ${facility.name} ended.'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not end support access: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _ending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(supportSessionFacilityProvider);
    final facility = session.asData?.value;
    if (facility == null) return const SizedBox.shrink();

    return Material(
      color: const Color(0xFF7A3E00),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.support_agent, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Support session: you are working inside ${facility.name}, '
                'which you do not own. Your changes are logged under your own name.',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: _ending ? null : () => _end(facility),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white24,
              ),
              child: _ending
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('End session'),
            ),
          ],
        ),
      ),
    );
  }
}
