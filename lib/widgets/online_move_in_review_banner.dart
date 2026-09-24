import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/facility_notification_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/services/autopay_service.dart';

/// Unread online move-in reviews for a facility, newest first.
final unreadOnlineMoveInReviewsProvider = StreamProvider.autoDispose
    .family<List<FacilityNotificationModel>, String>((ref, facilityId) {
  return AutopayService.watchFacilityNotificationsOfType(
    facilityId,
    FacilityNotificationType.onlineMoveInReview.value,
  ).map((snap) => unreadNewestFirst(snap.docs));
});

/// The unread notifications among [docs], newest first.
List<FacilityNotificationModel> unreadNewestFirst(
    Iterable<DocumentSnapshot> docs) {
  return docs
      .map(FacilityNotificationModel.fromFirestore)
      .where((n) => n.isUnread)
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}

/// Marks one facility notification read; tests replace it.
final markFacilityNotificationReadProvider =
    Provider<Future<void> Function(String facilityId, String notificationId)>(
  (ref) => (facilityId, notificationId) => AutopayService.markNotificationRead(
        facilityId: facilityId,
        notificationId: notificationId,
      ),
);

/// Shown across the top of every screen while an online move-in needs the
/// owner: a renter who had already paid online was moved into a unit taken
/// off online rental after they reserved it (unlisted, archived or set to
/// internal use), or a renter paid online and could not be moved in (the
/// unit was rented meanwhile, the reservation ended), so the payment needs
/// a refund.
///
/// completePublicMoveIn used to refuse the first renter after Checkout had
/// charged them. It now completes the move-in and leaves this alert, as the
/// paid-checkout trigger does for the second, and it stays until someone at
/// the facility marks it reviewed. The facility's Notifications list is not
/// on any screen, so this banner is where the owner sees it.
class OnlineMoveInReviewBanner extends ConsumerStatefulWidget {
  const OnlineMoveInReviewBanner({super.key});

  @override
  ConsumerState<OnlineMoveInReviewBanner> createState() =>
      _OnlineMoveInReviewBannerState();
}

class _OnlineMoveInReviewBannerState
    extends ConsumerState<OnlineMoveInReviewBanner> {
  final Set<String> _marking = <String>{};

  Future<void> _markReviewed(String facilityId, String notificationId) async {
    setState(() => _marking.add(notificationId));
    try {
      await ref.read(markFacilityNotificationReadProvider)(
          facilityId, notificationId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not mark it reviewed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _marking.remove(notificationId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final facilityId =
        ref.watch(activeFacilityIdProvider).whenOrNull(data: (id) => id);
    if (facilityId == null || facilityId.isEmpty || facilityId == 'all') {
      return const SizedBox.shrink();
    }
    final reviews = ref
            .watch(unreadOnlineMoveInReviewsProvider(facilityId))
            .whenOrNull(data: (list) => list) ??
        const <FacilityNotificationModel>[];
    if (reviews.isEmpty) return const SizedBox.shrink();

    return Material(
      color: const Color(0xFF8A4B00),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final review in reviews)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.white, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        review.message,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: _marking.contains(review.id)
                          ? null
                          : () => _markReviewed(facilityId, review.id),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.white24,
                      ),
                      child: const Text('Mark reviewed'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
