import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/autopay_service.dart';
import 'active_facility_provider.dart';

/// Unread notification count for a facility (for sidebar badge).
final unreadFacilityNotificationsCountProvider = StreamProvider.family<int, String>((ref, facilityId) {
  return AutopayService.watchUnreadNotificationCount(facilityId);
});

/// Unread count for the active facility (convenience for shell/sidebar).
final activeFacilityUnreadNotificationsCountProvider = Provider<int>((ref) {
  final facilityId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
  if (facilityId == null) return 0;
  final async = ref.watch(unreadFacilityNotificationsCountProvider(facilityId));
  return async.whenOrNull(data: (d) => d) ?? 0;
});
