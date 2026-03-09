import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/calendar_event_model.dart';
import '../models/contract_model.dart';
import '../router/app_route.dart';

/// Aggregates calendar events from all facility subsystems.
/// Events are derived on-the-fly from existing Firestore collections —
/// no separate calendar collection is required.
class CalendarService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Fetches all calendar events for a facility within [start]..[end].
  /// Runs all sub-queries in parallel for performance.
  static Future<List<CalendarEvent>> getEventsForRange({
    required String facilityId,
    required DateTime start,
    required DateTime end,
  }) async {
    final results = await Future.wait([
      _getTenantLifecycleEvents(facilityId, start, end),
      _getContractEvents(facilityId, start, end),
      _getLienAndAuctionEvents(facilityId, start, end),
      _getInsuranceEvents(facilityId, start, end),
      _getOverlockEvents(facilityId, start, end),
      _getMaintenanceEvents(facilityId, start, end),
    ]);

    final all = results.expand((list) => list).toList();
    all.sort((a, b) => a.date.compareTo(b.date));
    return all;
  }

  /// Returns events grouped by normalised date (midnight) for use with
  /// table_calendar's eventLoader.
  static Map<DateTime, List<CalendarEvent>> groupByDay(
      List<CalendarEvent> events) {
    final map = <DateTime, List<CalendarEvent>>{};
    for (final e in events) {
      final key = _dayKey(e.date);
      map.putIfAbsent(key, () => []).add(e);
    }
    return map;
  }

  // ── Tenant lifecycle (move-in, move-out, reservation) ─────────────────────

  static Future<List<CalendarEvent>> _getTenantLifecycleEvents(
    String facilityId,
    DateTime start,
    DateTime end,
  ) async {
    final events = <CalendarEvent>[];

    // Active tenants: move-in dates and scheduled move-out dates
    final tenantsSnap = await _db
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .where('isActive', isEqualTo: true)
        .get();

    for (final doc in tenantsSnap.docs) {
      final data = doc.data();
      final tenantId = doc.id;
      final tenantName = data['name'] as String? ?? 'Unknown Tenant';
      final unitNumber = data['unitNumber'] as String? ?? '';
      final unitId = data['unitId'] as String? ?? '';

      // Move-in
      final moveInTs = data['moveInDate'] as Timestamp?;
      if (moveInTs != null) {
        final moveIn = moveInTs.toDate();
        if (_inRange(moveIn, start, end)) {
          events.add(CalendarEvent(
            id: 'movein_${doc.id}',
            facilityId: facilityId,
            title: 'Move-In: $tenantName',
            subtitle: unitNumber.isNotEmpty ? 'Unit $unitNumber' : null,
            type: CalendarEventType.moveIn,
            priority: CalendarEventPriority.normal,
            date: moveIn,
            tenantId: tenantId,
            tenantName: tenantName,
            unitId: unitId,
            unitNumber: unitNumber,
            actionRoute: AppRoute.tenantDetail,
            actionParams: {
              'tenantId': tenantId,
              'facilityId': facilityId,
            },
          ));
        }
      }

      // Scheduled move-out
      final moveOutTs = data['scheduledMoveOutDate'] as Timestamp?;
      if (moveOutTs != null) {
        final moveOut = moveOutTs.toDate();
        if (_inRange(moveOut, start, end)) {
          events.add(CalendarEvent(
            id: 'moveout_${doc.id}',
            facilityId: facilityId,
            title: 'Move-Out: $tenantName',
            subtitle: unitNumber.isNotEmpty ? 'Unit $unitNumber' : null,
            type: CalendarEventType.moveOut,
            priority: CalendarEventPriority.normal,
            date: moveOut,
            tenantId: tenantId,
            tenantName: tenantName,
            unitId: unitId,
            unitNumber: unitNumber,
            actionRoute: AppRoute.tenantDetail,
            actionParams: {
              'tenantId': tenantId,
              'facilityId': facilityId,
            },
          ));
        }
      }

      // Billing due date (nextBillingDate / nextDueDate)
      final billingTs = (data['nextBillingDate'] ?? data['nextDueDate']) as Timestamp?;
      if (billingTs != null) {
        final billingDate = billingTs.toDate();
        if (_inRange(billingDate, start, end)) {
          final rate = (data['monthlyRate'] as num?)?.toDouble();
          events.add(CalendarEvent(
            id: 'billing_${doc.id}',
            facilityId: facilityId,
            title: 'Rent Due: $tenantName',
            subtitle: unitNumber.isNotEmpty ? 'Unit $unitNumber' : null,
            type: CalendarEventType.billingDue,
            priority: CalendarEventPriority.normal,
            date: billingDate,
            tenantId: tenantId,
            tenantName: tenantName,
            unitId: unitId,
            unitNumber: unitNumber,
            amount: rate,
            actionRoute: AppRoute.tenantDetail,
            actionParams: {
              'tenantId': tenantId,
              'facilityId': facilityId,
            },
          ));
        }
      }
    }

    // Reservations
    try {
      final reservationsSnap = await _db
          .collection('facilities')
          .doc(facilityId)
          .collection('reservations')
          .where('status', whereIn: ['pending', 'confirmed'])
          .get();

      for (final doc in reservationsSnap.docs) {
        final data = doc.data();
        final moveInTs = data['moveInDate'] as Timestamp?;
        if (moveInTs == null) continue;
        final moveIn = moveInTs.toDate();
        if (!_inRange(moveIn, start, end)) continue;

        final name = data['name'] as String? ?? data['email'] as String? ?? 'Reservation';
        final unitNumber = data['unitNumber'] as String? ?? '';
        events.add(CalendarEvent(
          id: 'reservation_${doc.id}',
          facilityId: facilityId,
          title: 'Reservation: $name',
          subtitle: unitNumber.isNotEmpty ? 'Unit $unitNumber' : null,
          type: CalendarEventType.reservation,
          priority: CalendarEventPriority.low,
          date: moveIn,
          unitNumber: unitNumber,
        ));
      }
    } catch (_) {
      // reservations collection may not exist on all facilities
    }

    return events;
  }

  // ── Contracts ──────────────────────────────────────────────────────────────

  static Future<List<CalendarEvent>> _getContractEvents(
    String facilityId,
    DateTime start,
    DateTime end,
  ) async {
    final events = <CalendarEvent>[];

    // Warn 30 days before expiry
    final warnStart = start.subtract(const Duration(days: 30));

    final contractsSnap = await _db
        .collection('facilities')
        .doc(facilityId)
        .collection('contracts')
        .where('isActive', isEqualTo: true)
        .where('status', whereIn: ['draft', 'sent', 'signed'])
        .get();

    for (final doc in contractsSnap.docs) {
      final data = doc.data();
      final contractId = doc.id;
      final tenantId = data['tenantId'] as String? ?? '';
      final title = data['title'] as String? ?? 'Contract';

      // Signed date
      final signedTs = data['signedAt'] as Timestamp?;
      if (signedTs != null) {
        final signed = signedTs.toDate();
        if (_inRange(signed, start, end)) {
          events.add(CalendarEvent(
            id: 'contract_signed_$contractId',
            facilityId: facilityId,
            title: 'Contract Signed: $title',
            type: CalendarEventType.contractSigned,
            priority: CalendarEventPriority.low,
            date: signed,
            tenantId: tenantId,
            contractId: contractId,
            isCompleted: true,
            actionRoute: AppRoute.contractDetail,
            actionParams: {'contractId': contractId, 'facilityId': facilityId},
          ));
        }
      }

      // Expiry warning
      final expiresTs = data['expiresAt'] as Timestamp?;
      if (expiresTs != null) {
        final expires = expiresTs.toDate();
        if (_inRange(expires, warnStart, end)) {
          final daysLeft = expires.difference(DateTime.now()).inDays;
          events.add(CalendarEvent(
            id: 'contract_expiring_$contractId',
            facilityId: facilityId,
            title: 'Contract Expiring: $title',
            subtitle: daysLeft > 0 ? 'Expires in $daysLeft days' : 'Expired',
            type: CalendarEventType.contractExpiring,
            priority: daysLeft <= 7
                ? CalendarEventPriority.high
                : CalendarEventPriority.normal,
            date: expires,
            tenantId: tenantId,
            contractId: contractId,
            actionRoute: AppRoute.contractDetail,
            actionParams: {'contractId': contractId, 'facilityId': facilityId},
          ));
        }
      }
    }

    return events;
  }

  // ── Liens & auctions ───────────────────────────────────────────────────────

  static Future<List<CalendarEvent>> _getLienAndAuctionEvents(
    String facilityId,
    DateTime start,
    DateTime end,
  ) async {
    final events = <CalendarEvent>[];

    final liensSnap = await _db
        .collection('facilities')
        .doc(facilityId)
        .collection('liens')
        .where('isActive', isEqualTo: true)
        .get();

    for (final doc in liensSnap.docs) {
      final data = doc.data();
      final lienId = doc.id;
      final tenantId = data['tenantId'] as String? ?? '';
      final unitId = data['unitId'] as String? ?? '';
      final totalAmount = (data['totalAmount'] as num?)?.toDouble();

      void addLienEvent({
        required String idSuffix,
        required String title,
        required CalendarEventType type,
        required DateTime date,
        CalendarEventPriority priority = CalendarEventPriority.high,
      }) {
        if (_inRange(date, start, end)) {
          events.add(CalendarEvent(
            id: 'lien_${idSuffix}_$lienId',
            facilityId: facilityId,
            title: title,
            type: type,
            priority: priority,
            date: date,
            tenantId: tenantId,
            unitId: unitId,
            lienId: lienId,
            amount: totalAmount,
            actionRoute: AppRoute.lienDetail,
            actionParams: {'lienId': lienId, 'facilityId': facilityId},
          ));
        }
      }

      final noticeSentTs = data['noticeSentDate'] as Timestamp?;
      if (noticeSentTs != null) {
        addLienEvent(
          idSuffix: 'notice',
          title: 'Lien Notice Sent',
          type: CalendarEventType.delinquencyNotice,
          date: noticeSentTs.toDate(),
          priority: CalendarEventPriority.high,
        );
      }

      final lienFiledTs = data['lienFiledDate'] as Timestamp?;
      if (lienFiledTs != null) {
        addLienEvent(
          idSuffix: 'filed',
          title: 'Lien Filed',
          type: CalendarEventType.lienFiled,
          date: lienFiledTs.toDate(),
          priority: CalendarEventPriority.critical,
        );
      }

      final auctionTs = data['auctionScheduledDate'] as Timestamp?;
      if (auctionTs != null) {
        addLienEvent(
          idSuffix: 'auction',
          title: 'Auction Scheduled',
          type: CalendarEventType.auctionScheduled,
          date: auctionTs.toDate(),
          priority: CalendarEventPriority.critical,
        );
      }

      final auctionCompleteTs = data['auctionCompleteDate'] as Timestamp?;
      if (auctionCompleteTs != null) {
        addLienEvent(
          idSuffix: 'auction_complete',
          title: 'Auction Complete',
          type: CalendarEventType.auctionComplete,
          date: auctionCompleteTs.toDate(),
          priority: CalendarEventPriority.normal,
        );
      }
    }

    return events;
  }

  // ── Insurance expirations ──────────────────────────────────────────────────

  static Future<List<CalendarEvent>> _getInsuranceEvents(
    String facilityId,
    DateTime start,
    DateTime end,
  ) async {
    final events = <CalendarEvent>[];

    // Warn up to 45 days ahead
    final warnEnd = end.add(const Duration(days: 45));

    try {
      final insuranceSnap = await _db
          .collection('facilities')
          .doc(facilityId)
          .collection('tenant_insurance')
          .where('isActive', isEqualTo: true)
          .get();

      for (final doc in insuranceSnap.docs) {
        final data = doc.data();
        final expiresTs = data['expiresAt'] as Timestamp?;
        if (expiresTs == null) continue;
        final expires = expiresTs.toDate();
        if (!_inRange(expires, start, warnEnd)) continue;

        final tenantId = data['tenantId'] as String? ?? '';
        final tenantName = data['tenantName'] as String? ?? 'Tenant';
        final daysLeft = expires.difference(DateTime.now()).inDays;

        events.add(CalendarEvent(
          id: 'insurance_${doc.id}',
          facilityId: facilityId,
          title: 'Insurance Expiring: $tenantName',
          subtitle: daysLeft > 0 ? 'Expires in $daysLeft days' : 'Expired',
          type: CalendarEventType.insuranceExpiring,
          priority: daysLeft <= 7
              ? CalendarEventPriority.high
              : CalendarEventPriority.normal,
          date: expires,
          tenantId: tenantId,
          tenantName: tenantName,
          actionRoute: AppRoute.insurance,
        ));
      }
    } catch (_) {
      // tenant_insurance collection may not exist
    }

    return events;
  }

  // ── Overlock events ────────────────────────────────────────────────────────

  static Future<List<CalendarEvent>> _getOverlockEvents(
    String facilityId,
    DateTime start,
    DateTime end,
  ) async {
    final events = <CalendarEvent>[];

    try {
      final overlockSnap = await _db
          .collection('facilities')
          .doc(facilityId)
          .collection('overlocks')
          .where('isActive', isEqualTo: true)
          .get();

      for (final doc in overlockSnap.docs) {
        final data = doc.data();
        final scheduledTs = data['scheduledDate'] as Timestamp?;
        if (scheduledTs == null) continue;
        final scheduled = scheduledTs.toDate();
        if (!_inRange(scheduled, start, end)) continue;

        final tenantId = data['tenantId'] as String? ?? '';
        final tenantName = data['tenantName'] as String? ?? 'Tenant';
        final unitNumber = data['unitNumber'] as String? ?? '';

        events.add(CalendarEvent(
          id: 'overlock_${doc.id}',
          facilityId: facilityId,
          title: 'Overlock: $tenantName',
          subtitle: unitNumber.isNotEmpty ? 'Unit $unitNumber' : null,
          type: CalendarEventType.overlockScheduled,
          priority: CalendarEventPriority.high,
          date: scheduled,
          tenantId: tenantId,
          tenantName: tenantName,
          unitNumber: unitNumber,
          actionRoute: AppRoute.managerOverlock,
        ));
      }
    } catch (_) {
      // overlocks collection may not exist
    }

    return events;
  }

  // ── Maintenance windows ────────────────────────────────────────────────────

  static Future<List<CalendarEvent>> _getMaintenanceEvents(
    String facilityId,
    DateTime start,
    DateTime end,
  ) async {
    final events = <CalendarEvent>[];

    try {
      // Units in maintenance status with a scheduled return-to-service date
      final unitsSnap = await _db
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .where('status', isEqualTo: 'maintenance')
          .get();

      for (final doc in unitsSnap.docs) {
        final data = doc.data();
        final returnTs = data['maintenanceEndDate'] as Timestamp?;
        if (returnTs == null) continue;
        final returnDate = returnTs.toDate();
        if (!_inRange(returnDate, start, end)) continue;

        final unitNumber = data['unitNumber'] as String? ?? doc.id;

        events.add(CalendarEvent(
          id: 'maintenance_${doc.id}',
          facilityId: facilityId,
          title: 'Maintenance: Unit $unitNumber',
          subtitle: 'Scheduled return to service',
          type: CalendarEventType.maintenanceWindow,
          priority: CalendarEventPriority.low,
          date: returnDate,
          unitId: doc.id,
          unitNumber: unitNumber,
          actionRoute: AppRoute.units,
        ));
      }
    } catch (_) {
      // units collection may not exist
    }

    return events;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static bool _inRange(DateTime date, DateTime start, DateTime end) {
    return !date.isBefore(start) && !date.isAfter(end);
  }

  static DateTime _dayKey(DateTime date) =>
      DateTime(date.year, date.month, date.day);
}
